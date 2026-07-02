import AppKit
import CoreGraphics
import Foundation

struct IconVariant {
    let code: String
    let title: String
    let callout: String
    let calloutFontSize: CGFloat
    let titleFontSize: CGFloat
    let titleTracking: CGFloat
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appDir = root.appendingPathComponent("ClickMate", isDirectory: true)

let variants = [
    IconVariant(
        code: "ZH",
        title: "右键增强",
        callout: "使用此软件",
        calloutFontSize: 34,
        titleFontSize: 88,
        titleTracking: 7
    ),
    IconVariant(
        code: "EN",
        title: "Right Click Enhancer",
        callout: "Use with Finder",
        calloutFontSize: 29,
        titleFontSize: 49,
        titleTracking: 0
    ),
]

let canvasSize = CGSize(width: 1024, height: 1024)
let scale: CGFloat = 1

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: canvasSize.height - y)
}

func flippedY(_ y: CGFloat, _ height: CGFloat) -> CGFloat {
    canvasSize.height - y - height
}

func roundedPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect(x, flippedY(y, h), w, h), xRadius: radius, yRadius: radius)
}

func drawLinearGradient(in path: NSBezierPath, colors: [NSColor], angle: CGFloat = 90) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: colors)?.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

func addShadow(_ color: NSColor, blur: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
    NSShadow().apply {
        $0.shadowColor = color
        $0.shadowBlurRadius = blur
        $0.shadowOffset = CGSize(width: offsetX, height: offsetY)
    }
}

extension NSObjectProtocol {
    func apply(_ block: (Self) -> Void) {
        block(self)
    }
}

func drawBase() {
    NSGraphicsContext.saveGraphicsState()
    addShadow(color(0x6c7c96, alpha: 0.22), blur: 34, offsetX: 0, offsetY: -24)
    let base = roundedPath(72, 102, 880, 792, 112)
    drawLinearGradient(in: base, colors: [color(0xfafdff), color(0xf2f7ff), color(0xe9f0fb)], angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let rim = roundedPath(72, 102, 880, 792, 112)
    color(0xd9e2ef, alpha: 0.95).setStroke()
    rim.lineWidth = 3
    rim.stroke()

    let topSheen = roundedPath(90, 118, 844, 390, 92)
    NSGraphicsContext.saveGraphicsState()
    topSheen.addClip()
    NSGradient(colors: [color(0xffffff, alpha: 0.9), color(0xffffff, alpha: 0)])?.draw(in: topSheen.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

func drawFolder() {
    let back = NSBezierPath()
    back.move(to: point(156, 304))
    back.line(to: point(344, 304))
    back.curve(to: point(382, 330), controlPoint1: point(366, 304), controlPoint2: point(370, 330))
    back.line(to: point(648, 330))
    back.curve(to: point(690, 374), controlPoint1: point(675, 330), controlPoint2: point(690, 346))
    back.line(to: point(690, 554))
    back.curve(to: point(638, 604), controlPoint1: point(690, 586), controlPoint2: point(674, 604))
    back.line(to: point(156, 604))
    back.close()

    NSGraphicsContext.saveGraphicsState()
    addShadow(color(0x004391, alpha: 0.26), blur: 24, offsetX: 0, offsetY: -18)
    drawLinearGradient(in: back, colors: [color(0x3fa6ff), color(0x0478ec)], angle: 87)
    NSGraphicsContext.restoreGraphicsState()

    let front = roundedPath(156, 366, 534, 256, 40)
    NSGraphicsContext.saveGraphicsState()
    addShadow(color(0x0061d8, alpha: 0.2), blur: 10, offsetX: 0, offsetY: 3)
    drawLinearGradient(in: front, colors: [color(0x9ed9ff), color(0x2198fb)], angle: 105)
    NSGraphicsContext.restoreGraphicsState()

    let frontStroke = roundedPath(156, 366, 534, 256, 40)
    color(0xffffff, alpha: 0.25).setStroke()
    frontStroke.lineWidth = 3
    frontStroke.stroke()
}

func drawMenu(_ variant: IconVariant) {
    let menu = roundedPath(424, 390, 438, 244, 30)
    NSGraphicsContext.saveGraphicsState()
    addShadow(color(0x56657a, alpha: 0.3), blur: 24, offsetX: 0, offsetY: -14)
    drawLinearGradient(in: menu, colors: [color(0xffffff), color(0xf7f9fc)], angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let menuStroke = roundedPath(424, 390, 438, 244, 30)
    color(0xdce3ec, alpha: 0.95).setStroke()
    menuStroke.lineWidth = 2
    menuStroke.stroke()

    let lineColor = color(0xbcc1c9)
    for (index, width) in [174.0, 154.0, 130.0].enumerated() {
        let y = CGFloat(452 + index * 54)
        let line = roundedPath(484, y, CGFloat(width), 11, 5.5)
        lineColor.setFill()
        line.fill()

        let chevron = NSBezierPath()
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.lineWidth = 5.5
        chevron.move(to: point(804, y - 3))
        chevron.line(to: point(817, y + 9))
        chevron.line(to: point(804, y + 21))
        color(0xb9bec7).setStroke()
        chevron.stroke()
    }

    let pill = roundedPath(444, 578, 398, 72, 17)
    color(0xd9ebff, alpha: 0.96).setFill()
    pill.fill()

    let arrowBox = roundedPath(462, 590, 54, 54, 13)
    drawLinearGradient(in: arrowBox, colors: [color(0x37a9ff), color(0x006de7)], angle: 90)

    let arrow = NSBezierPath()
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 7
    arrow.move(to: point(482, 626))
    arrow.line(to: point(500, 608))
    arrow.line(to: point(500, 622))
    arrow.move(to: point(500, 608))
    arrow.line(to: point(486, 608))
    color(0xffffff).setStroke()
    arrow.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    let calloutAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: variant.calloutFontSize, weight: .semibold),
        .foregroundColor: color(0x096fdc),
        .paragraphStyle: paragraph,
    ]
    let calloutRect = rect(538, flippedY(604, 48), 280, 48)
    variant.callout.draw(in: calloutRect, withAttributes: calloutAttributes)
}

func drawTitle(_ variant: IconVariant) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: variant.titleFontSize, weight: .heavy),
        .foregroundColor: color(0x071427),
        .paragraphStyle: paragraph,
        .kern: variant.titleTracking,
    ]
    let attributed = NSAttributedString(string: variant.title, attributes: attributes)
    let measured = attributed.boundingRect(
        with: CGSize(width: 792, height: 140),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let titleRect = rect(116, flippedY(718, 132), 792, 132)
    let drawRect = CGRect(
        x: titleRect.minX,
        y: titleRect.minY + max(0, (titleRect.height - measured.height) / 2) - 4,
        width: titleRect.width,
        height: measured.height + 12
    )
    variant.title.draw(in: drawRect, withAttributes: attributes)
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render PNG"])
    }
    try png.write(to: url)
}

func render(_ variant: IconVariant) throws -> URL {
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    NSColor.clear.setFill()
    rect(0, 0, canvasSize.width, canvasSize.height).fill()
    drawBase()
    drawFolder()
    drawMenu(variant)
    drawTitle(variant)
    image.unlockFocus()

    let output = appDir.appendingPathComponent("ClickMateIcon\(variant.code)-1024.png")
    try writePNG(image, to: output)
    try run("/usr/bin/sips", ["-z", "1024", "1024", output.path, "--out", output.path])
    return output
}

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "IconGeneration",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: output]
        )
    }
    return output
}

func buildICNS(for variant: IconVariant, from pngURL: URL) throws {
    let iconsetURL = appDir.appendingPathComponent("ClickMateIcon\(variant.code).iconset", isDirectory: true)
    let icnsURL = appDir.appendingPathComponent("ClickMateIcon\(variant.code).icns")

    try? FileManager.default.removeItem(at: iconsetURL)
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for size in sizes {
        let out = iconsetURL.appendingPathComponent(size.name)
        try run("/usr/bin/sips", ["-z", "\(size.pixels)", "\(size.pixels)", pngURL.path, "--out", out.path])
    }

    try? FileManager.default.removeItem(at: icnsURL)
    try run("/usr/bin/iconutil", ["-c", "icns", iconsetURL.path, "-o", icnsURL.path])
    try? FileManager.default.removeItem(at: iconsetURL)
}

for variant in variants {
    let pngURL = try render(variant)
    try buildICNS(for: variant, from: pngURL)
    print(pngURL.path)
}
