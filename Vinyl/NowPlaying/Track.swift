import Foundation

enum PlayerSource: String, CaseIterable, Identifiable, Codable {
    case spotify
    case appleMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    /// Distributed notification each player posts on every playback change.
    var notificationName: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .appleMusic: return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    /// AppleScript application name.
    var scriptName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }
}

enum PlaybackState: String, Codable {
    case playing, paused, stopped

    init(playerString: String?) {
        switch playerString?.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        default: self = .stopped
        }
    }
}

struct Track: Equatable, Codable {
    /// `spotify:track:…` for Spotify, the persistent ID for Music.
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    /// Seconds, when the player reports it.
    var duration: TimeInterval?
    var source: PlayerSource

    /// Identifies the album, used to cache artwork and build the recent stack.
    var albumKey: String {
        let who = (albumArtist?.isEmpty == false ? albumArtist! : artist)
        let what = album.isEmpty ? title : album
        return "\(source.rawValue)|\(who)|\(what)".lowercased()
    }

    /// Spotify ads and unknown items don't have real metadata.
    var isAdvertisement: Bool { id.hasPrefix("spotify:ad:") }
}

/// What one player is doing, as last reported.
struct PlayerSnapshot: Equatable {
    var track: Track?
    var state: PlaybackState
    var position: TimeInterval
    var positionDate: Date

    static let stopped = PlayerSnapshot(track: nil, state: .stopped, position: 0, positionDate: .distantPast)

    func position(at date: Date = Date()) -> TimeInterval {
        guard state == .playing else { return position }
        let p = position + date.timeIntervalSince(positionDate)
        if let d = track?.duration, d > 0 { return min(p, d) }
        return p
    }
}

/// An album shown in the recently-played stack.
struct RecentAlbum: Codable, Equatable, Identifiable {
    var key: String
    var title: String
    var artist: String
    var artworkFile: String
    var id: String { key }
}
