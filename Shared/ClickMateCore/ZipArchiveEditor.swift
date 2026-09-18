import Foundation
import zlib

/// A small ZIP reader/writer intended for in-place JAR configuration edits.
/// It copies every untouched local-file record verbatim and only regenerates
/// records the user changed. ZIP64, encrypted and multi-disk archives are
/// deliberately rejected rather than risking a lossy rewrite.
enum ZipArchiveEditor {
    enum CompressionMethod: UInt16, Equatable {
        case store = 0
        case deflate = 8

        var displayName: String {
            switch self {
            case .store: "STORE"
            case .deflate: "DEFLATE"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let name: String
        let compressionMethod: CompressionMethod
        let uncompressedSize: UInt32
        let compressedSize: UInt32
        let crc32: UInt32
        let flags: UInt16
        fileprivate let localHeaderOffset: UInt32
        fileprivate let centralDirectoryRecord: Data

        var id: String { name }
        var isDirectory: Bool { name.hasSuffix("/") }
        var isEncrypted: Bool { flags & 1 != 0 }
    }

    struct Archive {
        let url: URL
        let entries: [Entry]

        var hasSignatureFiles: Bool {
            entries.contains { entry in
                let uppercased = entry.name.uppercased()
                guard uppercased.hasPrefix("META-INF/") else { return false }
                return [".SF", ".RSA", ".DSA", ".EC"].contains { uppercased.hasSuffix($0) }
            }
        }
    }

    enum Error: LocalizedError {
        case invalidArchive(String)
        case unsupported(String)
        case entryNotFound(String)
        case corruptEntry(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidArchive(message), let .unsupported(message), let .corruptEntry(message), let .verificationFailed(message): message
            case let .entryNotFound(name): "The archive does not contain \(name)."
            }
        }
    }

    static func open(_ url: URL) throws -> Archive {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let layout = try parseLayout(data)
        return Archive(url: url, entries: layout.entries)
    }

    static func readEntry(named name: String, from archive: Archive) throws -> Data {
        guard let entry = archive.entries.first(where: { $0.name == name }) else {
            throw Error.entryNotFound(name)
        }
        guard !entry.isDirectory else { throw Error.corruptEntry("\(name) is a directory.") }
        guard !entry.isEncrypted else { throw Error.unsupported("Encrypted ZIP entries cannot be edited.") }

        let data = try Data(contentsOf: archive.url, options: .mappedIfSafe)
        let payload = try compressedPayload(for: entry, in: data)
        let expanded: Data
        switch entry.compressionMethod {
        case .store:
            expanded = payload
        case .deflate:
            expanded = try inflateRaw(payload, expectedSize: Int(entry.uncompressedSize))
        }
        guard crc32(of: expanded) == entry.crc32 else {
            throw Error.corruptEntry("CRC verification failed for \(name).")
        }
        return expanded
    }

    /// Writes a validated archive next to the original, then atomically replaces it.
    /// A backup is only created when `createBackup` is true and it does not yet exist.
    static func replaceEntry(
        named name: String,
        with contents: Data,
        in archive: Archive,
        createBackup: Bool
    ) throws {
        guard let replacement = archive.entries.first(where: { $0.name == name }) else {
            throw Error.entryNotFound(name)
        }
        guard !replacement.isDirectory else { throw Error.corruptEntry("A directory cannot be edited.") }
        guard !replacement.isEncrypted else { throw Error.unsupported("Encrypted ZIP entries cannot be edited.") }

        let original = try Data(contentsOf: archive.url, options: .mappedIfSafe)
        let layout = try parseLayout(original)
        guard layout.entries == archive.entries else {
            throw Error.verificationFailed("The archive changed on disk. Reopen it before saving.")
        }

        let temporaryURL = archive.url.deletingLastPathComponent()
            .appendingPathComponent(".\(archive.url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let rewritten = try rewrite(
            original: original,
            layout: layout,
            replacing: replacement,
            contents: contents
        )
        try rewritten.write(to: temporaryURL, options: .withoutOverwriting)
        try copyFilePermissions(from: archive.url, to: temporaryURL)
        try verify(
            archiveURL: temporaryURL,
            expectedContents: contents,
            changedEntry: replacement,
            originalEntries: layout.entries
        )

        if createBackup {
            let backupURL = archive.url.appendingPathExtension("bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: archive.url, to: backupURL)
            }
        }
        _ = try FileManager.default.replaceItemAt(
            archive.url,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }
}

private extension ZipArchiveEditor {
    struct Layout {
        let entries: [Entry]
        let centralDirectoryOffset: Int
        let centralDirectorySize: Int
        let trailingCentralDirectoryData: Data
        let endOfCentralDirectory: Data
    }

    static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    static let centralDirectorySignature: UInt32 = 0x0201_4B50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    static func parseLayout(_ data: Data) throws -> Layout {
        guard data.count >= 22 else { throw Error.invalidArchive("This file is not a ZIP/JAR archive.") }
        let searchStart = max(0, data.count - 65_557)
        var eocdOffset: Int?
        for offset in stride(from: data.count - 22, through: searchStart, by: -1) {
            if try data.uint32(at: offset) == endOfCentralDirectorySignature {
                let commentLength = Int(try data.uint16(at: offset + 20))
                if offset + 22 + commentLength == data.count {
                    eocdOffset = offset
                    break
                }
            }
        }
        guard let eocdOffset else { throw Error.invalidArchive("ZIP end-of-central-directory record is missing.") }
        guard try data.uint16(at: eocdOffset + 4) == 0, try data.uint16(at: eocdOffset + 6) == 0 else {
            throw Error.unsupported("Multi-disk ZIP archives are not supported.")
        }

        let entryCount = Int(try data.uint16(at: eocdOffset + 10))
        let centralDirectorySize = Int(try data.uint32(at: eocdOffset + 12))
        let centralDirectoryOffset = Int(try data.uint32(at: eocdOffset + 16))
        guard entryCount != Int(UInt16.max), centralDirectorySize != Int(UInt32.max), centralDirectoryOffset != Int(UInt32.max) else {
            throw Error.unsupported("ZIP64 archives are not supported for safe editing.")
        }
        guard centralDirectoryOffset >= 0, centralDirectoryOffset + centralDirectorySize <= eocdOffset else {
            throw Error.invalidArchive("ZIP central directory has invalid bounds.")
        }

        var entries: [Entry] = []
        var offset = centralDirectoryOffset
        for _ in 0 ..< entryCount {
            guard try data.uint32(at: offset) == centralDirectorySignature else {
                throw Error.invalidArchive("ZIP central directory entry is invalid.")
            }
            let filenameLength = Int(try data.uint16(at: offset + 28))
            let extraLength = Int(try data.uint16(at: offset + 30))
            let commentLength = Int(try data.uint16(at: offset + 32))
            let recordLength = 46 + filenameLength + extraLength + commentLength
            guard offset + recordLength <= centralDirectoryOffset + centralDirectorySize else {
                throw Error.invalidArchive("ZIP central directory entry extends past its directory.")
            }
            let flags = try data.uint16(at: offset + 8)
            let rawMethod = try data.uint16(at: offset + 10)
            guard let method = CompressionMethod(rawValue: rawMethod) else {
                throw Error.unsupported("ZIP entry uses unsupported compression method \(rawMethod).")
            }
            let compressedSize = try data.uint32(at: offset + 20)
            let uncompressedSize = try data.uint32(at: offset + 24)
            let localOffset = try data.uint32(at: offset + 42)
            guard compressedSize != UInt32.max, uncompressedSize != UInt32.max, localOffset != UInt32.max else {
                throw Error.unsupported("ZIP64 entries cannot be edited safely.")
            }
            let nameBytes = data.subdata(in: (offset + 46) ..< (offset + 46 + filenameLength))
            let name = try decodeName(nameBytes, flags: flags)
            entries.append(Entry(
                name: name,
                compressionMethod: method,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                crc32: try data.uint32(at: offset + 16),
                flags: flags,
                localHeaderOffset: localOffset,
                centralDirectoryRecord: data.subdata(in: offset ..< offset + recordLength)
            ))
            offset += recordLength
        }
        guard offset == centralDirectoryOffset + centralDirectorySize else {
            throw Error.invalidArchive("ZIP central directory size does not match its entries.")
        }
        guard Set(entries.map(\.name)).count == entries.count else {
            throw Error.unsupported("Archives with duplicate entry names cannot be edited safely.")
        }
        return Layout(
            entries: entries,
            centralDirectoryOffset: centralDirectoryOffset,
            centralDirectorySize: centralDirectorySize,
            trailingCentralDirectoryData: data.subdata(in: (centralDirectoryOffset + centralDirectorySize) ..< eocdOffset),
            endOfCentralDirectory: data.subdata(in: eocdOffset ..< data.count)
        )
    }

    static func rewrite(original: Data, layout: Layout, replacing entry: Entry, contents: Data) throws -> Data {
        let orderedByOffset = layout.entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        guard let firstOffset = orderedByOffset.first.map({ Int($0.localHeaderOffset) }) else {
            throw Error.invalidArchive("The archive has no entries.")
        }
        var output = Data(original.prefix(firstOffset))
        var newOffsets: [String: UInt32] = [:]

        for (index, current) in orderedByOffset.enumerated() {
            let start = Int(current.localHeaderOffset)
            let end = index + 1 < orderedByOffset.count
                ? Int(orderedByOffset[index + 1].localHeaderOffset)
                : layout.centralDirectoryOffset
            guard start < end, end <= original.count else {
                throw Error.invalidArchive("ZIP local-file offsets are invalid.")
            }
            guard output.count <= Int(UInt32.max) else { throw Error.unsupported("Archive exceeds classic ZIP limits.") }
            newOffsets[current.name] = UInt32(output.count)
            if current.name == entry.name {
                output.append(try modifiedLocalRecord(
                    for: current,
                    original: original,
                    recordEnd: end,
                    contents: contents
                ))
            } else {
                output.append(original.subdata(in: start ..< end))
            }
        }

        let newCentralDirectoryOffset = output.count
        for current in layout.entries {
            guard let newOffset = newOffsets[current.name] else { throw Error.invalidArchive("ZIP entry offset is missing.") }
            var centralRecord = current.centralDirectoryRecord
            try centralRecord.setUInt32(newOffset, at: 42)
            if current.name == entry.name {
                let compressed = try compressed(contents, using: current.compressionMethod)
                try centralRecord.setUInt32(crc32(of: contents), at: 16)
                try centralRecord.setUInt32(UInt32(compressed.count), at: 20)
                try centralRecord.setUInt32(UInt32(contents.count), at: 24)
            }
            output.append(centralRecord)
        }
        let newCentralDirectorySize = output.count - newCentralDirectoryOffset
        guard newCentralDirectoryOffset <= Int(UInt32.max), newCentralDirectorySize <= Int(UInt32.max) else {
            throw Error.unsupported("Archive exceeds classic ZIP limits.")
        }
        output.append(layout.trailingCentralDirectoryData)
        var eocd = layout.endOfCentralDirectory
        try eocd.setUInt32(UInt32(newCentralDirectorySize), at: 12)
        try eocd.setUInt32(UInt32(newCentralDirectoryOffset), at: 16)
        output.append(eocd)
        return output
    }

    static func modifiedLocalRecord(for entry: Entry, original: Data, recordEnd: Int, contents: Data) throws -> Data {
        let offset = Int(entry.localHeaderOffset)
        guard try original.uint32(at: offset) == localFileHeaderSignature else {
            throw Error.invalidArchive("Local file header for \(entry.name) is invalid.")
        }
        let nameLength = Int(try original.uint16(at: offset + 26))
        let extraLength = Int(try original.uint16(at: offset + 28))
        let headerLength = 30 + nameLength + extraLength
        guard offset + headerLength <= original.count else { throw Error.invalidArchive("Local file header is truncated.") }
        let compressedData = try compressed(contents, using: entry.compressionMethod)
        guard compressedData.count <= Int(UInt32.max), contents.count <= Int(UInt32.max) else {
            throw Error.unsupported("The edited file exceeds ZIP's classic size limit.")
        }
        let checksum = crc32(of: contents)
        var header = original.subdata(in: offset ..< offset + headerLength)
        try header.setUInt32(checksum, at: 14)
        try header.setUInt32(UInt32(compressedData.count), at: 18)
        try header.setUInt32(UInt32(contents.count), at: 22)
        var result = header
        result.append(compressedData)
        var trailingStart = offset + headerLength + Int(entry.compressedSize)
        if entry.flags & 0x0008 != 0 {
            // Keep the original descriptor convention: signed if the original used its signature.
            let dataStart = offset + headerLength
            let oldDescriptorStart = dataStart + Int(entry.compressedSize)
            let hasSignature: Bool
            if oldDescriptorStart + 4 <= original.count {
                hasSignature = try original.uint32(at: oldDescriptorStart) == 0x0807_4B50
            } else {
                hasSignature = false
            }
            if hasSignature { result.appendUInt32(0x0807_4B50) }
            result.appendUInt32(checksum)
            result.appendUInt32(UInt32(compressedData.count))
            result.appendUInt32(UInt32(contents.count))
            trailingStart += hasSignature ? 16 : 12
        }
        guard trailingStart <= recordEnd else { throw Error.invalidArchive("ZIP data descriptor is truncated.") }
        result.append(original.subdata(in: trailingStart ..< recordEnd))
        return result
    }

    static func compressedPayload(for entry: Entry, in data: Data) throws -> Data {
        let offset = Int(entry.localHeaderOffset)
        guard try data.uint32(at: offset) == localFileHeaderSignature else {
            throw Error.invalidArchive("Local file header for \(entry.name) is invalid.")
        }
        let nameLength = Int(try data.uint16(at: offset + 26))
        let extraLength = Int(try data.uint16(at: offset + 28))
        let payloadStart = offset + 30 + nameLength + extraLength
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadStart >= offset, payloadEnd <= data.count else { throw Error.invalidArchive("ZIP entry data is truncated.") }
        return data.subdata(in: payloadStart ..< payloadEnd)
    }

    static func verify(archiveURL: URL, expectedContents: Data, changedEntry: Entry, originalEntries: [Entry]) throws {
        let reopened = try open(archiveURL)
        guard reopened.entries.count == originalEntries.count else {
            throw Error.verificationFailed("The rewritten archive changed the number of entries.")
        }
        guard let changed = reopened.entries.first(where: { $0.name == changedEntry.name }) else {
            throw Error.verificationFailed("The edited entry is missing after rewriting.")
        }
        guard changed.compressionMethod == changedEntry.compressionMethod else {
            throw Error.verificationFailed("The edited entry's compression method changed.")
        }
        guard try readEntry(named: changed.name, from: reopened) == expectedContents else {
            throw Error.verificationFailed("The edited entry contents do not match after rewriting.")
        }
        for (before, after) in zip(originalEntries, reopened.entries) where before.name != changedEntry.name {
            guard before.name == after.name, before.compressionMethod == after.compressionMethod else {
                throw Error.verificationFailed("An untouched entry changed while rewriting.")
            }
        }
    }

    static func compressed(_ input: Data, using method: CompressionMethod) throws -> Data {
        switch method {
        case .store: input
        case .deflate: try deflateRaw(input)
        }
    }

    static func deflateRaw(_ input: Data) throws -> Data {
        var stream = z_stream()
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw Error.corruptEntry("Could not initialize ZIP compression.") }
        defer { deflateEnd(&stream) }

        return try input.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            repeat {
                let capacity = 32_768
                var chunk = [UInt8](repeating: 0, count: capacity)
                let resultStatus = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                result.append(contentsOf: chunk.prefix(produced))
                guard resultStatus == Z_OK || resultStatus == Z_STREAM_END else {
                    throw Error.corruptEntry("Could not compress ZIP entry data.")
                }
                if resultStatus == Z_STREAM_END { break }
            } while true
            return result
        }
    }

    static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Error.corruptEntry("Could not initialize ZIP decompression.")
        }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            result.reserveCapacity(expectedSize)
            repeat {
                let capacity = 32_768
                var chunk = [UInt8](repeating: 0, count: capacity)
                let resultStatus = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                result.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                guard resultStatus == Z_OK || resultStatus == Z_STREAM_END else {
                    throw Error.corruptEntry("Could not decompress ZIP entry data.")
                }
                if resultStatus == Z_STREAM_END { break }
            } while true
            return result
        }
    }

    static func crc32(of data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }

    static func decodeName(_ data: Data, flags: UInt16) throws -> String {
        if flags & 0x0800 != 0, let name = String(data: data, encoding: .utf8) { return name }
        if let name = String(data: data, encoding: .isoLatin1) { return name }
        throw Error.invalidArchive("An archive entry has an unreadable filename.")
    }

    static func copyFilePermissions(from source: URL, to destination: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
    }
}

private extension Data {
    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZipArchiveEditor.Error.invalidArchive("ZIP record is truncated.") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchiveEditor.Error.invalidArchive("ZIP record is truncated.") }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    mutating func setUInt32(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchiveEditor.Error.invalidArchive("ZIP record is truncated.") }
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
