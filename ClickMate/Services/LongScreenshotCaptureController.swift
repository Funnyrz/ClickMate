import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum LongScreenshotCaptureError: LocalizedError {
    case noOverlap
    case limitReached
    case captureFailed
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .noOverlap:
            return L10n.string("screenshot.longNoOverlap")
        case .limitReached:
            return L10n.string("screenshot.longLimitReached")
        case .captureFailed:
            return L10n.string("screenshot.outputFailed")
        case .targetChanged:
            return L10n.string("screenshot.longTargetChanged")
        }
    }
}

@MainActor
final class LongScreenshotCaptureController {
    private let screen: NSScreen
    private let selection: CGRect
    private let targetProcessIdentifier: pid_t?
    private let capture: @MainActor () async throws -> CGImage
    private let showsOverlay: Bool
    private let sleep: @MainActor (Duration) async throws -> Void
    private let targetApplicationIsActiveProvider: (@MainActor () -> Bool)?
    private let screenConfigurationIsValidProvider: (@MainActor () -> Bool)?
    private var onCompleted: ((CGImage, Bool) -> Void)?
    private var onCancelled: (() -> Void)?
    private var onError: ((Error) -> Void)?

    private let assembler: LongScreenshotAssembler
    private let hotKeys = LongScreenshotHotKeyMonitor()
    private var borderPanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private weak var toolbarView: LongScreenshotToolbarView?
    private var captureTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var failureState = LongScreenshotFailureState()
    private var isReady = false
    private var isPaused = false
    private var isFinished = false
    private var isFinishing = false
    private var sampleGeneration = 0
    private var currentSample: LongScreenshotSampleValidity?

    init(
        screen: NSScreen,
        selection: CGRect,
        targetProcessIdentifier: pid_t?,
        capture: @escaping @MainActor () async throws -> CGImage,
        onCompleted: @escaping (CGImage, Bool) -> Void,
        onCancelled: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        showsOverlay: Bool = true,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        targetApplicationIsActive: (@MainActor () -> Bool)? = nil,
        screenConfigurationIsValid: (@MainActor () -> Bool)? = nil,
        beforeAppend: (@Sendable () async -> Void)? = nil
    ) {
        self.screen = screen
        self.selection = selection
        self.targetProcessIdentifier = targetProcessIdentifier
        self.capture = capture
        self.showsOverlay = showsOverlay
        self.sleep = sleep
        targetApplicationIsActiveProvider = targetApplicationIsActive
        screenConfigurationIsValidProvider = screenConfigurationIsValid
        assembler = LongScreenshotAssembler(beforeAppend: beforeAppend)
        self.onCompleted = onCompleted
        self.onCancelled = onCancelled
        self.onError = onError
    }

    func start() {
        guard !isFinished, captureTask == nil else { return }
        if showsOverlay {
            presentOverlay()
            installControls()
        }
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard screenConfigurationIsValid() else { throw LongScreenshotCaptureError.captureFailed }
                guard targetApplicationIsActive() else { throw LongScreenshotCaptureError.targetChanged }
                let firstFrame = try await capture()
                try Task.checkCancellation()
                guard screenConfigurationIsValid() else { throw LongScreenshotCaptureError.captureFailed }
                guard targetApplicationIsActive() else { throw LongScreenshotCaptureError.targetChanged }
                try await assembler.start(with: firstFrame)
                try Task.checkCancellation()
                guard !isFinished, !isFinishing else { return }
                isReady = true
                let metrics = await assembler.metrics
                guard !isFinished, !isFinishing else { return }
                updateToolbar(metrics: metrics)
                await runCaptureLoop()
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
        timeoutTask = Task { [weak self, sleep] in
            do {
                try await sleep(.seconds(60))
            } catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if isReady {
                await finish(reachedLimit: true)
            } else {
                fail(LongScreenshotCaptureError.captureFailed)
            }
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        sampleGeneration += 1
        currentSample?.invalidate()
        failureState.reset()
        cleanup()
        let completion = onCancelled
        clearCallbacks()
        completion?()
    }

    private func installControls() {
        hotKeys.install(
            onReturn: { [weak self] in
                Task { @MainActor in await self?.finish(reachedLimit: false) }
            },
            onEscape: { [weak self] in self?.cancel() }
        )
    }

    private func runCaptureLoop() async {
        while !Task.isCancelled, !isFinished, !isFinishing {
            do {
                try await sleep(.milliseconds(150))
                try Task.checkCancellation()
            } catch { return }
            guard !isFinished, !isFinishing else { return }
            guard !isPaused else { continue }
            let generation = sampleGeneration
            let sample = LongScreenshotSampleValidity()
            currentSample = sample
            do {
                guard screenConfigurationIsValid() else {
                    pause(with: LongScreenshotCaptureError.captureFailed)
                    continue
                }
                guard targetApplicationIsActive() else {
                    pause(with: LongScreenshotCaptureError.targetChanged)
                    continue
                }
                // Each ScreenCaptureKit image is a complete compositor frame. Waiting for
                // scrolling to stop would lose intermediate frames needed for overlap.
                let frame = try await capture()
                try Task.checkCancellation()
                guard sampleIsCurrent(generation) else { continue }
                guard screenConfigurationIsValid() else {
                    pause(with: LongScreenshotCaptureError.captureFailed)
                    continue
                }
                guard targetApplicationIsActive() else {
                    pause(with: LongScreenshotCaptureError.targetChanged)
                    continue
                }
                guard let result = try await assembler.append(frame, sample: sample) else { continue }
                try Task.checkCancellation()
                guard sampleIsCurrent(generation) else { continue }
                let shouldPauseForOverlap = failureState.recordAppend(result)
                if shouldPauseForOverlap {
                    pause(with: LongScreenshotCaptureError.noOverlap)
                    continue
                }
                let metrics = await assembler.metrics
                guard sampleIsCurrent(generation) else { continue }
                updateToolbar(metrics: metrics)
                if metrics.reachedLimit {
                    requestFinishAtLimit()
                    return
                }
            } catch is CancellationError {
                return
            } catch let error as LongScreenshotStitcher.StitchingError {
                guard sampleIsCurrent(generation) else { continue }
                switch error {
                case .pixelHeightLimitExceeded, .rawMemoryLimitExceeded:
                    requestFinishAtLimit()
                    return
                default:
                    pause(with: error)
                }
            } catch {
                guard sampleIsCurrent(generation) else { continue }
                if failureState.recordCaptureFailure() {
                    pause(with: error)
                }
            }
        }
    }

    private func sampleIsCurrent(_ generation: Int) -> Bool {
        !isFinished && !isFinishing && !isPaused && generation == sampleGeneration
    }

    private func requestFinishAtLimit() {
        // Finish drains captureTask; dispatch it outside that task to avoid self-await.
        Task { [weak self] in await self?.finish(reachedLimit: true) }
    }

    private func pause(with error: Error?) {
        guard !isFinished, !isFinishing else { return }
        isPaused = true
        sampleGeneration += 1
        currentSample?.invalidate()
        Task { [weak self] in
            guard let self else { return }
            let metrics = await assembler.metrics
            guard !isFinished, !isFinishing else { return }
            updateToolbar(metrics: metrics)
        }
        if let error {
            onError?(error)
        }
    }

    func togglePause() {
        guard !isFinished, !isFinishing else { return }
        isPaused.toggle()
        sampleGeneration += 1
        currentSample?.invalidate()
        if !isPaused {
            failureState.reset()
        }
        Task { [weak self] in
            guard let self else { return }
            let metrics = await assembler.metrics
            guard !isFinished, !isFinishing else { return }
            updateToolbar(metrics: metrics)
        }
    }

    func finish(reachedLimit: Bool) async {
        guard !isFinished, !isFinishing else { return }
        guard isReady else {
            if reachedLimit { fail(LongScreenshotCaptureError.captureFailed) }
            return
        }
        isFinishing = true
        sampleGeneration += 1
        currentSample?.invalidate()
        captureTask?.cancel()
        // The actor serializes image assembly after admitted synchronous appends.
        // Invalidated samples cannot append later; a stalled screen-capture
        // callback must not prevent exporting the content already committed.
        do {
            let image = try await assembler.makeImage()
            guard !isFinished else { return }
            isFinished = true
            cleanup()
            let completion = onCompleted
            clearCallbacks()
            completion?(image, reachedLimit)
        } catch {
            guard !isFinished else { return }
            isFinished = true
            cleanup()
            let errorHandler = onError
            let cancelHandler = onCancelled
            clearCallbacks()
            errorHandler?(error)
            cancelHandler?()
        }
    }

    private func fail(_ error: Error) {
        guard !isFinished, !isFinishing else { return }
        isFinished = true
        cleanup()
        let errorHandler = onError
        let cancelHandler = onCancelled
        clearCallbacks()
        errorHandler?(error)
        cancelHandler?()
    }

    private func targetApplicationIsActive() -> Bool {
        if let targetApplicationIsActiveProvider { return targetApplicationIsActiveProvider() }
        guard let targetProcessIdentifier else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier
    }

    private func screenConfigurationIsValid() -> Bool {
        if let screenConfigurationIsValidProvider { return screenConfigurationIsValidProvider() }
        return NSScreen.screens.contains { candidate in
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

private final class LongScreenshotSampleValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.withLock { valid = false }
    }

    var isValid: Bool { lock.withLock { valid } }
}

private actor LongScreenshotAssembler {
    private var stitcher: LongScreenshotStitcher?
    private let beforeAppend: (@Sendable () async -> Void)?

    init(beforeAppend: (@Sendable () async -> Void)?) {
        self.beforeAppend = beforeAppend
    }

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
        try Task.checkCancellation()
        stitcher = try LongScreenshotStitcher(firstFrame: image)
    }

    func append(_ image: CGImage, sample: LongScreenshotSampleValidity) async throws -> LongScreenshotAppendResult? {
        await beforeAppend?()
        try Task.checkCancellation()
        // Admission is the commit boundary. A pause invalidates queued samples;
        // synchronous stitching already admitted here is allowed to finish.
        guard sample.isValid else { return nil }
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
