import SwiftUI

/// The panel that drops down from Vinyl's menu bar icon.
struct MenuBarView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var nowPlaying = NowPlayingService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                NowPlayingSummary()
                TransportControls(size: 13, spacing: 2)
                    .fixedSize()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Scene")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show Vinyl", isOn: $prefs.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(prefs.enabled ? "Hide Vinyl" : "Show Vinyl")
                }
                HStack(spacing: 6) {
                    ForEach(VinylScene.allCases) { scene in
                        SceneTile(scene: scene, selected: prefs.scene == scene) {
                            prefs.scene = scene
                            prefs.enabled = true
                        }
                    }
                }
                .opacity(prefs.enabled ? 1 : 0.5)
            }

            if prefs.scene.isDesktopScene {
                VStack(spacing: 10) {
                    sizeRow($prefs.desktopSize, in: 0...1)
                    row("Room background", isOn: $prefs.showBackground)
                    row("Mini player too", isOn: $prefs.miniAlongside)
                }
            } else {
                VStack(spacing: 10) {
                    Picker("Style", selection: $prefs.miniStyle) {
                        ForEach(MiniStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker("Record", selection: $prefs.miniLabelStyle) {
                        ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    sizeRow($prefs.miniHeight, in: Preferences.miniHeightRange)
                    row("Keep on top", isOn: $prefs.miniFloats)
                }
            }

            Divider()

            HStack {
                Button {
                    SettingsWindow.shared.show()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit Vinyl") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 330)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: prefs.scene.isDesktopScene)
    }

    private func sizeRow(_ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text("Size").font(.system(size: 12))
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel("Size")
        }
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

private struct SceneTile: View {
    let scene: VinylScene
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(scene == .listeningRoom ? "Listening" : scene == .miniPlayer ? "Mini" : scene.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
        .help(scene.title)
        .accessibilityLabel(scene.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
