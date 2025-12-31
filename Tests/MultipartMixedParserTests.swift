import XCTest
@testable import MacCalendarSync

final class MultipartMixedParserTests: XCTestCase {

    func testSimpleMultipartParsing() {
        let boundary = "batch_boundary"
        let multipartData = """
        --batch_boundary
        Content-Type: application/json
        Content-ID: <item0>

        {"id": "123", "name": "test"}
        --batch_boundary
        Content-Type: application/json
        Content-ID: <item1>

        {"id": "456", "name": "test2"}
        --batch_boundary--
        """.data(using: .utf8)!

        let parts = MultipartMixedParser.parse(data: multipartData, boundary: boundary)

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].header("Content-Type"), "application/json")
        XCTAssertEqual(parts[0].header("Content-ID"), "<item0>")

        let body0 = String(data: parts[0].body, encoding: .utf8)
        XCTAssertTrue(body0?.contains("\"id\": \"123\"") ?? false)
    }

    func testNestedHTTPResponse() {
        let boundary = "batch_xyz"
        let multipartData = """
        --batch_xyz
        Content-Type: application/http
        Content-ID: <response-item0>

        HTTP/1.1 200 OK
        Content-Type: application/json; charset=UTF-8
        ETag: "12345"

        {"kind": "calendar#event", "id": "abc123"}
        --batch_xyz--
        """.data(using: .utf8)!

        let parts = MultipartMixedParser.parse(data: multipartData, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].header("Content-Type"), "application/http")
        XCTAssertEqual(parts[0].header("Content-ID"), "<response-item0>")

        // Body should be just the JSON, not the HTTP headers
        let body = String(data: parts[0].body, encoding: .utf8)
        XCTAssertTrue(body?.contains("\"kind\": \"calendar#event\"") ?? false)
        XCTAssertFalse(body?.contains("HTTP/1.1") ?? true)
        XCTAssertFalse(body?.contains("ETag") ?? true)
    }

    func testMultipleNestedHTTPResponses() {
        let boundary = "batch_boundary_123"
        let multipartData = """
        --batch_boundary_123
        Content-Type: application/http
        Content-ID: <response-item0>

        HTTP/1.1 200 OK
        Content-Type: application/json

        {"id": "event1"}
        --batch_boundary_123
        Content-Type: application/http
        Content-ID: <response-item1>

        HTTP/1.1 201 Created
        Content-Type: application/json

        {"id": "event2"}
        --batch_boundary_123
        Content-Type: application/http
        Content-ID: <response-item2>

        HTTP/1.1 404 Not Found
        Content-Type: application/json

        {"error": "not found"}
        --batch_boundary_123--
        """.data(using: .utf8)!

        let parts = MultipartMixedParser.parse(data: multipartData, boundary: boundary)

        XCTAssertEqual(parts.count, 3)

        // First part
        let body0 = String(data: parts[0].body, encoding: .utf8)
        XCTAssertTrue(body0?.contains("\"id\": \"event1\"") ?? false)
        XCTAssertFalse(body0?.contains("HTTP/1.1") ?? true)

        // Second part
        let body1 = String(data: parts[1].body, encoding: .utf8)
        XCTAssertTrue(body1?.contains("\"id\": \"event2\"") ?? false)

        // Third part
        let body2 = String(data: parts[2].body, encoding: .utf8)
        XCTAssertTrue(body2?.contains("\"error\"") ?? false)
    }

    func testCRLFLineEndings() {
        let boundary = "batch_crlf"
        let multipartData = "--batch_crlf\r\nContent-Type: application/json\r\nContent-ID: <item0>\r\n\r\n{\"test\": true}\r\n--batch_crlf--\r\n".data(using: .utf8)!

        let parts = MultipartMixedParser.parse(data: multipartData, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].header("Content-Type"), "application/json")

        let body = String(data: parts[0].body, encoding: .utf8)
        XCTAssertTrue(body?.contains("\"test\": true") ?? false)
    }

    func testCaseInsensitiveHeaders() {
        let boundary = "test"
        let multipartData = """
        --test
        content-type: application/json
        CONTENT-ID: <item0>

        {}
        --test--
        """.data(using: .utf8)!

        let parts = MultipartMixedParser.parse(data: multipartData, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].header("Content-Type"), "application/json")
        XCTAssertEqual(parts[0].header("content-type"), "application/json")
        XCTAssertEqual(parts[0].header("CONTENT-TYPE"), "application/json")
    }

    func testEmptyParts() {
        let boundary = "test"
        let multipartData = """
        --test

        --test
        Content-Type: application/json

        {"valid": true}
        --test--
        """.data(using: .utf8)!

        let parts = MultipartMixedParser.parse(data: multipartData, boundary: boundary)

        // Should skip empty parts
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].header("Content-Type"), "application/json")
    }
}
