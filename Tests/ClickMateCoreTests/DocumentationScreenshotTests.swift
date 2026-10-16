import AppKit
import ServiceManagement
import SwiftUI
import XCTest

#if DEBUG

/// Opt-in native UI captures. Fixtures live under the ignored build directory;
/// no system permission, shared preference, or clipboard operation is performed.
@MainActor
final class DocumentationScreenshotTests: XCTestCase {
    func testGenerateReadmeScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["CLICKMATE_DOCUMENTATION_OUTPUT"] else {
            throw XCTSkip("Run Scripts/generate_documentation_images.sh to generate documentation images.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = output.deletingLastPathComponent().appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let previousProvider = L10n.languageProvider
        defer { L10n.languageProvider = previousProvider }
        let archive = try makeDemoArchive(in: fixtures)
        let screen = try XCTUnwrap(NSScreen.main)

        for language in [AppLanguage.english, .simplifiedChinese] {
            let chinese = language == .simplifiedChinese
            let suffix = chinese ? "zh-CN" : "en"
            let settingsURL = fixtures.appendingPathComponent("settings-\(suffix).json")
            var preferences = ClickMatePreferences.defaults
            preferences.language = language
            preferences.hasDismissedPermissionGuide = true
            preferences.pinnedApplicationPaths = ["/System/Applications/Utilities/Terminal.app", "/System/Applications/TextEdit.app"]
            preferences.monitoredFolderPaths = [fixtures.path]
            preferences.menuCommandOrder = [.newFile, .editArchive, .compress, .moveToNewFolder, .createAlias, .sha256, .copyPOSIXPath, .openTerminal, .metadata, .toggleHiddenFiles]
            preferences.templates = FileTemplate.defaults.filter { ["txt", "md", "json"].contains($0.id) }
            let customTemplate = FileTemplate(id: "documentation-template", displayName: chinese ? "项目说明" : "Project Notes",
                fileExtension: "md", defaultBasename: "Project-Notes", contents: chinese
                ? "# 项目说明\n\n## 目标\n说明本次工作的目标。\n\n## 检查清单\n- [ ] 检查内容\n- [ ] 分享前移除隐私信息\n"
                : "# Project Notes\n\n## Goal\nDescribe the work to be done.\n\n## Checklist\n- [ ] Review the content\n- [ ] Remove private information before sharing\n")
            preferences.templates.append(customTemplate)
            preferences.quickFeatureSettings = preferences.quickFeatureSettings.map { setting in
                var setting = setting
                setting.isEnabled = true
                return setting
            }
            try JSONEncoder().encode(preferences).write(to: settingsURL)
            let backup = settingsURL.deletingPathExtension().appendingPathExtension("backup.json")
            try JSONEncoder().encode(preferences).write(to: backup)
            let store = PreferencesStore(fileURL: settingsURL, allowsWrites: false)
            let observation = AppPreferences.bindLocalization(to: store)
            defer { observation.cancel() }
            let service = QuickFeatureHelperService(
                service: .loginItem(identifier: "com.zxacn.clickmate.documentation"),
                mainBundleURL: fixtures.appendingPathComponent("ClickMate.app"),
                isFinderRuntimeChannelAvailable: false,
                presentationSnapshotLoader: {
                    QuickFeaturePresentationSnapshot(registrationStatus: .notRegistered, runtimeSnapshot: nil,
                        finderRuntimeSnapshot: nil, finderExtensionStatus: .unknown)
                }
            )
            defer { service.stop() }
            func destination(_ scene: String) -> URL {
                output.appendingPathComponent("clickmate-\(scene)-\(suffix).png")
            }
            try render(MenusView().environmentObject(store).padding(22), title: L10n.string("tab.menus"),
                       size: NSSize(width: 980, height: 590), to: destination("settings-menus"))
            try render(MenuLayoutView().environmentObject(store).padding(22), title: L10n.string("tab.layout"),
                       size: NSSize(width: 980, height: 620), to: destination("settings-layout"))
            try render(FileTemplateEditorView(template: customTemplate, isNew: false, onSave: { _ in }),
                       title: L10n.string("templates.editTitle"), size: NSSize(width: 620, height: 640), to: destination("template-editor"))
            try render(AppsView().environmentObject(store).padding(22), title: L10n.string("tab.apps"),
                       size: NSSize(width: 980, height: 590), to: destination("settings-apps"))
            try render(QuickFeaturesView(helperService: service).environmentObject(store).padding(22),
                       title: L10n.string("tab.quickFeatures"), size: NSSize(width: 980, height: 550), to: destination("quick-features"))
            try render(PermissionsView(helperService: service).environmentObject(store).padding(22),
                       title: L10n.string("tab.permissions"), size: NSSize(width: 980, height: 590), to: destination("permissions"))
            try render(SettingsDataView().environmentObject(store), title: L10n.string("settingsData.title"),
                       size: NSSize(width: 660, height: 570), to: destination("settings-data"))

            let model = ArchiveEditorModel()
            model.open(archive)
            model.selectEntry(named: "config.json")
            model.editorText = "{\n  \"name\": \"ClickMate Demo\",\n  \"environment\": \"preview\",\n  \"features\": {\n    \"templates\": true,\n    \"screenshots\": true,\n    \"fileTasks\": true\n  },\n  \"notes\": \"Review before saving\"\n}\n"
            // Searching for the next entry keeps the current draft open, without
            // AppKit's uncapturable glass sidebar selection effect in the image.
            model.searchText = ".md"
            XCTAssertTrue(model.isEditable)
            XCTAssertTrue(model.isDirty)
            try render(ArchiveEditorView(model: model).environmentObject(store), title: L10n.string("archive.windowTitle"),
                       size: NSSize(width: 1180, height: 680), to: destination("archive-editor"))
            XCTAssertEqual(model.selectedEntryName, "config.json")
            XCTAssertNil(model.pendingAction)

            let center = FileTaskCenter(presentsWindows: false, clipboardWriter: { _ in XCTFail("Screenshot fixtures must not write the clipboard"); return false })
            let safeDemo = URL(fileURLWithPath: "/tmp/ClickMate-Demo", isDirectory: true)
            center.items = [
                FileTaskItem(id: UUID(), title: "SHA-256", detail: "Release.dmg · 384 MB / 640 MB", fraction: 0.6, cancellation: FileTaskCancellation()),
                FileTaskItem(id: UUID(), title: L10n.string("command.compress"), detail: "Project.zip", state: .succeeded,
                    outputURLs: [safeDemo.appendingPathComponent("Project.zip")], cancellation: FileTaskCancellation()),
                FileTaskItem(id: UUID(), title: L10n.string("command.moveToNewFolder"), detail: L10n.string("tasks.summary", 2, 1), state: .partial,
                    results: [
                        FileTaskResult(source: safeDemo.appendingPathComponent("Notes.md"), destination: safeDemo.appendingPathComponent("Review/Notes.md"), error: nil),
                        FileTaskResult(source: safeDemo.appendingPathComponent("config.json"), destination: safeDemo.appendingPathComponent("Review/config.json"), error: nil),
                        FileTaskResult(source: safeDemo.appendingPathComponent("Protected.txt"), destination: nil, error: L10n.string("notification.permissionRequired"))
                    ], canRestore: true, cancellation: FileTaskCancellation())
            ]
            try render(FileTasksView(center: center), title: L10n.string("tasks.title"),
                       size: NSSize(width: 820, height: 650), to: destination("file-tasks"))

            let size = CGSize(width: 1000, height: 700)
            let page = try demoPage(chinese: chinese, size: size)
            let session = ScreenshotSessionModel(image: page, screenSize: size)
            session.setSelection(CGRect(x: 34, y: 78, width: 932, height: 580))
            session.enterEditing()
            session.addAnnotation(.rectangle(CGRect(x: 40, y: 537, width: chinese ? 300 : 390, height: 55), .default))
            session.addAnnotation(.arrow(start: CGPoint(x: 650, y: 480), end: CGPoint(x: 876, y: 350), style: .init(color: .blue, lineWidth: 4)))
            session.addAnnotation(.text(origin: CGPoint(x: 580, y: 565), text: chinese ? "分享前检查内容" : "Review before sharing", style: .init(color: .red, lineWidth: 4)))
            let selection = ScreenshotSelectionController.documentationView(model: session, size: size)
            try renderNative(selection, title: chinese ? "截图标注" : "Screenshot Annotation", size: size,
                             to: destination("screenshot-annotation"))
            let longImage = try demoPage(chinese: chinese, size: CGSize(width: 1000, height: 1800))
            let preview = LongScreenshotPreviewWindowController(screen: screen, image: longImage,
                defaultFileName: { "ClickMate-Demo.png" }, copyImage: { _ in XCTFail("No clipboard writes") },
                saveImage: { _, _ in XCTFail("No export dialogs") }, onClose: {}, onError: { XCTFail($0.localizedDescription) }, onOutputSuccess: {})
            let window = try XCTUnwrap(preview.documentationWindow)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            try snapshot(window, to: destination("scrolling-capture"))
            preview.close()
        }
    }

    private func makeDemoArchive(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("archive-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("{\n  \"name\": \"ClickMate Demo\",\n  \"environment\": \"development\"\n}\n".utf8).write(to: source.appendingPathComponent("config.json"))
        try Data("# ClickMate Demo\n\nOnly example content is used in documentation.\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data("# Release Notes\n\n- Review the content\n- Save a backup\n".utf8).write(to: source.appendingPathComponent("docs/Release-Notes.md"))
        let archive = directory.appendingPathComponent("ClickMate-Demo.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-r", archive.path, "config.json", "README.md", "docs"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func render<V: View>(_ root: V, title: String, size: NSSize, to url: URL) throws {
        let view = NSHostingView(rootView: root
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            .tint(.blue)
            .background(Color(nsColor: .windowBackgroundColor)))
        try renderNative(view, title: title, size: size, to: url)
    }

    private func renderNative(_ view: NSView, title: String, size: NSSize, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ClickMate — \(title)"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try snapshot(window, to: url)
    }

    private func snapshot(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertGreaterThan(bitmap.pixelsWide, 600)
    }

    private func demoPage(chinese: Bool, size: CGSize) throws -> CGImage {
        let root = DocumentationDemoPage(chinese: chinese, isLong: size.height > 1000)
            .frame(width: size.width, height: size.height, alignment: .top).background(Color.white)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }
}

private struct DocumentationDemoPage: View {
    let chinese: Bool
    let isLong: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Label("ClickMate Demo", systemImage: "cursorarrow.click").font(.headline).foregroundStyle(.blue)
                Spacer()
                Text(chinese ? "演示内容 · 不含个人数据" : "Demo content · No personal data").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(chinese ? "发布检查清单" : "Release checklist").font(.system(size: 38, weight: .bold))
                Text(chinese ? "整理文件、检查内容，再把结果分享出去。" : "Organize your files, review the details, then share the result.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                card(chinese ? "准备文件" : "Prepare files", detail: "Project.zip · Notes.md", icon: "folder", color: .blue)
                card(chinese ? "检查内容" : "Review content", detail: chinese ? "3 项检查已完成" : "3 checks completed", icon: "checkmark.shield", color: .green)
            }
            ForEach(0..<(isLong ? 9 : 2), id: \.self) { index in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(String(format: "%02d", index + 1)).font(.headline.monospaced()).foregroundStyle(.blue)
                        Text(chinese ? "检查项目 \(index + 1)" : "Review item \(index + 1)").font(.headline)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(chinese ? "示例文件用于展示截图、长截图和标注。分享前请检查文件名、路径和敏感信息。" : "Example files demonstrate capture, scrolling capture, and annotations. Review filenames, paths, and sensitive content before sharing.")
                        .font(.body).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer(minLength: 0)
        }.padding(46)
    }

    private func card(_ title: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(title).font(.title3.bold())
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

#endif
