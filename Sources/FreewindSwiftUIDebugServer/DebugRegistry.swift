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
    // 最近操作。
    private var events: [DebugEvent] = []
    // 下一个事件序号。
    private var nextEventSequence = 1
    // 环形上限。
    private let eventLimit: Int

    // 构造。
    public init(eventLimit: Int = 200) {
        self.eventLimit = max(1, eventLimit)
    }

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

    // 按查询生成裁剪 snapshot。
    public func snapshot(appState: [String: String], query: DebugSnapshotQuery) -> DebugSnapshotResponse {
        let selectedNodes = filteredNodes(query: query)
        let appStatePayload = query.includeAppState ? filteredAppState(appState, keys: query.appStateKeys) : nil
        let actionNames = query.includeActionNames ? intents.keys.sorted() : nil
        let nodePayloads = query.includeNodes ? selectedNodes.map { projectNode($0, fields: query.nodeFields) } : nil

        return DebugSnapshotResponse(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            totalNodeCount: nodes.count,
            matchedNodeCount: selectedNodes.count,
            appState: appStatePayload,
            nodes: nodePayloads,
            actionNames: actionNames
        )
    }

    // 执行动作。
    public func perform(request: DebugActionRequest) -> DebugActionResponse {
        let result: DebugActionResponse
        if request.type == "intent", let name = request.name, let action = intents[name] {
            result = action()
        } else if request.type == "node", let id = request.id, let actionName = request.action, let action = nodeActions["\(id)::\(actionName)"] {
            result = action()
        } else {
            result = .fail("Unknown action request")
        }
        recordEvent(
            source: request.source ?? "ai",
            kind: request.type,
            name: request.name,
            id: request.id,
            action: request.action,
            ok: result.ok,
            message: result.message,
            metadata: request.metadata ?? [:]
        )
        return result
    }

    // 外部显式记录事件。
    public func recordEvent(
        source: String,
        kind: String,
        name: String? = nil,
        id: String? = nil,
        action: String? = nil,
        ok: Bool? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let event = DebugEvent(
            sequence: nextEventSequence,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            source: source,
            kind: kind,
            name: name,
            id: id,
            action: action,
            ok: ok,
            message: message,
            metadata: metadata
        )
        nextEventSequence += 1
        events.append(event)
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }
    }

    // 记录节点事件，默认视为人类交互。
    public func recordNodeEvent(
        source: String = "human",
        id: String,
        action: String,
        ok: Bool? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        recordEvent(
            source: source,
            kind: "node",
            id: id,
            action: action,
            ok: ok,
            message: message,
            metadata: metadata
        )
    }

    // 记录值变化，自动附上前后值。
    public func recordValueChange(
        source: String = "human",
        id: String,
        action: String = "change",
        oldValue: String? = nil,
        newValue: String? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        var payload = metadata
        if let oldValue {
            payload["from"] = oldValue
        }
        if let newValue {
            payload["to"] = newValue
        }
        recordNodeEvent(
            source: source,
            id: id,
            action: action,
            message: message,
            metadata: payload
        )
    }

    // 包装无返回值动作，先记日志再执行。
    public func wrapNodeAction(
        source: String = "human",
        id: String,
        action: String,
        metadata: [String: String] = [:],
        perform: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        { [weak self] in
            self?.recordNodeEvent(source: source, id: id, action: action, metadata: metadata)
            perform()
        }
    }

    // 包装返回 DebugActionResponse 的动作，日志带结果。
    public func wrapNodeAction(
        source: String = "human",
        id: String,
        action: String,
        metadata: [String: String] = [:],
        perform: @escaping @MainActor () -> DebugActionResponse
    ) -> @MainActor () -> DebugActionResponse {
        { [weak self] in
            let result = perform()
            self?.recordNodeEvent(
                source: source,
                id: id,
                action: action,
                ok: result.ok,
                message: result.message,
                metadata: metadata
            )
            return result
        }
    }

    // 拉取最近事件。
    public func events(query: DebugEventQuery) -> DebugEventResponse {
        let limited = events
            .filter { event in
                event.sequence > query.afterSequence
                    && matches(query.sources, value: event.source)
                    && matches(query.kinds, value: event.kind)
                    && matches(query.ids, value: event.id)
            }
            .prefix(max(0, query.limit))

        return DebugEventResponse(nextSequence: nextEventSequence, events: Array(limited))
    }

    private func filteredNodes(query: DebugSnapshotQuery) -> [DebugNodeSnapshot] {
        var selected = nodes.values.filter { node in
            matches(query.nodeIDs, value: node.id)
                && matches(query.roles, value: node.role)
                && (!query.visibleOnly || node.isVisible)
                && matches(query.rect, node: node)
        }

        if query.includeAncestors {
            selected = includeAncestors(for: selected, depth: query.ancestorDepth)
        }

        let sorted = selected.sorted { $0.id < $1.id }
        guard let limit = query.limit, limit >= 0 else {
            return sorted
        }
        return Array(sorted.prefix(limit))
    }

    private func includeAncestors(for selected: [DebugNodeSnapshot], depth: Int?) -> [DebugNodeSnapshot] {
        var map = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })

        for node in selected {
            var currentParentID = node.parentID
            var remainingDepth = depth

            while let parentID = currentParentID, let parent = nodes[parentID] {
                if map[parent.id] == nil {
                    map[parent.id] = parent
                }
                currentParentID = parent.parentID
                if let remainingDepth {
                    if remainingDepth <= 1 {
                        break
                    }
                    remainingDepth = remainingDepth - 1
                }
            }
        }

        return Array(map.values)
    }

    private func filteredAppState(_ appState: [String: String], keys: [String]?) -> [String: String] {
        guard let keys, !keys.isEmpty else {
            return appState
        }
        return appState.filter { keys.contains($0.key) }
    }

    private func projectNode(_ node: DebugNodeSnapshot, fields: [String]?) -> DebugNodePayload {
        let fieldSet = Set(fields ?? [
            "id",
            "parentID",
            "role",
            "label",
            "x",
            "y",
            "width",
            "height",
            "isVisible",
            "actions",
        ])

        return DebugNodePayload(
            id: node.id,
            parentID: fieldSet.contains("parentID") ? node.parentID : nil,
            role: fieldSet.contains("role") ? node.role : nil,
            label: fieldSet.contains("label") ? node.label : nil,
            x: fieldSet.contains("x") ? node.x : nil,
            y: fieldSet.contains("y") ? node.y : nil,
            width: fieldSet.contains("width") ? node.width : nil,
            height: fieldSet.contains("height") ? node.height : nil,
            isVisible: fieldSet.contains("isVisible") ? node.isVisible : nil,
            actions: fieldSet.contains("actions") ? node.actions : nil
        )
    }

    private func matches(_ allowedValues: [String]?, value: String?) -> Bool {
        guard let allowedValues, !allowedValues.isEmpty else {
            return true
        }
        guard let value else {
            return false
        }
        return allowedValues.contains(value)
    }

    private func matches(_ rect: DebugRectFilter?, node: DebugNodeSnapshot) -> Bool {
        guard let rect else {
            return true
        }

        let nodeMaxX = node.x + node.width
        let nodeMaxY = node.y + node.height

        if let minX = rect.minX, nodeMaxX < minX {
            return false
        }
        if let maxX = rect.maxX, node.x > maxX {
            return false
        }
        if let minY = rect.minY, nodeMaxY < minY {
            return false
        }
        if let maxY = rect.maxY, node.y > maxY {
            return false
        }
        return true
    }
}
