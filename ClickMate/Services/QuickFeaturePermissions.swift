import ApplicationServices
import AppKit
import Combine
import CoreGraphics

enum QuickFeaturePermissionKind: String, Codable, CaseIterable, Hashable {
    case accessibility
    case screenRecording
}

enum QuickFeaturePermissionState: Equatable {
    case unknown
    case checking
    case waitingForUser
    case notGranted
    case restartRequired
    case granted
    case failed
}

struct QuickFeaturePermissionRequestContext: Equatable {
    static let timeout: TimeInterval = 20

    let id: UUID
    let kind: QuickFeaturePermissionKind
    let startedAt: Date
    var commandID: UUID?
    var settingsOpenedAt: Date?
    var didAttemptRecovery: Bool
    var lastRefreshCommandID: UUID?
    var lastObservedSnapshotUpdatedAt: Date?
    var refreshGeneration: Int

    init(
        id: UUID = UUID(),
        kind: QuickFeaturePermissionKind,
        startedAt: Date = .now,
        commandID: UUID? = nil,
        settingsOpenedAt: Date? = nil,
        didAttemptRecovery: Bool = false,
        lastRefreshCommandID: UUID? = nil,
        lastObservedSnapshotUpdatedAt: Date? = nil,
        refreshGeneration: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.commandID = commandID
        self.settingsOpenedAt = settingsOpenedAt
        self.didAttemptRecovery = didAttemptRecovery
        self.lastRefreshCommandID = lastRefreshCommandID
        self.lastObservedSnapshotUpdatedAt = lastObservedSnapshotUpdatedAt
        self.refreshGeneration = refreshGeneration
    }

    func isExpired(
        referenceDate: Date = .now,
        timeout: TimeInterval = Self.timeout
    ) -> Bool {
        referenceDate.timeIntervalSince(startedAt) > timeout
    }

    var shouldAttemptRecoveryAfterActivation: Bool {
        guard !didAttemptRecovery else { return false }
        switch kind {
        case .accessibility:
            return false
        case .screenRecording:
            return settingsOpenedAt != nil
        }
    }
}

enum QuickFeaturePermissionPollingPolicy {
    static let refreshDelays: [TimeInterval] = [
        0,
        0.25,
        0.75,
        1.5,
        3,
        5
    ]
}

struct QuickFeaturePermissionRequestTracker {
    private(set) var context: QuickFeaturePermissionRequestContext?

    mutating func begin(
        kind: QuickFeaturePermissionKind,
        startedAt: Date = .now,
        settingsOpened: Bool = false
    ) -> QuickFeaturePermissionRequestContext? {
        guard context == nil else { return nil }
        let request = QuickFeaturePermissionRequestContext(
            kind: kind,
            startedAt: startedAt,
            settingsOpenedAt: settingsOpened ? startedAt : nil
        )
        context = request
        return request
    }

    mutating func assignCommandID(_ commandID: UUID, requestID: UUID) -> Bool {
        guard context?.id == requestID else { return false }
        context?.commandID = commandID
        return true
    }

    mutating func markSettingsOpened(at date: Date = .now, requestID: UUID) -> Bool {
        guard context?.id == requestID else { return false }
        context?.settingsOpenedAt = date
        return true
    }

    mutating func markRecoveryAttempted(requestID: UUID) -> Bool {
        guard context?.id == requestID, context?.didAttemptRecovery == false else { return false }
        context?.didAttemptRecovery = true
        return true
    }

    mutating func beginRefresh(
        commandID: UUID,
        observedSnapshotUpdatedAt: Date?,
        requestID: UUID
    ) -> Int? {
        guard context?.id == requestID else { return nil }
        context?.lastRefreshCommandID = commandID
        context?.lastObservedSnapshotUpdatedAt = observedSnapshotUpdatedAt
        context?.refreshGeneration += 1
        return context?.refreshGeneration
    }

    mutating func clear(requestID: UUID? = nil) {
        guard requestID == nil || context?.id == requestID else { return }
        context = nil
    }
}

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

    func refreshOnce() {
        refreshTask?.cancel()
        refreshTask = nil
        updateSnapshot()
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

    @discardableResult
    static func relaunchApplication() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    private static func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
