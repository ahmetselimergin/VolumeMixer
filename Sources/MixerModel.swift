import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

struct AppEntry: Identifiable, Equatable {
    let id: pid_t
    let key: String
    let name: String
    let icon: NSImage
    let tint: Color
    let isPlaying: Bool

    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.key == b.key && a.name == b.name && a.isPlaying == b.isPlaying
    }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var volumes: [String: Float]
    @Published private(set) var mutes: [String: Bool]
    @Published private(set) var errors: [String: String] = [:]

    @Published private(set) var deviceName = ""
    @Published private(set) var hasSystemVolume = false
    @Published private(set) var systemVolume: Float = 1
    @Published private(set) var systemMuted = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// How long an app keeps its tap after it stops playing (so audio I/O doesn't block sleep).
    private let lingerSeconds: TimeInterval = 15

    private struct Group {
        let app: NSRunningApplication
        let key: String
        var processObjects: [AudioObjectID] = []
        var isPlaying = false
    }

    private var groups: [pid_t: Group] = [:]
    private var lastPlaying: [pid_t: Date] = [:]
    private var taps: [pid_t: AppTap] = [:]
    private var tints: [String: Color] = [:]
    private var outputDevice = AudioObjectID.defaultOutputDevice
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        volumes = defaults.dictionary(forKey: "volumes") as? [String: Float] ?? [:]
        mutes = defaults.dictionary(forKey: "mutes") as? [String: Bool] ?? [:]

        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(.system, &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputDeviceChanged() }
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.taps.removeAll() }
        }
    }

    // MARK: - User actions

    func volume(for key: String) -> Float { volumes[key] ?? 1 }
    func isMuted(_ key: String) -> Bool { mutes[key] ?? false }

    func setVolume(_ value: Float, for key: String) {
        volumes[key] = value
        if value > 0 { mutes[key] = false }
        save(key)
    }

    func toggleMute(_ key: String) {
        mutes[key] = !isMuted(key)
        save(key)
    }

    func reset(_ key: String) {
        volumes[key] = nil
        mutes[key] = nil
        save(key)
    }

    func setSystemVolume(_ value: Float) {
        let output = SystemOutput(device: outputDevice)
        output.volume = value
        if value > 0, output.isMuted { output.isMuted = false }
        refreshSystemOutput()
    }

    func toggleSystemMute() {
        let output = SystemOutput(device: outputDevice)
        output.isMuted = !output.isMuted
        refreshSystemOutput()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("VolumeMixer: could not update launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save(_ key: String) {
        defaults.set(volumes, forKey: "volumes")
        defaults.set(mutes, forKey: "mutes")
        errors[key] = nil
        for (pid, group) in groups where group.key == key { syncTap(pid: pid, group: group) }
    }

    // MARK: - Polling

    private func refresh() {
        refreshSystemOutput()

        let myPID = ProcessInfo.processInfo.processIdentifier
        var newGroups: [pid_t: Group] = [:]
        for process in AudioProcess.all() where process.pid > 0 && process.pid != myPID {
            guard let app = owningApplication(of: process.pid), app.processIdentifier != myPID else { continue }
            let pid = app.processIdentifier
            var group = newGroups[pid] ?? Group(app: app, key: app.bundleIdentifier ?? "pid.\(pid)")
            group.processObjects.append(process.objectID)
            group.isPlaying = group.isPlaying || process.isRunningOutput
            newGroups[pid] = group
        }
        for pid in newGroups.keys { newGroups[pid]!.processObjects.sort() }

        let now = Date()
        for (pid, group) in newGroups where group.isPlaying { lastPlaying[pid] = now }
        lastPlaying = lastPlaying.filter { newGroups[$0.key] != nil }
        groups = newGroups

        for pid in taps.keys where groups[pid] == nil { taps[pid] = nil }
        for (pid, group) in groups { syncTap(pid: pid, group: group) }

        // Like the Windows mixer: an app stays listed until it quits once it has played audio.
        let entries = groups.compactMap { pid, group -> AppEntry? in
            guard lastPlaying[pid] != nil else { return nil }
            let icon = group.app.icon ?? NSImage(named: NSImage.applicationIconName)!
            return AppEntry(id: pid, key: group.key,
                            name: group.app.localizedName ?? group.key,
                            icon: icon,
                            tint: tint(for: group.key, icon: icon),
                            isPlaying: group.isPlaying)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if entries != apps { apps = entries }
    }

    private func refreshSystemOutput() {
        let output = SystemOutput(device: outputDevice)
        let name = output.name, has = output.hasVolume, vol = output.volume, muted = output.isMuted
        if deviceName != name { deviceName = name }
        if hasSystemVolume != has { hasSystemVolume = has }
        if abs(systemVolume - vol) > 0.001 { systemVolume = vol }
        if systemMuted != muted { systemMuted = muted }
    }

    private func tint(for key: String, icon: NSImage) -> Color {
        if let cached = tints[key] { return cached }
        let color = icon.accentColor.map(Color.init(nsColor:)) ?? .accentColor
        tints[key] = color
        return color
    }

    private func isActive(_ pid: pid_t) -> Bool {
        guard let last = lastPlaying[pid] else { return false }
        return Date().timeIntervalSince(last) < lingerSeconds
    }

    private func outputDeviceChanged() {
        outputDevice = AudioObjectID.defaultOutputDevice
        taps.removeAll()
        for (pid, group) in groups { syncTap(pid: pid, group: group) }
        refreshSystemOutput()
    }

    /// Ensures a tap exists exactly when the app is active and not at 100%.
    private func syncTap(pid: pid_t, group: Group) {
        let gain: Float = isMuted(group.key) ? 0 : volume(for: group.key)
        guard isActive(pid), gain < 0.995, errors[group.key] == nil else {
            taps[pid] = nil
            return
        }
        if let tap = taps[pid], tap.processObjects == group.processObjects, tap.outputDevice == outputDevice {
            tap.gain = gain
            return
        }
        taps[pid] = nil
        do {
            taps[pid] = try AppTap(processObjects: group.processObjects, outputDevice: outputDevice, gain: gain)
        } catch {
            errors[group.key] = "\(error)"
        }
    }
}

private extension NSImage {
    /// The most saturated common color of the icon, used to tint that app's slider.
    var accentColor: NSColor? {
        let size = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        // Bucket pixels by hue, weighting by saturation, and pick the strongest bucket.
        var buckets = [(weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                let s = c.saturationComponent, v = c.brightnessComponent
                guard s > 0.25, v > 0.25 else { continue }
                let i = min(11, Int(c.hueComponent * 12))
                let w = s * v
                buckets[i].weight += w
                buckets[i].r += c.redComponent * w
                buckets[i].g += c.greenComponent * w
                buckets[i].b += c.blueComponent * w
            }
        }
        guard let best = buckets.max(by: { $0.weight < $1.weight }), best.weight > 0.5 else { return nil }
        let avg = NSColor(deviceRed: best.r / best.weight, green: best.g / best.weight, blue: best.b / best.weight, alpha: 1)
        return NSColor(hue: avg.hueComponent, saturation: max(avg.saturationComponent, 0.55),
                       brightness: min(max(avg.brightnessComponent, 0.7), 0.92), alpha: 1)
    }
}
