import Foundation
import MetaBrainCore

public struct ServerRouter: Sendable {
    private let storeServer: MetaBrainStoreServer?

    public init(storeServer: MetaBrainStoreServer? = nil) {
        self.storeServer = storeServer
    }

    public init(configuration: ServerServeConfiguration) {
        self.init()
    }

    public func route(_ request: ServerHTTPRequest) -> ServerHTTPResponse {
        switch (request.method, normalizedPath(request.path)) {
        case (.get, "/health"):
            return jsonResponse(statusCode: 200, payload: ServerHealthPayload())
        case (_, "/health"):
            return methodNotAllowed(request, allowedMethod: "GET")
        case (.get, "/v1/version"):
            return routeVersion()
        case (_, "/v1/version"):
            return methodNotAllowed(request, allowedMethod: "GET")
        case (.post, "/v1/init"):
            return routeStoreOperation { storeServer in
                await storeServer.initialize()
            }
        case (_, "/v1/init"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/put"):
            return routeStoreOperation { storeServer in
                let decoded = try decode(ServerPutRequest.self, from: request)
                return try await storeServer.put(decoded)
            }
        case (_, "/v1/put"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/get"):
            return routeStoreOperation { storeServer in
                let decoded = try decode(ServerGetRequest.self, from: request)
                return try await storeServer.get(decoded)
            }
        case (_, "/v1/get"):
            return methodNotAllowed(request, allowedMethod: "POST")
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

    private func routeVersion() -> ServerHTTPResponse {
        jsonResponse(
            statusCode: 200,
            payload: VersionOutput(
                currentTag: MetaBrainVersion.currentSoftwareTag(),
                releaseCheck: nil
            )
        )
    }

    private func routeStoreOperation<T: Encodable & Sendable>(
        _ operation: @escaping @Sendable (MetaBrainStoreServer) async throws -> T
    ) -> ServerHTTPResponse {
        guard let storeServer else {
            return jsonResponse(
                statusCode: 500,
                payload: ServerErrorPayload(
                    error: "server_not_configured",
                    message: "The daemon store is not available."
                )
            )
        }

        do {
            let payload = try ServerAsyncBridge.run {
                try await operation(storeServer)
            }
            return jsonResponse(statusCode: 200, payload: payload)
        } catch {
            return errorResponse(for: error)
        }
    }

    private func methodNotAllowed(_ request: ServerHTTPRequest, allowedMethod: String) -> ServerHTTPResponse {
        jsonResponse(
            statusCode: 405,
            payload: ServerErrorPayload(
                error: "method_not_allowed",
                message: "\(request.method.rawValue) is not supported for \(normalizedPath(request.path))."
            ),
            additionalHeaders: ["Allow": allowedMethod]
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: ServerHTTPRequest) throws -> T {
        let body = request.body.isEmpty ? Data("{}".utf8) : request.body
        return try MetaBrainJSON.decoder().decode(type, from: body)
    }

    private func errorResponse(for error: Error) -> ServerHTTPResponse {
        if let storeError = error as? MetaBrainStoreError {
            return storeErrorResponse(storeError)
        }

        return jsonResponse(
            statusCode: 400,
            payload: ServerErrorPayload(
                error: "invalid_request",
                message: String(describing: error)
            )
        )
    }

    private func storeErrorResponse(_ error: MetaBrainStoreError) -> ServerHTTPResponse {
        switch error {
        case .documentNotFound:
            return jsonResponse(
                statusCode: 404,
                payload: ServerErrorPayload(
                    error: "document_not_found",
                    message: error.description
                )
            )
        default:
            return jsonResponse(
                statusCode: 500,
                payload: ServerErrorPayload(
                    error: "store_error",
                    message: error.description
                )
            )
        }
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
