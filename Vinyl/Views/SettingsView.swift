import AppKit
import SwiftUI

/// Vinyl's main window. Closing it leaves Vinyl running in the menu bar.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Appear in the Dock and ⌘-Tab while the window is open.
        NSApp.setActivationPolicy(.regular)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vinyl"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 600, height: 760))
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if !Preferences.shared.showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var nowPlaying = NowPlayingService.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(VinylScene.allCases) { scene in
                        SceneCard(scene: scene, selected: prefs.scene == scene) {
                            prefs.scene = scene
                            prefs.enabled = true
                        }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Show Vinyl", isOn: $prefs.enabled)
            } header: {
                Text("Scene")
            } footer: {
                Text("Desktop scenes sit behind your windows, right on top of the wallpaper. The mini player floats wherever you put it.")
                    .settingsFootnote()
            }

            Section("Desktop") {
                VStack(alignment: .leading, spacing: 3) {
                    SizeSlider(value: $prefs.desktopSize, in: 0...1)
                    Text(prefs.scene == .turntable
                         ? "How big the turntable sits on your desktop."
                         : "Zoom from the whole desk in to the turntable.")
                        .settingsFootnote()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Room background", isOn: $prefs.showBackground)
                    Text("Turn off to put the turntable straight onto your own wallpaper.")
                        .settingsFootnote()
                }
                Picker("Show on", selection: $prefs.displayTarget) {
                    ForEach(DisplayTarget.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Spin built-in records when nothing is playing", isOn: $prefs.spinWhenIdle)
            }
            .disabled(!prefs.scene.isDesktopScene)

            Section("Mini Player") {
                if prefs.scene.isDesktopScene {
                    Toggle("Also show the mini player", isOn: $prefs.miniAlongside)
                }
                Picker("Style", selection: $prefs.miniStyle) {
                    ForEach(MiniStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Record", selection: $prefs.miniLabelStyle) {
                    ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 3) {
                    SizeSlider(value: $prefs.miniHeight, in: Preferences.miniHeightRange)
                    Text("You can also drag the player's bottom-right corner, or pinch on it.")
                        .settingsFootnote()
                }
                Toggle("Keep on top of other windows", isOn: $prefs.miniFloats)
                Toggle("Show on every Space", isOn: $prefs.miniOnAllSpaces)
            }

            Section {
                Picker("Follow", selection: $prefs.source) {
                    ForEach(SourcePreference.allCases) { Text($0.title).tag($0) }
                }
                ForEach(PlayerSource.allCases) { source in
                    SourceRow(source: source)
                }
            } header: {
                Text("Music")
            } footer: {
                Text("Vinyl picks up track changes from Spotify and Music without any login. Connecting lets it show what's already playing when it starts, keep the tonearm in sync, use Apple Music's exact artwork and run the play, pause and skip controls.")
                    .settingsFootnote()
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        do {
                            launchAtLogin = try LaunchAtLogin.set(wanted)
                            loginError = LaunchAtLogin.needsApproval ? "Approve Vinyl in System Settings › General › Login Items." : nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).settingsFootnote()
                }
                Toggle("Show in Dock", isOn: $prefs.showInDock)
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Energy", selection: $prefs.energy) {
                        ForEach(EnergyMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(prefs.energy.detail + ". Vinyl also stops drawing whenever it's completely covered.")
                        .settingsFootnote()
                }
            }

            Section {
                HStack {
                    Link(destination: URL(string: "https://github.com/CycloneDraco/Vinyl")!) {
                        Label("Vinyl is open source", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Spacer()
                    Button("Quit Vinyl") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 600, idealHeight: 760)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            nowPlaying.refreshPermissions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vinyl")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.3)
                    Text("A turntable for your desktop · Version \(Bundle.main.shortVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                NowPlayingSummary(artworkSize: 40)
                TransportControls(size: 13, spacing: 4).fixedSize()
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !nowPlaying.permissions.values.contains(.granted) {
                Label {
                    Text("Track changes in Spotify and Music already show up here. Connect a player under **Music** to see what's playing at launch and use the play/skip buttons.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SceneCard: View {
    let scene: VinylScene
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(scene.previewImageName)
                    .resizable()
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                          lineWidth: selected ? 3 : 0.5)
                    )
                HStack(spacing: 6) {
                    Image(systemName: scene.symbol)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(scene.title)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(scene.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
        .accessibilityLabel(scene.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SourceRow: View {
    let source: PlayerSource
    @ObservedObject private var nowPlaying = NowPlayingService.shared
    @State private var asking = false

    var body: some View {
        let status = nowPlaying.permissions[source] ?? .unknown
        let installed = nowPlaying.isInstalled(source)
        HStack(spacing: 10) {
            Image(systemName: source == .spotify ? "waveform" : "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(source == .spotify ? Color(red: 0.12, green: 0.73, blue: 0.33) : Color(red: 0.98, green: 0.24, blue: 0.35),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(source == .spotify ? "Spotify" : "Apple Music")
                Text(installed ? detail(status) : "Not installed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.system(size: 12, weight: .medium))
            case .denied:
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            default:
                Button(asking ? "Waiting…" : "Connect") {
                    asking = true
                    Task {
                        await nowPlaying.requestAccess(to: source)
                        asking = false
                    }
                }
                .disabled(asking || !installed)
            }
        }
    }

    private func detail(_ status: AutomationStatus) -> String {
        switch status {
        case .granted: return "Track info, artwork and controls"
        case .denied: return "Allow Vinyl under Automation"
        case .notRunning: return "Connect to allow controls"
        default: return "Track changes work already"
        }
    }
}

/// "Size" slider with Small / Large end labels, like the Dock size in System Settings.
private struct SizeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(value: Binding<Double>, in range: ClosedRange<Double>) {
        _value = value
        self.range = range
    }

    var body: some View {
        Slider(value: $value, in: range) {
            Text("Size")
        } minimumValueLabel: {
            Text("Small").font(.system(size: 11)).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Text("Large").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
