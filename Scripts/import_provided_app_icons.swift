import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

struct IconSource {
    let code: String
    let path: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appDir = root.appendingPathComponent("ClickMate", isDirectory: true)

let sources = [
    IconSource(
        code: "EN",
        path: "/Users/fuyangyang/Downloads/ChatGPT Image 2026年7月1日 16_37_13.png"
    ),
    IconSource(
        code: "ZH",
        path: "/Users/fuyangyang/Downloads/ChatGPT Image 2026年7月1日 16_37_09.png"
    ),
]

let transparentEdgeExpansionPixels = 6

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
            domain: "IconImport",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: output]
        )
    }
    return output
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to write PNG"])
    }
    try png.write(to: url)
}

func removeConnectedWhiteBackground(from url: URL) throws {
    guard
        let sourceRef = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil)
    else {
        throw NSError(domain: "IconImport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to process alpha for \(url.path)"])
    }

    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = Array(repeating: UInt8(0), count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    else {
        throw NSError(domain: "IconImport", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap context"])
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var visited = Array(repeating: false, count: width * height)
    var queue: [(Int, Int)] = []
    var head = 0

    func index(_ x: Int, _ y: Int) -> Int {
        y * width + x
    }

    func byteOffset(_ x: Int, _ y: Int) -> Int {
        y * bytesPerRow + x * 4
    }

    func isEdgeBackground(_ x: Int, _ y: Int) -> Bool {
        let offset = byteOffset(x, y)
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let alpha = Int(pixels[offset + 3])
        let maxDelta = max(abs(red - green), abs(red - blue), abs(green - blue))
        let brightest = max(red, green, blue)
        let darkest = min(red, green, blue)

        return alpha > 2
            && (
                (red > 218 && green > 218 && blue > 214 && maxDelta < 45)
                    || (brightest > 130 && darkest > 105 && maxDelta < 38)
            )
    }

    func enqueue(_ x: Int, _ y: Int) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let i = index(x, y)
        guard !visited[i], isEdgeBackground(x, y) else { return }
        visited[i] = true
        queue.append((x, y))
    }

    for x in 0..<width {
        enqueue(x, 0)
        enqueue(x, height - 1)
    }
    for y in 0..<height {
        enqueue(0, y)
        enqueue(width - 1, y)
    }

    while head < queue.count {
        let (x, y) = queue[head]
        head += 1
        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)
    }

    for _ in 0..<transparentEdgeExpansionPixels {
        var expanded = visited
        for y in 0..<height {
            for x in 0..<width where visited[index(x, y)] {
                for offsetY in -1...1 {
                    for offsetX in -1...1 {
                        let nextX = x + offsetX
                        let nextY = y + offsetY
                        guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                        expanded[index(nextX, nextY)] = true
                    }
                }
            }
        }
        visited = expanded
    }

    for y in 0..<height {
        for x in 0..<width {
            guard visited[index(x, y)] else { continue }

            let offset = byteOffset(x, y)
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }
    }

    guard
        let outputContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let outputImage = outputContext.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw NSError(domain: "IconImport", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to encode alpha PNG"])
    }

    CGImageDestinationAddImage(destination, outputImage, nil)
    if !CGImageDestinationFinalize(destination) {
        throw NSError(domain: "IconImport", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to write alpha PNG"])
    }
}

func normalizeTo1024(source: IconSource) throws -> URL {
    let sourceURL = URL(fileURLWithPath: source.path)
    guard let input = NSImage(contentsOf: sourceURL) else {
        throw NSError(domain: "IconImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing icon source: \(source.path)"])
    }

    let outputURL = appDir.appendingPathComponent("ClickMateIcon\(source.code)-1024.png")
    let canvasSize = CGSize(width: 1024, height: 1024)
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    NSColor.clear.setFill()
    CGRect(origin: .zero, size: canvasSize).fill()

    let sourceSize = input.size
    let scale = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
    let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let drawRect = CGRect(
        x: (canvasSize.width - drawSize.width) / 2,
        y: (canvasSize.height - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    input.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    image.unlockFocus()

    try writePNG(image, to: outputURL)
    try run("/usr/bin/sips", ["-z", "1024", "1024", outputURL.path, "--out", outputURL.path])
    try removeConnectedWhiteBackground(from: outputURL)
    return outputURL
}

func buildICNS(code: String, from pngURL: URL) throws {
    let iconsetURL = appDir.appendingPathComponent("ClickMateIcon\(code).iconset", isDirectory: true)
    let icnsURL = appDir.appendingPathComponent("ClickMateIcon\(code).icns")

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
        let outputURL = iconsetURL.appendingPathComponent(size.name)
        try run("/usr/bin/sips", ["-z", "\(size.pixels)", "\(size.pixels)", pngURL.path, "--out", outputURL.path])
    }

    try? FileManager.default.removeItem(at: icnsURL)
    try run("/usr/bin/iconutil", ["-c", "icns", iconsetURL.path, "-o", icnsURL.path])
    try? FileManager.default.removeItem(at: iconsetURL)
}

for source in sources {
    let pngURL = try normalizeTo1024(source: source)
    try buildICNS(code: source.code, from: pngURL)
    print(pngURL.path)
}
