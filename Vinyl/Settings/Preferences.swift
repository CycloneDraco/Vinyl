import AppKit
import Combine

/// The four looks Vinyl can take. The first three render on the desktop
/// behind your windows; the mini player is a small floating record.
enum VinylScene: String, CaseIterable, Identifiable {
    case listeningRoom = "listening-room"
    case afterHours = "after-hours"
    case turntable = "turntable"
    case miniPlayer = "mini"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listeningRoom: return "Listening Room"
        case .afterHours: return "After Hours"
        case .turntable: return "Turntable"
        case .miniPlayer: return "Mini Player"
        }
    }

    var subtitle: String {
        switch self {
        case .listeningRoom: return "Golden afternoon sun"
        case .afterHours: return "Lamp-lit, late night"
        case .turntable: return "Top-down on your desk"
        case .miniPlayer: return "A record that floats"
        }
    }

    var symbol: String {
        switch self {
        case .listeningRoom: return "sun.max"
        case .afterHours: return "moon.stars"
        case .turntable: return "record.circle"
        case .miniPlayer: return "pip"
        }
    }

    /// Asset catalog image used for the settings preview card.
    var previewImageName: String {
        switch self {
        case .listeningRoom: return "PreviewListeningRoom"
        case .afterHours: return "PreviewAfterHours"
        case .turntable: return "PreviewTurntable"
        case .miniPlayer: return "PreviewMini"
        }
    }

    var isDesktopScene: Bool { self != .miniPlayer }

    /// Starting size (0 = smallest, 1 = largest): rooms open wide, the
    /// top-down deck at half the screen width (1.0's "Wide"). Mirrors
    /// `framingSizes.wide` in the renderer's scenes.
    var defaultSize: Double { self == .turntable ? 0.37 : 0 }
}

enum MiniStyle: String, CaseIterable, Identifiable {
    case turntable, record
    var id: String { rawValue }
    var title: String { self == .turntable ? "Turntable" : "Record Only" }
}

enum LabelStyle: String, CaseIterable, Identifiable {
    case label, picture
    var id: String { rawValue }
    var title: String { self == .label ? "Label" : "Picture Disc" }
}

enum DisplayTarget: String, CaseIterable, Identifiable {
    case main, all
    var id: String { rawValue }
    var title: String { self == .main ? "Main Display" : "All Displays" }
}

/// Quick size presets for the mini player (its height in points).
enum MiniSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var height: Double {
        switch self {
        case .small: return 190
        case .medium: return 280
        case .large: return 400
        }
    }
}

enum SourcePreference: String, CaseIterable, Identifiable {
    case automatic, spotify, appleMusic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }
}

enum EnergyMode: String, CaseIterable, Identifiable {
    case automatic, quality, saver
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .quality: return "Best Quality"
        case .saver: return "Battery Saver"
        }
    }
    var detail: String {
        switch self {
        case .automatic: return "Smooth on power, lighter on battery"
        case .quality: return "60 fps at full resolution"
        case .saver: return "30 fps at reduced resolution"
        }
    }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    /// Master switch ("Desktop Artwork" in the original): hides everything.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    @Published var scene: VinylScene { didSet { defaults.set(scene.rawValue, forKey: Keys.scene) } }
    /// Size of each desktop scene, 0 (smallest) … 1 (largest), keyed by scene.
    @Published var sceneSizes: [String: Double] { didSet { defaults.set(sceneSizes, forKey: Keys.sceneSizes) } }
    @Published var showBackground: Bool { didSet { defaults.set(showBackground, forKey: Keys.background) } }
    @Published var displayTarget: DisplayTarget { didSet { defaults.set(displayTarget.rawValue, forKey: Keys.display) } }
    @Published var spinWhenIdle: Bool { didSet { defaults.set(spinWhenIdle, forKey: Keys.idleSpin) } }

    @Published var miniAlongside: Bool { didSet { defaults.set(miniAlongside, forKey: Keys.miniAlongside) } }
    @Published var miniLabelStyle: LabelStyle { didSet { defaults.set(miniLabelStyle.rawValue, forKey: Keys.miniLabel) } }
    @Published var miniStyle: MiniStyle { didSet { defaults.set(miniStyle.rawValue, forKey: Keys.miniStyle) } }
    /// Mini player height in points; the width follows the style's aspect ratio.
    @Published var miniHeight: Double {
        didSet {
            // (Assigning inside didSet doesn't re-trigger it.)
            let clamped = min(max(miniHeight, Self.miniHeightRange.lowerBound), Self.miniHeightRange.upperBound)
            if clamped != miniHeight { miniHeight = clamped }
            defaults.set(miniHeight, forKey: Keys.miniHeight)
        }
    }
    static let miniHeightRange: ClosedRange<Double> = 140...720
    @Published var miniFloats: Bool { didSet { defaults.set(miniFloats, forKey: Keys.miniFloats) } }
    @Published var miniOnAllSpaces: Bool { didSet { defaults.set(miniOnAllSpaces, forKey: Keys.miniSpaces) } }

    @Published var source: SourcePreference { didSet { defaults.set(source.rawValue, forKey: Keys.source) } }
    @Published var energy: EnergyMode { didSet { defaults.set(energy.rawValue, forKey: Keys.energy) } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Keys.dock) } }

    func size(for scene: VinylScene) -> Double {
        sceneSizes[scene.rawValue] ?? scene.defaultSize
    }

    /// The selected desktop scene's size (what the Size sliders edit).
    var desktopSize: Double {
        get { size(for: scene) }
        set { sceneSizes[scene.rawValue] = min(max(newValue, 0), 1) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Keys.launched) }
        set { defaults.set(newValue, forKey: Keys.launched) }
    }

    var miniOrigin: NSPoint? {
        get {
            guard let s = defaults.string(forKey: Keys.miniOrigin) else { return nil }
            let p = NSPointFromString(s)
            return p == .zero ? nil : p
        }
        set { defaults.set(newValue.map { NSStringFromPoint($0) }, forKey: Keys.miniOrigin) }
    }

    /// Whether a desktop scene should be on screen right now.
    var desktopScene: VinylScene? { enabled && scene.isDesktopScene ? scene : nil }
    /// Whether the floating mini player should be on screen right now.
    var showsMiniPlayer: Bool { enabled && (scene == .miniPlayer || miniAlongside) }

    private init() {
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.background: true,
            Keys.idleSpin: true,
            Keys.miniTonearm: true,
            Keys.miniFloats: true,
            Keys.miniSpaces: true,
        ])
        enabled = defaults.bool(forKey: Keys.enabled)
        scene = VinylScene(rawValue: defaults.string(forKey: Keys.scene) ?? "") ?? .listeningRoom
        if let saved = defaults.dictionary(forKey: Keys.sceneSizes) {
            // (`defaults write … -dict` stores the numbers as strings.)
            sceneSizes = saved.compactMapValues { ($0 as? NSNumber)?.doubleValue ?? Double($0 as? String ?? "") }
        } else if let framing = defaults.string(forKey: Keys.framing) {
            // 1.0 stored Wide / Mid / Close; carry it over to the rooms.
            let room = ["wide": 0.0, "mid": 0.5, "close": 1.0][framing] ?? 0
            let deck = ["wide": 0.37, "mid": 0.63, "close": 0.93][framing] ?? 0.37
            sceneSizes = [VinylScene.listeningRoom.rawValue: room, VinylScene.afterHours.rawValue: room,
                          VinylScene.turntable.rawValue: deck]
        } else {
            sceneSizes = [:]
        }
        showBackground = defaults.bool(forKey: Keys.background)
        displayTarget = DisplayTarget(rawValue: defaults.string(forKey: Keys.display) ?? "") ?? .main
        spinWhenIdle = defaults.bool(forKey: Keys.idleSpin)
        miniAlongside = defaults.bool(forKey: Keys.miniAlongside)
        miniLabelStyle = LabelStyle(rawValue: defaults.string(forKey: Keys.miniLabel) ?? "") ?? .label
        if let style = MiniStyle(rawValue: defaults.string(forKey: Keys.miniStyle) ?? "") {
            miniStyle = style
        } else {
            // 1.0 had a "Tonearm" switch instead.
            miniStyle = defaults.bool(forKey: Keys.miniTonearm) ? .turntable : .record
        }
        if defaults.object(forKey: Keys.miniHeight) != nil {
            miniHeight = min(max(defaults.double(forKey: Keys.miniHeight), Self.miniHeightRange.lowerBound), Self.miniHeightRange.upperBound)
        } else {
            miniHeight = (MiniSize(rawValue: defaults.string(forKey: Keys.miniSize) ?? "") ?? .medium).height
        }
        miniFloats = defaults.bool(forKey: Keys.miniFloats)
        miniOnAllSpaces = defaults.bool(forKey: Keys.miniSpaces)
        source = SourcePreference(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .automatic
        energy = EnergyMode(rawValue: defaults.string(forKey: Keys.energy) ?? "") ?? .automatic
        showInDock = defaults.bool(forKey: Keys.dock)
    }

    private enum Keys {
        static let enabled = "enabled"
        static let scene = "scene"
        static let framing = "framing" // 1.0 only; migrated to sceneSizes
        static let sceneSizes = "sceneSizes"
        static let background = "showBackground"
        static let display = "displayTarget"
        static let idleSpin = "spinWhenIdle"
        static let miniAlongside = "miniAlongside"
        static let miniLabel = "miniLabelStyle"
        static let miniTonearm = "miniShowsTonearm" // 1.0 only; migrated to miniStyle
        static let miniSize = "miniSize" // 1.0 only; migrated to miniHeight
        static let miniStyle = "miniStyle"
        static let miniHeight = "miniHeight"
        static let miniFloats = "miniFloats"
        static let miniSpaces = "miniOnAllSpaces"
        static let miniOrigin = "miniOrigin"
        static let source = "source"
        static let energy = "energy"
        static let dock = "showInDock"
        static let launched = "hasLaunchedBefore"
    }
}
