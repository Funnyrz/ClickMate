import Foundation
import XCTest

final class BatchRoutingTests: XCTestCase {
    private let urls = [
        URL(fileURLWithPath: "/tmp/中文 File.txt"),
        URL(fileURLWithPath: "/tmp/Bob's file[1].txt")
    ]

    func testBatchActionsRoundTripQueueAndFallbackRoute() throws {
        for command in [MenuCommand.duplicateTimestamp, .createAlias, .moveToNewFolder] {
            let route = FinderActionRoute.batchFileAction(command: command, urls: urls)
            let url = try XCTUnwrap(route.url)
            XCTAssertEqual(FinderActionRoute(url: url), route)
            XCTAssertTrue(route.requiresVisibleWindow)

            let pending = route.pendingCommand
            XCTAssertEqual(pending.kind, .batchFileAction)
            XCTAssertEqual(pending.menuCommand, command)
            XCTAssertEqual(pending.urls, urls)
            let encoded = try JSONEncoder().encode(pending)
            XCTAssertEqual(try JSONDecoder().decode(PendingCommand.self, from: encoded), pending)
        }
    }

    func testBatchRouteRejectsOtherCommandsAndNonFileURLs() throws {
        XCTAssertNil(FinderActionRoute.batchFileAction(command: .compress, urls: urls).url)
        XCTAssertNil(FinderActionRoute.batchFileAction(command: .moveToNewFolder, urls: []).url)
        XCTAssertNil(FinderActionRoute.batchFileAction(command: .createAlias, urls: [try XCTUnwrap(URL(string: "https://example.com/file"))]).url)

        let validURL = try XCTUnwrap(FinderActionRoute.batchFileAction(command: .createAlias, urls: urls).url)
        var components = try XCTUnwrap(URLComponents(url: validURL, resolvingAgainstBaseURL: false))
        components.scheme = "https"
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
        components.scheme = AppConstants.urlScheme
        components.queryItems = [URLQueryItem(name: "command", value: MenuCommand.compress.rawValue)] + urls.map { URLQueryItem(name: "url", value: $0.absoluteString) }
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
        components.queryItems = [
            URLQueryItem(name: "command", value: MenuCommand.createAlias.rawValue),
            URLQueryItem(name: "url", value: "https://example.com/file")
        ]
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
        components.queryItems = [
            URLQueryItem(name: "command", value: MenuCommand.createAlias.rawValue),
            URLQueryItem(name: "command", value: MenuCommand.moveToNewFolder.rawValue),
            URLQueryItem(name: "url", value: urls[0].absoluteString)
        ]
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
    }

    func testExistingQueuePayloadStillDecodesWithoutAdditionalFields() throws {
        let command = PendingCommand.compress(urls: urls)
        let encoded = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(PendingCommand.self, from: encoded), command)
    }

    func testHashTaskRequiresVisibleWindow() {
        XCTAssertTrue(FinderActionRoute.copyHash(algorithm: .sha256, urls: urls).requiresVisibleWindow)
    }

    func testGeneratedURLsGiveDistinctRequestsDistinctIdentities() throws {
        let route = FinderActionRoute.batchFileAction(command: .createAlias, urls: urls)
        let first = try XCTUnwrap(route.url)
        let second = try XCTUnwrap(route.url)
        XCTAssertNotEqual(first, second)
        let components = try XCTUnwrap(URLComponents(url: first, resolvingAgainstBaseURL: false))
        let request = try XCTUnwrap(components.queryItems?.first { $0.name == "requestID" }?.value)
        XCTAssertNotNil(UUID(uuidString: request))
        XCTAssertEqual(FinderActionRoute(url: first), route)
        XCTAssertEqual(FinderActionRoute(url: first), route)
        XCTAssertEqual(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "requestID" }?.value, request)
    }

    func testRequestIdentityIsOptionalForLegacyURLsButMustBeValidAndUnique() throws {
        let route = FinderActionRoute.toggleHiddenFiles
        let generated = try XCTUnwrap(route.url)
        XCTAssertEqual(FinderActionRoute(url: generated), route)
        var components = try XCTUnwrap(URLComponents(url: generated, resolvingAgainstBaseURL: false))
        components.queryItems = nil
        XCTAssertEqual(FinderActionRoute(url: try XCTUnwrap(components.url)), route)
        components.queryItems = [URLQueryItem(name: "requestID", value: "invalid")]
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
        components.queryItems = [URLQueryItem(name: "requestID", value: nil)]
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
        components.queryItems = [URLQueryItem(name: "requestID", value: UUID().uuidString), URLQueryItem(name: "requestID", value: UUID().uuidString)]
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
        components.queryItems = [URLQueryItem(name: "requestID", value: UUID().uuidString), URLQueryItem(name: "extra", value: "unexpected")]
        XCTAssertNil(FinderActionRoute(url: try XCTUnwrap(components.url)))
    }
}
