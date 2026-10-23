import SwiftUI

@main
struct VolumeMixerApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.vertical.3") {
            MixerView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                Text("APPLICATIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                if model.apps.isEmpty {
                    EmptyState()
                } else {
                    ForEach(model.apps) { app in
                        AppRow(app: app, model: model)
                    }
                }
            }
            .padding(10)
            .animation(.snappy(duration: 0.25), value: model.apps.map(\.id))

            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.49, green: 0.40, blue: 1.0),
                                                      Color(red: 0.24, green: 0.15, blue: 0.62)],
                                             startPoint: .top, endPoint: .bottom))
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Volume Mixer")
                        .font(.system(size: 13, weight: .semibold))
                    Label(model.deviceName, systemImage: "hifispeaker.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if model.hasSystemVolume {
                HStack(spacing: 10) {
                    MuteButton(muted: model.systemMuted, volume: model.systemVolume, tint: .accentColor) {
                        model.toggleSystemMute()
                    }
                    VolumeSlider(value: Binding(
                        get: { model.systemMuted ? 0 : model.systemVolume },
                        set: { model.setSystemVolume($0) }
                    ), tint: .accentColor, dimmed: model.systemMuted)
                    PercentLabel(muted: model.systemMuted, volume: model.systemVolume)
                }
                .padding(.leading, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at login").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No apps are playing audio")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Apps appear here when they play sound.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

struct AppRow: View {
    let app: AppEntry
    @ObservedObject var model: MixerModel
    @State private var hovering = false

    var body: some View {
        let muted = model.isMuted(app.key)
        let volume = model.volume(for: app.key)

        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .saturation(muted ? 0 : 1)
                .opacity(muted ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    EqualizerBars(active: app.isPlaying && !muted, tint: app.tint)
                    Spacer(minLength: 4)
                    if hovering && (volume < 0.995 || muted) {
                        Button { model.reset(app.key) } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Reset to 100%")
                        .transition(.opacity)
                    }
                    PercentLabel(muted: muted, volume: volume)
                }
                HStack(spacing: 8) {
                    MuteButton(muted: muted, volume: volume, tint: app.tint) { model.toggleMute(app.key) }
                    VolumeSlider(value: Binding(
                        get: { muted ? 0 : volume },
                        set: { model.setVolume($0, for: app.key) }
                    ), tint: app.tint, dimmed: muted)
                }
                if let error = model.errors[app.key] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.075 : 0.045))
        )
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu {
            Button("Reset to 100%") { model.reset(app.key) }
        }
    }
}

private struct PercentLabel: View {
    let muted: Bool
    let volume: Float

    var body: some View {
        Text(muted ? "Muted" : "\(Int((volume * 100).rounded()))%")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(muted ? AnyShapeStyle(.red.opacity(0.85)) : AnyShapeStyle(.secondary))
            .frame(minWidth: 38, alignment: .trailing)
            .contentTransition(.numericText())
    }
}

private struct MuteButton: View {
    let muted: Bool
    let volume: Float
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(muted ? Color.red : tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill((muted ? Color.red : tint).opacity(0.14)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute" : "Mute")
    }

    private var symbol: String {
        if muted { return "speaker.slash.fill" }
        switch volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Capsule slider tinted per app; the track thickens while hovered or dragged.
struct VolumeSlider: View {
    @Binding var value: Float
    let tint: Color
    var dimmed = false

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = 14
            let track: CGFloat = (hovering || dragging) ? 7 : 5
            let x = CGFloat(value) * width
            let fill = dimmed ? Color.secondary.opacity(0.5) : tint

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                    .frame(height: track)
                Capsule().fill(fill.gradient)
                    .frame(width: max(0, x), height: track)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: min(max(x - knob / 2, 0), width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        value = Float(min(max(g.location.x / width, 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: track)
            .animation(.spring(duration: 0.2), value: dragging)
        }
        .frame(height: 18)
        .onHover { hovering = $0 }
    }
}

/// Small animated bars shown next to an app that is currently producing sound.
private struct EqualizerBars: View {
    let active: Bool
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * (4.1 + Double(i) * 1.7) + Double(i) * 1.3
                    Capsule()
                        .fill(active ? tint : Color.secondary.opacity(0.4))
                        .frame(width: 2.5, height: active ? 3 + 7 * abs(sin(phase)) : 2.5)
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
        .help(active ? "Playing" : "Silent")
    }
}
