import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func httpCodecParsesRequestsAndSerializesResponses() throws {
    let codec = ServerHTTPCodec()
    let body = #"{"ping":true}"#
    let request = try codec.parseRequest(
        Data(
            """
            POST /v1/put?trace=true HTTP/1.1\r
            Host: 127.0.0.1\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            \r
            \(body)
            """.utf8
        )
    )

    #expect(request.method == .post)
    #expect(request.path == "/v1/put?trace=true")
    #expect(request.headers["Host"] == "127.0.0.1")
    #expect(request.headers["Content-Length"] == "\(body.utf8.count)")
    #expect(request.body == Data(body.utf8))

    let response = codec.serializeResponse(
        ServerHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"ok":true}"#.utf8)
        )
    )
    let responseText = String(decoding: response, as: UTF8.self)

    #expect(responseText.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(responseText.contains("Connection: close\r\n"))
    #expect(responseText.contains("Content-Length: 11\r\n"))
    #expect(responseText.hasSuffix(#"{"ok":true}"#))
}

@Test func httpCodecReportsStableParseErrors() throws {
    let codec = ServerHTTPCodec()

    #expect(try codec.expectedRequestByteCount(Data("GET /health HTTP/1.1\r\n".utf8)) == nil)
    #expect(throws: ServerHTTPCodecError.missingHeaderTerminator) {
        _ = try codec.parseRequest(Data("GET /health HTTP/1.1\r\n".utf8))
    }
    #expect(throws: ServerHTTPCodecError.malformedRequestLine) {
        _ = try codec.parseRequest(Data("GET /health\r\n\r\n".utf8))
    }
    #expect(throws: ServerHTTPCodecError.unsupportedMethod("TRACE")) {
        _ = try codec.parseRequest(Data("TRACE /health HTTP/1.1\r\n\r\n".utf8))
    }
    #expect(throws: ServerHTTPCodecError.malformedHeader("Broken")) {
        _ = try codec.parseRequest(Data("GET /health HTTP/1.1\r\nBroken\r\n\r\n".utf8))
    }
    #expect(throws: ServerHTTPCodecError.malformedHeader(": missing-name")) {
        _ = try codec.parseRequest(Data("GET /health HTTP/1.1\r\n: missing-name\r\n\r\n".utf8))
    }
    #expect(throws: ServerHTTPCodecError.invalidContentLength("nope")) {
        _ = try codec.parseRequest(Data("POST /v1/put HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8))
    }
    #expect(throws: ServerHTTPCodecError.incompleteBody(expected: 4, actual: 2)) {
        _ = try codec.parseRequest(Data("POST /v1/put HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8))
    }
    #expect(throws: ServerHTTPCodecError.invalidUTF8) {
        _ = try codec.parseRequest(Data([0x47, 0x45, 0x54, 0x20, 0xff, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31, 0x0d, 0x0a, 0x0d, 0x0a]))
    }
    #expect(throws: ServerHTTPCodecError.invalidUTF8) {
        _ = try codec.expectedRequestByteCount(Data([0x47, 0x45, 0x54, 0x20, 0xff, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31, 0x0d, 0x0a, 0x0d, 0x0a]))
    }
    #expect(throws: ServerHTTPCodecError.malformedHeader("Broken")) {
        _ = try codec.expectedRequestByteCount(Data("GET /health HTTP/1.1\r\nBroken\r\n\r\n".utf8))
    }
}

@Test func httpCodecComputesExpectedRequestByteCounts() throws {
    let codec = ServerHTTPCodec()
    let request = Data("POST /v1/put HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)

    #expect(try codec.expectedRequestByteCount(request) == request.count)
    #expect(try codec.expectedRequestByteCount(Data("GET /health HTTP/1.1\r\n\r\n".utf8)) == 24)
    #expect(try codec.expectedRequestBodyByteCount(Data("GET /health HTTP/1.1\r\n".utf8)) == nil)
    #expect(throws: ServerHTTPCodecError.invalidContentLength("\(Int.max)")) {
        _ = try codec.expectedRequestByteCount(
            Data("POST /v1/put HTTP/1.1\r\nContent-Length: \(Int.max)\r\n\r\n".utf8)
        )
    }
}

@Test func httpCodecSerializesKnownAndFallbackReasonPhrases() {
    let codec = ServerHTTPCodec()

    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 400)), as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 401)), as: UTF8.self).hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 403)), as: UTF8.self).hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 404)), as: UTF8.self).hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 405)), as: UTF8.self).hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 408)), as: UTF8.self).hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 413)), as: UTF8.self).hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 429)), as: UTF8.self).hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 500)), as: UTF8.self).hasPrefix("HTTP/1.1 500 Internal Server Error\r\n"))
    #expect(String(decoding: codec.serializeResponse(ServerHTTPResponse(statusCode: 202)), as: UTF8.self).hasPrefix("HTTP/1.1 202 HTTP Response\r\n"))
}

@Test func httpCodecErrorDescriptionsAreStable() {
    #expect(ServerHTTPCodecError.invalidUTF8.description == "HTTP message must be valid UTF-8")
    #expect(ServerHTTPCodecError.missingHeaderTerminator.description == "HTTP headers must end with CRLF CRLF")
    #expect(ServerHTTPCodecError.malformedRequestLine.description == "HTTP request line must be METHOD PATH HTTP/1.1")
    #expect(ServerHTTPCodecError.unsupportedMethod("TRACE").description == "unsupported HTTP method: TRACE")
    #expect(ServerHTTPCodecError.malformedHeader("Broken").description == "malformed HTTP header: Broken")
    #expect(ServerHTTPCodecError.invalidContentLength("abc").description == "invalid Content-Length header: abc")
    #expect(ServerHTTPCodecError.incompleteBody(expected: 3, actual: 2).description == "HTTP body is incomplete: expected 3 bytes, got 2")
}
