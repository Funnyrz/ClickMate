import ApplicationServices
import AppKit
import Combine
import CoreGraphics

struct QuickFeaturePermissionSnapshot: Equatable {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool

    static var current: QuickFeaturePermissionSnapshot {
        QuickFeaturePermissionSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }
}

extension Notification.Name {
    static let quickFeaturePermissionStatusChanged = Notification.Name(
        "ClickMate.quickFeaturePermissionStatusChanged"
    )
}

@MainActor
final class QuickFeaturePermissionMonitor: ObservableObject {
    typealias SnapshotProvider = @MainActor () -> QuickFeaturePermissionSnapshot

    static let shared = QuickFeaturePermissionMonitor()

    @Published private(set) var snapshot: QuickFeaturePermissionSnapshot

    private let snapshotProvider: SnapshotProvider
    private let retryDelays: [Duration]
    private var refreshTask: Task<Void, Never>?

    init(
        snapshotProvider: @escaping SnapshotProvider = { .current },
        retryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(750),
            .milliseconds(1_500),
            .milliseconds(3_000)
        ]
    ) {
        self.snapshotProvider = snapshotProvider
        self.retryDelays = retryDelays
        snapshot = snapshotProvider()
    }

    func refresh() {
        refreshTask?.cancel()
        updateSnapshot()
        guard !snapshot.accessibilityGranted || !snapshot.screenRecordingGranted else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for delay in retryDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                updateSnapshot()
                if snapshot.accessibilityGranted && snapshot.screenRecordingGranted {
                    return
                }
            }
        }
    }

    private func updateSnapshot() {
        let updatedSnapshot = snapshotProvider()
        guard updatedSnapshot != snapshot else { return }
        snapshot = updatedSnapshot
        NotificationCenter.default.post(name: .quickFeaturePermissionStatusChanged, object: nil)
    }
}

enum QuickFeaturePermissions {
    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openSystemSettings(pane: "Privacy_ScreenCapture")
    }

    static func relaunchApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            NSSound.beep()
        }
    }

    private static func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
