import AppKit
import SwiftUI

struct QuickFeaturesView: View {
    @EnvironmentObject private var store: PreferencesStore
    @ObservedObject private var helperService = QuickFeatureHelperService.shared
    @State private var validationMessages: [QuickFeatureID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("quickFeatures.title"))
                    .font(.title2.bold())
                Text(L10n.string("quickFeatures.description"))
                    .foregroundStyle(.secondary)
            }

            if !helperService.isRuntimeRunning {
                Label(
                    L10n.string("quickFeatures.backgroundServiceWarning"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            ScrollView {
                VStack(spacing: 12) {
                    featureCard(for: .finderCut)
                    featureCard(for: .screenshot)
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear {
            refreshPermissions()
        }
    }

    private func featureCard(for id: QuickFeatureID) -> some View {
        let setting = settings(for: id)
        let permissionState = permissionState(for: id)
        let permissionGranted = permissionState == .granted
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: id.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(id.titleKey))
                        .font(.headline)
                    Text(L10n.string(id.descriptionKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: enabledBinding(for: id))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            HStack(spacing: 10) {
                Text(L10n.string("quickFeatures.shortcut"))
                    .font(.subheadline.weight(.medium))
                ShortcutRecorder(shortcut: setting.shortcut) { shortcut in
                    assign(shortcut, to: id)
                }
                Button(L10n.string("quickFeatures.restoreDefault")) {
                    assign(QuickFeatureSettings.defaultShortcut(for: id), to: id)
                }
                Spacer()
                Label(
                    permissionTitle(for: permissionState),
                    systemImage: permissionIcon(for: permissionState)
                )
                .font(.caption)
                .foregroundStyle(permissionColor(for: permissionState))
            }

            if !permissionGranted {
                HStack {
                    Button(L10n.string("quickFeatures.requestPermission")) {
                        requestPermission(for: id)
                    }
                    .disabled(permissionRequestIsActive(permissionState))
                    Button(L10n.string("quickFeatures.openSettings")) {
                        openPermissionSettings(for: id)
                    }
                    if id == .screenshot {
                        Button(L10n.string("permissions.restartBackgroundService")) {
                            helperService.restart()
                        }
                        .disabled(permissionRequestIsActive(permissionState))
                    }
                    Spacer()
                }
            }

            if let message = validationMessages[id] {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message = helperService.permissionFailureMessage(
                for: id == .finderCut ? .accessibility : .screenRecording
            ) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if helperService.failedFeatureIDs.contains(id) {
                Label(L10n.string("quickFeatures.registrationFailed"), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func settings(for id: QuickFeatureID) -> QuickFeatureSettings {
        store.preferences.quickFeatureSettings(for: id)
    }

    private func enabledBinding(for id: QuickFeatureID) -> Binding<Bool> {
        Binding {
            settings(for: id).isEnabled
        } set: { isEnabled in
            updateSettings(for: id) { settings in
                settings.isEnabled = isEnabled
            }
            if isEnabled {
                store.preferences.backgroundServiceEnabled = true
            }
            store.waitForPendingSaves()
            helperService.synchronize(preferences: store.preferences)
            validationMessages[id] = nil
            if isEnabled && !permissionIsGranted(for: id) {
                requestPermission(for: id)
            }
        }
    }

    private func assign(_ shortcut: KeyboardShortcut, to id: QuickFeatureID) {
        guard shortcut.isValid, !isReservedFinderCutShortcut(shortcut, featureID: id) else {
            validationMessages[id] = L10n.string("quickFeatures.invalidShortcut")
            return
        }
        let hasDuplicate = store.preferences.quickFeatureSettings.contains {
            $0.id != id && $0.shortcut == shortcut
        }
        guard !hasDuplicate else {
            validationMessages[id] = L10n.string("quickFeatures.duplicateShortcut")
            return
        }

        updateSettings(for: id) { settings in
            settings.shortcut = shortcut
        }
        validationMessages[id] = nil
        helperService.refreshRuntimeStatus()
    }

    private func updateSettings(for id: QuickFeatureID, update: (inout QuickFeatureSettings) -> Void) {
        var settings = QuickFeatureSettings.normalized(store.preferences.quickFeatureSettings)
        guard let index = settings.firstIndex(where: { $0.id == id }) else { return }
        update(&settings[index])
        store.preferences.quickFeatureSettings = settings
    }

    private func isReservedFinderCutShortcut(_ shortcut: KeyboardShortcut, featureID: QuickFeatureID) -> Bool {
        guard featureID == .finderCut else { return false }
        return shortcut == KeyboardShortcut(keyCode: 8, modifiers: .command)
            || shortcut == KeyboardShortcut(keyCode: 9, modifiers: .command)
    }

    private func permissionIsGranted(for id: QuickFeatureID) -> Bool {
        permissionState(for: id) == .granted
    }

    private func permissionState(for id: QuickFeatureID) -> QuickFeaturePermissionState {
        helperService.permissionState(for: id == .finderCut ? .accessibility : .screenRecording)
    }

    private func requestPermission(for id: QuickFeatureID) {
        switch id {
        case .finderCut:
            helperService.requestAccessibilityAccess()
        case .screenshot:
            helperService.requestScreenRecordingAccess()
        }
    }

    private func permissionTitle(for state: QuickFeaturePermissionState) -> String {
        switch state {
        case .unknown:
            return L10n.string("quickFeatures.permissionUnknown")
        case .notGranted:
            return L10n.string("quickFeatures.permissionMissing")
        case .granted:
            return L10n.string("quickFeatures.permissionGranted")
        case .checking, .waitingForUser, .restartRequired:
            return L10n.string("quickFeatures.permissionRefreshing")
        case .failed:
            return L10n.string("quickFeatures.permissionFailed")
        }
    }

    private func permissionIcon(for state: QuickFeaturePermissionState) -> String {
        switch state {
        case .unknown:
            return "questionmark.circle.fill"
        case .notGranted:
            return "exclamationmark.triangle.fill"
        case .granted:
            return "checkmark.circle.fill"
        case .checking, .waitingForUser, .restartRequired:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private func permissionColor(for state: QuickFeaturePermissionState) -> Color {
        switch state {
        case .unknown:
            return .secondary
        case .notGranted, .checking, .waitingForUser, .restartRequired:
            return .orange
        case .granted:
            return .green
        case .failed:
            return .red
        }
    }

    private func permissionRequestIsActive(_ state: QuickFeaturePermissionState) -> Bool {
        switch state {
        case .checking, .waitingForUser, .restartRequired:
            return true
        case .unknown, .notGranted, .granted, .failed:
            return false
        }
    }

    private func openPermissionSettings(for id: QuickFeatureID) {
        switch id {
        case .finderCut:
            helperService.openPermissionSettings(.accessibility)
        case .screenshot:
            helperService.openPermissionSettings(.screenRecording)
        }
    }

    private func refreshPermissions() {
        helperService.refreshAllStatuses()
    }
}

private extension QuickFeatureID {
    var titleKey: String {
        switch self {
        case .finderCut:
            return "quickFeatures.finderCutTitle"
        case .screenshot:
            return "quickFeatures.screenshotTitle"
        }
    }

    var descriptionKey: String {
        switch self {
        case .finderCut:
            return "quickFeatures.finderCutDescription"
        case .screenshot:
            return "quickFeatures.screenshotDescription"
        }
    }

    var systemImage: String {
        switch self {
        case .finderCut:
            return "scissors"
        case .screenshot:
            return "camera.viewfinder"
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut
    let onShortcut: (KeyboardShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onShortcut: onShortcut)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording(_:))
        button.onShortcut = onShortcut
        button.normalTitle = shortcut.displayString
        button.frame.size = NSSize(width: 128, height: 28)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onShortcut = onShortcut
        button.normalTitle = shortcut.displayString
        if !button.isRecording {
            button.title = shortcut.displayString
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let onShortcut: (KeyboardShortcut) -> Void

        init(onShortcut: @escaping (KeyboardShortcut) -> Void) {
            self.onShortcut = onShortcut
        }

        @objc func beginRecording(_ sender: ShortcutRecorderButton) {
            let sessionID = UUID()
            guard QuickFeatureHelperService.shared.beginShortcutRecording(sessionID: sessionID) else {
                return
            }
            sender.recordingSessionID = sessionID
            sender.isRecording = true
            sender.title = L10n.string("quickFeatures.recording")
            sender.window?.makeFirstResponder(sender)
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onShortcut: ((KeyboardShortcut) -> Void)?
    var normalTitle = ""
    var isRecording = false
    var recordingSessionID: UUID?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            finishRecording()
            window?.makeFirstResponder(nil)
            return
        }

        var modifiers: KeyboardShortcut.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        finishRecording()
        window?.makeFirstResponder(nil)
        onShortcut?(KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        title = normalTitle
        if let recordingSessionID {
            QuickFeatureHelperService.shared.endShortcutRecording(sessionID: recordingSessionID)
            self.recordingSessionID = nil
        }
    }
}
