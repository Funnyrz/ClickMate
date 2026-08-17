import AppKit
import SwiftUI

struct QuickFeaturesView: View {
    @EnvironmentObject private var store: PreferencesStore
    @ObservedObject private var permissionMonitor = QuickFeaturePermissionMonitor.shared
    @State private var validationMessages: [QuickFeatureID: String] = [:]
    @State private var registrationFailures: Set<QuickFeatureID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("quickFeatures.title"))
                    .font(.title2.bold())
                Text(L10n.string("quickFeatures.description"))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 12) {
                    featureCard(for: .finderCut)
                    featureCard(for: .screenshot)
                }
                .padding(.vertical, 2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickFeatureRuntimeStatusChanged)) { notification in
            registrationFailures = Set(notification.userInfo?["failedIDs"] as? [QuickFeatureID] ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onAppear {
            refreshPermissions()
        }
    }

    private func featureCard(for id: QuickFeatureID) -> some View {
        let setting = settings(for: id)
        let permissionGranted = permissionIsGranted(for: id)
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
                    permissionGranted
                        ? L10n.string("quickFeatures.permissionGranted")
                        : L10n.string("quickFeatures.permissionMissing"),
                    systemImage: permissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(permissionGranted ? .green : .orange)
            }

            if !permissionGranted {
                HStack {
                    Button(L10n.string("quickFeatures.requestPermission")) {
                        requestPermission(for: id)
                    }
                    Button(L10n.string("quickFeatures.openSettings")) {
                        openPermissionSettings(for: id)
                    }
                    if id == .screenshot {
                        Button(L10n.string("permissions.restartApplication")) {
                            QuickFeaturePermissions.relaunchApplication()
                        }
                    }
                    Spacer()
                }
            }

            if let message = validationMessages[id] {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if registrationFailures.contains(id) {
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
        registrationFailures.remove(id)
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
        switch id {
        case .finderCut:
            return permissionMonitor.snapshot.accessibilityGranted
        case .screenshot:
            return permissionMonitor.snapshot.screenRecordingGranted
        }
    }

    private func requestPermission(for id: QuickFeatureID) {
        switch id {
        case .finderCut:
            QuickFeaturePermissions.requestAccessibilityAccess()
        case .screenshot:
            QuickFeaturePermissions.requestScreenRecordingAccess()
        }
        refreshPermissions()
    }

    private func openPermissionSettings(for id: QuickFeatureID) {
        switch id {
        case .finderCut:
            QuickFeaturePermissions.openAccessibilitySettings()
        case .screenshot:
            QuickFeaturePermissions.openScreenRecordingSettings()
        }
    }

    private func refreshPermissions() {
        permissionMonitor.refresh()
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
            sender.isRecording = true
            sender.title = L10n.string("quickFeatures.recording")
            NotificationCenter.default.post(
                name: .quickFeatureShortcutRecordingChanged,
                object: nil,
                userInfo: ["isRecording": true]
            )
            sender.window?.makeFirstResponder(sender)
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onShortcut: ((KeyboardShortcut) -> Void)?
    var normalTitle = ""
    var isRecording = false

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
        NotificationCenter.default.post(
            name: .quickFeatureShortcutRecordingChanged,
            object: nil,
            userInfo: ["isRecording": false]
        )
    }
}

extension Notification.Name {
    static let quickFeatureRuntimeStatusChanged = Notification.Name("ClickMate.quickFeatureRuntimeStatusChanged")
    static let quickFeatureShortcutRecordingChanged = Notification.Name("ClickMate.quickFeatureShortcutRecordingChanged")
}
