import Foundation
import Observation

// 对业务暴露的总入口。
@Observable
@MainActor
public final class DebugBridge {
    // 共享 registry，供 view 环境注入。
    public let registry = DebugRegistry()
    // 当前 server。
    private var server: DebugHTTPServer?
    // 当前端口。
    public private(set) var port: UInt16?
    // 启动状态说明。
    public private(set) var statusMessage: String = "Not started"

    // 构造。
    public init() {}

    // 注册 intent。
    public func registerIntent(name: String, perform: @escaping @MainActor () -> DebugActionResponse) {
        registry.registerIntent(name: name, perform: perform)
    }

    // 注册节点动作。
    public func registerNodeAction(id: String, action: String, perform: @escaping @MainActor () -> DebugActionResponse) {
        registry.registerNodeAction(id: id, action: action, perform: perform)
    }

    // 启动 server。
    public func start(port: UInt16, appState: @escaping @MainActor () -> [String: String]) {
        stop()
        self.port = port
        server = DebugHTTPServer(
            port: port,
            getSnapshot: { [weak self] in
                await MainActor.run {
                    guard let self else {
                        return DebugSnapshot(
                            timestamp: ISO8601DateFormatter().string(from: Date()),
                            appState: [:],
                            nodeCount: 0,
                            nodes: [],
                            actionNames: []
                        )
                    }
                    return self.registry.snapshot(appState: appState())
                }
            },
            performAction: { [weak self] request in
                await MainActor.run {
                    guard let self else {
                        return .fail("DebugBridge deallocated")
                    }
                    return self.registry.perform(request: request)
                }
            }
        )

        do {
            try server?.start()
            statusMessage = "Listening at http://127.0.0.1:\(port)"
        } catch {
            statusMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    // 停止 server。
    public func stop() {
        server?.stop()
        server = nil
        port = nil
    }
}
