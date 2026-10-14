import AppKit
import CoreServices
import os

/// Automation (Apple Events) permission for one target app.
enum AutomationStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case notRunning
    case unknown

    var description: String {
        switch self {
        case .granted: return "Connected"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not connected"
        case .notRunning: return "Not running"
        case .unknown: return "Unknown"
        }
    }
}

/// Runs AppleScript against Spotify / Music on a private serial queue.
/// NSAppleScript isn't thread-safe, so every script lives and runs on `queue`
/// (which is also what makes the unchecked Sendable conformance sound).
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "vinyl.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Vinyl", category: "AppleScript")

    struct ScriptError: Error, CustomStringConvertible {
        let number: Int
        let message: String
        var description: String { "AppleScript error \(number): \(message)" }
        /// -1743: the user hasn't allowed Vinyl to control this app.
        var isPermissionDenied: Bool { number == -1743 }
    }

    func run(_ source: String) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script: NSAppleScript
                if let cached = self.compiled[source] {
                    script = cached
                } else if let fresh = NSAppleScript(source: source) {
                    self.compiled[source] = fresh
                    script = fresh
                } else {
                    continuation.resume(throwing: ScriptError(number: -1, message: "Could not create script"))
                    return
                }
                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
                    self.log.debug("script failed: \(number) \(message, privacy: .public)")
                    continuation.resume(throwing: ScriptError(number: number, message: message))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Checks (and optionally asks for) permission to send Apple Events to
    /// `bundleIdentifier`. Asking blocks until the user answers, so this always
    /// runs off the main thread.
    func automationStatus(for bundleIdentifier: String, ask: Bool) async -> AutomationStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.determinePermission(bundleIdentifier, ask: ask))
            }
        }
    }

    private static func determinePermission(_ bundleIdentifier: String, ask: Bool) -> AutomationStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleIdentifier.utf8)
        let created = bytes.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == 0 else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask
        )
        switch status {
        case 0: return .granted
        case -1743: return .denied // errAEEventNotPermitted
        case -1744: return .notDetermined // errAEEventWouldRequireUserConsent
        case -600: return .notRunning // procNotFound
        default: return .unknown
        }
    }
}

extension NSAppleEventDescriptor {
    /// 1-based list access that tolerates missing items.
    func item(_ index: Int) -> NSAppleEventDescriptor? {
        guard index >= 1, index <= numberOfItems else { return nil }
        return atIndex(index)
    }

    var numberValue: Double? {
        switch descriptorType {
        case DescType(typeIEEE64BitFloatingPoint), DescType(typeIEEE32BitFloatingPoint),
             DescType(typeSInt32), DescType(typeSInt16), DescType(typeSInt64), DescType(typeUInt32):
            return doubleValue
        default:
            if let s = stringValue { return Double(s.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }
    }
}
