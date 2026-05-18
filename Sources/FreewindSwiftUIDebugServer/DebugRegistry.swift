import Foundation
import Observation

// 节点注册中心，负责收集节点与动作。
@Observable
@MainActor
public final class DebugRegistry {
    // 所有节点。
    public private(set) var nodes: [String: DebugNodeSnapshot] = [:]
    // 语义动作。
    private var intents: [String: @MainActor () -> DebugActionResponse] = [:]
    // 节点动作。
    private var nodeActions: [String: @MainActor () -> DebugActionResponse] = [:]

    // 构造。
    public init() {}

    // 写入或更新节点。
    public func upsert(_ node: DebugNodeSnapshot) {
        nodes[node.id] = node
    }

    // 移除节点。
    public func remove(id: String) {
        nodes.removeValue(forKey: id)
        nodeActions.keys
            .filter { $0.hasPrefix("\(id)::") }
            .forEach { nodeActions.removeValue(forKey: $0) }
    }

    // 注册 intent。
    public func registerIntent(name: String, perform: @escaping @MainActor () -> DebugActionResponse) {
        intents[name] = perform
    }

    // 注册节点动作。
    public func registerNodeAction(id: String, action: String, perform: @escaping @MainActor () -> DebugActionResponse) {
        nodeActions["\(id)::\(action)"] = perform
    }

    // 生成 snapshot。
    public func snapshot(appState: [String: String]) -> DebugSnapshot {
        DebugSnapshot(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appState: appState,
            nodeCount: nodes.count,
            nodes: nodes.values.sorted { $0.id < $1.id },
            actionNames: intents.keys.sorted()
        )
    }

    // 执行动作。
    public func perform(request: DebugActionRequest) -> DebugActionResponse {
        if request.type == "intent", let name = request.name, let action = intents[name] {
            return action()
        }
        if request.type == "node", let id = request.id, let actionName = request.action, let action = nodeActions["\(id)::\(actionName)"] {
            return action()
        }
        return .fail("Unknown action request")
    }
}
