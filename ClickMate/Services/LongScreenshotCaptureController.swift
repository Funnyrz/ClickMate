import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum LongScreenshotCaptureError: LocalizedError {
    case noOverlap
    case limitReached
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noOverlap:
            return L10n.string("screenshot.longNoOverlap")
        case .limitReached:
            return L10n.string("screenshot.longLimitReached")
        case .captureFailed:
            return L10n.string("screenshot.outputFailed")
        }
    }
}

@MainActor
final class LongScreenshotCaptureController {
    private let screen: NSScreen
    private let selection: CGRect
    private let targetProcessIdentifier: pid_t?
    private let capture: @MainActor () async throws -> CGImage
    private var onCompleted: ((CGImage, Bool) -> Void)?
    private var onCancelled: (() -> Void)?
    private var onError: ((Error) -> Void)?

    private let assembler = LongScreenshotAssembler()
    private let hotKeys = LongScreenshotHotKeyMonitor()
    private var borderPanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private weak var toolbarView: LongScreenshotToolbarView?
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var captureTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var duplicateCount = 0
    private var failureCount = 0
    private var isReady = false
    private var hasPendingScroll = false
    private var isPaused = false
    private var isFinished = false

    init(
        screen: NSScreen,
        selection: CGRect,
        targetProcessIdentifier: pid_t?,
        capture: @escaping @MainActor () async throws -> CGImage,
        onCompleted: @escaping (CGImage, Bool) -> Void,
        onCancelled: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.screen = screen
        self.selection = selection
        self.targetProcessIdentifier = targetProcessIdentifier
        self.capture = capture
        self.onCompleted = onCompleted
        self.onCancelled = onCancelled
        self.onError = onError
    }

    func start() {
        guard !isFinished else { return }
        presentOverlay()
        installControls()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let firstFrame = try await capture()
                try Task.checkCancellation()
                try await assembler.start(with: firstFrame)
                isReady = true
                captureTask = nil
                let metrics = await assembler.metrics
                updateToolbar(metrics: metrics)
                if hasPendingScroll {
                    hasPendingScroll = false
                    scheduleCapture()
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.finish(reachedLimit: true)
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        cleanup()
        let completion = onCancelled
        clearCallbacks()
        completion?()
    }

    private func installControls() {
        let handleScroll: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.scheduleCapture()
            }
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { _ in
            handleScroll()
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleScroll()
            return event
        }
        hotKeys.install(
            onReturn: { [weak self] in
                Task { @MainActor in await self?.finish(reachedLimit: false) }
            },
            onEscape: { [weak self] in self?.cancel() }
        )
    }

    private func scheduleCapture(delay: Duration = .milliseconds(320)) {
        guard !isFinished, !isPaused else { return }
        guard isReady else {
            hasPendingScroll = true
            return
        }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                guard screenConfigurationIsValid() else {
                    pause(with: LongScreenshotCaptureError.captureFailed)
                    return
                }
                guard targetApplicationIsActive() else {
                    failureCount += 1
                    if failureCount >= 3 {
                        pause(with: LongScreenshotCaptureError.captureFailed)
                    } else {
                        scheduleCapture(delay: .milliseconds(250))
                    }
                    return
                }
                let firstSample = try await capture()
                try await Task.sleep(for: .milliseconds(120))
                let stableSample = try await capture()
                try Task.checkCancellation()
                guard LongScreenshotFrameComparator.difference(firstSample, stableSample) < 3.2 else {
                    scheduleCapture(delay: .milliseconds(180))
                    return
                }
                let result = try await assembler.append(stableSample)
                failureCount = 0
                switch result {
                case .appended:
                    duplicateCount = 0
                case .duplicate:
                    duplicateCount += 1
                    if duplicateCount >= 3 {
                        await finish(reachedLimit: false)
                        return
                    }
                case .noOverlap:
                    failureCount += 1
                    if failureCount >= 2 {
                        pause(with: LongScreenshotCaptureError.noOverlap)
                        return
                    }
                    scheduleCapture(delay: .milliseconds(240))
                }
                let metrics = await assembler.metrics
                updateToolbar(metrics: metrics)
                if metrics.reachedLimit {
                    await finish(reachedLimit: true)
                }
            } catch is CancellationError {
                return
            } catch let error as LongScreenshotStitcher.StitchingError {
                switch error {
                case .pixelHeightLimitExceeded, .rawMemoryLimitExceeded:
                    await finish(reachedLimit: true)
                default:
                    failureCount += 1
                    pause(with: error)
                }
            } catch {
                failureCount += 1
                if failureCount >= 3 {
                    pause(with: error)
                } else {
                    scheduleCapture(delay: .milliseconds(250))
                }
            }
        }
    }

    private func pause(with error: Error?) {
        guard !isFinished else { return }
        isPaused = true
        captureTask?.cancel()
        captureTask = nil
        Task { [weak self] in
            guard let self else { return }
            let metrics = await assembler.metrics
            updateToolbar(metrics: metrics)
        }
        if let error {
            onError?(error)
        }
    }

    private func togglePause() {
        guard !isFinished else { return }
        isPaused.toggle()
        if !isPaused {
            duplicateCount = 0
            failureCount = 0
            scheduleCapture(delay: .milliseconds(180))
        }
        Task { [weak self] in
            guard let self else { return }
            let metrics = await assembler.metrics
            updateToolbar(metrics: metrics)
        }
    }

    private func finish(reachedLimit: Bool) async {
        guard !isFinished, isReady else { return }
        isFinished = true
        captureTask?.cancel()
        do {
            let image = try await assembler.makeImage()
            cleanup()
            let completion = onCompleted
            clearCallbacks()
            completion?(image, reachedLimit)
        } catch {
            cleanup()
            let errorHandler = onError
            let cancelHandler = onCancelled
            clearCallbacks()
            errorHandler?(error)
            cancelHandler?()
        }
    }

    private func fail(_ error: Error) {
        guard !isFinished else { return }
        isFinished = true
        cleanup()
        let errorHandler = onError
        let cancelHandler = onCancelled
        clearCallbacks()
        errorHandler?(error)
        cancelHandler?()
    }

    private func targetApplicationIsActive() -> Bool {
        guard let targetProcessIdentifier else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier
    }

    private func screenConfigurationIsValid() -> Bool {
        NSScreen.screens.contains { candidate in
            candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                && candidate.frame.size == screen.frame.size
        }
    }

    private func updateToolbar(metrics: LongScreenshotMetrics) {
        toolbarView?.update(
            frameCount: metrics.frameCount,
            pixelHeight: metrics.pixelHeight,
            isPaused: isPaused
        )
    }

    private func presentOverlay() {
        let borderView = LongScreenshotBorderView(frame: CGRect(origin: .zero, size: screen.frame.size))
        borderView.selection = selection
        let borderPanel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        borderPanel.contentView = borderView
        borderPanel.isOpaque = false
        borderPanel.backgroundColor = .clear
        borderPanel.level = .screenSaver
        borderPanel.hasShadow = false
        borderPanel.ignoresMouseEvents = true
        borderPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderPanel.orderFrontRegardless()
        self.borderPanel = borderPanel

        let toolbarView = LongScreenshotToolbarView(frame: CGRect(x: 0, y: 0, width: 360, height: 46))
        toolbarView.onTogglePause = { [weak self] in self?.togglePause() }
        toolbarView.onFinish = { [weak self] in
            Task { @MainActor in await self?.finish(reachedLimit: false) }
        }
        toolbarView.onCancel = { [weak self] in self?.cancel() }
        let toolbarFrame = toolbarFrame(size: toolbarView.frame.size)
        let toolbarPanel = NSPanel(
            contentRect: toolbarFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toolbarPanel.contentView = toolbarView
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.level = .screenSaver
        toolbarPanel.hasShadow = true
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbarPanel.orderFrontRegardless()
        self.toolbarView = toolbarView
        self.toolbarPanel = toolbarPanel
    }

    private func toolbarFrame(size: CGSize) -> CGRect {
        let visible = screen.visibleFrame
        let globalSelection = selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        var origin = CGPoint(x: globalSelection.maxX - size.width, y: globalSelection.minY - size.height - 8)
        if origin.y < visible.minY {
            origin.y = min(globalSelection.maxY + 8, visible.maxY - size.height)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }

    private func cleanup() {
        captureTask?.cancel()
        captureTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        hotKeys.invalidate()
        borderPanel?.orderOut(nil)
        borderPanel?.close()
        borderPanel = nil
        toolbarPanel?.orderOut(nil)
        toolbarPanel?.close()
        toolbarPanel = nil
    }

    private func clearCallbacks() {
        onCompleted = nil
        onCancelled = nil
        onError = nil
    }
}

private actor LongScreenshotAssembler {
    private var stitcher: LongScreenshotStitcher?

    var metrics: LongScreenshotMetrics {
        guard let stitcher else { return LongScreenshotMetrics(frameCount: 0, pixelHeight: 0, reachedLimit: false) }
        return LongScreenshotMetrics(
            frameCount: stitcher.frameCount,
            pixelHeight: stitcher.pixelHeight,
            reachedLimit: stitcher.pixelHeight >= stitcher.limits.maxPixelHeight
                || stitcher.estimatedRawBytes >= stitcher.limits.maxRawBytes
        )
    }

    func start(with image: CGImage) throws {
        stitcher = try LongScreenshotStitcher(firstFrame: image)
    }

    func append(_ image: CGImage) throws -> LongScreenshotAppendResult {
        guard let stitcher else { throw LongScreenshotCaptureError.captureFailed }
        return try stitcher.append(image)
    }

    func makeImage() throws -> CGImage {
        guard let stitcher else { throw LongScreenshotCaptureError.captureFailed }
        return try stitcher.makeImage()
    }
}

private struct LongScreenshotMetrics {
    let frameCount: Int
    let pixelHeight: Int
    let reachedLimit: Bool
}

private enum LongScreenshotFrameComparator {
    static func difference(_ first: CGImage, _ second: CGImage) -> Double {
        guard let firstSamples = samples(first), let secondSamples = samples(second),
              firstSamples.count == secondSamples.count
        else { return .greatestFiniteMagnitude }
        let total = zip(firstSamples, secondSamples).reduce(0.0) { result, pair in
            result + abs(Double(pair.0) - Double(pair.1))
        }
        return total / Double(max(firstSamples.count, 1))
    }

    private static func samples(_ image: CGImage) -> [UInt8]? {
        let width = 32
        let height = 32
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}

private final class LongScreenshotBorderView: NSView {
    var selection: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selection.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
    }
}

private final class LongScreenshotToolbarView: NSVisualEffectView {
    var onTogglePause: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingMiddle

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.toolTip = L10n.string("screenshot.longPause")
        pauseButton.setAccessibilityLabel(L10n.string("screenshot.longPause"))
        let finishButton = NSButton(title: L10n.string("screenshot.longFinish"), target: self, action: #selector(finish))
        finishButton.bezelStyle = .rounded
        finishButton.toolTip = L10n.string("screenshot.longFinish")
        finishButton.setAccessibilityLabel(L10n.string("screenshot.longFinish"))
        let cancelButton = NSButton(title: L10n.string("screenshot.cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.toolTip = L10n.string("screenshot.cancel")
        cancelButton.setAccessibilityLabel(L10n.string("screenshot.cancel"))

        let stack = NSStackView(views: [statusLabel, pauseButton, finishButton, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(frameCount: Int, pixelHeight: Int, isPaused: Bool) {
        let key = isPaused ? "screenshot.longPaused" : "screenshot.longCapturing"
        statusLabel.stringValue = String(format: L10n.string(key), frameCount, pixelHeight)
        let pauseKey = isPaused ? "screenshot.longContinue" : "screenshot.longPause"
        pauseButton.title = L10n.string(pauseKey)
        pauseButton.toolTip = L10n.string(pauseKey)
        pauseButton.setAccessibilityLabel(L10n.string(pauseKey))
    }

    @objc private func togglePause() { onTogglePause?() }
    @objc private func finish() { onFinish?() }
    @objc private func cancel() { onCancel?() }
}

@MainActor
private final class LongScreenshotHotKeyMonitor {
    private static let signature: OSType = 0x434D_4C53
    private var eventHandler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var onReturn: (() -> Void)?
    private var onEscape: (() -> Void)?

    func install(onReturn: @escaping () -> Void, onEscape: @escaping () -> Void) {
        self.onReturn = onReturn
        self.onEscape = onEscape
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        ) == noErr else { return }
        register(keyCode: UInt32(kVK_Return), identifier: 1)
        register(keyCode: UInt32(kVK_Escape), identifier: 2)
    }

    func invalidate() {
        for reference in references {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onReturn = nil
        onEscape = nil
    }

    private func register(keyCode: UInt32, identifier: UInt32) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        if RegisterEventHotKey(
            keyCode,
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        ) == noErr, let reference {
            references.append(reference)
        }
    }

    private static let handler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        guard GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        ) == noErr, identifier.signature == LongScreenshotHotKeyMonitor.signature
        else { return OSStatus(eventNotHandledErr) }
        let monitor = Unmanaged<LongScreenshotHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
        return MainActor.assumeIsolated {
            switch identifier.id {
            case 1: monitor.onReturn?()
            case 2: monitor.onEscape?()
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }
    }
}
