import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func healthRouteReturnsStableJSON() throws {
    let response = ServerRouter().route(
        ServerHTTPRequest(method: .get, path: "/health?verbose=true")
    )

    #expect(response.statusCode == 200)
    #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
    #expect(response.headers["Cache-Control"] == "no-store")
    #expect(response.bodyText == #"{"service":"mbd","status":"ok"}"#)
    #expect(try MetaBrainJSON.decoder().decode(ServerHealthPayload.self, from: response.body) == ServerHealthPayload())
}

@Test func routerCanBeBuiltFromServeConfiguration() throws {
    let configuration = try ServerServeConfiguration()
    let response = ServerRouter(configuration: configuration).route(
        ServerHTTPRequest(method: .get, path: "/health")
    )

    #expect(response.statusCode == 200)
}

@Test func healthRouteRejectsUnsupportedMethods() throws {
    let response = ServerRouter().route(
        ServerHTTPRequest(method: .post, path: "/health")
    )

    #expect(response.statusCode == 405)
    #expect(response.headers["Allow"] == "GET")
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body)
            == ServerErrorPayload(
                error: "method_not_allowed",
                message: "POST is not supported for /health."
            )
    )
}

@Test func routerReturnsNotFoundJSONForUnknownRoutes() throws {
    let response = ServerRouter().route(
        ServerHTTPRequest(method: .get, path: "/v1/run")
    )

    #expect(response.statusCode == 404)
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body)
            == ServerErrorPayload(
                error: "not_found",
                message: "No server route exists for GET /v1/run."
            )
    )
}

@Test func sharedRouterHandlesConcurrentLightweightRoutes() async throws {
    let router = ServerRouter()
    let requests = (0..<64).map { index in
        index.isMultiple(of: 2)
            ? ServerHTTPRequest(method: .get, path: "/health?index=\(index)")
            : ServerHTTPRequest(method: .post, path: "/v1/put", body: Data("{".utf8))
    }

    let responses = await withTaskGroup(of: (Int, ServerHTTPResponse).self) { group in
        for (index, request) in requests.enumerated() {
            group.addTask {
                (index, router.route(request))
            }
        }

        var responses = Array<ServerHTTPResponse?>(repeating: nil, count: requests.count)
        for await (index, response) in group {
            responses[index] = response
        }
        return responses.map { $0! }
    }

    for (index, response) in responses.enumerated() {
        #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(response.headers["Cache-Control"] == "no-store")
        if index.isMultiple(of: 2) {
            #expect(response.statusCode == 200)
            #expect(response.bodyText == #"{"service":"mbd","status":"ok"}"#)
        } else {
            #expect(response.statusCode == 404)
            #expect(response.bodyText == #"{"error":"not_found","message":"No server route exists for POST /v1/put."}"#)
        }
    }
}
