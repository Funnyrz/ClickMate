import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotSelectionController {
    private let model: ScreenshotSessionModel
    private let defaultFileName: () -> String
    private let copyImage: (CGImage) throws -> Void
    private let saveImage: (CGImage, URL) throws -> Void
    private var onCompleted: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onError: ((Error) -> Void)?
    private var panel: ScreenshotSelectionPanel?
    private weak var selectionView: ScreenshotSelectionView?
    private var isFinishing = false

    init(
        screen: NSScreen,
        image: CGImage,
        initialSelection: CGRect? = nil,
        defaultFileName: @escaping () -> String,
        copyImage: @escaping (CGImage) throws -> Void,
        saveImage: @escaping (CGImage, URL) throws -> Void,
        onCompleted: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let sessionModel = ScreenshotSessionModel(image: image, screenSize: screen.frame.size)
        sessionModel.setSelection(initialSelection)
        model = sessionModel
        self.defaultFileName = defaultFileName
        self.copyImage = copyImage
        self.saveImage = saveImage
        self.onCompleted = onCompleted
        self.onCancel = onCancel
        self.onError = onError

        let selectionView = ScreenshotSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            model: model
        )
        let panel = ScreenshotSelectionPanel(screen: screen, contentView: selectionView)
        selectionView.onCopy = { [weak self] in self?.copySelection() }
        selectionView.onSave = { [weak self] in self?.presentSavePanel() }
        selectionView.onCancel = { [weak self] in self?.cancel() }
        self.selectionView = selectionView
        self.panel = panel
    }

    func present() {
        NSCursor.crosshair.set()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        panel?.makeFirstResponder(selectionView)
    }

    func dismiss() {
        onCompleted = nil
        onCancel = nil
        onError = nil
        closePanel()
    }

    private func copySelection() {
        guard !isFinishing else { return }
        do {
            try copyImage(model.renderedImage())
            finish(completed: true)
        } catch {
            onError?(error)
        }
    }

    private func presentSavePanel() {
        guard !isFinishing, let panel else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = defaultFileName()
        NSApp.activate(ignoringOtherApps: true)
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = savePanel.url else {
                panel.makeKey()
                panel.makeFirstResponder(self.selectionView)
                return
            }
            do {
                try self.saveImage(self.model.renderedImage(), destination)
                self.finish(completed: true)
            } catch {
                self.onError?(error)
                panel.makeKey()
                panel.makeFirstResponder(self.selectionView)
            }
        }
    }

    private func cancel() {
        guard !isFinishing else { return }
        finish(completed: false)
    }

    private func finish(completed: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        let completion = completed ? onCompleted : onCancel
        onCompleted = nil
        onCancel = nil
        onError = nil
        closePanel()
        DispatchQueue.main.async {
            completion?()
        }
    }

    private func closePanel() {
        NSCursor.arrow.set()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private final class ScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        setFrame(screen.frame, display: false)
        isFloatingPanel = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        sharingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum ScreenshotSelectionHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    func frame(for selection: CGRect, size: CGFloat = 8) -> CGRect {
        let center: CGPoint
        switch self {
        case .topLeft: center = CGPoint(x: selection.minX, y: selection.maxY)
        case .top: center = CGPoint(x: selection.midX, y: selection.maxY)
        case .topRight: center = CGPoint(x: selection.maxX, y: selection.maxY)
        case .right: center = CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: center = CGPoint(x: selection.maxX, y: selection.minY)
        case .bottom: center = CGPoint(x: selection.midX, y: selection.minY)
        case .bottomLeft: center = CGPoint(x: selection.minX, y: selection.minY)
        case .left: center = CGPoint(x: selection.minX, y: selection.midY)
        }
        return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }
}

enum ScreenshotToolbarLayout {
    static func frame(selection: CGRect?, in bounds: CGRect, size: CGSize) -> CGRect {
        let margin: CGFloat = 10
        let spacing: CGFloat = 8
        let width = min(size.width, max(bounds.width - margin * 2, 1))
        let x: CGFloat
        let y: CGFloat

        if let selection {
            x = min(max(selection.maxX - width, bounds.minX + margin), bounds.maxX - width - margin)
            let below = selection.minY - size.height - spacing
            let above = selection.maxY + spacing
            if below >= bounds.minY + margin {
                y = below
            } else if above + size.height <= bounds.maxY - margin {
                y = above
            } else {
                y = min(max(selection.minY, bounds.minY + margin), bounds.maxY - size.height - margin)
            }
        } else {
            x = bounds.midX - width / 2
            y = bounds.minY + 24
        }

        return CGRect(x: x, y: y, width: width, height: size.height)
    }
}

enum ScreenshotToolbarAppearance {
    static func backgroundAlpha(isSelected: Bool, isEnabled: Bool, isHovered: Bool) -> CGFloat {
        guard isEnabled else { return 0.04 }
        if isSelected { return 0.95 }
        return isHovered ? 0.18 : 0.08
    }
}

enum ScreenshotToolbarVisual: Equatable {
    case symbol(String)
    case viewfinder
    case text(String)
    case color(ScreenshotAnnotationColor)
    case strokeWidth(CGFloat)

    static let fullScreen: ScreenshotToolbarVisual = .viewfinder
    static let textTool: ScreenshotToolbarVisual = .text("字")

    var isCircularControl: Bool {
        switch self {
        case .color, .strokeWidth:
            return true
        case .symbol, .viewfinder, .text:
            return false
        }
    }
}

enum ScreenshotToolbarGeometry {
    static let buttonSize: CGFloat = 32
    static let circularControlWidth: CGFloat = 24

    static func centeredSquare(in frame: CGRect, side: CGFloat) -> CGRect {
        let clampedSide = min(max(side, 0), min(frame.width, frame.height))
        return CGRect(
            x: frame.midX - clampedSide / 2,
            y: frame.midY - clampedSide / 2,
            width: clampedSide,
            height: clampedSide
        )
    }

    static func aspectFitRect(imageSize: CGSize, in frame: CGRect, maximumSide: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return centeredSquare(in: frame, side: maximumSide)
        }
        let scale = min(maximumSide / imageSize.width, maximumSide / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: frame.midX - fittedSize.width / 2,
            y: frame.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func viewfinderSegments(in frame: CGRect) -> [(CGPoint, CGPoint)] {
        let iconFrame = centeredSquare(in: frame, side: 18)
        let length: CGFloat = 6
        return [
            (CGPoint(x: iconFrame.minX, y: iconFrame.maxY - length), CGPoint(x: iconFrame.minX, y: iconFrame.maxY)),
            (CGPoint(x: iconFrame.minX, y: iconFrame.maxY), CGPoint(x: iconFrame.minX + length, y: iconFrame.maxY)),
            (CGPoint(x: iconFrame.maxX - length, y: iconFrame.maxY), CGPoint(x: iconFrame.maxX, y: iconFrame.maxY)),
            (CGPoint(x: iconFrame.maxX, y: iconFrame.maxY), CGPoint(x: iconFrame.maxX, y: iconFrame.maxY - length)),
            (CGPoint(x: iconFrame.minX, y: iconFrame.minY + length), CGPoint(x: iconFrame.minX, y: iconFrame.minY)),
            (CGPoint(x: iconFrame.minX, y: iconFrame.minY), CGPoint(x: iconFrame.minX + length, y: iconFrame.minY)),
            (CGPoint(x: iconFrame.maxX - length, y: iconFrame.minY), CGPoint(x: iconFrame.maxX, y: iconFrame.minY)),
            (CGPoint(x: iconFrame.maxX, y: iconFrame.minY), CGPoint(x: iconFrame.maxX, y: iconFrame.minY + length))
        ]
    }
}

private final class ScreenshotSelectionView: NSView, NSTextFieldDelegate {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum SelectionInteraction {
        case creating(anchor: CGPoint)
        case moving(offset: CGPoint)
        case resizing(handle: ScreenshotSelectionHandle, original: CGRect)
    }

    private enum ToolbarAction: Equatable {
        case fullScreen
        case edit
        case tool(ScreenshotTool)
        case color(ScreenshotAnnotationColor)
        case width(CGFloat)
        case undo
        case redo
        case clear
        case save
        case copy
        case cancel
    }

    private struct ToolbarItem {
        let action: ToolbarAction
        let visual: ScreenshotToolbarVisual
        let frame: CGRect
        let tooltip: String
    }

    private let model: ScreenshotSessionModel
    private let image: NSImage
    private var selectionInteraction: SelectionInteraction?
    private var annotationStart: CGPoint?
    private var annotationPoints: [CGPoint] = []
    private var draftTextField: NSTextField?
    private var toolbarItems: [ToolbarItem] = []
    private var hoveredToolbarAction: ToolbarAction?
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, model: ScreenshotSessionModel) {
        self.model = model
        image = NSImage(cgImage: model.originalImage, size: frame.size)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredItem = toolbarItems.first(where: { $0.frame.contains(point) })
        toolTip = hoveredItem?.tooltip
        if hoveredToolbarAction != hoveredItem?.action {
            hoveredToolbarAction = hoveredItem?.action
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        toolTip = nil
        hoveredToolbarAction = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.isEditing ? .arrow : .crosshair)
        guard !model.isEditing, let selection = model.selection else { return }
        addCursorRect(selection, cursor: .openHand)
        for handle in ScreenshotSelectionHandle.allCases {
            addCursorRect(handle.frame(for: selection, size: 14), cursor: cursor(for: handle))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawImage()
        NSColor.black.withAlphaComponent(0.46).setFill()
        bounds.fill()

        if let selection = model.selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            drawImage()
            drawAnnotations(model.annotations)
            if let draft = draftAnnotation() {
                drawAnnotations([draft])
            }
            NSGraphicsContext.restoreGraphicsState()
            drawSelectionBorder(selection)
            if !model.isEditing {
                drawResizeHandles(selection)
            }
            drawSizeBadge(for: selection)
        }

        if model.selection == nil {
            drawHint()
        }
        drawToolbar()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let item = toolbarItems.first(where: { $0.frame.contains(point) }) {
            perform(item.action)
            return
        }
        guard let selection = model.selection else {
            selectionInteraction = .creating(anchor: point)
            model.setSelection(nil)
            needsDisplay = true
            return
        }
        guard selection.contains(point) else {
            guard !model.isEditing else { return }
            selectionInteraction = .creating(anchor: point)
            model.setSelection(nil)
            needsDisplay = true
            return
        }
        if event.clickCount >= 2 {
            copySelection()
            return
        }
        if model.isEditing {
            beginAnnotation(at: point)
            return
        }
        if let handle = hitHandle(at: point, selection: selection) {
            selectionInteraction = .resizing(handle: handle, original: selection)
        } else {
            selectionInteraction = .moving(
                offset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
            )
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if model.isEditing, annotationStart != nil {
            if model.selectedTool == .pen || model.selectedTool == .mosaic {
                if annotationPoints.last.map({ hypot($0.x - point.x, $0.y - point.y) >= 1 }) != false {
                    annotationPoints.append(point)
                }
            } else if let start = annotationStart {
                annotationPoints = [start, point]
            }
            needsDisplay = true
            return
        }

        guard let selectionInteraction else { return }
        switch selectionInteraction {
        case let .creating(anchor):
            model.setSelection(rect(from: anchor, to: point).intersection(bounds))
        case let .moving(offset):
            guard let selection = model.selection else { return }
            var origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - selection.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - selection.height)
            model.setSelection(CGRect(origin: origin, size: selection.size))
        case let .resizing(handle, original):
            model.setSelection(resized(original, handle: handle, to: point))
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            selectionInteraction = nil
            NSCursor.arrow.set()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
        if model.isEditing, annotationStart != nil {
            commitAnnotation()
            return
        }
        if let selection = model.selection, selection.width < 2 || selection.height < 2 {
            model.setSelection(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            copySelection()
        case 123, 124, 125, 126:
            moveSelection(for: event.keyCode, modifiers: event.modifierFlags)
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                event.modifierFlags.contains(.shift) ? model.redo() : model.undo()
                needsDisplay = true
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelDraftText()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitDraftText()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if draftTextField != nil {
            commitDraftText()
        }
    }

    private func perform(_ action: ToolbarAction) {
        switch action {
        case .fullScreen:
            model.setSelection(bounds)
        case .edit:
            guard model.selection != nil else {
                NSSound.beep()
                return
            }
            model.enterEditing()
        case let .tool(tool):
            model.selectedTool = tool
        case let .color(color):
            model.style.color = color
            draftTextField?.textColor = color.nsColor
        case let .width(width):
            model.style.lineWidth = width
        case .undo:
            model.undo()
        case .redo:
            model.redo()
        case .clear:
            model.clear()
        case .save:
            guard validSelection else {
                NSSound.beep()
                return
            }
            commitDraftText()
            onSave?()
        case .copy:
            copySelection()
        case .cancel:
            onCancel?()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func copySelection() {
        guard validSelection else {
            NSSound.beep()
            return
        }
        commitDraftText()
        onCopy?()
    }

    private var validSelection: Bool {
        guard let selection = model.selection else { return false }
        return selection.width >= 2 && selection.height >= 2
    }

    private func beginAnnotation(at point: CGPoint) {
        guard model.selection?.contains(point) == true else { return }
        if model.selectedTool == .text {
            beginText(at: point)
            return
        }
        annotationStart = point
        annotationPoints = [point]
    }

    private func commitAnnotation() {
        if let annotation = draftAnnotation() {
            model.addAnnotation(annotation)
        }
        annotationStart = nil
        annotationPoints = []
    }

    private func draftAnnotation() -> ScreenshotAnnotation? {
        guard let start = annotationStart, let end = annotationPoints.last else { return nil }
        switch model.selectedTool {
        case .rectangle:
            let rectangle = rect(from: start, to: end)
            return rectangle.width >= 2 && rectangle.height >= 2 ? .rectangle(rectangle, model.style) : nil
        case .arrow:
            return hypot(end.x - start.x, end.y - start.y) >= 2
                ? .arrow(start: start, end: end, style: model.style)
                : nil
        case .pen:
            return annotationPoints.count >= 2 ? .pen(points: annotationPoints, style: model.style) : nil
        case .text:
            return nil
        case .mosaic:
            return annotationPoints.count >= 2
                ? .mosaic(points: annotationPoints, diameter: model.style.lineWidth * 5)
                : nil
        }
    }

    private func beginText(at point: CGPoint) {
        commitDraftText()
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y - 2, width: 240, height: 34))
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: max(16, model.style.lineWidth * 4), weight: .medium)
        field.textColor = model.style.color.nsColor
        field.placeholderString = L10n.string("screenshot.textPlaceholder")
        field.maximumNumberOfLines = 1
        addSubview(field)
        draftTextField = field
        window?.makeFirstResponder(field)
    }

    private func commitDraftText() {
        guard let field = draftTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = field.frame.origin
        draftTextField = nil
        field.delegate = nil
        field.removeFromSuperview()
        if !text.isEmpty {
            model.addAnnotation(.text(origin: origin, text: text, style: model.style))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancelDraftText() {
        let field = draftTextField
        draftTextField = nil
        field?.delegate = nil
        field?.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func moveSelection(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard !model.isEditing, var selection = model.selection else { return }
        let distance: CGFloat = modifiers.contains(.shift) ? 10 : 1
        switch keyCode {
        case 123: selection.origin.x -= distance
        case 124: selection.origin.x += distance
        case 125: selection.origin.y -= distance
        case 126: selection.origin.y += distance
        default: return
        }
        selection.origin.x = min(max(selection.origin.x, bounds.minX), bounds.maxX - selection.width)
        selection.origin.y = min(max(selection.origin.y, bounds.minY), bounds.maxY - selection.height)
        model.setSelection(selection)
        needsDisplay = true
    }

    private func resized(_ original: CGRect, handle: ScreenshotSelectionHandle, to point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        ).intersection(bounds)
    }

    private func hitHandle(at point: CGPoint, selection: CGRect) -> ScreenshotSelectionHandle? {
        ScreenshotSelectionHandle.allCases.first {
            $0.frame(for: selection, size: 16).contains(point)
        }
    }

    private func cursor(for handle: ScreenshotSelectionHandle) -> NSCursor {
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return .crosshair
        }
    }

    private func drawImage() {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    private func drawAnnotations(_ annotations: [ScreenshotAnnotation]) {
        for annotation in annotations {
            switch annotation {
            case let .rectangle(rectangle, style):
                style.color.nsColor.setStroke()
                let path = NSBezierPath(rect: rectangle)
                path.lineWidth = style.lineWidth
                path.stroke()
            case let .arrow(start, end, style):
                drawArrow(from: start, to: end, style: style)
            case let .pen(points, style):
                drawStroke(points: points, color: style.color.nsColor, width: style.lineWidth)
            case let .text(origin, text, style):
                (text as NSString).draw(
                    at: origin,
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: max(16, style.lineWidth * 4), weight: .medium),
                        .foregroundColor: style.color.nsColor,
                        .strokeColor: NSColor.black.withAlphaComponent(0.3),
                        .strokeWidth: -1
                    ]
                )
            case let .mosaic(points, diameter):
                drawMosaic(points: points, diameter: diameter)
            }
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, style: ScreenshotAnnotationStyle) {
        drawStroke(points: [start, end], color: style.color.nsColor, width: style.lineWidth)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(10, style.lineWidth * 4)
        let wing = CGFloat.pi / 6
        let first = CGPoint(x: end.x - cos(angle - wing) * length, y: end.y - sin(angle - wing) * length)
        let second = CGPoint(x: end.x - cos(angle + wing) * length, y: end.y - sin(angle + wing) * length)
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
        guard let context = NSGraphicsContext.current?.cgContext,
              let first = points.first,
              let pixelated = ScreenshotAnnotationRenderer.pixelatedImage(
                model.originalImage,
                scale: max(8, diameter / 2)
              )
        else { return }
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
        context.saveGState()
        context.addPath(clipPath)
        context.clip()
        NSImage(cgImage: pixelated, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.restoreGState()
    }

    private func drawSelectionBorder(_ selection: CGRect) {
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        NSColor.systemBlue.setStroke()
        let accent = NSBezierPath(rect: selection.insetBy(dx: 1.5, dy: 1.5))
        accent.lineWidth = 2
        accent.stroke()
    }

    private func drawResizeHandles(_ selection: CGRect) {
        for handle in ScreenshotSelectionHandle.allCases {
            let frame = handle.frame(for: selection)
            NSColor.white.setFill()
            frame.fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(rect: frame).stroke()
        }
    }

    private func drawHint() {
        let text = L10n.string("screenshot.selectionHint") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .shadow: textShadow
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 28),
            withAttributes: attributes
        )
    }

    private func drawSizeBadge(for selection: CGRect) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + textSize.height + 8 > bounds.maxY {
            origin.y = max(selection.minY - textSize.height - 14, bounds.minY + 4)
        }
        let badge = CGRect(origin: origin, size: CGSize(width: textSize.width + 16, height: textSize.height + 8))
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: attributes)
    }

    private func drawToolbar() {
        let frame = toolbarFrame
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
        toolbarItems = makeToolbarItems(in: frame)
        for item in toolbarItems {
            drawToolbarItem(item)
        }
    }

    private func makeToolbarItems(in frame: CGRect) -> [ToolbarItem] {
        var items: [ToolbarItem] = []
        var x = frame.minX + 8
        let y = frame.minY + 7
        let height = frame.height - 14

        func add(
            _ action: ToolbarAction,
            _ visual: ScreenshotToolbarVisual,
            _ tooltipKey: String,
            width: CGFloat = ScreenshotToolbarGeometry.buttonSize
        ) {
            let itemFrame = CGRect(x: x, y: y, width: width, height: height)
            items.append(ToolbarItem(
                action: action,
                visual: visual,
                frame: itemFrame,
                tooltip: L10n.string(tooltipKey)
            ))
            x += width + 3
        }

        func gap() { x += 6 }

        if model.isEditing {
            add(.tool(.rectangle), .symbol("rectangle"), "screenshot.rectangle")
            add(.tool(.arrow), .symbol("arrow.up.right"), "screenshot.arrow")
            add(.tool(.pen), .symbol("pencil.line"), "screenshot.pen")
            add(.tool(.text), .textTool, "screenshot.text")
            add(.tool(.mosaic), .symbol("circle.grid.3x3.fill"), "screenshot.mosaic")
            gap()
            for color in ScreenshotAnnotationColor.allCases {
                add(
                    .color(color),
                    .color(color),
                    color.localizationKey,
                    width: ScreenshotToolbarGeometry.circularControlWidth
                )
            }
            gap()
            for width in ScreenshotAnnotationStyle.availableLineWidths {
                add(
                    .width(width),
                    .strokeWidth(width),
                    ScreenshotAnnotationStyle.localizationKey(for: width),
                    width: ScreenshotToolbarGeometry.circularControlWidth
                )
            }
            gap()
            add(.undo, .symbol("arrow.uturn.backward"), "screenshot.undo")
            add(.redo, .symbol("arrow.uturn.forward"), "screenshot.redo")
            add(.clear, .symbol("trash"), "screenshot.clear")
            gap()
        } else {
            add(.fullScreen, .fullScreen, "screenshot.fullScreen")
            add(.edit, .symbol("pencil.tip"), "screenshot.edit")
            gap()
        }
        add(.save, .symbol("square.and.arrow.down"), "screenshot.save")
        add(.copy, .symbol("doc.on.doc"), "screenshot.copy")
        add(.cancel, .symbol("xmark"), "screenshot.cancel")
        return items
    }

    private func drawToolbarItem(_ item: ToolbarItem) {
        let isSelected: Bool
        let isEnabled: Bool
        switch item.action {
        case let .tool(tool):
            isSelected = model.selectedTool == tool
            isEnabled = true
        case let .color(color):
            isSelected = model.style.color == color
            isEnabled = true
        case let .width(width):
            isSelected = model.style.lineWidth == width
            isEnabled = true
        case .undo:
            isSelected = false
            isEnabled = model.canUndo
        case .redo:
            isSelected = false
            isEnabled = model.canRedo
        case .clear:
            isSelected = false
            isEnabled = model.canClear
        case .edit, .save, .copy:
            isSelected = false
            isEnabled = validSelection
        default:
            isSelected = false
            isEnabled = true
        }

        let backgroundColor = isSelected ? NSColor.systemBlue : NSColor.white
        backgroundColor.withAlphaComponent(
            ScreenshotToolbarAppearance.backgroundAlpha(
                isSelected: isSelected,
                isEnabled: isEnabled,
                isHovered: hoveredToolbarAction == item.action
            )
        ).setFill()
        if item.visual.isCircularControl {
            NSBezierPath(
                ovalIn: ScreenshotToolbarGeometry.centeredSquare(
                    in: item.frame,
                    side: ScreenshotToolbarGeometry.circularControlWidth
                )
            ).fill()
        } else {
            NSBezierPath(roundedRect: item.frame, xRadius: 7, yRadius: 7).fill()
        }

        switch item.visual {
        case let .color(color):
            let swatchFrame = ScreenshotToolbarGeometry.centeredSquare(in: item.frame, side: 14)
            color.nsColor.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
            NSBezierPath(ovalIn: swatchFrame).fill()
            if color == .white {
                NSColor.gray.setStroke()
                NSBezierPath(ovalIn: swatchFrame).stroke()
            }
        case let .strokeWidth(width):
            NSColor.white.withAlphaComponent(isEnabled ? 0.95 : 0.35).setFill()
            let diameter = min(max(width + 2, 5), 16)
            NSBezierPath(ovalIn: ScreenshotToolbarGeometry.centeredSquare(in: item.frame, side: diameter)).fill()
        case let .symbol(name):
            drawSymbol(name, in: item, isEnabled: isEnabled)
        case .viewfinder:
            drawViewfinder(in: item, isEnabled: isEnabled)
        case let .text(text):
            drawTextGlyph(text, in: item, isEnabled: isEnabled)
        }
    }

    private func iconColor(for action: ToolbarAction, isEnabled: Bool) -> NSColor {
        guard isEnabled else { return NSColor.white.withAlphaComponent(0.30) }
        switch action {
        case .edit:
            return .systemOrange
        case .save:
            return .systemYellow
        case .copy:
            return .systemGreen
        case .cancel, .clear:
            return .systemRed
        default:
            return .white
        }
    }

    @discardableResult
    private func drawSymbol(_ name: String, in item: ToolbarItem, isEnabled: Bool) -> Bool {
        guard let symbol = NSImage(
            systemSymbolName: name,
            accessibilityDescription: item.tooltip
        ) else {
            return false
        }
        let symbolColor = iconColor(for: item.action, isEnabled: isEnabled)
        guard let configuredSymbol = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [symbolColor]))
        ) else {
            return false
        }
        let symbolFrame = ScreenshotToolbarGeometry.aspectFitRect(
            imageSize: configuredSymbol.size,
            in: item.frame,
            maximumSide: 18
        )
        configuredSymbol.draw(in: symbolFrame)
        return true
    }

    private func drawViewfinder(in item: ToolbarItem, isEnabled: Bool) {
        guard !drawSymbol("viewfinder", in: item, isEnabled: isEnabled) else { return }
        let path = NSBezierPath()
        for segment in ScreenshotToolbarGeometry.viewfinderSegments(in: item.frame) {
            path.move(to: segment.0)
            path.line(to: segment.1)
        }
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        iconColor(for: item.action, isEnabled: isEnabled).setStroke()
        path.stroke()
    }

    private func drawTextGlyph(_ text: String, in item: ToolbarItem, isEnabled: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: iconColor(for: item.action, isEnabled: isEnabled)
        ]
        let glyph = text as NSString
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: CGPoint(x: item.frame.midX - size.width / 2, y: item.frame.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private var toolbarFrame: CGRect {
        ScreenshotToolbarLayout.frame(
            selection: model.selection,
            in: bounds,
            size: CGSize(width: model.isEditing ? 668 : 198, height: 46)
        )
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        return shadow
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private extension ScreenshotAnnotationColor {
    var localizationKey: String {
        switch self {
        case .red: return "screenshot.color.red"
        case .yellow: return "screenshot.color.yellow"
        case .green: return "screenshot.color.green"
        case .blue: return "screenshot.color.blue"
        case .white: return "screenshot.color.white"
        case .black: return "screenshot.color.black"
        }
    }
}
