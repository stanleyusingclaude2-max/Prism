import Foundation
import XCTest
@testable import PlayitTransferCore

final class TransferHTTPTests: XCTestCase {
    func testGeneratedSessionTokenIsEightLowercaseHexDigits() {
        for _ in 0..<100 {
            let token = TransferFilePolicy.makeSessionToken()
            XCTAssertEqual(token.utf8.count, 8)
            XCTAssertTrue(token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
    }

    func testShortSessionTokenMustMatchExactly() throws {
        let token = "a1b2c3d4"
        XCTAssertEqual(try TransferFilePolicy.uploadFilename(target: "/a1b2c3d4/upload?name=clip.mp4", token: token), "clip.mp4")
        for path in ["/a1b2c3d5/upload", "/A1B2C3D4/upload", "/a1b2c3d4extra/upload", "/a1b2c3d/upload"] {
            XCTAssertNil(try TransferFilePolicy.uploadFilename(target: path + "?name=clip.mp4", token: token))
        }
    }

    func testBrowserEntryWithOrWithoutSessionSlashRedirectsToWorkingPage() throws {
        let token = "a1b2c3d4"
        let baseURL = try XCTUnwrap(URL(string: "http://192.168.1.8:8080/"))
        for target in ["/", "/a1b2c3d4"] {
            guard case .redirect(let location) = TransferFilePolicy.webRoute(target: target, token: token) else {
                return XCTFail("Browser entry must redirect: \(target)")
            }
            let destination = try XCTUnwrap(URL(string: location, relativeTo: baseURL)?.absoluteURL)
            XCTAssertEqual(destination.absoluteString, "http://192.168.1.8:8080/a1b2c3d4/")
            let requestPath = try XCTUnwrap(URLComponents(url: destination, resolvingAgainstBaseURL: false)?.percentEncodedPath)
            XCTAssertEqual(TransferFilePolicy.webRoute(target: requestPath, token: token), .page)
            let statusURL = destination.appendingPathComponent("status")
            XCTAssertEqual(TransferFilePolicy.webRoute(target: statusURL.path, token: token), .status)
        }
    }

    func testBrowserRoutesKeepSessionAndFontPathsExact() {
        let token = "a1b2c3d4"
        XCTAssertEqual(TransferFilePolicy.webRoute(target: "/a1b2c3d4/fonts/D-DIN.otf", token: token), .font("D-DIN"))
        XCTAssertEqual(TransferFilePolicy.webRoute(target: "/a1b2c3d4/fonts/D-DIN-Bold.otf", token: token), .font("D-DIN-Bold"))
        for target in ["/wrong/", "/A1B2C3D4/", "/a1b2c3d4%2f", "/status", "/fonts/D-DIN.otf",
                       "/a1b2c3d4/fonts/other.otf", "/a1b2c3d4/fonts/../D-DIN.otf", "//evil.test/", "http://evil.test/"] {
            XCTAssertEqual(TransferFilePolicy.webRoute(target: target, token: token), .notFound, target)
        }
    }

    func testRootBrowserEntryDoesNotEnableTokenlessUploads() throws {
        let token = "a1b2c3d4"
        for target in ["/upload?name=clip.mp4", "/upload/?name=clip.mp4", "/wrong/upload?name=clip.mp4"] {
            XCTAssertNil(try TransferFilePolicy.uploadFilename(target: target, token: token), target)
        }
        XCTAssertEqual(try TransferFilePolicy.uploadFilename(target: "/a1b2c3d4/upload?name=clip.mp4", token: token), "clip.mp4")
    }

    func testInitialUnavailableNetworkSnapshotsDoNotCancelStartup() {
        var network = TransferNetworkContinuity()
        XCTAssertFalse(network.shouldStop(isSatisfied: false, hasOriginalAddress: false))
        XCTAssertFalse(network.shouldStop(isSatisfied: false, hasOriginalAddress: true))
        XCTAssertFalse(network.shouldStop(isSatisfied: true, hasOriginalAddress: true))
        XCTAssertFalse(network.shouldStop(isSatisfied: true, hasOriginalAddress: true))
        XCTAssertTrue(network.shouldStop(isSatisfied: false, hasOriginalAddress: false))
    }

    func testChangedWiFiAddressStopsReceiverBeforeOrAfterStartup() {
        var startingNetwork = TransferNetworkContinuity()
        XCTAssertTrue(startingNetwork.shouldStop(isSatisfied: true, hasOriginalAddress: false))
        var establishedNetwork = TransferNetworkContinuity()
        XCTAssertFalse(establishedNetwork.shouldStop(isSatisfied: true, hasOriginalAddress: true))
        XCTAssertTrue(establishedNetwork.shouldStop(isSatisfied: true, hasOriginalAddress: false))
    }

    func testRequestCanBeSplitAtEveryByteBoundary() throws {
        let raw = Data("POST /session/upload?name=clip.mp4 HTTP/1.1\r\nHost: 192.168.1.8:8080\r\nContent-Length: 5\r\n\r\n".utf8)
        for end in 0..<raw.count {
            XCTAssertNil(try TransferRequestHead.parse(raw.prefix(end)), "Boundary \(end)")
        }
        let result = try XCTUnwrap(TransferRequestHead.parse(raw))
        XCTAssertEqual(result.head.method, "POST")
        XCTAssertEqual(result.head.contentLength, 5)
        XCTAssertEqual(result.consumed, raw.count)
    }

    func testBodyBytesAreNotPartOfHeaderLimitOrConsumedCount() throws {
        let head = Data("POST /token/upload?name=clip.mp4 HTTP/1.1\r\nHost: 1.2.3.4:8080\r\nContent-Length: 100000\r\n\r\n".utf8)
        let result = try XCTUnwrap(TransferRequestHead.parse(head + Data(repeating: 0, count: 65_536)))
        XCTAssertEqual(result.consumed, head.count)
        XCTAssertEqual(result.head.contentLength, 100_000)
    }

    func testOversizedUnterminatedHeaderIsRejected() {
        XCTAssertThrowsError(try TransferRequestHead.parse(Data(repeating: 65, count: 16_385))) {
            XCTAssertEqual($0 as? TransferHTTPError, .headersTooLarge)
        }
    }

    func testDuplicateHeadersIncludingDifferentCaseAreRejected() {
        for fields in ["Content-Length: 1\r\ncontent-length: 2", "Host: other:80"] {
            let raw = Data("POST /x HTTP/1.1\r\nHost: 1.2.3.4:8080\r\n\(fields)\r\n\r\n".utf8)
            XCTAssertThrowsError(try TransferRequestHead.parse(raw))
        }
    }

    func testAmbiguousLengthsAndChunkedBodiesAreRejected() {
        for length in ["-1", "+1", "1, 1", "1 1", "9223372036854775808", ""] {
            let raw = Data("POST /x HTTP/1.1\r\nHost: 1.2.3.4:8080\r\nContent-Length: \(length)\r\n\r\n".utf8)
            XCTAssertThrowsError(try TransferRequestHead.parse(raw), "Length \(length)")
        }
        XCTAssertThrowsError(try TransferRequestHead.parse(Data("POST /x HTTP/1.1\r\nHost: 1.2.3.4:8080\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
    }

    func testHostAbsoluteTargetsAndFoldedFieldsAreRejected() {
        for raw in [
            "GET / HTTP/1.1\r\n\r\n",
            "GET http://evil.test/ HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET //evil.test/ HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: x\r\n continued\r\n\r\n",
            "GET / HTTP/1.0\r\nHost: x\r\n\r\n"
        ] { XCTAssertThrowsError(try TransferRequestHead.parse(Data(raw.utf8))) }
    }

    func testUnicodeAndUppercaseExtensionAreAccepted() throws {
        XCTAssertEqual(try TransferFilePolicy.validatedFilename("海边冲浪_01.MP4"), "海边冲浪_01.MP4")
        XCTAssertEqual(try TransferFilePolicy.validatedFilename("猫的照片.heic"), "猫的照片.heic")
    }

    func testPathTraversalAndInvalidFileTypesAreRejected() {
        let bad = ["../escape.mp4", "/escape.mp4", "a/b.mp4", "a\\b.mp4", "a:b.mp4", ".hidden.mp4", ".", "..", "clip.mp4\0", "clip.mp4 ", " clip.mp4", "a\n.mp4", "x.exe", "x.html", String(repeating: "a", count: 241) + ".mp4"]
        for name in bad { XCTAssertThrowsError(try TransferFilePolicy.validatedFilename(name), name) }
    }

    func testSessionAndEncodedFilenameValidation() throws {
        XCTAssertEqual(try TransferFilePolicy.uploadFilename(target: "/token/upload?name=%E6%B5%B7%E8%BE%B9.mp4", token: "token"), "海边.mp4")
        XCTAssertNil(try TransferFilePolicy.uploadFilename(target: "/wrong/upload?name=clip.mp4", token: "token"))
        XCTAssertNil(try TransferFilePolicy.uploadFilename(target: "/token%2fupload?name=clip.mp4", token: "token"))
        XCTAssertThrowsError(try TransferFilePolicy.uploadFilename(target: "/token/upload?name=..%2Fescape.mp4", token: "token"))
        XCTAssertThrowsError(try TransferFilePolicy.uploadFilename(target: "/token/upload?name=one.mp4&name=two.mp4", token: "token"))
        XCTAssertThrowsError(try TransferFilePolicy.uploadFilename(target: "/token/upload", token: "token"))
    }

    func testOriginMustMatchPublishedAuthorityExactly() {
        XCTAssertTrue(TransferFilePolicy.isSameOrigin("http://192.168.1.8:8080", authority: "192.168.1.8:8080"))
        for origin: String? in [nil, "null", "https://192.168.1.8:8080", "http://evil.test", "http://192.168.1.8:8081", "http://192.168.1.8:8080.evil.test"] {
            XCTAssertFalse(TransferFilePolicy.isSameOrigin(origin, authority: "192.168.1.8:8080"))
        }
    }
}
