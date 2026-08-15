import Combine
import Foundation

struct GitHubRelease: Decodable, Equatable, Sendable {
    static let fallbackDownloadURL = URL(string: "https://github.com/Funnyrz/ClickMate/releases/latest")!

    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?

    var normalizedVersion: String? {
        AppVersion.normalizedVersion(tagName)
    }

    var safeDownloadURL: URL {
        guard htmlURL.scheme?.lowercased() == "https",
              let host = htmlURL.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else {
            return Self.fallbackDownloadURL
        }
        return htmlURL
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

protocol UpdateChecking: Sendable {
    func latestRelease() async throws -> GitHubRelease
}

enum UpdateCheckError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidCurrentVersion
    case invalidReleaseVersion(String)
}

struct GitHubReleaseChecker: UpdateChecking {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Funnyrz/ClickMate/releases/latest")!

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = GitHubReleaseChecker.makeSession(), endpoint: URL = latestReleaseURL) {
        self.session = session
        self.endpoint = endpoint
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClickMate-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

extension AppVersion {
    static func shortVersion(bundle: Bundle = .main) -> String? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty
        else {
            return nil
        }
        return version
    }

    static func normalizedVersion(_ value: String) -> String? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let segments = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }
        return normalized
    }

    static func compare(_ lhs: String, to rhs: String) -> ComparisonResult? {
        guard let left = versionSegments(lhs), let right = versionSegments(rhs) else {
            return nil
        }

        let segmentCount = max(left.count, right.count)
        for index in 0..<segmentCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue {
                return .orderedAscending
            }
            if leftValue > rightValue {
                return .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func versionSegments(_ value: String) -> [UInt]? {
        guard let normalized = normalizedVersion(value) else { return nil }
        let segments = normalized.split(separator: ".", omittingEmptySubsequences: false)
        let values = segments.compactMap { UInt($0) }
        return values.count == segments.count ? values : nil
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case updateAvailable(GitHubRelease)
    case failed
}

enum ManualUpdateCheckResult: Equatable, Identifiable {
    case upToDate(String)
    case updateAvailable(currentVersion: String, release: GitHubRelease)
    case failed

    var id: String {
        switch self {
        case let .upToDate(version):
            return "up-to-date-\(version)"
        case let .updateAvailable(_, release):
            return "update-available-\(release.tagName)"
        case .failed:
            return "failed"
        }
    }
}

@MainActor
protocol UpdateCheckStoring: AnyObject {
    var lastAutomaticCheckDate: Date? { get set }
    var lastNotifiedVersion: String? { get set }
}

@MainActor
final class UserDefaultsUpdateCheckStore: UpdateCheckStoring {
    private enum Key {
        static let lastAutomaticCheckDate = "updates.lastAutomaticCheckDate"
        static let lastNotifiedVersion = "updates.lastNotifiedVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastAutomaticCheckDate: Date? {
        get { defaults.object(forKey: Key.lastAutomaticCheckDate) as? Date }
        set { defaults.set(newValue, forKey: Key.lastAutomaticCheckDate) }
    }

    var lastNotifiedVersion: String? {
        get { defaults.string(forKey: Key.lastNotifiedVersion) }
        set { defaults.set(newValue, forKey: Key.lastNotifiedVersion) }
    }
}

@MainActor
final class UpdateCheckCoordinator: ObservableObject {
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: UpdateCheckState = .idle
    @Published private(set) var manualResult: ManualUpdateCheckResult?

    private let checker: any UpdateChecking
    private let store: any UpdateCheckStoring
    private let currentVersion: () -> String?
    private let now: () -> Date
    private let notificationHandler: (String) -> Void
    private var isChecking = false

    init(
        checker: any UpdateChecking = GitHubReleaseChecker(),
        store: any UpdateCheckStoring = UserDefaultsUpdateCheckStore(),
        currentVersion: @escaping () -> String? = { AppVersion.shortVersion() },
        now: @escaping () -> Date = Date.init,
        notificationHandler: @escaping (String) -> Void = { version in
            ActionNotifier.notify(
                titleKey: "update.notificationTitle",
                bodyKey: "update.notificationBody",
                bodyArguments: [version]
            )
        }
    ) {
        self.checker = checker
        self.store = store
        self.currentVersion = currentVersion
        self.now = now
        self.notificationHandler = notificationHandler
    }

    var availableRelease: GitHubRelease? {
        guard case let .updateAvailable(release) = state else { return nil }
        return release
    }

    func checkAutomaticallyIfNeeded() async {
        let checkDate = now()
        if let lastCheckDate = store.lastAutomaticCheckDate,
           checkDate.timeIntervalSince(lastCheckDate) < Self.automaticCheckInterval
        {
            return
        }

        store.lastAutomaticCheckDate = checkDate
        let previousState = state
        do {
            let evaluation = try await performCheck()
            apply(evaluation)
            if case let .updateAvailable(_, release, normalizedVersion) = evaluation,
               store.lastNotifiedVersion != normalizedVersion
            {
                notificationHandler(normalizedVersion)
                store.lastNotifiedVersion = normalizedVersion
                state = .updateAvailable(release)
            }
        } catch {
            state = previousState == .checking ? .idle : previousState
        }
    }

    func checkManually() async {
        do {
            let evaluation = try await performCheck()
            apply(evaluation)
            switch evaluation {
            case let .upToDate(currentVersion):
                manualResult = .upToDate(currentVersion)
            case let .updateAvailable(currentVersion, release, normalizedVersion):
                store.lastNotifiedVersion = normalizedVersion
                manualResult = .updateAvailable(currentVersion: currentVersion, release: release)
            }
        } catch {
            state = .failed
            manualResult = .failed
        }
    }

    func dismissManualResult() {
        manualResult = nil
    }

    private func performCheck() async throws -> Evaluation {
        guard !isChecking else {
            throw UpdateCheckError.invalidResponse
        }

        isChecking = true
        state = .checking
        defer { isChecking = false }

        guard let currentVersion = currentVersion(),
              let normalizedCurrentVersion = AppVersion.normalizedVersion(currentVersion)
        else {
            throw UpdateCheckError.invalidCurrentVersion
        }

        let release = try await checker.latestRelease()
        guard let normalizedReleaseVersion = AppVersion.normalizedVersion(release.tagName),
              let comparison = AppVersion.compare(normalizedReleaseVersion, to: normalizedCurrentVersion)
        else {
            throw UpdateCheckError.invalidReleaseVersion(release.tagName)
        }

        if comparison == .orderedDescending {
            return .updateAvailable(normalizedCurrentVersion, release, normalizedReleaseVersion)
        }
        return .upToDate(normalizedCurrentVersion)
    }

    private func apply(_ evaluation: Evaluation) {
        switch evaluation {
        case let .upToDate(version):
            state = .upToDate(version)
        case let .updateAvailable(_, release, _):
            state = .updateAvailable(release)
        }
    }

    private enum Evaluation {
        case upToDate(String)
        case updateAvailable(String, GitHubRelease, String)
    }
}
