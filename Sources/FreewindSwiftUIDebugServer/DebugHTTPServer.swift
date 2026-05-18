import Foundation
import Network

// 本地 HTTP server。
final class DebugHTTPServer: @unchecked Sendable {
    // 监听端口。
    private let port: UInt16
    // 生成 snapshot。
    private let getSnapshot: @Sendable () async -> DebugSnapshot
    // 执行动作。
    private let performAction: @Sendable (DebugActionRequest) async -> DebugActionResponse
    // 底层 listener。
    private var listener: NWListener?

    // 构造。
    init(
        port: UInt16,
        getSnapshot: @escaping @Sendable () async -> DebugSnapshot,
        performAction: @escaping @Sendable (DebugActionRequest) async -> DebugActionResponse
    ) {
        self.port = port
        self.getSnapshot = getSnapshot
        self.performAction = performAction
    }

    // 启动监听。
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

    // 停止监听。
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // 处理单个连接。
    private func handle(connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let requestData = try await receiveAll(from: connection)
            let requestText = String(decoding: requestData, as: UTF8.self)
            let responseData = try await route(requestText: requestText)
            try await send(responseData, to: connection)
        } catch {
            let body = #"{"ok":false,"message":"\#(error.localizedDescription)"}"#
            let response = httpResponse(status: "500 Internal Server Error", body: body)
            try? await send(response, to: connection)
        }
        connection.cancel()
    }

    // 读请求。
    private func receiveAll(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(returning: Data())
                    return
                }
                if isComplete {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // 路由。
    private func route(requestText: String) async throws -> Data {
        let parts = requestText.components(separatedBy: "\r\n\r\n")
        let headerText = parts.first ?? ""
        let bodyText = parts.count > 1 ? parts[1] : ""
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let requestLine = firstLine.split(separator: " ")
        guard requestLine.count >= 2 else {
            return httpResponse(status: "400 Bad Request", body: #"{"ok":false,"message":"Bad request"}"#)
        }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        if method == "GET", path == "/snapshot" {
            let snapshot = await getSnapshot()
            return try httpResponse(status: "200 OK", encodableBody: snapshot)
        }

        if method == "POST", path == "/action" {
            let request = try JSONDecoder().decode(DebugActionRequest.self, from: Data(bodyText.utf8))
            let result = await performAction(request)
            return try httpResponse(
                status: result.ok ? "200 OK" : "400 Bad Request",
                encodableBody: result
            )
        }

        return httpResponse(status: "404 Not Found", body: #"{"ok":false,"message":"Not found"}"#)
    }

    // 发响应。
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

    // HTTP + JSON。
    private func httpResponse<T: Encodable>(status: String, encodableBody: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = try encoder.encode(encodableBody)
        return httpResponse(status: status, bodyData: body)
    }

    // HTTP + 纯文本 body。
    private func httpResponse(status: String, body: String) -> Data {
        httpResponse(status: status, bodyData: Data(body.utf8))
    }

    // 组装响应。
    private func httpResponse(status: String, bodyData: Data) -> Data {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(header.utf8) + bodyData
    }
}
