import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Raw captures stay in build/. Only fresh, OCR-checked PNGs enter img/.
private let scenes = [
    "finder-menu", "quick-features", "screenshot-annotation", "scrolling-capture",
    "archive-editor", "file-tasks", "settings-menus", "settings-layout",
    "template-editor", "settings-apps", "permissions", "settings-data",
]
private let languages = ["en", "zh-CN"]
private let expectedNames = Set(scenes.flatMap { scene in
    languages.map { "clickmate-\(scene)-\($0).png" }
})

private enum Failure: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case let .message(message): return message } }
}

private struct Options {
    var input = URL(fileURLWithPath: "build/documentation/raw", isDirectory: true)
    var output = URL(fileURLWithPath: "img", isDirectory: true)
    var report = URL(fileURLWithPath: "build/documentation/privacy-report.json")
    var validate = false
    var selfTest = false
    var extraTokens: [String] = []

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--validate": validate = true
            case "--self-test": selfTest = true
            case "--input", "--output", "--report", "--private-token":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    throw Failure.message("Missing value for \(argument).")
                }
                let value = arguments[index]
                switch argument {
                case "--input": input = URL(fileURLWithPath: value, isDirectory: true)
                case "--output": output = URL(fileURLWithPath: value, isDirectory: true)
                case "--report": report = URL(fileURLWithPath: value)
                default: extraTokens.append(value)
                }
            case "--help", "-h":
                print("""
                Usage: swift Scripts/prepare_documentation_images.swift [options]
                  --input DIR          Raw PNG directory (default: build/documentation/raw)
                  --output DIR         Sanitized PNG directory (default: img)
                  --report FILE        Privacy report (default: build/documentation/privacy-report.json)
                  --private-token TEXT Additional private name to remove (repeatable)
                  --validate           Check final output without changing images
                  --self-test          Exercise OCR, irreversible redaction, and metadata removal
                Reports contain rule IDs and pixel rectangles, never recognized text or private tokens.
                """)
                exit(0)
            default: throw Failure.message("Unknown option. Use --help for supported arguments.")
            }
            index += 1
        }
        guard !(validate && selfTest) else { throw Failure.message("Choose --validate or --self-test.") }
        guard input.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else {
            throw Failure.message("Input and output directories must differ.")
        }
        guard report.pathExtension.lowercased() == "json" else { throw Failure.message("The report must use a .json filename.") }
    }
}

private struct PrivacyRule {
    let id: String
    let expression: NSRegularExpression
}

private struct Redaction: Codable {
    let rule: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct ImageReport: Codable {
    let file: String
    let width: Int
    let height: Int
    let redactions: [Redaction]
    let privacyPassed: Bool
    let metadataPassed: Bool
}

private struct Report: Encodable {
    let formatVersion = 1
    let mode: String
    let expectedImageCount: Int
    let checkedImageCount: Int
    let passed: Bool
    let images: [ImageReport]
}

private final class Sanitizer {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let rules: [PrivacyRule]

    init(extraTokens: [String]) throws {
        let host = ProcessInfo.processInfo.hostName
        let hostShort = host.components(separatedBy: ".").first ?? host
        let tokens = Set([NSUserName(), NSFullUserName(), FileManager.default.homeDirectoryForCurrentUser.lastPathComponent,
                          host, hostShort] + extraTokens)
        var expressions: [(String, String)] = [
            ("email", #"[A-Z0-9._%+\-]+\s*@\s*[A-Z0-9.\-]+\.[A-Z]{2,}"#),
            ("user-home-path", #"/\s*Users\s*/\s*[^/\s]+"#),
        ]
        for token in tokens.sorted() where !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Unicode-aware boundaries also catch account names inside /Users/name/ paths.
            expressions.append(("local-identity", "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: token) + "(?![\\p{L}\\p{N}_])"))
        }
        rules = try expressions.map { PrivacyRule(id: $0.0, expression: try NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }
    }

    func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.message("Cannot decode a single PNG image: \(url.lastPathComponent).")
        }
        guard image.width >= 320, image.height >= 200, image.width <= 10_000, image.height <= 20_000 else {
            throw Failure.message("Unexpected screenshot dimensions: \(url.lastPathComponent).")
        }
        return image
    }

    func findings(in image: CGImage) throws -> [Redaction] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        var findings: [Redaction] = []
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for rule in rules {
                for match in rule.expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    let normalized = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                    let rectangle = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height),
                                           width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
                        .insetBy(dx: -12, dy: -8).integral.intersection(bounds)
                    findings.append(Redaction(rule: rule.id, x: Int(rectangle.minX), y: Int(rectangle.minY),
                                              width: Int(rectangle.width), height: Int(rectangle.height)))
                }
            }
        }
        return findings
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.message("Cannot allocate screenshot bitmap.")
        }
        return bitmap
    }

    func sanitized(_ image: CGImage, findings: [Redaction]) throws -> CGImage {
        let bitmap = try bitmap(width: image.width, height: image.height)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(extent)
        bitmap.draw(image, in: extent)
        // Erase source pixels first. Blurring original text alone can disclose short names.
        bitmap.setFillColor(CGColor(gray: 0.86, alpha: 1))
        findings.forEach { bitmap.fill($0.rect) }
        guard let erased = bitmap.makeImage() else { throw Failure.message("Cannot erase private screenshot regions.") }
        if !findings.isEmpty {
            let blurred = CIImage(cgImage: erased).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
            for finding in findings {
                let area = finding.rect.insetBy(dx: -4, dy: -4).intersection(extent)
                guard let patch = context.createCGImage(blurred, from: area) else { throw Failure.message("Cannot blur erased screenshot region.") }
                bitmap.draw(patch, in: area)
            }
        }
        guard let result = bitmap.makeImage() else { throw Failure.message("Cannot create sanitized screenshot.") }
        return result
    }

    func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.message("Cannot create output PNG: \(url.lastPathComponent).")
        }
        // A newly created destination receives no properties from the captured source.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("Cannot finalize output PNG.") }
    }

    func metadataIsClean(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        let forbidden = [kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                         kCGImagePropertyGPSDictionary, kCGImagePropertyMakerAppleDictionary]
        guard forbidden.allSatisfy({ properties[$0 as String] == nil }) else { return false }
        // ImageIO synthesizes these three technical EXIF fields for fresh sRGB PNGs.
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            guard Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]) else { return false }
        }
        if let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            guard Set(png.keys).isSubset(of: ["Chromaticities", "Gamma", "InterlaceType", "sRGBIntent", "XPixelsPerMeter", "YPixelsPerMeter"]) else { return false }
        }
        return Set(properties.keys).isSubset(of: ["ColorModel", "Depth", "HasAlpha", "PixelHeight", "PixelWidth", "ProfileName", "DPIWidth", "DPIHeight", "IsFloat", "Indexed", "{Exif}", "{PNG}"])
    }
}

private func saveReport(_ report: Report, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: url, options: .atomic)
}

private func selfTest(_ sanitizer: Sanitizer, reportURL: URL) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clickmate-privacy-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = NSImage(size: NSSize(width: 1100, height: 420))
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1100, height: 420)).fill()
    let lines = ["ClickMate privacy regression fixture", "User: \(NSUserName())", "Name: \(NSFullUserName())",
                 "Path: /Users/\(NSUserName())/Documents/fixture.txt", "Email: fixture-private@example.invalid",
                 "Host: \(ProcessInfo.processInfo.hostName)"]
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 28, y: 360 - index * 55), withAttributes: [.font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.black])
    }
    image.unlockFocus()
    guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.message("Cannot create privacy fixture.") }
    let taggedURL = directory.appendingPathComponent("metadata-fixture.png")
    guard let taggedDestination = CGImageDestinationCreateWithURL(taggedURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure.message("Cannot create metadata fixture.")
    }
    CGImageDestinationAddImage(taggedDestination, original, [kCGImagePropertyPNGDictionary: ["Comment": "Private fixture metadata"]] as CFDictionary)
    guard CGImageDestinationFinalize(taggedDestination), !sanitizer.metadataIsClean(taggedURL) else {
        throw Failure.message("Privacy self-test did not reject textual metadata.")
    }
    let findings = try sanitizer.findings(in: original)
    guard Set(findings.map(\.rule)).isSuperset(of: ["email", "user-home-path", "local-identity"]) else {
        throw Failure.message("Privacy self-test failed to recognize all fixture rules.")
    }
    let output = try sanitizer.sanitized(sanitizer.load(taggedURL), findings: findings)
    guard try sanitizer.findings(in: output).isEmpty else { throw Failure.message("Privacy self-test retained private text.") }
    guard original.dataProvider?.data != output.dataProvider?.data else { throw Failure.message("Privacy self-test did not change source pixels.") }
    let url = directory.appendingPathComponent("fixture.png")
    try sanitizer.write(output, to: url)
    guard sanitizer.metadataIsClean(url) else { throw Failure.message("Privacy self-test retained metadata.") }
    try saveReport(Report(mode: "self-test", expectedImageCount: 1, checkedImageCount: 1, passed: true,
                          images: [ImageReport(file: "fixture.png", width: output.width, height: output.height, redactions: findings,
                                               privacyPassed: true, metadataPassed: true)]), to: reportURL)
    print("Privacy self-test passed: OCR detection, erased pixels, final OCR, and fresh PNG metadata.")
}

private func run(_ options: Options) throws {
    let sanitizer = try Sanitizer(extraTokens: options.extraTokens)
    if options.selfTest { try selfTest(sanitizer, reportURL: options.report); return }
    let fm = FileManager.default
    let sourceDirectory = options.validate ? options.output : options.input
    let present = Set(try fm.contentsOfDirectory(atPath: sourceDirectory.path).filter { $0.hasPrefix("clickmate-") && $0.hasSuffix(".png") })
    let missing = expectedNames.subtracting(present).sorted()
    guard missing.isEmpty else { throw Failure.message("Missing expected screenshots: \(missing.joined(separator: ", ")).") }
    guard present == expectedNames else { throw Failure.message("Unexpected ClickMate screenshot names are present; remove stale captures before continuing.") }
    let stage = options.output.deletingLastPathComponent().appendingPathComponent(".clickmate-screenshots-\(UUID().uuidString)", isDirectory: true)
    if !options.validate { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
    defer { if !options.validate { try? fm.removeItem(at: stage) } }
    var reports: [ImageReport] = []
    for name in expectedNames.sorted() {
        let sourceURL = sourceDirectory.appendingPathComponent(name)
        let source = try sanitizer.load(sourceURL)
        let findings = try sanitizer.findings(in: source)
        let checkedURL: URL
        if options.validate { checkedURL = sourceURL } else {
            checkedURL = stage.appendingPathComponent(name)
            try sanitizer.write(sanitizer.sanitized(source, findings: findings), to: checkedURL)
        }
        let privacyPassed = try sanitizer.findings(in: sanitizer.load(checkedURL)).isEmpty
        let metadataPassed = sanitizer.metadataIsClean(checkedURL)
        reports.append(ImageReport(file: name, width: source.width, height: source.height,
                                   redactions: findings, privacyPassed: privacyPassed, metadataPassed: metadataPassed))
    }
    let passed = reports.allSatisfy { $0.privacyPassed && $0.metadataPassed }
    try saveReport(Report(mode: options.validate ? "validate" : "sanitize", expectedImageCount: expectedNames.count,
                          checkedImageCount: reports.count, passed: passed, images: reports), to: options.report)
    guard passed else { throw Failure.message("Screenshot privacy validation failed. See rule IDs in the report; output images were not published.") }
    if !options.validate {
        try fm.createDirectory(at: options.output, withIntermediateDirectories: true)
        // All 24 images are checked before replacing any published screenshot.
        for name in expectedNames.sorted() {
            let target = options.output.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: stage.appendingPathComponent(name)) }
            else { try fm.moveItem(at: stage.appendingPathComponent(name), to: target) }
        }
    }
    print("\(options.validate ? "Validated" : "Sanitized and validated") \(reports.count) screenshots; privacy and metadata checks passed.")
}

do { try run(Options(Array(CommandLine.arguments.dropFirst()))) }
catch { fputs("Documentation image preparation failed: \(error)\n", stderr); exit(1) }
