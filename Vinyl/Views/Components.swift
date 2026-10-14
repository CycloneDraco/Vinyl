import AppKit
import SwiftUI

/// Buttons answer on press, not on release: a quick, critically damped squish.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Previous / play-pause / next.
struct TransportControls: View {
    @ObservedObject private var nowPlaying = NowPlayingService.shared
    var size: CGFloat = 15
    var spacing: CGFloat = 18

    var body: some View {
        let playing = nowPlaying.now.state == .playing
        let enabled = nowPlaying.now.track != nil || nowPlaying.hasRunningPlayer || nowPlaying.canLaunchPlayer
        HStack(spacing: spacing) {
            button("backward.fill", label: "Previous Track", scale: 0.8) { nowPlaying.send(.previous) }
            button(playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", scale: 1.15) {
                nowPlaying.send(.playPause)
            }
            button("forward.fill", label: "Next Track", scale: 0.8) { nowPlaying.send(.next) }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func button(_ symbol: String, label: String, scale: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * scale, weight: .semibold))
                .frame(width: size * 1.9, height: size * 1.9)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Small rounded album cover loaded from the artwork cache.
struct ArtworkThumbnail: View {
    let file: String?
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: file) {
            guard let file else {
                image = nil
                return
            }
            let url = ArtworkStore.shared.url(forFile: file)
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            withAnimation(.easeOut(duration: 0.25)) { image = data.flatMap(NSImage.init(data:)) }
        }
    }
}

/// The track line used in the menu bar panel and settings header.
struct NowPlayingSummary: View {
    @ObservedObject private var nowPlaying = NowPlayingService.shared
    var artworkSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(file: nowPlaying.now.track == nil ? nil : nowPlaying.artworkFile, size: artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                if let track = nowPlaying.now.track {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(statusLine(track))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Play a song in Spotify or Music.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusLine(_ track: Track) -> String {
        let state: String
        switch nowPlaying.now.state {
        case .playing: state = "Playing"
        case .paused: state = "Paused"
        case .stopped: state = "Stopped"
        }
        return "\(state) in \(track.source.displayName)"
    }
}

/// Controls that fade in over the mini player's record on hover.
struct MiniControlsView: View {
    @ObservedObject var hover: MiniHoverState
    @ObservedObject private var nowPlaying = NowPlayingService.shared

    var body: some View {
        VStack(spacing: 3) {
            if !hover.compact, let track = nowPlaying.now.track {
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 1)
            }
            TransportControls(size: hover.compact ? 11 : 13, spacing: hover.compact ? 4 : 8)
        }
        .frame(width: hover.compact ? 104 : 150)
        .padding(.horizontal, 10)
        .padding(.vertical, hover.compact ? 4 : 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: hover.compact ? 14 : 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: hover.compact ? 14 : 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .padding(12) // room for the shadow
    }
}
