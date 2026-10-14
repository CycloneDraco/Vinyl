import AppKit
import Combine
import IOKit.ps
import ServiceManagement

/// Power source, Low Power Mode, display sleep and Reduce Motion: everything
/// that should make the renderer slow down or stop.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var onBattery = false
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Displays asleep, screen locked or the user switched away.
    @Published private(set) var systemIdle = false

    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        refreshPower()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refreshPower() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .store(in: &cancellables)

        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
            .store(in: &cancellables)

        let idleOn: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let idleOff: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in idleOn {
            ws.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.systemIdle = true }
                .store(in: &cancellables)
        }
        for name in idleOff {
            ws.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.systemIdle = false }
                .store(in: &cancellables)
        }
    }

    private func refreshPower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return }
        let battery = (type as String) == kIOPSBatteryPowerValue
        if battery != onBattery { onBattery = battery }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the new state, or throws with the system's reason.
    @discardableResult
    static func set(_ enabled: Bool) throws -> Bool {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
        return isEnabled
    }

    /// macOS asks the user to approve login items in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
