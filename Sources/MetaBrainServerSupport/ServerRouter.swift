import Foundation

public struct ServerRouter: Sendable {
    public init() {}

    public init(configuration: ServerServeConfiguration) {
        self.init()
    }

    public func route(_ request: ServerHTTPRequest) -> ServerHTTPResponse {
        switch (request.method, normalizedPath(request.path)) {
        case (.get, "/health"):
            return jsonResponse(statusCode: 200, payload: ServerHealthPayload())
        case (_, "/health"):
            return jsonResponse(
                statusCode: 405,
                payload: ServerErrorPayload(
                    error: "method_not_allowed",
                    message: "\(request.method.rawValue) is not supported for /health."
                ),
                additionalHeaders: ["Allow": "GET"]
            )
        default:
            return jsonResponse(
                statusCode: 404,
                payload: ServerErrorPayload(
                    error: "not_found",
                    message: "No server route exists for \(request.method.rawValue) \(request.path)."
                )
            )
        }
    }

    private func normalizedPath(_ path: String) -> String {
        guard let questionMark = path.firstIndex(of: "?") else {
            return path
        }
        return String(path[..<questionMark])
    }

    private func jsonResponse<T: Encodable>(
        statusCode: Int,
        payload: T,
        additionalHeaders: [String: String] = [:]
    ) -> ServerHTTPResponse {
        var headers = [
            "Cache-Control": "no-store",
            "Content-Type": "application/json; charset=utf-8",
        ]
        for (name, value) in additionalHeaders {
            headers[name] = value
        }

        return ServerHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: try! MetaBrainJSON.encoder().encode(payload)
        )
    }
}
