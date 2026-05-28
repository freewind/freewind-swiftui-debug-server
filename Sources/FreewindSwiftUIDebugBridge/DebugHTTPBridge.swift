import Foundation
import Network

private struct HTTPRequest {
    let method: String
    let path: String
    let url: URL?
    let body: Data
}

final class DebugHTTPBridge: @unchecked Sendable {
    private let port: UInt16
    private let getMeta: @Sendable () async -> DebugMetaResponse
    private let getHelp: @Sendable () async -> DebugHelpResponse
    private let getActionCatalog: @Sendable (DebugActionCatalogQuery) async -> DebugActionCatalogResponse
    private let getLogs: @Sendable (DebugLogsQuery) async -> DebugLogsResponse
    private let clearLogs: @Sendable () async -> DebugLogsClearResponse
    private let getState: @Sendable (DebugStateQuery) async -> DebugStateResponse
    private let getSnapshot: @Sendable (DebugSnapshotQuery) async -> DebugSnapshotResponse
    private let performAction: @Sendable (DebugActionRequest) async -> DebugActionResponse
    private var listener: NWListener?

    init(
        port: UInt16,
        getMeta: @escaping @Sendable () async -> DebugMetaResponse,
        getHelp: @escaping @Sendable () async -> DebugHelpResponse,
        getActionCatalog: @escaping @Sendable (DebugActionCatalogQuery) async -> DebugActionCatalogResponse,
        getLogs: @escaping @Sendable (DebugLogsQuery) async -> DebugLogsResponse,
        clearLogs: @escaping @Sendable () async -> DebugLogsClearResponse,
        getState: @escaping @Sendable (DebugStateQuery) async -> DebugStateResponse,
        getSnapshot: @escaping @Sendable (DebugSnapshotQuery) async -> DebugSnapshotResponse,
        performAction: @escaping @Sendable (DebugActionRequest) async -> DebugActionResponse
    ) {
        self.port = port
        self.getMeta = getMeta
        self.getHelp = getHelp
        self.getActionCatalog = getActionCatalog
        self.getLogs = getLogs
        self.clearLogs = clearLogs
        self.getState = getState
        self.getSnapshot = getSnapshot
        self.performAction = performAction
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                return
            }
            Task {
                await self.handle(connection: connection)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let requestData = try await receiveAll(from: connection)
            let request = try parseRequest(requestData)
            let responseData = try await route(request)
            try await send(responseData, to: connection)
        } catch {
            let response = jsonErrorResponse(
                status: "500 Internal Server Error",
                message: error.localizedDescription,
                errorType: "bridge_error"
            )
            try? await send(response, to: connection)
        }
        connection.cancel()
    }

    private func receiveAll(from connection: NWConnection) async throws -> Data {
        var data = Data()

        while true {
            let chunk = try await receiveChunk(from: connection)
            if let body = chunk.data {
                data.append(body)
            }
            if chunk.isComplete || requestComplete(data) {
                return data
            }
        }
    }

    private func receiveChunk(from connection: NWConnection) async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (data, isComplete))
            }
        }
    }

    private func requestComplete(_ data: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else {
            return false
        }

        let headerData = data.subdata(in: 0..<range.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.components(separatedBy: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) }
            ?? 0

        let bodyStart = range.upperBound
        let bodyCount = data.count - bodyStart
        return bodyCount >= contentLength
    }

    private func parseRequest(_ data: Data) throws -> HTTPRequest {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else {
            throw NSError(domain: "DebugHTTPBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad request"])
        }

        let headerData = data.subdata(in: 0..<range.lowerBound)
        let bodyData = data.subdata(in: range.upperBound..<data.count)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw NSError(domain: "DebugHTTPBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad request"])
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw NSError(domain: "DebugHTTPBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bad request"])
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        return HTTPRequest(
            method: method,
            path: URL(string: "http://127.0.0.1\(rawPath)")?.path ?? rawPath,
            url: URL(string: "http://127.0.0.1\(rawPath)"),
            body: bodyData
        )
    }

    private func route(_ request: HTTPRequest) async throws -> Data {
        switch (request.method, request.path) {
        case ("GET", "/meta"):
            return try jsonResponse(status: "200 OK", body: await getMeta())
        case ("GET", "/help"):
            return try jsonResponse(status: "200 OK", body: await getHelp())
        case ("GET", "/action"):
            return try jsonResponse(
                status: "200 OK",
                body: await getActionCatalog(actionQuery(from: request.url))
            )
        case ("POST", "/action"):
            let actionRequest: DebugActionRequest
            do {
                actionRequest = try JSONDecoder().decode(DebugActionRequest.self, from: request.body)
            } catch {
                return jsonErrorResponse(
                    status: "400 Bad Request",
                    message: "invalid action request",
                    errorType: "bad_request"
                )
            }
            let result = await performAction(actionRequest)
            return try jsonResponse(
                status: result.accepted ? "200 OK" : "400 Bad Request",
                body: result
            )
        case ("GET", "/logs"):
            return try jsonResponse(
                status: "200 OK",
                body: await getLogs(logsQuery(from: request.url))
            )
        case ("DELETE", "/logs"):
            return try jsonResponse(status: "200 OK", body: await clearLogs())
        case ("GET", "/state"):
            return try jsonResponse(
                status: "200 OK",
                body: await getState(stateQuery(from: request.url))
            )
        case ("GET", "/snapshot"):
            return try jsonResponse(
                status: "200 OK",
                body: await getSnapshot(snapshotQuery(from: request.url))
            )
        default:
            return jsonErrorResponse(
                status: "404 Not Found",
                message: "not found",
                errorType: "not_found"
            )
        }
    }

    private func actionQuery(from url: URL?) -> DebugActionCatalogQuery {
        let values = queryMap(from: url)
        return DebugActionCatalogQuery(
            targetId: values["targetId"],
            action: values["action"],
            screen: values["screen"]
        )
    }

    private func logsQuery(from url: URL?) -> DebugLogsQuery {
        let values = queryMap(from: url)
        return DebugLogsQuery(
            isQueryRequest: !values.isEmpty,
            event: values["event"],
            level: values["level"],
            source: values["source"],
            targetId: values["targetId"],
            screen: values["screen"],
            from: values["from"],
            to: values["to"],
            limit: Int(values["limit"] ?? "") ?? 20,
            keyword: values["keyword"]
        )
    }

    private func stateQuery(from url: URL?) -> DebugStateQuery {
        let values = queryMap(from: url)
        return DebugStateQuery(
            isQueryRequest: !values.isEmpty,
            keys: splitCSV(values["keys"]),
            targetId: values["targetId"],
            scope: values["scope"]
        )
    }

    private func snapshotQuery(from url: URL?) -> DebugSnapshotQuery {
        let values = queryMap(from: url)
        return DebugSnapshotQuery(
            isQueryRequest: !values.isEmpty,
            targetId: values["targetId"],
            scope: values["scope"],
            depth: Int(values["depth"] ?? ""),
            types: splitCSV(values["types"]),
            textKeyword: values["textKeyword"],
            visible: parseBool(values["visible"]),
            enabled: parseBool(values["enabled"]),
            clickable: parseBool(values["clickable"]),
            fields: splitCSV(values["fields"]),
            limit: Int(values["limit"] ?? "") ?? 20
        )
    }

    private func queryMap(from url: URL?) -> [String: String] {
        guard
            let url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return [:]
        }

        return (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value ?? ""
        }
    }

    private func splitCSV(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else {
            return []
        }
        return value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value else {
            return nil
        }
        switch value.lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func jsonResponse<T: Encodable>(status: String, body: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bodyData = try encoder.encode(body)
        return httpResponse(
            status: status,
            contentType: "application/json; charset=utf-8",
            bodyData: bodyData
        )
    }

    private func jsonErrorResponse(
        status: String,
        message: String,
        errorType: String? = nil
    ) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bodyData = (try? encoder.encode(
            DebugActionResponse.fail(message, errorType: errorType)
        )) ?? Data(#"{"accepted":false,"message":"request failed"}"#.utf8)

        return httpResponse(
            status: status,
            contentType: "application/json; charset=utf-8",
            bodyData: bodyData
        )
    }

    private func textResponse(status: String, contentType: String, body: String) -> Data {
        httpResponse(
            status: status,
            contentType: contentType,
            bodyData: Data(body.utf8)
        )
    }

    private func httpResponse(status: String, contentType: String, bodyData: Data) -> Data {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(header.utf8) + bodyData
    }

}
