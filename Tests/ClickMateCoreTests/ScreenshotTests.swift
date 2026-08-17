import AppKit
import CoreGraphics
import Foundation
import XCTest

final class ScreenshotTests: XCTestCase {
    @MainActor
    func testSelectionRenderConvertsScreenPointsToRetinaPixels() throws {
        let model = ScreenshotSessionModel(
            image: try makeSolidImage(width: 200, height: 100),
            screenSize: CGSize(width: 100, height: 50)
        )
        model.setSelection(CGRect(x: 25, y: 10, width: 50, height: 20))

        let rendered = try model.renderedImage()

        XCTAssertEqual(rendered.width, 100)
        XCTAssertEqual(rendered.height, 40)
    }

    @MainActor
    func testAllAnnotationToolsRenderIntoSingleCroppedImage() throws {
        let original = try makeSolidImage(width: 160, height: 120)
        let model = ScreenshotSessionModel(image: original, screenSize: CGSize(width: 160, height: 120))
        model.setSelection(CGRect(x: 10, y: 10, width: 130, height: 90))
        model.enterEditing()
        model.addAnnotation(.rectangle(CGRect(x: 20, y: 20, width: 35, height: 28), .default))
        model.addAnnotation(.arrow(
            start: CGPoint(x: 30, y: 40),
            end: CGPoint(x: 100, y: 75),
            style: ScreenshotAnnotationStyle(color: .yellow, lineWidth: 7)
        ))
        model.addAnnotation(.pen(
            points: [CGPoint(x: 20, y: 60), CGPoint(x: 55, y: 80), CGPoint(x: 90, y: 55)],
            style: ScreenshotAnnotationStyle(color: .green, lineWidth: 4)
        ))
        model.addAnnotation(.text(
            origin: CGPoint(x: 38, y: 32),
            text: "ClickMate",
            style: ScreenshotAnnotationStyle(color: .white, lineWidth: 4)
        ))
        model.addAnnotation(.mosaic(
            points: [CGPoint(x: 60, y: 30), CGPoint(x: 85, y: 45), CGPoint(x: 115, y: 40)],
            diameter: 20
        ))

        let rendered = try model.renderedImage()

        XCTAssertEqual(rendered.width, 130)
        XCTAssertEqual(rendered.height, 90)
        XCTAssertNotEqual(try imageData(rendered), try imageData(try ScreenshotService().crop(
            original,
            screenSize: CGSize(width: 160, height: 120),
            selection: CGRect(x: 10, y: 10, width: 130, height: 90)
        )))
    }

    @MainActor
    func testMosaicBrushChangesStrokeWithoutChangingFarCorner() throws {
        let original = try makeCheckerboardImage(width: 80, height: 80)
        let model = ScreenshotSessionModel(image: original, screenSize: CGSize(width: 80, height: 80))
        model.setSelection(CGRect(x: 0, y: 0, width: 80, height: 80))
        model.enterEditing()
        model.addAnnotation(.mosaic(
            points: [CGPoint(x: 15, y: 40), CGPoint(x: 65, y: 40)],
            diameter: 22
        ))

        let rendered = try model.renderedImage()

        XCTAssertEqual(try pixel(in: original, x: 3, y: 3), try pixel(in: rendered, x: 3, y: 3))
        XCTAssertNotEqual(try imageData(original), try imageData(rendered))
    }

    @MainActor
    func testUndoRedoClearAndEditingLocksSelectionGeometry() throws {
        let model = ScreenshotSessionModel(
            image: try makeSolidImage(width: 100, height: 80),
            screenSize: CGSize(width: 100, height: 80)
        )
        let selection = CGRect(x: 10, y: 12, width: 70, height: 50)
        model.setSelection(selection)
        model.enterEditing()
        model.setSelection(CGRect(x: 0, y: 0, width: 10, height: 10))
        model.addAnnotation(.rectangle(CGRect(x: 20, y: 20, width: 20, height: 15), .default))

        XCTAssertEqual(model.selection, selection)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertTrue(model.canClear)

        model.undo()
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertEqual(model.annotations.count, 1)

        model.clear()
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(model.canUndo)
    }

    func testToolbarPlacementStaysVisibleAtEveryScreenCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let selections = [
            CGRect(x: 0, y: 0, width: 80, height: 60),
            CGRect(x: 820, y: 0, width: 80, height: 60),
            CGRect(x: 0, y: 540, width: 80, height: 60),
            CGRect(x: 820, y: 540, width: 80, height: 60),
            CGRect(x: 430, y: 280, width: 20, height: 20)
        ]

        for selection in selections {
            let frame = ScreenshotToolbarLayout.frame(
                selection: selection,
                in: bounds,
                size: CGSize(width: 542, height: 46)
            )
            XCTAssertTrue(bounds.contains(frame), "Toolbar escaped bounds for \(selection)")
        }
    }

    func testToolbarEnabledButtonsRemainTranslucentInsteadOfSolidWhite() {
        XCTAssertEqual(
            ScreenshotToolbarAppearance.backgroundAlpha(
                isSelected: false,
                isEnabled: true,
                isHovered: false
            ),
            0.08
        )
        XCTAssertLessThan(
            ScreenshotToolbarAppearance.backgroundAlpha(
                isSelected: false,
                isEnabled: true,
                isHovered: true
            ),
            1
        )
        XCTAssertEqual(
            ScreenshotToolbarAppearance.backgroundAlpha(
                isSelected: true,
                isEnabled: true,
                isHovered: false
            ),
            0.95
        )
    }

    func testToolbarUsesViewfinderAndChineseTextGlyph() {
        XCTAssertEqual(ScreenshotToolbarVisual.fullScreen, .viewfinder)
        XCTAssertEqual(ScreenshotToolbarVisual.textTool, .text("字"))
    }

    func testToolbarButtonsAndSelectionDotsUseSquareGeometry() {
        XCTAssertEqual(ScreenshotToolbarGeometry.buttonSize, 32)

        let itemFrame = CGRect(x: 10, y: 20, width: 24, height: 32)
        let circleFrame = ScreenshotToolbarGeometry.centeredSquare(in: itemFrame, side: 18)

        XCTAssertEqual(circleFrame.width, circleFrame.height)
        XCTAssertEqual(circleFrame.midX, itemFrame.midX)
        XCTAssertEqual(circleFrame.midY, itemFrame.midY)
    }

    func testViewfinderFallbackAndSymbolAspectFitRemainInsideButton() {
        let buttonFrame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let segments = ScreenshotToolbarGeometry.viewfinderSegments(in: buttonFrame)
        let fitted = ScreenshotToolbarGeometry.aspectFitRect(
            imageSize: CGSize(width: 22, height: 17),
            in: buttonFrame,
            maximumSide: 18
        )

        XCTAssertEqual(segments.count, 8)
        XCTAssertTrue(segments.allSatisfy { buttonFrame.contains($0.0) && buttonFrame.contains($0.1) })
        XCTAssertTrue(buttonFrame.contains(fitted))
        XCTAssertEqual(fitted.width / fitted.height, 22.0 / 17.0, accuracy: 0.001)
    }

    func testEightResizeHandlesMapToSelectionEdges() {
        let selection = CGRect(x: 20, y: 30, width: 100, height: 80)
        let centers = ScreenshotSelectionHandle.allCases.map {
            CGPoint(x: $0.frame(for: selection).midX, y: $0.frame(for: selection).midY)
        }

        XCTAssertEqual(centers.count, 8)
        XCTAssertEqual(Set(centers.map { "\($0.x),\($0.y)" }).count, 8)
        XCTAssertTrue(centers.allSatisfy {
            $0.x == selection.minX || $0.x == selection.midX || $0.x == selection.maxX
        })
        XCTAssertTrue(centers.allSatisfy {
            $0.y == selection.minY || $0.y == selection.midY || $0.y == selection.maxY
        })
    }

    @MainActor
    func testCopyWritesPNGAndTIFFPasteboardRepresentations() throws {
        let service = ScreenshotService()

        try service.copyToPasteboard(try makeSolidImage(width: 24, height: 18))

        XCTAssertNotNil(NSPasteboard.general.data(forType: .png))
        XCTAssertNotNil(NSPasteboard.general.data(forType: .tiff))
    }

    @MainActor
    func testSavePNGUsesRequestedURLAndReportsFailure() throws {
        let service = ScreenshotService()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.png")

        try service.savePNG(try makeSolidImage(width: 20, height: 12), to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(
            try service.savePNG(try makeSolidImage(width: 20, height: 12), to: directory)
        )
    }

    @MainActor
    func testDefaultSaveNameUsesPngExtension() {
        let name = ScreenshotService().defaultFileName(
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(name.hasPrefix("ClickMate Screenshot "))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { context in
            context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeCheckerboardImage(width: Int, height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { context in
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    let isLight = ((x / 4) + (y / 4)).isMultiple(of: 2)
                    context.setFillColor(gray: isLight ? 0.95 : 0.1, alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.imageCreationFailed
        }
        draw(context)
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private func imageData(_ image: CGImage) throws -> Data {
        guard let data = image.dataProvider?.data else {
            throw TestError.imageDataUnavailable
        }
        return data as Data
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try imageData(image)
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        guard offset >= 0, offset + bytesPerPixel <= data.count else {
            throw TestError.imageDataUnavailable
        }
        return Array(data[offset..<(offset + bytesPerPixel)])
    }

    private enum TestError: Error {
        case imageCreationFailed
        case imageDataUnavailable
    }
}
