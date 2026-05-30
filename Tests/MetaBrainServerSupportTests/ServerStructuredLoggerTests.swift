import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func logLevelValidatesAndOrdersAcceptedValues() throws {
    #expect(try ServerLogLevel(validating: " DEBUG ") == .debug)
    #expect(try ServerLogLevel(validating: "info") == .info)
    #expect(try ServerLogLevel(validating: "Warn") == .warn)
    #expect(try ServerLogLevel(validating: "ERROR") == .error)
    #expect(ServerLogLevel.debug < .info)
    #expect(ServerLogLevel.warn < .error)
    #expect(ServerLogLevel.allCases == [.debug, .info, .warn, .error])
}

@Test func structuredLoggerEmitsJSONLinesAtOrAboveMinimumLevel() throws {
    let sink = CapturedServerLogLines()
    let logger = ServerStructuredLogger(minimumLevel: .info) { line in
        sink.append(line)
    }
    let request = ServerHTTPRequest(method: .get, path: "/health")
    let response = ServerHTTPResponse(statusCode: 200)

    logger.log(ServerLogRecord(level: .debug, event: "ignored"))
    logger.requestStarted(request)
    logger.requestCompleted(request, response: response)

    let lines = sink.lines
    #expect(lines.count == 2)
    #expect(lines[0] == #"{"event":"request_started","level":"info","method":"GET","path":"/health"}"#)
    #expect(lines[1] == #"{"event":"request_completed","level":"info","method":"GET","path":"/health","statusCode":200}"#)
    #expect(
        try MetaBrainJSON.decoder().decode(ServerLogRecord.self, from: Data(lines[1].utf8))
            == ServerLogRecord(
                level: .info,
                event: "request_completed",
                method: "GET",
                path: "/health",
                statusCode: 200
            )
    )
}

@Test func structuredLoggerCanLogFailuresAndStayDisabledByDefault() {
    let disabledSink = CapturedServerLogLines()
    ServerStructuredLogger.disabled.log(ServerLogRecord(level: .error, event: "ignored"))
    #expect(disabledSink.lines.isEmpty)

    let sink = CapturedServerLogLines()
    let logger = ServerStructuredLogger(minimumLevel: .warn) { line in
        sink.append(line)
    }
    let response = ServerHTTPResponse(
        statusCode: 400,
        body: Data(#"{"error":"bad_request","message":"Malformed HTTP request."}"#.utf8)
    )

    logger.requestFailed(nil, response: response, error: ServerHTTPCodecError.malformedRequestLine)

    #expect(sink.lines == [
        #"{"error":"HTTP request line must be METHOD PATH HTTP/1.1","event":"request_error","level":"warn","message":"{\"error\":\"bad_request\",\"message\":\"Malformed HTTP request.\"}","statusCode":400}"#,
    ])
}

private final class CapturedServerLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLines: [String] = []

    var lines: [String] {
        lock.withLock { storedLines }
    }

    func append(_ line: String) {
        lock.withLock {
            storedLines.append(line)
        }
    }
}
