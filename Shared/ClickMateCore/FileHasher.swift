import CryptoKit
import Foundation

enum HashAlgorithm: String, Codable {
    case sha256 = "SHA-256"
    case sha1 = "SHA-1"
    case md5 = "MD5"
}

enum FileHasher {
    struct HashResult: Equatable {
        let text: String
        let failures: [String]

        var succeeded: Bool {
            failures.isEmpty
        }
    }

    static func hash(fileAt url: URL, algorithm: HashAlgorithm) throws -> String {
        let data = try Data(contentsOf: url)
        switch algorithm {
        case .sha256:
            return SHA256.hash(data: data).hexString
        case .sha1:
            return Insecure.SHA1.hash(data: data).hexString
        case .md5:
            return Insecure.MD5.hash(data: data).hexString
        }
    }

    static func hashes(for urls: [URL], algorithm: HashAlgorithm) -> String {
        hashResult(for: urls, algorithm: algorithm).text
    }

    static func hashResult(for urls: [URL], algorithm: HashAlgorithm) -> HashResult {
        var failures: [String] = []
        let lines = urls.map { url in
            do {
                return "\(try hash(fileAt: url, algorithm: algorithm))  \(url.lastPathComponent)"
            } catch {
                failures.append(url.lastPathComponent)
                return "ERROR  \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return HashResult(text: lines.joined(separator: "\n"), failures: failures)
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
