import AppKit
import UniformTypeIdentifiers

@MainActor
final class LongScreenshotPreviewWindowController: NSObject, NSWindowDelegate {
    private let model: ScreenshotSessionModel
    private let defaultFileName: () -> String
    private let copyImage: (CGImage) throws -> Void
    private let saveImage: (CGImage, URL) throws -> Void
    private var onClose: (() -> Void)?
    private let onError: (Error) -> Void
    private let onOutputSuccess: () -> Void

    private var previewWindow: NSWindow?
    private let scrollView = LongScreenshotPreviewScrollView()
    private let canvasView: LongScreenshotPreviewCanvasView
    private let toolbarStack = NSStackView()
    private var editingControls: [NSView] = []
    private var toolButtons: [(ScreenshotTool, LongScreenshotPreviewButton)] = []
    private var colorButtons: [(ScreenshotAnnotationColor, LongScreenshotPreviewButton)] = []
    private var widthButtons: [(CGFloat, LongScreenshotPreviewButton)] = []
    private var editButton: LongScreenshotPreviewButton?
    private var undoButton: LongScreenshotPreviewButton?
    private var redoButton: LongScreenshotPreviewButton?
    private var clearButton: LongScreenshotPreviewButton?
    private var editingControlsVisible = false
    private var hasClosed = false

    init(
        screen: NSScreen,
        image: CGImage,
        defaultFileName: @escaping () -> String,
        copyImage: @escaping (CGImage) throws -> Void,
        saveImage: @escaping (CGImage, URL) throws -> Void,
        onClose: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onOutputSuccess: @escaping () -> Void
    ) {
        let imageSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let model = ScreenshotSessionModel(image: image, screenSize: imageSize)
        model.setSelection(CGRect(origin: .zero, size: imageSize))
        model.replaceWithLongScreenshot(image)

        self.model = model
        self.defaultFileName = defaultFileName
        self.copyImage = copyImage
        self.saveImage = saveImage
        self.onClose = onClose
        self.onError = onError
        self.onOutputSuccess = onOutputSuccess
        canvasView = LongScreenshotPreviewCanvasView(model: model)
        super.init()

        let window = makeWindow(screen: screen)
        previewWindow = window
        configureContent(of: window)
        configureToolbar()

        canvasView.onModelChanged = { [weak self] in
            self?.refreshToolbarState()
        }
        canvasView.onError = { [weak self] error in
            self?.onError(error)
        }
        scrollView.onViewportChanged = { [weak self] width in
            self?.canvasView.fitToViewport(width: width)
        }
        refreshToolbarState()
    }

    func present() {
        guard let previewWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        previewWindow.makeKeyAndOrderFront(nil)
        previewWindow.makeFirstResponder(canvasView)
        scrollView.updateDocumentLayout()
    }

    func bringToFront() {
        present()
    }

    func close() {
        previewWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !hasClosed else { return }
        hasClosed = true
        canvasView.cancelTextEditing()
        previewWindow = nil
        let completion = onClose
        onClose = nil
        completion?()
    }

    private func makeWindow(screen: NSScreen) -> NSWindow {
        let visibleFrame = screen.visibleFrame
        let preferredWidth = min(max(visibleFrame.width * 0.72, 960), visibleFrame.width)
        let preferredHeight = min(max(visibleFrame.height * 0.78, 620), visibleFrame.height)
        let frame = CGRect(
            x: visibleFrame.midX - preferredWidth / 2,
            y: visibleFrame.midY - preferredHeight / 2,
            width: preferredWidth,
            height: preferredHeight
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = L10n.string("screenshot.longPreview")
        window.minSize = CGSize(width: min(960, visibleFrame.width), height: min(520, visibleFrame.height))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        return window
    }

    private func configureContent(of window: NSWindow) {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootView

        let toolbarBackground = NSVisualEffectView()
        toolbarBackground.translatesAutoresizingMaskIntoConstraints = false
        toolbarBackground.material = .headerView
        toolbarBackground.blendingMode = .withinWindow
        toolbarBackground.state = .active

        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.distribution = .gravityAreas
        toolbarStack.spacing = 6
        toolbarBackground.addSubview(toolbarStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor.blended(
            withFraction: 0.45,
            of: .black
        ) ?? .darkGray
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4

        rootView.addSubview(toolbarBackground)
        rootView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbarBackground.topAnchor.constraint(equalTo: rootView.topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbarBackground.heightAnchor.constraint(equalToConstant: 50),

            toolbarStack.leadingAnchor.constraint(equalTo: toolbarBackground.leadingAnchor, constant: 10),
            toolbarStack.trailingAnchor.constraint(lessThanOrEqualTo: toolbarBackground.trailingAnchor, constant: -10),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbarBackground.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbarBackground.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func configureToolbar() {
        let edit = makeSymbolButton(
            symbolName: "pencil.and.outline",
            toolTip: L10n.string("screenshot.edit")
        ) { [weak self] in
            self?.toggleEditingControls()
        }
        edit.setButtonType(.toggle)
        editButton = edit
        toolbarStack.addArrangedSubview(edit)

        let toolDefinitions: [(ScreenshotTool, String?, String, String?)] = [
            (.rectangle, "rectangle", L10n.string("screenshot.rectangle"), nil),
            (.arrow, "arrow.up.right", L10n.string("screenshot.arrow"), nil),
            (.pen, "pencil.tip", L10n.string("screenshot.pen"), nil),
            (.text, nil, L10n.string("screenshot.text"), "A"),
            (.mosaic, "square.grid.3x3.fill", L10n.string("screenshot.mosaic"), nil)
        ]
        for (tool, symbolName, toolTip, title) in toolDefinitions {
            let button: LongScreenshotPreviewButton
            if let title {
                button = makeTextButton(title: title, toolTip: toolTip) { [weak self] in
                    self?.selectTool(tool)
                }
            } else {
                button = makeSymbolButton(symbolName: symbolName, toolTip: toolTip) { [weak self] in
                    self?.selectTool(tool)
                }
            }
            button.setButtonType(.toggle)
            toolButtons.append((tool, button))
            addEditingControl(button)
        }

        addEditingControl(makeSeparator())

        for color in ScreenshotAnnotationColor.allCases {
            let button = makeImageButton(
                image: colorIndicatorImage(color.nsColor),
                toolTip: colorToolTip(color)
            ) { [weak self] in
                self?.selectColor(color)
            }
            button.setButtonType(.toggle)
            colorButtons.append((color, button))
            addEditingControl(button)
        }

        addEditingControl(makeSeparator())

        for width in ScreenshotAnnotationStyle.availableLineWidths {
            let button = makeImageButton(
                image: widthIndicatorImage(width),
                toolTip: L10n.string(ScreenshotAnnotationStyle.localizationKey(for: width))
            ) { [weak self] in
                self?.selectWidth(width)
            }
            button.setButtonType(.toggle)
            widthButtons.append((width, button))
            addEditingControl(button)
        }

        addEditingControl(makeSeparator())

        let undo = makeSymbolButton(
            symbolName: "arrow.uturn.backward",
            toolTip: L10n.string("screenshot.undo")
        ) { [weak self] in
            self?.undo()
        }
        undoButton = undo
        addEditingControl(undo)

        let redo = makeSymbolButton(
            symbolName: "arrow.uturn.forward",
            toolTip: L10n.string("screenshot.redo")
        ) { [weak self] in
            self?.redo()
        }
        redoButton = redo
        addEditingControl(redo)

        let clear = makeSymbolButton(
            symbolName: "trash",
            toolTip: L10n.string("screenshot.clear")
        ) { [weak self] in
            self?.clearAnnotations()
        }
        clearButton = clear
        addEditingControl(clear)

        toolbarStack.addArrangedSubview(makeFlexibleSpace())

        let save = makeSymbolButton(
            symbolName: "square.and.arrow.down",
            toolTip: L10n.string("screenshot.save")
        ) { [weak self] in
            self?.presentSavePanel()
        }
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        toolbarStack.addArrangedSubview(save)

        let copy = makeSymbolButton(
            symbolName: "doc.on.doc",
            toolTip: L10n.string("screenshot.copyToClipboard")
        ) { [weak self] in
            self?.copyToPasteboard()
        }
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command]
        toolbarStack.addArrangedSubview(copy)

        let close = makeSymbolButton(
            symbolName: "xmark",
            toolTip: L10n.string("screenshot.close")
        ) { [weak self] in
            self?.close()
        }
        close.keyEquivalent = "w"
        close.keyEquivalentModifierMask = [.command]
        toolbarStack.addArrangedSubview(close)

        setEditingControlsHidden(true)
    }

    private func addEditingControl(_ view: NSView) {
        editingControls.append(view)
        toolbarStack.addArrangedSubview(view)
    }

    private func toggleEditingControls() {
        editingControlsVisible.toggle()
        if editingControlsVisible {
            model.enterEditing()
        } else {
            canvasView.cancelTextEditing()
        }
        canvasView.isAnnotationEnabled = editingControlsVisible
        setEditingControlsHidden(!editingControlsVisible)
        refreshToolbarState()
        previewWindow?.makeFirstResponder(canvasView)
    }

    private func setEditingControlsHidden(_ hidden: Bool) {
        for control in editingControls {
            control.isHidden = hidden
        }
    }

    private func selectTool(_ tool: ScreenshotTool) {
        model.selectedTool = tool
        canvasView.cancelTextEditing()
        refreshToolbarState()
    }

    private func selectColor(_ color: ScreenshotAnnotationColor) {
        model.style.color = color
        canvasView.updateTextEditorStyle()
        refreshToolbarState()
    }

    private func selectWidth(_ width: CGFloat) {
        model.style.lineWidth = width
        canvasView.updateTextEditorStyle()
        refreshToolbarState()
    }

    private func undo() {
        canvasView.cancelTextEditing()
        model.undo()
        canvasView.modelDidChange()
    }

    private func redo() {
        canvasView.cancelTextEditing()
        model.redo()
        canvasView.modelDidChange()
    }

    private func clearAnnotations() {
        canvasView.cancelTextEditing()
        model.clear()
        canvasView.modelDidChange()
    }

    private func refreshToolbarState() {
        editButton?.state = editingControlsVisible ? .on : .off
        for (tool, button) in toolButtons {
            button.state = model.selectedTool == tool ? .on : .off
        }
        for (color, button) in colorButtons {
            button.state = model.style.color == color ? .on : .off
        }
        for (width, button) in widthButtons {
            button.state = abs(model.style.lineWidth - width) < 0.01 ? .on : .off
        }
        undoButton?.isEnabled = model.canUndo
        redoButton?.isEnabled = model.canRedo
        clearButton?.isEnabled = model.canClear
    }

    private func copyToPasteboard() {
        canvasView.commitTextEditing()
        do {
            try copyImage(model.renderedImage())
            onOutputSuccess()
            previewWindow?.makeKeyAndOrderFront(nil)
        } catch {
            onError(error)
        }
    }

    private func presentSavePanel() {
        guard let previewWindow else { return }
        canvasView.commitTextEditing()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = defaultFileName()
        NSApp.activate(ignoringOtherApps: true)
        savePanel.beginSheetModal(for: previewWindow) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = savePanel.url else {
                previewWindow.makeKeyAndOrderFront(nil)
                previewWindow.makeFirstResponder(self.canvasView)
                return
            }
            do {
                try self.saveImage(self.model.renderedImage(), destination)
                self.onOutputSuccess()
            } catch {
                self.onError(error)
            }
            previewWindow.makeKeyAndOrderFront(nil)
            previewWindow.makeFirstResponder(self.canvasView)
        }
    }

    private func makeSymbolButton(
        symbolName: String?,
        toolTip: String,
        handler: @escaping () -> Void
    ) -> LongScreenshotPreviewButton {
        let image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: toolTip)
        }
        if let image {
            return makeImageButton(image: image, toolTip: toolTip, handler: handler)
        }
        return makeTextButton(title: String(toolTip.prefix(1)), toolTip: toolTip, handler: handler)
    }

    private func makeImageButton(
        image: NSImage,
        toolTip: String,
        handler: @escaping () -> Void
    ) -> LongScreenshotPreviewButton {
        let button = makeButton(toolTip: toolTip, handler: handler)
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        return button
    }

    private func makeTextButton(
        title: String,
        toolTip: String,
        handler: @escaping () -> Void
    ) -> LongScreenshotPreviewButton {
        let button = makeButton(toolTip: toolTip, handler: handler)
        button.title = title
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.imagePosition = .noImage
        return button
    }

    private func makeButton(
        toolTip: String,
        handler: @escaping () -> Void
    ) -> LongScreenshotPreviewButton {
        let button = LongScreenshotPreviewButton(handler: handler)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return separator
    }

    private func makeFlexibleSpace() -> NSView {
        let space = NSView()
        space.translatesAutoresizingMaskIntoConstraints = false
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        space.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        return space
    }

    private func colorIndicatorImage(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let circle = rect.insetBy(dx: 1.5, dy: 1.5)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(ovalIn: circle)
            border.lineWidth = 1
            border.stroke()
            return true
        }
    }

    private func widthIndicatorImage(_ width: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let diameter: CGFloat
            switch width {
            case ScreenshotAnnotationStyle.availableLineWidths.first: diameter = 5
            case ScreenshotAnnotationStyle.availableLineWidths.last: diameter = 13
            default: diameter = 9
            }
            let circle = CGRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            return true
        }
    }

    private func colorToolTip(_ color: ScreenshotAnnotationColor) -> String {
        let key: String
        switch color {
        case .red: key = "screenshot.color.red"
        case .yellow: key = "screenshot.color.yellow"
        case .green: key = "screenshot.color.green"
        case .blue: key = "screenshot.color.blue"
        case .white: key = "screenshot.color.white"
        case .black: key = "screenshot.color.black"
        }
        return L10n.string(key)
    }
}

@MainActor
final class LongScreenshotPreviewCanvasView: NSView, NSTextFieldDelegate {
    private let model: ScreenshotSessionModel
    private var annotationStart: CGPoint?
    private var annotationPoints: [CGPoint] = []
    private weak var textField: NSTextField?
    private var pixelatedImages: [Int: CGImage] = [:]

    var isAnnotationEnabled = false {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    var onModelChanged: (() -> Void)?
    var onError: ((Error) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: ScreenshotSessionModel) {
        self.model = model
        let imageSize = CGSize(
            width: CGFloat(model.originalImage.width),
            height: CGFloat(model.originalImage.height)
        )
        super.init(frame: CGRect(origin: .zero, size: imageSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func fitToViewport(width: CGFloat) {
        let fittedWidth = max(width, 1)
        guard abs(frame.width - fittedWidth) > 0.5 else { return }
        let visibleRect = enclosingScrollView?.documentVisibleRect ?? .zero
        let oldScrollableHeight = max(frame.height - visibleRect.height, 1)
        let verticalProgress = min(max(visibleRect.minY / oldScrollableHeight, 0), 1)
        let aspectRatio = CGFloat(model.originalImage.height) / CGFloat(max(model.originalImage.width, 1))
        let fittedHeight = max(fittedWidth * aspectRatio, 1)
        setFrameSize(CGSize(width: fittedWidth, height: fittedHeight))
        needsDisplay = true

        guard let clipView = enclosingScrollView?.contentView else { return }
        let newScrollableHeight = max(fittedHeight - clipView.bounds.height, 0)
        clipView.scroll(to: CGPoint(x: 0, y: newScrollableHeight * verticalProgress))
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    func modelDidChange() {
        pixelatedImages.removeAll()
        needsDisplay = true
        onModelChanged?()
    }

    func updateTextEditorStyle() {
        guard let textField else { return }
        textField.textColor = model.style.color.nsColor
        textField.font = .systemFont(
            ofSize: max(16, model.style.lineWidth * 4),
            weight: .medium
        )
    }

    func commitTextEditing() {
        guard let textField else { return }
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = pointForImage(textField.frame.origin)
        self.textField = nil
        textField.delegate = nil
        textField.removeFromSuperview()
        if !text.isEmpty {
            model.addAnnotation(.text(
                origin: origin,
                text: text,
                style: annotationStyleForImage
            ))
            modelDidChange()
        }
        window?.makeFirstResponder(self)
    }

    func cancelTextEditing() {
        guard let textField else { return }
        self.textField = nil
        textField.delegate = nil
        textField.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isAnnotationEnabled ? .crosshair : .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        dirtyRect.fill()
        NSImage(cgImage: model.originalImage, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        for annotation in model.annotations {
            draw(annotation)
        }
        if let draft = draftAnnotation() {
            draw(draft)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isAnnotationEnabled else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if model.selectedTool == .text {
            beginText(at: point)
            return
        }
        let imagePoint = pointForImage(point)
        annotationStart = imagePoint
        annotationPoints = [imagePoint]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard annotationStart != nil else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        let imagePoint = pointForImage(clamped)
        if model.selectedTool == .pen || model.selectedTool == .mosaic {
            annotationPoints.append(imagePoint)
        } else if annotationPoints.count == 1 {
            annotationPoints.append(imagePoint)
        } else {
            annotationPoints[annotationPoints.count - 1] = imagePoint
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard annotationStart != nil else {
            super.mouseUp(with: event)
            return
        }
        if let annotation = draftAnnotation() {
            model.addAnnotation(annotation)
        }
        annotationStart = nil
        annotationPoints = []
        modelDidChange()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) {
                model.redo()
            } else {
                model.undo()
            }
            modelDidChange()
            return
        }
        if event.keyCode == 53, textField != nil {
            cancelTextEditing()
            return
        }
        super.keyDown(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelTextEditing()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitTextEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if textField != nil {
            commitTextEditing()
        }
    }

    private func beginText(at point: CGPoint) {
        commitTextEditing()
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y, width: 240, height: 34))
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.84)
        field.focusRingType = .none
        field.font = .systemFont(ofSize: max(16, model.style.lineWidth * 4), weight: .medium)
        field.textColor = model.style.color.nsColor
        field.placeholderString = L10n.string("screenshot.textPlaceholder")
        field.maximumNumberOfLines = 1
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    private var imageScale: CGFloat {
        bounds.width / CGFloat(max(model.originalImage.width, 1))
    }

    private var annotationStyleForImage: ScreenshotAnnotationStyle {
        ScreenshotAnnotationStyle(
            color: model.style.color,
            lineWidth: model.style.lineWidth / max(imageScale, 0.0001)
        )
    }

    private func pointForImage(_ point: CGPoint) -> CGPoint {
        let scale = max(imageScale, 0.0001)
        return CGPoint(
            x: point.x / scale,
            y: (bounds.height - point.y) / scale
        )
    }

    private func pointForDisplay(_ point: CGPoint) -> CGPoint {
        let scale = imageScale
        return CGPoint(
            x: point.x * scale,
            y: bounds.height - point.y * scale
        )
    }

    private func draftAnnotation() -> ScreenshotAnnotation? {
        guard let start = annotationStart, let end = annotationPoints.last else { return nil }
        switch model.selectedTool {
        case .rectangle:
            let rectangle = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            return rectangle.width >= 2 && rectangle.height >= 2
                ? .rectangle(rectangle, annotationStyleForImage)
                : nil
        case .arrow:
            return hypot(end.x - start.x, end.y - start.y) >= 2
                ? .arrow(start: start, end: end, style: annotationStyleForImage)
                : nil
        case .pen:
            return annotationPoints.count >= 2
                ? .pen(points: annotationPoints, style: annotationStyleForImage)
                : nil
        case .text:
            return nil
        case .mosaic:
            return annotationPoints.count >= 2
                ? .mosaic(points: annotationPoints, diameter: annotationStyleForImage.lineWidth * 5)
                : nil
        }
    }

    private func draw(_ annotation: ScreenshotAnnotation) {
        switch annotation {
        case let .rectangle(rectangle, style):
            style.color.nsColor.setStroke()
            let path = NSBezierPath(rect: displayRect(rectangle))
            path.lineWidth = style.lineWidth * imageScale
            path.stroke()
        case let .arrow(start, end, style):
            drawArrow(from: pointForDisplay(start), to: pointForDisplay(end), style: displayStyle(style))
        case let .pen(points, style):
            drawStroke(
                points: points.map(pointForDisplay),
                color: style.color.nsColor,
                width: style.lineWidth * imageScale
            )
        case let .text(origin, text, style):
            let displayStyle = displayStyle(style)
            (text as NSString).draw(
                at: pointForDisplay(origin),
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: max(16 * imageScale, displayStyle.lineWidth * 4),
                        weight: .medium
                    ),
                    .foregroundColor: displayStyle.color.nsColor,
                    .strokeColor: NSColor.black.withAlphaComponent(0.3),
                    .strokeWidth: -1
                ]
            )
        case let .mosaic(points, diameter):
            drawMosaic(points: points.map(pointForDisplay), diameter: diameter * imageScale)
        }
    }

    private func displayRect(_ rectangle: CGRect) -> CGRect {
        let bottomLeft = pointForDisplay(CGPoint(x: rectangle.minX, y: rectangle.minY))
        let topRight = pointForDisplay(CGPoint(x: rectangle.maxX, y: rectangle.maxY))
        return CGRect(
            x: min(bottomLeft.x, topRight.x),
            y: min(bottomLeft.y, topRight.y),
            width: abs(topRight.x - bottomLeft.x),
            height: abs(topRight.y - bottomLeft.y)
        )
    }

    private func displayStyle(_ style: ScreenshotAnnotationStyle) -> ScreenshotAnnotationStyle {
        ScreenshotAnnotationStyle(color: style.color, lineWidth: style.lineWidth * imageScale)
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        style: ScreenshotAnnotationStyle
    ) {
        drawStroke(points: [start, end], color: style.color.nsColor, width: style.lineWidth)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(10, style.lineWidth * 4)
        let wing = CGFloat.pi / 6
        let first = CGPoint(
            x: end.x - cos(angle - wing) * length,
            y: end.y - sin(angle - wing) * length
        )
        let second = CGPoint(
            x: end.x - cos(angle + wing) * length,
            y: end.y - sin(angle + wing) * length
        )
        drawStroke(points: [first, end, second], color: style.color.nsColor, width: style.lineWidth)
    }

    private func drawStroke(points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawMosaic(points: [CGPoint], diameter: CGFloat) {
        guard let first = points.first else { return }
        let pixelationScale = max(8, diameter / max(imageScale, 0.0001) / 2)
        let cacheKey = Int(pixelationScale.rounded())
        let pixelatedImage: CGImage
        if let cached = pixelatedImages[cacheKey] {
            pixelatedImage = cached
        } else if let generated = ScreenshotAnnotationRenderer.pixelatedImage(
            model.originalImage,
            scale: pixelationScale
        ) {
            pixelatedImages[cacheKey] = generated
            pixelatedImage = generated
        } else {
            return
        }

        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        let clipPath = path.copy(
            strokingWithWidth: diameter,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 2
        )
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(clipPath)
        context.clip()
        NSImage(cgImage: pixelatedImage, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        context.restoreGState()
    }
}

@MainActor
private final class LongScreenshotPreviewScrollView: NSScrollView {
    var onViewportChanged: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        onViewportChanged?(contentView.bounds.width)
    }

    func updateDocumentLayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        onViewportChanged?(contentView.bounds.width)
    }
}

@MainActor
private final class LongScreenshotPreviewButton: NSButton {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        handler()
    }
}
