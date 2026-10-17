import AppKit
import XCTest

#if DEBUG

/// Exercises the production Finder menu builder without loading shared settings,
/// registering observers, or dispatching any file operation.
@MainActor
final class FinderMenuDocumentationTests: XCTestCase {
    func testProxyMenuItemRecoversHashActionAndSnapshotWithoutRepresentedObject() throws {
        let directory = try menuFixtureDirectory()
        let file = directory.appendingPathComponent("Selected.txt")
        try Data("selection".utf8).write(to: file)
        let finder = FinderSync(documentationStore: demoStore(in: directory, language: .english))
        let menu = finder.documentationMenu(context: FinderMenuContext(
            kind: .items, selectedURLs: [file], targetedURL: directory
        ))
        let original = try XCTUnwrap(menuItem(in: menu, title: MenuCommand.md5.title))
        let proxy = proxyItem(for: original)

        let action = try XCTUnwrap(finder.documentationAction(
            for: proxy, currentSelectedURLs: [file], currentTargetedURL: directory
        ))

        XCTAssertNil(proxy.representedObject)
        XCTAssertEqual(action.token, .command(.md5))
        XCTAssertEqual(action.context.selectedURLs, [file])
        XCTAssertEqual(action.context.targetedURL, directory)
    }

    func testProxyMenuItemRecoversNewFileActionWithoutRepresentedObject() throws {
        let directory = try menuFixtureDirectory()
        let finder = FinderSync(documentationStore: demoStore(in: directory, language: .english))
        let menu = finder.documentationMenu(context: FinderMenuContext(
            kind: .container, selectedURLs: [], targetedURL: directory
        ))
        let submenu = try XCTUnwrap(menu.items.first { $0.title == MenuCommandGroup.newFile.title }?.submenu)
        let original = try XCTUnwrap(submenu.items.first { $0.tag > 0 })

        let action = try XCTUnwrap(finder.documentationAction(
            for: proxyItem(for: original), currentSelectedURLs: [], currentTargetedURL: directory
        ))

        XCTAssertEqual(action.token, .template(FileTemplate.defaults[0].id))
        XCTAssertEqual(action.context.destinationDirectory, directory)
    }

    func testMenuRebuildExpiresOldTagsWithoutReusingThem() throws {
        let directory = try menuFixtureDirectory()
        let file = directory.appendingPathComponent("Selected.txt")
        try Data().write(to: file)
        let finder = FinderSync(documentationStore: demoStore(in: directory, language: .english))
        let context = FinderMenuContext(kind: .items, selectedURLs: [file], targetedURL: directory)
        let previous = try XCTUnwrap(menuItem(in: finder.documentationMenu(context: context), title: MenuCommand.md5.title))
        let current = try XCTUnwrap(menuItem(in: finder.documentationMenu(context: context), title: MenuCommand.md5.title))

        XCTAssertGreaterThan(current.tag, previous.tag)
        XCTAssertNil(finder.documentationAction(for: previous, currentSelectedURLs: [file], currentTargetedURL: directory))
        XCTAssertNil(finder.documentationAction(for: proxyItem(for: previous), currentSelectedURLs: [file], currentTargetedURL: directory))
        XCTAssertNotNil(finder.documentationAction(for: proxyItem(for: current), currentSelectedURLs: [file], currentTargetedURL: directory))
    }

    func testProxyMenuItemRejectsUnknownTagAndChangedFinderSelection() throws {
        let directory = try menuFixtureDirectory()
        let file = directory.appendingPathComponent("Selected.txt")
        let changed = directory.appendingPathComponent("Changed.txt")
        try Data().write(to: file)
        try Data().write(to: changed)
        let finder = FinderSync(documentationStore: demoStore(in: directory, language: .english))
        let menu = finder.documentationMenu(context: FinderMenuContext(
            kind: .items, selectedURLs: [file], targetedURL: directory
        ))
        let original = try XCTUnwrap(menuItem(in: menu, title: MenuCommand.md5.title))
        let unknown = proxyItem(for: original)
        unknown.tag = Int.max

        XCTAssertNil(finder.documentationAction(for: unknown, currentSelectedURLs: [file], currentTargetedURL: directory))
        XCTAssertNil(finder.documentationAction(for: proxyItem(for: original), currentSelectedURLs: [changed], currentTargetedURL: directory))
    }

    func testDocumentationMenuKeepsProductionSelectionRules() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clickmate-menu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldLanguage = L10n.languageProvider
        L10n.languageProvider = { .english }
        defer { L10n.languageProvider = oldLanguage }
        let store = demoStore(in: directory, language: .english)
        let finder = FinderSync(documentationStore: store)
        let archive = directory.appendingPathComponent("Sample Project.zip")
        let selected = finder.documentationMenu(context: FinderMenuContext(
            kind: .items, selectedURLs: [archive], targetedURL: directory
        ))
        let utilities = try XCTUnwrap(selected.items.first { $0.title == MenuCommandGroup.fileUtilities.title }?.submenu)
        XCTAssertEqual(utilities.items.map(\.title), MenuCommandGroup.fileUtilities.commands.map(\.title))
        XCTAssertTrue(utilities.items.allSatisfy(\.isEnabled))

        let blank = finder.documentationMenu(context: FinderMenuContext(
            kind: .container, selectedURLs: [archive], targetedURL: directory
        ))
        let blankUtilities = try XCTUnwrap(blank.items.first { $0.title == MenuCommandGroup.fileUtilities.title }?.submenu)
        XCTAssertFalse(blankUtilities.items.contains { $0.title == MenuCommand.editArchive.title })
        XCTAssertFalse(try XCTUnwrap(blankUtilities.items.first { $0.title == MenuCommand.moveToNewFolder.title }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(blank.items.first { $0.title == MenuCommandGroup.newFile.title }).hasSubmenu)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path))
    }

    func testGenerateNativeFinderMenuDocumentation() throws {
        guard let path = ProcessInfo.processInfo.environment["CLICKMATE_DOCUMENTATION_OUTPUT"],
              path.hasPrefix("/")
        else { throw XCTSkip("Set CLICKMATE_DOCUMENTATION_OUTPUT to generate native documentation images.") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtureDirectory = output.appendingPathComponent("Finder Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let archive = fixtureDirectory.appendingPathComponent("Sample Project.zip")
        // The menu needs a supported selection; no file action is executed.
        try Data().write(to: archive)
        _ = NSApplication.shared
        let oldLanguage = L10n.languageProvider
        let oldAppearance = NSApp.appearance
        defer {
            L10n.languageProvider = oldLanguage
            NSApp.appearance = oldAppearance
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        NSApp.appearance = NSAppearance(named: .aqua)

        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.languageProvider = { language }
            let store = demoStore(in: fixtureDirectory, language: language)
            let finder = FinderSync(documentationStore: store)
            let menu = finder.documentationMenu(context: FinderMenuContext(
                kind: .items, selectedURLs: [archive], targetedURL: fixtureDirectory
            ))
            let item = try XCTUnwrap(menu.items.first { $0.title == MenuCommandGroup.fileUtilities.title })
            let png = try captureNativeMenu(menu, opening: item)
            let suffix = language == .english ? "en" : "zh-CN"
            try png.write(to: output.appendingPathComponent("clickmate-finder-menu-\(suffix).png"))
        }
    }

    private func demoStore(in directory: URL, language: AppLanguage) -> PreferencesStore {
        let store = PreferencesStore(fileURL: directory.appendingPathComponent("preferences.json"), allowsWrites: false)
        var preferences = ClickMatePreferences.defaults
        preferences.language = language
        preferences.foldedMenuGroups = []
        preferences.pinnedApplicationPaths = []
        // Keep the fixture independent of locally installed third-party apps.
        preferences.detectedApplicationOrder = ["com.apple.Terminal"]
        store.replaceLoadedPreferences(preferences)
        return store
    }

    private func menuFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clickmate-action-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func proxyItem(for original: NSMenuItem) -> NSMenuItem {
        let proxy = NSMenuItem(title: original.title, action: original.action, keyEquivalent: "")
        proxy.tag = original.tag
        return proxy
    }

    private func menuItem(in menu: NSMenu, title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = menuItem(in: submenu, title: title) { return found }
        }
        return nil
    }

    private func captureNativeMenu(_ menu: NSMenu, opening item: NSMenuItem) throws -> Data {
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let host = NSWindow(contentRect: NSRect(x: 40, y: 200, width: 800, height: 500),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = NSColor(white: 0.96, alpha: 1)
        host.appearance = NSAppearance(named: .aqua)
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let state = MenuCaptureState(menu: menu, host: host)
        let navigation = Timer(timeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated {
                do {
                    state.parentMenuBitmaps = try Self.menuBitmaps(from: NSApp.windows.filter {
                        $0 !== state.host && $0.isVisible
                            && !visibleBefore.contains(ObjectIdentifier($0))
                            && String(describing: type(of: $0)).contains("MenuWindow")
                    })
                } catch {
                    state.error = error
                    state.menu.cancelTracking()
                    return
                }
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: state.host.windowNumber, context: nil,
                    characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
                    isARepeat: false, keyCode: 124
                ) else { return }
                // Local AppKit menu tracking only: no system-wide event injection.
                NSApp.postEvent(event, atStart: true)
            }
        }
        let capture = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                defer { state.menu.cancelTracking() }
                do {
                    let windows = NSApp.windows.filter {
                        $0 !== state.host && $0.isVisible
                            && !visibleBefore.contains(ObjectIdentifier($0))
                            && String(describing: type(of: $0)).contains("MenuWindow")
                    }
                    guard windows.count >= 2 else { throw MenuCaptureError.submenuNotVisible }
                    let childBitmaps = try Self.menuBitmaps(from: windows.filter { window in
                        !state.parentMenuBitmaps.contains { $0.frame == window.frame }
                    })
                    // Capture the parent before navigation: AppKit's cached
                    // inactive-menu highlight omits its vibrancy text layers.
                    state.png = try Self.compositeMenuViews(state.parentMenuBitmaps + childBitmaps)
                } catch { state.error = error }
            }
        }
        RunLoop.main.add(navigation, forMode: .common)
        RunLoop.main.add(capture, forMode: .common)
        defer {
            navigation.invalidate()
            capture.invalidate()
        }
        menu.popUp(positioning: item, at: NSPoint(x: 35, y: 220), in: host.contentView)
        if let error = state.error { throw error }
        return try XCTUnwrap(state.png, "Native menu tracking returned before capture.")
    }

    private static func menuBitmaps(from windows: [NSWindow]) throws -> [NativeMenuBitmap] {
        try windows.map { window in
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { throw MenuCaptureError.bitmapUnavailable }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw MenuCaptureError.bitmapUnavailable }
            return NativeMenuBitmap(frame: window.frame, image: image)
        }
    }

    /// Composes actual parent and child menu content bitmaps in their native
    /// relative positions. No desktop, host window, cursor or other app is read.
    private static func compositeMenuViews(_ bitmaps: [NativeMenuBitmap]) throws -> Data {
        let frame = bitmaps.reduce(NSRect.null) { $0.union($1.frame) }
        let padding: CGFloat = 20
        let scale: CGFloat = 2
        let size = NSSize(width: frame.width + padding * 2, height: frame.height + padding * 2)
        let pixels = NSSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        guard let context = CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MenuCaptureError.bitmapUnavailable }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(NSRect(origin: .zero, size: size))
        for bitmap in bitmaps.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let destination = NSRect(x: bitmap.frame.minX - frame.minX + padding,
                                     y: bitmap.frame.minY - frame.minY + padding,
                                     width: bitmap.frame.width, height: bitmap.frame.height)
            context.draw(bitmap.image, in: destination)
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw MenuCaptureError.bitmapUnavailable }
        return png
    }
}

@MainActor
private final class MenuCaptureState {
    let menu: NSMenu
    let host: NSWindow
    var png: Data?
    var error: Error?
    var parentMenuBitmaps: [NativeMenuBitmap] = []

    init(menu: NSMenu, host: NSWindow) {
        self.menu = menu
        self.host = host
    }
}

private struct NativeMenuBitmap {
    let frame: NSRect
    let image: CGImage
}

private enum MenuCaptureError: Error {
    case submenuNotVisible
    case bitmapUnavailable
}

#endif
