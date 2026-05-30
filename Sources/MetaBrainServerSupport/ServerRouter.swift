import Foundation
import MetaBrainCore

private enum ServerStorePathHeaderError: Error, CustomStringConvertible {
    case invalidStorePathHeader

    var description: String {
        switch self {
        case .invalidStorePathHeader:
            return "\(MetaBrainStoreRegistry.storePathHeader) must be a base64-encoded UTF-8 store path"
        }
    }
}

public struct ServerRouter: Sendable {
    private let storeServer: MetaBrainStoreServer?
    private let storeRegistry: MetaBrainStoreRegistry?
    private let defaultStorePath: String

    public init(storeServer: MetaBrainStoreServer? = nil) {
        self.storeServer = storeServer
        self.storeRegistry = nil
        self.defaultStorePath = ServerServeConfiguration.defaultStorePath
    }

    public init(
        storeRegistry: MetaBrainStoreRegistry,
        defaultStorePath: String = ServerServeConfiguration.defaultStorePath
    ) {
        self.storeServer = nil
        self.storeRegistry = storeRegistry
        self.defaultStorePath = defaultStorePath
    }

    public init(configuration: ServerServeConfiguration) {
        self.init(
            storeRegistry: MetaBrainStoreRegistry(
                idleTimeoutSeconds: configuration.storeIdleTimeoutSeconds
            ),
            defaultStorePath: configuration.storePath
        )
    }

    public func route(_ request: ServerHTTPRequest) async -> ServerHTTPResponse {
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
            return await routeStoreOperation(request) { storeServer in
                await storeServer.initialize()
            }
        case (_, "/v1/init"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/put"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerPutRequest.self, from: request)
                return try await storeServer.put(decoded)
            }
        case (_, "/v1/put"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/patch"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerPatchRequest.self, from: request)
                return try await storeServer.patch(decoded)
            }
        case (_, "/v1/patch"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/move"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerMoveRequest.self, from: request)
                return try await storeServer.move(decoded)
            }
        case (_, "/v1/move"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/get"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerGetRequest.self, from: request)
                return try await storeServer.get(decoded)
            }
        case (_, "/v1/get"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/list"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerListRequest.self, from: request)
                return try await storeServer.list(decoded)
            }
        case (_, "/v1/list"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/tree"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerTreeRequest.self, from: request)
                return try await storeServer.tree(decoded)
            }
        case (_, "/v1/tree"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/search"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerSearchRequest.self, from: request)
                return try await storeServer.search(decoded)
            }
        case (_, "/v1/search"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/dump"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerDumpRequest.self, from: request)
                return try await storeServer.dump(decoded)
            }
        case (_, "/v1/dump"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/versions"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerVersionsRequest.self, from: request)
                return try await storeServer.versions(decoded)
            }
        case (_, "/v1/versions"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/prune"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerPruneRequest.self, from: request)
                return try await storeServer.prune(decoded)
            }
        case (_, "/v1/prune"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/delete"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerDeleteRequest.self, from: request)
                return try await storeServer.delete(decoded)
            }
        case (_, "/v1/delete"):
            return methodNotAllowed(request, allowedMethod: "POST")
        case (.post, "/v1/remove-version"):
            return await routeStoreOperation(request) { storeServer in
                let decoded = try decode(ServerRemoveVersionRequest.self, from: request)
                return try await storeServer.removeVersion(decoded)
            }
        case (_, "/v1/remove-version"):
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

    public func routeBlocking(_ request: ServerHTTPRequest) -> ServerHTTPResponse {
        try! ServerAsyncBridge.run {
            await route(request)
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
        _ request: ServerHTTPRequest,
        _ operation: @escaping @Sendable (MetaBrainStoreServer) async throws -> T
    ) async -> ServerHTTPResponse {
        if let storeServer {
            do {
                let payload = try await operation(storeServer)
                return jsonResponse(statusCode: 200, payload: payload)
            } catch {
                return errorResponse(for: error)
            }
        }

        guard let storeRegistry else {
            return jsonResponse(
                statusCode: 500,
                payload: ServerErrorPayload(
                    error: "server_not_configured",
                    message: "The daemon store is not available."
                )
            )
        }

        do {
            let payload = try await storeRegistry.withStore(
                at: try storePath(for: request),
                operation: operation
            )
            return jsonResponse(statusCode: 200, payload: payload)
        } catch {
            return errorResponse(for: error)
        }
    }

    private func storePath(for request: ServerHTTPRequest) throws -> String {
        guard let value = request.headers.first(where: {
            $0.key.lowercased() == MetaBrainStoreRegistry.storePathHeader.lowercased()
        })?.value else {
            return defaultStorePath
        }

        guard let storePath = MetaBrainStoreRegistry.storePath(fromHeaderValue: value) else {
            throw ServerStorePathHeaderError.invalidStorePathHeader
        }
        return storePath
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

        if let patchError = error as? MetaBrainPatchError {
            return patchErrorResponse(patchError)
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
        case .pathAlreadyExists, .currentVersionCannotBeRemoved:
            return jsonResponse(
                statusCode: 409,
                payload: ServerErrorPayload(
                    error: "conflict",
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

    private func patchErrorResponse(_ error: MetaBrainPatchError) -> ServerHTTPResponse {
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
                statusCode: 400,
                payload: ServerErrorPayload(
                    error: "invalid_patch",
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
