import AppKit
import ServiceManagement
import SwiftUI
import XCTest

@MainActor
final class UIRenderingTests: XCTestCase {
    func testQuickFeaturesAndPermissionsRenderInBothLanguages() throws {
        let directory = URL(fileURLWithPath: "/tmp/clickmate-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldProvider = L10n.languageProvider
        defer { L10n.languageProvider = oldProvider }
        let service = QuickFeatureHelperService(
            service: .loginItem(identifier: "com.zxacn.clickmate.tests.render"),
            mainBundleURL: directory.appendingPathComponent("ClickMate.app"),
            isFinderRuntimeChannelAvailable: false,
            presentationSnapshotLoader: {
                QuickFeaturePresentationSnapshot(
                    registrationStatus: .notRegistered, runtimeSnapshot: nil,
                    finderRuntimeSnapshot: nil, finderExtensionStatus: .unknown
                )
            }
        )
        defer { service.stop() }
        for language in [AppLanguage.english, .simplifiedChinese] {
            let store = PreferencesStore(fileURL: directory.appendingPathComponent("tabs.json"), allowsWrites: false)
            store.preferences.language = language
            let observation = AppPreferences.bindLocalization(to: store)
            defer { observation.cancel() }
            let suffix = language == .english ? "en" : "zh"
            try render(QuickFeaturesView(helperService: service).environmentObject(store).padding(20),
                       size: NSSize(width: 940, height: 510), to: directory.appendingPathComponent("quick-features-\(suffix).png"))
            try render(PermissionsView(helperService: service).environmentObject(store).padding(20),
                       size: NSSize(width: 940, height: 510), to: directory.appendingPathComponent("permissions-\(suffix).png"))
        }
    }

    func testTemplatesConfigurationAndGuideRenderInBothLanguages() throws {
        let directory = URL(fileURLWithPath: "/tmp/clickmate-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldProvider = L10n.languageProvider
        defer { L10n.languageProvider = oldProvider }
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.languageProvider = { language }
            let suffix = language == .english ? "en" : "zh"
            let store = PreferencesStore(fileURL: directory.appendingPathComponent("settings-\(suffix).json"), allowsWrites: false)
            store.preferences.language = language
            try render(TemplatesView().environmentObject(store).padding(20),
                       size: NSSize(width: 940, height: 510), to: directory.appendingPathComponent("templates-\(suffix).png"))
            let template = try XCTUnwrap(FileTemplate.defaults.first(where: { $0.id == "json" }))
            try render(FileTemplateEditorView(template: template, isNew: false, onSave: { _ in }),
                       size: NSSize(width: 620, height: 640), to: directory.appendingPathComponent("template-editor-\(suffix).png"))
            try render(SettingsDataView().environmentObject(store), size: NSSize(width: 660, height: 570),
                       to: directory.appendingPathComponent("configuration-\(suffix).png"))
            try render(ScrollView {
                FeaturePermissionGuideView(
                    readiness: [.finderTools: .available, .finderCut: .needsPermission, .screenshot: .restartRequired],
                    selectedFeatures: [.finderTools, .finderCut, .screenshot]
                ).padding(20)
            }, size: NSSize(width: 940, height: 510), to: directory.appendingPathComponent("guide-\(suffix).png"))
        }
    }

    func testNativeTaskAndArchiveViewsRenderInBothLanguages() throws {
        let directory = URL(fileURLWithPath: "/tmp/clickmate-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldProvider = L10n.languageProvider
        defer { L10n.languageProvider = oldProvider }
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.languageProvider = { language }
            let suffix = language == .english ? "en" : "zh"
            let center = FileTaskCenter()
            center.items = [FileTaskItem(
                id: UUID(), title: L10n.string("command.compress"),
                detail: "Project 资料.zip", state: .succeeded,
                outputURLs: [URL(fileURLWithPath: "/tmp/Project 资料.zip")],
                cancellation: FileTaskCancellation()
            )]
            try render(FileTasksView(center: center), size: NSSize(width: 620, height: 430),
                       to: directory.appendingPathComponent("tasks-\(suffix).png"))
            center.items = [FileTaskItem(
                id: UUID(), title: L10n.string("command.moveToNewFolder"),
                detail: L10n.string("tasks.summary", 1, 1), state: .partial,
                results: [
                    FileTaskResult(source: URL(fileURLWithPath: "/tmp/config.json"), destination: URL(fileURLWithPath: "/tmp/New Folder/config.json"), error: nil),
                    FileTaskResult(source: URL(fileURLWithPath: "/tmp/protected.txt"), destination: nil, error: L10n.string("notification.permissionRequired"))
                ], canRestore: true, cancellation: FileTaskCancellation()
            )]
            try render(FileTasksView(center: center), size: NSSize(width: 620, height: 430),
                       to: directory.appendingPathComponent("tasks-partial-\(suffix).png"))
            center.items = [FileTaskItem(
                id: UUID(), title: "SHA-256", detail: "1/2 · Archive.dmg\n512 MB / 1 GB",
                fraction: 0.5, cancellation: FileTaskCancellation()
            )]
            try render(FileTasksView(center: center), size: NSSize(width: 620, height: 430),
                       to: directory.appendingPathComponent("tasks-running-\(suffix).png"))
            let settingsURL = directory.appendingPathComponent("preview-settings-\(suffix).json")
            let store = PreferencesStore(fileURL: settingsURL, allowsWrites: false)
            try render(ArchiveEditorView(model: ArchiveEditorModel()).environmentObject(store),
                       size: NSSize(width: 1180, height: 760),
                       to: directory.appendingPathComponent("archive-\(suffix).png"))
        }
    }

    func render<V: View>(_ root: V, size: NSSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 1000)
        window.orderOut(nil)
        window.contentView = nil
    }
}
