import AppKit
import Combine
import CoreGraphics
import ScreenCaptureKit

enum ScreenshotCaptureMode {
    case region
    case fullScreen
}

enum ScreenshotError: LocalizedError {
    case permissionDenied
    case displayUnavailable
    case invalidSelection
    case captureFailed(Error)
    case imageEncodingFailed
    case pasteboardWriteFailed
    case desktopUnavailable
    case saveFailed(Error)
    case outputSelectionRequired

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L10n.string("permissions.screenRecordingMissing")
        case .displayUnavailable,
             .invalidSelection,
             .captureFailed,
             .imageEncodingFailed,
             .pasteboardWriteFailed,
             .desktopUnavailable,
             .saveFailed,
             .outputSelectionRequired:
            return L10n.string("screenshot.outputFailed")
        }
    }

    var failureReason: String? {
        switch self {
        case let .captureFailed(error), let .saveFailed(error):
            return error.localizedDescription
        default:
            return nil
        }
    }
}

@MainActor
final class ScreenshotService {
    func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    func requestCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func capture(screen: NSScreen, selection: CGRect? = nil) async throws -> CGImage {
        guard requestCaptureAccess() else {
            throw ScreenshotError.permissionDenied
        }

        guard let displayID = screen.displayID else {
            throw ScreenshotError.displayUnavailable
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotError.displayUnavailable
            }

            let currentProcessID = ProcessInfo.processInfo.processIdentifier
            let currentBundleIdentifier = Bundle.main.bundleIdentifier
            let currentApplications = content.applications.filter {
                $0.processID == currentProcessID
                    || (currentBundleIdentifier != nil && $0.bundleIdentifier == currentBundleIdentifier)
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: currentApplications,
                exceptingWindows: []
            )
            let sourceRect = try validatedSourceRect(selection, display: display)
            let scale = max(CGFloat(filter.pointPixelScale), 1)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = max(Int(ceil(sourceRect.width * scale)), 1)
            configuration.height = max(Int(ceil(sourceRect.height * scale)), 1)
            configuration.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch let error as ScreenshotError {
            throw error
        } catch {
            throw ScreenshotError.captureFailed(error)
        }
    }

    func copyToPasteboard(_ image: CGImage) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let pngData = bitmap.representation(using: .png, properties: [:])
        let tiffData = bitmap.representation(using: .tiff, properties: [:])
        guard pngData != nil || tiffData != nil else {
            throw ScreenshotError.imageEncodingFailed
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrotePNG = pngData.map { pasteboard.setData($0, forType: .png) } ?? false
        let wroteTIFF = tiffData.map { pasteboard.setData($0, forType: .tiff) } ?? false
        guard wrotePNG || wroteTIFF else {
            throw ScreenshotError.pasteboardWriteFailed
        }
    }

    func crop(_ image: CGImage, screenSize: CGSize, selection: CGRect) throws -> CGImage {
        guard screenSize.width > 0, screenSize.height > 0 else {
            throw ScreenshotError.invalidSelection
        }
        let normalizedSelection = selection.standardized.intersection(
            CGRect(origin: .zero, size: screenSize)
        )
        guard !normalizedSelection.isNull,
              normalizedSelection.width >= 1,
              normalizedSelection.height >= 1
        else {
            throw ScreenshotError.invalidSelection
        }

        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let pixelRect = CGRect(
            x: normalizedSelection.minX * scaleX,
            y: (screenSize.height - normalizedSelection.maxY) * scaleY,
            width: normalizedSelection.width * scaleX,
            height: normalizedSelection.height * scaleY
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !pixelRect.isNull, let croppedImage = image.cropping(to: pixelRect) else {
            throw ScreenshotError.invalidSelection
        }
        return croppedImage
    }

    func savePNGToDesktop(_ image: CGImage, date: Date = Date()) throws -> URL {
        guard let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            throw ScreenshotError.desktopUnavailable
        }

        let baseName = defaultFileName(date: date).replacingOccurrences(of: ".png", with: "")

        do {
            var suffix = 1
            while true {
                let fileName = suffix == 1 ? "\(baseName).png" : "\(baseName)-\(suffix).png"
                let destination = desktopURL.appendingPathComponent(fileName, isDirectory: false)
                do {
                    try savePNG(image, to: destination, options: [.atomic, .withoutOverwriting])
                    return destination
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    suffix += 1
                }
            }
        } catch {
            throw ScreenshotError.saveFailed(error)
        }
    }

    func savePNG(_ image: CGImage, to destination: URL) throws {
        do {
            try savePNG(image, to: destination, options: .atomic)
        } catch let error as ScreenshotError {
            throw error
        } catch {
            throw ScreenshotError.saveFailed(error)
        }
    }

    func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "ClickMate Screenshot \(formatter.string(from: date)).png"
    }

    private func savePNG(
        _ image: CGImage,
        to destination: URL,
        options: Data.WritingOptions
    ) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.imageEncodingFailed
        }
        try pngData.write(to: destination, options: options)
    }

    private func validatedSourceRect(_ selection: CGRect?, display: SCDisplay) throws -> CGRect {
        let displayBounds = CGRect(
            origin: .zero,
            size: CGSize(width: display.width, height: display.height)
        )
        guard let selection else {
            return displayBounds
        }

        let sourceRect = selection.standardized.intersection(displayBounds).integral
        guard !sourceRect.isNull, sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw ScreenshotError.invalidSelection
        }
        return sourceRect
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

@MainActor
final class ScreenshotCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case selecting
        case capturing
    }

    static let shared = ScreenshotCoordinator()

    @Published private(set) var state: State = .idle
    @Published private(set) var lastErrorMessage: String?

    var errorHandler: ((String) -> Void)?
    var completionHandler: (() -> Void)?

    private let service: ScreenshotService
    private var captureTask: Task<Void, Never>?
    private var selectionController: ScreenshotSelectionController?
    private var captureGeneration = 0

    init(service: ScreenshotService = ScreenshotService()) {
        self.service = service
        super.init()
    }

    @objc func captureRegion() {
        startCapture(.region)
    }

    @objc func captureFullScreen() {
        startCapture(.fullScreen)
    }

    func capture(_ mode: ScreenshotCaptureMode) {
        startCapture(mode)
    }

    @objc func cancel() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        selectionController?.dismiss()
        selectionController = nil
        state = .idle
    }

    private func startCapture(_ mode: ScreenshotCaptureMode) {
        guard state == .idle else {
            report(message: L10n.string("quickFeatures.screenshotInProgress"), resetState: false)
            return
        }
        guard service.requestCaptureAccess() else {
            report(ScreenshotError.permissionDenied)
            return
        }

        captureGeneration += 1
        let generation = captureGeneration
        lastErrorMessage = nil
        guard let screen = service.screenUnderMouse() else {
            report(ScreenshotError.displayUnavailable)
            return
        }
        switch mode {
        case .region:
            prepareSelection(screen: screen, initialFullScreen: false, generation: generation)
        case .fullScreen:
            prepareSelection(screen: screen, initialFullScreen: true, generation: generation)
        }
    }

    private func prepareSelection(screen: NSScreen, initialFullScreen: Bool, generation: Int) {
        state = .capturing
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await service.capture(screen: screen, selection: nil)
                try Task.checkCancellation()
                guard generation == captureGeneration else { return }
                captureTask = nil
                state = .selecting
                let controller = ScreenshotSelectionController(
                    screen: screen,
                    image: image,
                    initialSelection: initialFullScreen
                        ? CGRect(origin: .zero, size: screen.frame.size)
                        : nil,
                    defaultFileName: { [service] in service.defaultFileName() },
                    copyImage: { [service] output in try service.copyToPasteboard(output) },
                    saveImage: { [service] output, destination in
                        try service.savePNG(output, to: destination)
                    },
                    onCompleted: { [weak self] in
                        guard let self, generation == captureGeneration else { return }
                        selectionController = nil
                        state = .idle
                        completionHandler?()
                    },
                    onCancel: { [weak self] in
                        guard let self, generation == captureGeneration else { return }
                        selectionController = nil
                        state = .idle
                    },
                    onError: { [weak self] error in
                        self?.report(error, resetState: false)
                    }
                )
                selectionController = controller
                controller.present()
            } catch is CancellationError {
                guard generation == captureGeneration else { return }
                captureTask = nil
                state = .idle
            } catch {
                guard generation == captureGeneration else { return }
                captureTask = nil
                report(error)
            }
        }
    }

    private func report(_ error: Error, resetState: Bool = true) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? L10n.string("screenshot.outputFailed")
        report(message: message, resetState: resetState)
    }

    private func report(message: String, resetState: Bool = true) {
        if resetState {
            state = .idle
        }
        lastErrorMessage = message
        if let errorHandler {
            errorHandler(message)
        } else {
            NSSound.beep()
        }
    }
}
