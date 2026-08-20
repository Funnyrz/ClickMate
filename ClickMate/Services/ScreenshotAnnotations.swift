import AppKit
import CoreImage

enum ScreenshotTool: CaseIterable, Equatable {
    case rectangle
    case arrow
    case pen
    case text
    case mosaic
}

enum ScreenshotAnnotationColor: CaseIterable, Equatable {
    case red
    case yellow
    case green
    case blue
    case white
    case black

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .white: return .white
        case .black: return .black
        }
    }
}

struct ScreenshotAnnotationStyle: Equatable {
    static let availableLineWidths: [CGFloat] = [2, 4, 7]
    static let `default` = ScreenshotAnnotationStyle(color: .red, lineWidth: 4)

    var color: ScreenshotAnnotationColor
    var lineWidth: CGFloat

    static func localizationKey(for width: CGFloat) -> String {
        switch width {
        case availableLineWidths.first: return "screenshot.size.small"
        case availableLineWidths.last: return "screenshot.size.large"
        default: return "screenshot.size.medium"
        }
    }
}

enum ScreenshotAnnotation: Equatable {
    case rectangle(CGRect, ScreenshotAnnotationStyle)
    case arrow(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case pen(points: [CGPoint], style: ScreenshotAnnotationStyle)
    case text(origin: CGPoint, text: String, style: ScreenshotAnnotationStyle)
    case mosaic(points: [CGPoint], diameter: CGFloat)
}

@MainActor
final class ScreenshotSessionModel {
    private(set) var originalImage: CGImage
    let screenSize: CGSize

    private(set) var selection: CGRect?
    private(set) var isEditing = false
    private(set) var isLongScreenshot = false
    private(set) var annotations: [ScreenshotAnnotation] = []
    var selectedTool: ScreenshotTool = .rectangle
    var style: ScreenshotAnnotationStyle = .default

    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []

    init(image: CGImage, screenSize: CGSize) {
        originalImage = image
        self.screenSize = screenSize
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canClear: Bool { !annotations.isEmpty }

    func setSelection(_ selection: CGRect?) {
        guard !isEditing else { return }
        guard let selection else {
            self.selection = nil
            return
        }
        let displayBounds = CGRect(origin: .zero, size: screenSize)
        let clamped = selection.standardized.intersection(displayBounds)
        self.selection = clamped.isNull ? nil : clamped
    }

    func enterEditing() {
        guard selection != nil else { return }
        isEditing = true
    }

    func replaceWithLongScreenshot(_ image: CGImage) {
        originalImage = image
        isLongScreenshot = true
        isEditing = false
        annotations = []
        undoStack = []
        redoStack = []
    }

    func addAnnotation(_ annotation: ScreenshotAnnotation) {
        commit(annotations + [annotation])
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        commit([])
    }

    func renderedImage() throws -> CGImage {
        if isLongScreenshot {
            return try ScreenshotAnnotationRenderer.render(
                image: originalImage,
                screenSize: CGSize(width: originalImage.width, height: originalImage.height),
                selection: CGRect(x: 0, y: 0, width: originalImage.width, height: originalImage.height),
                annotations: annotations
            )
        }
        guard let selection else {
            throw ScreenshotError.invalidSelection
        }
        return try ScreenshotAnnotationRenderer.render(
            image: originalImage,
            screenSize: screenSize,
            selection: selection,
            annotations: annotations
        )
    }

    private func commit(_ next: [ScreenshotAnnotation]) {
        undoStack.append(annotations)
        annotations = next
        redoStack.removeAll()
    }
}

enum ScreenshotAnnotationRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: true])

    static func render(
        image: CGImage,
        screenSize: CGSize,
        selection: CGRect,
        annotations: [ScreenshotAnnotation]
    ) throws -> CGImage {
        guard screenSize.width > 0, screenSize.height > 0 else {
            throw ScreenshotError.invalidSelection
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = screenSize
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ScreenshotError.imageEncodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        let displayBounds = CGRect(origin: .zero, size: screenSize)
        NSImage(cgImage: image, size: screenSize).draw(
            in: displayBounds,
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        draw(
            annotations: annotations,
            originalImage: image,
            screenSize: screenSize,
            in: graphicsContext.cgContext
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let composed = bitmap.cgImage else {
            throw ScreenshotError.imageEncodingFailed
        }
        return try crop(composed, screenSize: screenSize, selection: selection)
    }

    static func pixelatedImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(scale, 4), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return context.createCGImage(output, from: input.extent)
    }

    private static func crop(_ image: CGImage, screenSize: CGSize, selection: CGRect) throws -> CGImage {
        let normalized = selection.standardized.intersection(CGRect(origin: .zero, size: screenSize))
        guard !normalized.isNull, normalized.width >= 1, normalized.height >= 1 else {
            throw ScreenshotError.invalidSelection
        }
        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let pixelRect = CGRect(
            x: normalized.minX * scaleX,
            y: (screenSize.height - normalized.maxY) * scaleY,
            width: normalized.width * scaleX,
            height: normalized.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isNull, let cropped = image.cropping(to: pixelRect) else {
            throw ScreenshotError.invalidSelection
        }
        return cropped
    }

    private static func draw(
        annotations: [ScreenshotAnnotation],
        originalImage: CGImage,
        screenSize: CGSize,
        in context: CGContext
    ) {
        for annotation in annotations {
            switch annotation {
            case let .rectangle(rect, style):
                style.color.nsColor.setStroke()
                let path = NSBezierPath(rect: rect)
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
                drawMosaic(
                    points: points,
                    diameter: diameter,
                    originalImage: originalImage,
                    screenSize: screenSize,
                    in: context
                )
            }
        }
    }

    private static func drawArrow(
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

    private static func drawStroke(points: [CGPoint], color: NSColor, width: CGFloat) {
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

    private static func drawMosaic(
        points: [CGPoint],
        diameter: CGFloat,
        originalImage: CGImage,
        screenSize: CGSize,
        in context: CGContext
    ) {
        guard let first = points.first,
              let pixelated = pixelatedImage(originalImage, scale: max(8, diameter / 2))
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
        NSImage(cgImage: pixelated, size: screenSize).draw(
            in: CGRect(origin: .zero, size: screenSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.restoreGState()
    }
}
