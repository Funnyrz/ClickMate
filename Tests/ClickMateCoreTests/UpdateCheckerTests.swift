import XCTest

final class UpdateCheckerTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testVersionComparisonNormalizesTagsAndNumericSegments() {
        XCTAssertEqual(AppVersion.normalizedVersion("v1.4"), "1.4")
        XCTAssertEqual(AppVersion.normalizedVersion(" V1.4.0 "), "1.4.0")
        XCTAssertEqual(AppVersion.compare("v1.4", to: "1.3"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare("1.10", to: "1.9"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare("1.4", to: "1.4.0"), .orderedSame)
        XCTAssertEqual(AppVersion.compare("1.3", to: "1.4"), .orderedAscending)
        XCTAssertNil(AppVersion.normalizedVersion("v1.4-beta"))
        XCTAssertNil(AppVersion.compare("latest", to: "1.3"))
    }

    func testUpdateLocalizationKeysExistInBothLanguages() {
        for key in [
            "update.check",
            "update.checking",
            "update.availableInline",
            "update.alertAvailableTitle",
            "update.alertAvailableMessage",
            "update.alertUpToDateTitle",
            "update.alertUpToDateMessage",
            "update.alertFailedTitle",
            "update.alertFailedMessage",
            "update.openDownload",
            "update.openReleases",
            "update.later",
            "update.close",
            "update.notificationTitle",
            "update.notificationBody"
        ] {
            XCTAssertNotEqual(L10n.string(key, language: .english), key)
            XCTAssertNotEqual(L10n.string(key, language: .simplifiedChinese), key)
        }
    }

    func testReleaseUsesOnlyTrustedGitHubDownloadURLs() throws {
        let trusted = try makeRelease(tagName: "v1.4", htmlURL: "https://github.com/Funnyrz/ClickMate/releases/tag/v1.4")
        let untrusted = try makeRelease(tagName: "v1.4", htmlURL: "https://example.com/ClickMate")
        let insecure = try makeRelease(tagName: "v1.4", htmlURL: "http://github.com/Funnyrz/ClickMate/releases/tag/v1.4")

        XCTAssertEqual(trusted.safeDownloadURL, trusted.htmlURL)
        XCTAssertEqual(untrusted.safeDownloadURL, GitHubRelease.fallbackDownloadURL)
        XCTAssertEqual(insecure.safeDownloadURL, GitHubRelease.fallbackDownloadURL)
    }

    func testGitHubReleaseCheckerDecodesLatestReleaseAndSendsRequiredHeaders() async throws {
        let session = makeStubbedSession()
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.test/repos/Funnyrz/ClickMate/releases/latest"))
        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.url, endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ClickMate-Updater")
            let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
            let data = Data(
                """
                {
                  "tag_name": "v1.4",
                  "name": "ClickMate 1.4",
                  "html_url": "https://github.com/Funnyrz/ClickMate/releases/tag/v1.4",
                  "published_at": "2026-08-15T08:00:00Z"
                }
                """.utf8
            )
            return (response, data)
        }

        let release = try await GitHubReleaseChecker(session: session, endpoint: endpoint).latestRelease()

        XCTAssertEqual(release.tagName, "v1.4")
        XCTAssertEqual(release.name, "ClickMate 1.4")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/Funnyrz/ClickMate/releases/tag/v1.4")
        XCTAssertNotNil(release.publishedAt)
    }

    func testGitHubReleaseCheckerRejectsNonSuccessResponses() async throws {
        let session = makeStubbedSession()
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.test/releases/latest"))
        URLProtocolStub.requestHandler = { _ in
            let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 403, httpVersion: nil, headerFields: nil))
            return (response, Data())
        }

        do {
            _ = try await GitHubReleaseChecker(session: session, endpoint: endpoint).latestRelease()
            XCTFail("Expected an HTTP status error")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .httpStatus(403))
        }
    }

    func testGitHubReleaseCheckerPropagatesInvalidJSONAndTimeouts() async throws {
        let session = makeStubbedSession()
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.test/releases/latest"))
        URLProtocolStub.requestHandler = { _ in
            let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data("not-json".utf8))
        }

        do {
            _ = try await GitHubReleaseChecker(session: session, endpoint: endpoint).latestRelease()
            XCTFail("Expected decoding to fail")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }

        URLProtocolStub.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await GitHubReleaseChecker(session: session, endpoint: endpoint).latestRelease()
            XCTFail("Expected timeout to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    @MainActor
    func testAutomaticCheckSkipsWithinTwentyFourHours() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let checker = CountingUpdateChecker(release: try makeRelease(tagName: "v1.4"))
        let store = InMemoryUpdateCheckStore(lastAutomaticCheckDate: now.addingTimeInterval(-60 * 60))
        let coordinator = makeCoordinator(checker: checker, store: store, now: now)

        await coordinator.checkAutomaticallyIfNeeded()

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testAutomaticCheckRunsAfterTwentyFourHoursAndRecordsAttempt() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let release = try makeRelease(tagName: "v1.4")
        let checker = CountingUpdateChecker(release: release)
        let store = InMemoryUpdateCheckStore(lastAutomaticCheckDate: now.addingTimeInterval(-25 * 60 * 60))
        var notifications: [String] = []
        let coordinator = makeCoordinator(
            checker: checker,
            store: store,
            now: now,
            notificationHandler: { notifications.append($0) }
        )

        await coordinator.checkAutomaticallyIfNeeded()

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.lastAutomaticCheckDate, now)
        XCTAssertEqual(store.lastNotifiedVersion, "1.4")
        XCTAssertEqual(notifications, ["1.4"])
        XCTAssertEqual(coordinator.state, .updateAvailable(release))
    }

    @MainActor
    func testManualCheckBypassesThrottleAndReportsLatestVersion() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let checker = CountingUpdateChecker(release: try makeRelease(tagName: "v1.3"))
        let store = InMemoryUpdateCheckStore(lastAutomaticCheckDate: now)
        let coordinator = makeCoordinator(checker: checker, store: store, now: now)

        await coordinator.checkManually()

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(coordinator.state, .upToDate("1.3"))
        XCTAssertEqual(coordinator.manualResult, .upToDate("1.3"))
    }

    @MainActor
    func testManualCheckTreatsOlderReleaseAsUpToDate() async throws {
        let checker = CountingUpdateChecker(release: try makeRelease(tagName: "v1.2"))
        let coordinator = makeCoordinator(checker: checker, store: InMemoryUpdateCheckStore(), now: Date())

        await coordinator.checkManually()

        XCTAssertEqual(coordinator.state, .upToDate("1.3"))
        XCTAssertEqual(coordinator.manualResult, .upToDate("1.3"))
    }

    @MainActor
    func testManualCheckReportsNewReleaseAndSuppressesLaterDuplicateNotification() async throws {
        let release = try makeRelease(tagName: "v1.4")
        let checker = CountingUpdateChecker(release: release)
        let store = InMemoryUpdateCheckStore()
        let coordinator = makeCoordinator(checker: checker, store: store, now: Date())

        await coordinator.checkManually()

        XCTAssertEqual(coordinator.state, .updateAvailable(release))
        XCTAssertEqual(coordinator.manualResult, .updateAvailable(currentVersion: "1.3", release: release))
        XCTAssertEqual(store.lastNotifiedVersion, "1.4")
    }

    @MainActor
    func testMalformedReleaseVersionFailsWithoutReportingAnUpdate() async throws {
        let checker = CountingUpdateChecker(release: try makeRelease(tagName: "v1.4-beta"))
        let coordinator = makeCoordinator(checker: checker, store: InMemoryUpdateCheckStore(), now: Date())

        await coordinator.checkManually()

        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertEqual(coordinator.manualResult, .failed)
    }

    @MainActor
    func testAutomaticCheckDoesNotRepeatNotificationForSameVersion() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let checker = CountingUpdateChecker(release: try makeRelease(tagName: "v1.4"))
        let store = InMemoryUpdateCheckStore(lastNotifiedVersion: "1.4")
        var notifications: [String] = []
        let coordinator = makeCoordinator(
            checker: checker,
            store: store,
            now: now,
            notificationHandler: { notifications.append($0) }
        )

        await coordinator.checkAutomaticallyIfNeeded()

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(coordinator.state, .updateAvailable(try makeRelease(tagName: "v1.4")))
    }

    @MainActor
    func testAutomaticFailureIsSilentWhileManualFailureIsPresented() async {
        let checker = CountingUpdateChecker(error: .httpStatus(500))
        let store = InMemoryUpdateCheckStore()
        let coordinator = makeCoordinator(checker: checker, store: store, now: Date())

        await coordinator.checkAutomaticallyIfNeeded()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.manualResult)

        await coordinator.checkManually()

        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertEqual(coordinator.manualResult, .failed)
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeRelease(
        tagName: String,
        htmlURL: String = "https://github.com/Funnyrz/ClickMate/releases/tag/v1.4"
    ) throws -> GitHubRelease {
        GitHubRelease(
            tagName: tagName,
            name: "ClickMate \(tagName)",
            htmlURL: try XCTUnwrap(URL(string: htmlURL)),
            publishedAt: nil
        )
    }

    @MainActor
    private func makeCoordinator(
        checker: some UpdateChecking,
        store: InMemoryUpdateCheckStore,
        now: Date,
        notificationHandler: @escaping (String) -> Void = { _ in }
    ) -> UpdateCheckCoordinator {
        UpdateCheckCoordinator(
            checker: checker,
            store: store,
            currentVersion: { "1.3" },
            now: { now },
            notificationHandler: notificationHandler
        )
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor CountingUpdateChecker: UpdateChecking {
    private(set) var callCount = 0
    private let release: GitHubRelease?
    private let error: UpdateCheckError?

    init(release: GitHubRelease? = nil, error: UpdateCheckError? = nil) {
        self.release = release
        self.error = error
    }

    func latestRelease() async throws -> GitHubRelease {
        callCount += 1
        if let error {
            throw error
        }
        guard let release else {
            throw UpdateCheckError.invalidResponse
        }
        return release
    }
}

@MainActor
private final class InMemoryUpdateCheckStore: UpdateCheckStoring {
    var lastAutomaticCheckDate: Date?
    var lastNotifiedVersion: String?

    init(lastAutomaticCheckDate: Date? = nil, lastNotifiedVersion: String? = nil) {
        self.lastAutomaticCheckDate = lastAutomaticCheckDate
        self.lastNotifiedVersion = lastNotifiedVersion
    }
}
