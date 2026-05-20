import Foundation
import Observation

@Observable
@MainActor
public final class DebugRegistry {
    public final class RegistrationToken {
        private let onCancel: @MainActor () -> Void
        private var isCancelled = false

        init(onCancel: @escaping @MainActor () -> Void) {
            self.onCancel = onCancel
        }

        @MainActor
        public func cancel() {
            guard !isCancelled else {
                return
            }
            isCancelled = true
            onCancel()
        }

        deinit {
            guard !isCancelled else {
                return
            }
            Task { @MainActor [onCancel] in
                onCancel()
            }
        }
    }

    public private(set) var nodes: [String: DebugNodeSnapshot] = [:]
    private struct RegisteredAction {
        let args: [String]
        let perform: @MainActor (DebugActionRequest) -> DebugActionResponse
    }

    private var intents: [String: RegisteredAction] = [:]
    private var nodeActions: [String: RegisteredAction] = [:]
    private var targetStates: [String: [String: String]] = [:]
    private var logs: [DebugLogEntry] = []
    private var nextLogSequence = 1
    private let logLimit: Int

    public init(logLimit: Int = 500) {
        self.logLimit = max(1, logLimit)
    }

    public func upsert(_ node: DebugNodeSnapshot) {
        nodes[node.id] = node
    }

    public func remove(id: String) {
        nodes.removeValue(forKey: id)
        targetStates.removeValue(forKey: id)
        nodeActions.keys
            .filter { $0.hasPrefix("\(id)::") }
            .forEach { nodeActions.removeValue(forKey: $0) }
    }

    @discardableResult
    public func registerIntent(
        name: String,
        args: [String] = [],
        perform: @escaping @MainActor (DebugActionRequest) -> DebugActionResponse
    ) -> RegistrationToken {
        intents[name] = RegisteredAction(args: args, perform: perform)
        return RegistrationToken { [weak self] in
            self?.unregisterIntent(name: name)
        }
    }

    @discardableResult
    public func registerNodeAction(
        id: String,
        action: String,
        args: [String] = [],
        perform: @escaping @MainActor (DebugActionRequest) -> DebugActionResponse
    ) -> RegistrationToken {
        nodeActions[nodeActionKey(id: id, action: action)] = RegisteredAction(args: args, perform: perform)
        return RegistrationToken { [weak self] in
            self?.unregisterNodeAction(id: id, action: action)
        }
    }

    public func unregisterIntent(name: String) {
        intents.removeValue(forKey: name)
    }

    public func unregisterNodeAction(id: String, action: String) {
        nodeActions.removeValue(forKey: nodeActionKey(id: id, action: action))
    }

    public func publishTargetState(id: String, state: [String: String]) {
        targetStates[id] = state
    }

    public func clearTargetState(id: String) {
        targetStates.removeValue(forKey: id)
    }

    public func help(context: DebugServerContext, appState: [String: String]) -> DebugHelpResponse {
        let actionSummary = actionSummaryCounts()
        return DebugHelpResponse(
            appName: context.appName,
            consoleTitle: context.consoleTitle,
            screenName: context.screenName,
            serverTime: context.serverTime,
            capabilities: ["meta", "action", "logs", "state", "snapshot"],
            counts: DebugHelpCounts(
                actionTargetCount: actionSummary.targetCount,
                logCount: logs.count,
                stateKeyCount: appState.count,
                snapshotNodeCount: nodes.count
            ),
            endpoints: [
                DebugEndpointDescriptor(
                    method: "GET",
                    path: "/meta",
                    summary: "return app identity and build version"
                ),
                DebugEndpointDescriptor(
                    method: "GET",
                    path: "/help",
                    summary: "return dynamic full help for AI"
                ),
                DebugEndpointDescriptor(
                    method: "GET",
                    path: "/action",
                    summary: "show executable targets and actions",
                    queryFields: ["targetId", "action", "screen"]
                ),
                DebugEndpointDescriptor(
                    method: "POST",
                    path: "/action",
                    summary: "trigger one concrete action",
                    bodyFields: ["action", "targetId", "text", "dx", "dy", "args", "source"]
                ),
                DebugEndpointDescriptor(
                    method: "GET",
                    path: "/logs",
                    summary: "show log summary or query matching logs",
                    queryFields: ["event", "level", "source", "targetId", "screen", "from", "to", "limit", "keyword"]
                ),
                DebugEndpointDescriptor(
                    method: "DELETE",
                    path: "/logs",
                    summary: "clear all current logs"
                ),
                DebugEndpointDescriptor(
                    method: "GET",
                    path: "/state",
                    summary: "show state summary or query state values",
                    queryFields: ["keys", "targetId", "scope"]
                ),
                DebugEndpointDescriptor(
                    method: "GET",
                    path: "/snapshot",
                    summary: "show tree summary or query node snapshot",
                    queryFields: ["targetId", "scope", "depth", "types", "textKeyword", "visible", "enabled", "clickable", "fields", "limit"]
                ),
            ],
            examples: [
                "GET /meta",
                "GET /help",
                "GET /action",
                "GET /logs",
                "DELETE /logs",
                "GET /state?keys=counter",
                "GET /snapshot?targetId=increment_button&scope=branchToRoot&fields=id,type,text,bounds",
                "POST /action {\"action\":\"press\",\"targetId\":\"increment_button\"}",
            ]
        )
    }

    public func actionCatalog(context: DebugServerContext, query: DebugActionCatalogQuery) -> DebugActionCatalogResponse {
        let groupedNodeActions = groupedVisibleNodeActionKeys()

        var items: [DebugActionCatalogItem] = groupedNodeActions.keys.sorted().compactMap { targetId in
            let actionNames = groupedNodeActions[targetId, default: []]
                .compactMap { $0.components(separatedBy: "::").last }
                .sorted()

            // Swift 6 在这里对 compactMap 推断不稳，显式构造更稳，也更利于后续扩字段。
            var descriptors: [DebugActionDescriptor] = []
            for actionName in actionNames {
                guard let registered = nodeActions[nodeActionKey(id: targetId, action: actionName)] else {
                    continue
                }
                descriptors.append(
                    DebugActionDescriptor(
                        name: actionName,
                        args: registered.args,
                        summary: "trigger \(targetId) \(actionName)",
                        example: DebugActionRequest(action: actionName, targetId: targetId)
                    )
                )
            }

            guard !descriptors.isEmpty else {
                return nil
            }

            return DebugActionCatalogItem(
                targetId: targetId,
                targetType: displayType(for: nodes[targetId]),
                screen: context.screenName,
                actions: descriptors
            )
        }

        // 这里同样保留显式 append，减少 Swift 版本差异导致的推断问题。
        var intentItems: [DebugActionCatalogItem] = []
        for name in intents.keys.sorted() {
            guard let registered = intents[name] else {
                continue
            }
            intentItems.append(
                DebugActionCatalogItem(
                targetId: name,
                targetType: "Intent",
                screen: context.screenName,
                actions: [
                    DebugActionDescriptor(
                        name: "invoke",
                        args: registered.args,
                        summary: "invoke intent \(name)",
                        example: DebugActionRequest(action: "invoke", targetId: name)
                    ),
                ]
                )
            )
        }
        items += intentItems

        let filteredItems = items.filter { item in
            matches(query.targetId, value: item.targetId)
                && matches(query.screen, value: item.screen)
                && (query.action == nil || item.actions.contains { $0.name == query.action })
        }

        let actionCount = filteredItems.reduce(0) { $0 + $1.actions.count }
        return DebugActionCatalogResponse(
            summary: DebugActionCatalogSummary(
                targetCount: filteredItems.count,
                actionCount: actionCount
            ),
            items: filteredItems
        )
    }

    public func perform(request: DebugActionRequest) -> DebugActionResponse {
        let startedAt = Date()
        let rawResult: DebugActionResponse
        if
            nodes[request.targetId] != nil,
            let action = nodeActions[nodeActionKey(id: request.targetId, action: request.action)]
        {
            rawResult = action.perform(request)
        } else if request.action == "invoke", let intent = intents[request.targetId] {
            rawResult = intent.perform(request)
        } else {
            rawResult = .fail("unsupported action", errorType: "unsupported_action")
        }

        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))

        let result = DebugActionResponse(
            accepted: rawResult.accepted,
            message: rawResult.message,
            action: rawResult.action ?? request.action,
            targetId: rawResult.targetId ?? request.targetId,
            errorType: rawResult.errorType,
            timedOut: rawResult.timedOut,
            durationMs: rawResult.durationMs ?? durationMs
        )

        var data = request.args ?? [:]
        if let text = request.text {
            data["text"] = text
        }
        if let dx = request.dx {
            data["dx"] = "\(dx)"
        }
        if let dy = request.dy {
            data["dy"] = "\(dy)"
        }
        if let durationMs = result.durationMs {
            data["durationMs"] = "\(durationMs)"
        }
        data["accepted"] = result.accepted ? "true" : "false"

        log(
            event: request.action,
            level: result.accepted ? "info" : "warn",
            source: request.source ?? "ai",
            targetId: request.targetId,
            summary: result.accepted
                ? "accepted \(request.targetId) \(request.action)"
                : "rejected \(request.targetId) \(request.action)",
            data: data
        )
        return result
    }

    public func logs(query: DebugLogsQuery) -> DebugLogsResponse {
        guard query.hasFilters else {
            return DebugLogsResponse(summary: logsSummary())
        }

        let filtered = logs
            .filter { entry in
                matches(query.event, value: entry.event)
                    && matches(query.level, value: entry.level)
                    && matches(query.source, value: entry.source)
                    && matches(query.targetId, value: entry.targetId)
                    && matches(query.screen, value: entry.data["screen"])
                    && matchesTime(entry.time, from: query.from, to: query.to)
                    && matchesKeyword(query.keyword, entry: entry)
            }
            .prefix(max(0, query.limit))

        return DebugLogsResponse(
            items: Array(filtered),
            nextAfterSeq: filtered.last?.seq ?? max(nextLogSequence - 1, 0)
        )
    }

    public func clearLogs() -> DebugLogsClearResponse {
        let clearedCount = logs.count
        logs.removeAll()
        nextLogSequence = 1
        return DebugLogsClearResponse(
            accepted: true,
            message: "cleared \(clearedCount) logs",
            clearedCount: clearedCount
        )
    }

    public func state(appState: [String: String], query: DebugStateQuery) -> DebugStateResponse {
        guard query.hasFilters else {
            return DebugStateResponse(
                summary: DebugStateSummary(
                    appStateKeys: appState
                        .keys
                        .sorted()
                        .map { key in
                            DebugStateKeySample(key: key, sample: appState[key] ?? "")
                        },
                    targetStateTargets: targetStates.keys
                        .filter { nodes[$0] != nil }
                        .sorted()
                )
            )
        }

        let normalizedScope = query.scope?.lowercased()
        let appStatePayload = normalizedScope == "target" || normalizedScope == "branch"
            ? nil
            : filteredState(appState, keys: query.keys)

        let targetStatePayload: [String: String]?
        if normalizedScope == "branch", let targetId = query.targetId {
            targetStatePayload = nodes[targetId] == nil
                ? [:]
                : filteredState(branchTargetState(targetId: targetId), keys: query.keys)
        } else if let targetId = query.targetId {
            targetStatePayload = nodes[targetId] == nil
                ? [:]
                : filteredState(targetStates[targetId] ?? [:], keys: query.keys)
        } else {
            targetStatePayload = nil
        }

        return DebugStateResponse(
            appState: appStatePayload,
            targetState: targetStatePayload
        )
    }

    public func snapshot(context: DebugServerContext, query: DebugSnapshotQuery) -> DebugSnapshotResponse {
        guard query.hasFilters else {
            let summary = snapshotSummary(screenName: context.screenName)
            return DebugSnapshotResponse(
                summary: summary,
                fieldCatalog: snapshotFieldCatalog,
                examples: [
                    "/snapshot?targetId=increment_button&scope=self",
                    "/snapshot?targetId=increment_button&scope=branchToRoot&fields=id,type,text,bounds",
                    "/snapshot?types=Button&clickable=true&limit=20",
                ]
            )
        }

        let selectedNodes = filteredNodes(query: query)
        return DebugSnapshotResponse(
            screen: context.screenName,
            nodes: selectedNodes.map { projectNode($0, fields: query.fields) }
        )
    }

    public func log(
        event: String,
        level: String = "info",
        source: String = "system",
        targetId: String? = nil,
        summary: String,
        data: [String: String] = [:]
    ) {
        let entry = DebugLogEntry(
            seq: nextLogSequence,
            time: debugTimestampString(),
            source: source,
            level: level,
            event: event,
            targetId: targetId,
            summary: summary,
            data: data
        )
        nextLogSequence += 1
        logs.append(entry)
        if logs.count > logLimit {
            logs.removeFirst(logs.count - logLimit)
        }
    }

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
        var data = metadata
        data["kind"] = kind
        if let name {
            data["name"] = name
        }
        if let ok {
            data["accepted"] = ok ? "true" : "false"
        }

        log(
            event: action ?? kind,
            level: ok == false ? "warn" : "info",
            source: source,
            targetId: id,
            summary: message ?? defaultSummary(source: source, targetId: id, action: action ?? kind),
            data: data
        )
    }

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

    public func recordValueChange(
        source: String = "human",
        id: String,
        action: String = "change",
        oldValue: String? = nil,
        newValue: String? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        var data = metadata
        if let oldValue {
            data["from"] = oldValue
        }
        if let newValue {
            data["to"] = newValue
        }
        recordNodeEvent(
            source: source,
            id: id,
            action: action,
            message: message ?? "value changed",
            metadata: data
        )
    }

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
                ok: result.accepted,
                message: result.message,
                metadata: metadata
            )
            return result
        }
    }

    private func actionSummaryCounts() -> DebugActionCatalogSummary {
        let visibleNodeActionKeys = groupedVisibleNodeActionKeys()
        let nodeTargetCount = visibleNodeActionKeys.count
        let actionCount = visibleNodeActionKeys.values.reduce(0) { $0 + $1.count } + intents.count
        return DebugActionCatalogSummary(
            targetCount: nodeTargetCount + intents.count,
            actionCount: actionCount
        )
    }

    private func groupedVisibleNodeActionKeys() -> [String: [String]] {
        Dictionary(
            grouping: nodeActions.keys.filter { key in
                guard let targetId = key.components(separatedBy: "::").first else {
                    return false
                }
                return nodes[targetId] != nil
            },
            by: { key in
                String(key.split(separator: ":", maxSplits: 1).first ?? "")
            }
        )
    }

    private func nodeActionKey(id: String, action: String) -> String {
        "\(id)::\(action)"
    }

    private func logsSummary() -> DebugLogsSummary {
        let levelCounts = countBy(logs.map(\.level))
        let sourceCounts = countBy(logs.map(\.source))
        let topEvents = countBy(logs.map(\.event))
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(5)

        let timeRange: DebugTimeRange?
        if let first = logs.first, let last = logs.last {
            timeRange = DebugTimeRange(from: first.time, to: last.time)
        } else {
            timeRange = nil
        }

        return DebugLogsSummary(
            total: logs.count,
            timeRange: timeRange,
            levelCounts: levelCounts,
            sourceCounts: sourceCounts,
            eventCountsTop: Dictionary(topEvents.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func snapshotSummary(screenName: String) -> DebugSnapshotSummary {
        let sortedNodes = nodes.values.sorted { $0.id < $1.id }
        let rootIds = sortedNodes.filter { $0.parentID == nil }.map(\.id)
        let typeCounts = countBy(sortedNodes.map { displayType(for: $0) })
        let clickableCount = sortedNodes.filter { !$0.actions.isEmpty }.count
        return DebugSnapshotSummary(
            screen: screenName,
            nodeCount: sortedNodes.count,
            rootIds: rootIds,
            typeCounts: typeCounts,
            clickableCount: clickableCount
        )
    }

    private func filteredNodes(query: DebugSnapshotQuery) -> [DebugNodeSnapshot] {
        let scopedNodes = scopedNodes(for: query)
        let filtered = scopedNodes.filter { node in
            matchesTypes(query.types, node: node)
                && matchesText(query.textKeyword, node: node)
                && matchesBool(query.visible, value: node.isVisible)
                && matchesBool(query.enabled, value: true)
                && matchesBool(query.clickable, value: !node.actions.isEmpty)
        }
        return Array(filtered.sorted { $0.id < $1.id }.prefix(max(0, query.limit)))
    }

    private func scopedNodes(for query: DebugSnapshotQuery) -> [DebugNodeSnapshot] {
        guard let targetId = query.targetId else {
            return Array(nodes.values)
        }
        guard let targetNode = nodes[targetId] else {
            return []
        }

        switch query.scope?.lowercased() {
        case "branchtoroot":
            return branchToRoot(for: targetNode)
        case "subtree":
            return subtree(for: targetNode, depth: query.depth)
        case "self", nil:
            return [targetNode]
        default:
            return [targetNode]
        }
    }

    private func branchToRoot(for targetNode: DebugNodeSnapshot) -> [DebugNodeSnapshot] {
        var result: [DebugNodeSnapshot] = [targetNode]
        var currentParentID = targetNode.parentID
        while let parentID = currentParentID, let parent = nodes[parentID] {
            result.append(parent)
            currentParentID = parent.parentID
        }
        return result
    }

    private func subtree(for targetNode: DebugNodeSnapshot, depth: Int?) -> [DebugNodeSnapshot] {
        var result: [DebugNodeSnapshot] = []
        var queue: [(DebugNodeSnapshot, Int)] = [(targetNode, 0)]

        while !queue.isEmpty {
            let (node, level) = queue.removeFirst()
            result.append(node)

            if let depth, level >= depth {
                continue
            }

            let children = nodes.values
                .filter { $0.parentID == node.id }
                .sorted { $0.id < $1.id }
            queue.append(contentsOf: children.map { ($0, level + 1) })
        }
        return result
    }

    private func branchTargetState(targetId: String) -> [String: String] {
        var merged: [String: String] = [:]
        let branchNodes = branchToRoot(for: nodes[targetId] ?? DebugNodeSnapshot(
            id: targetId,
            role: "node",
            label: targetId,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            isVisible: false,
            actions: []
        )).reversed()

        for node in branchNodes {
            for (key, value) in targetStates[node.id] ?? [:] {
                merged[key] = value
            }
        }
        return merged
    }

    private func filteredState(_ state: [String: String], keys: [String]) -> [String: String] {
        guard !keys.isEmpty else {
            return state
        }
        let allowed = Set(keys)
        return state.filter { allowed.contains($0.key) }
    }

    private func projectNode(_ node: DebugNodeSnapshot, fields: [String]) -> DebugSnapshotNodePayload {
        let fieldSet = Set(fields.isEmpty ? snapshotFieldCatalog : fields)
        return DebugSnapshotNodePayload(
            id: node.id,
            parentId: fieldSet.contains("parentId") ? node.parentID : nil,
            type: fieldSet.contains("type") ? displayType(for: node) : nil,
            text: fieldSet.contains("text") ? node.label : nil,
            role: fieldSet.contains("role") ? node.role : nil,
            backgroundColor: fieldSet.contains("backgroundColor") ? nil : nil,
            contentColor: fieldSet.contains("contentColor") ? nil : nil,
            visible: fieldSet.contains("visible") ? node.isVisible : nil,
            enabled: fieldSet.contains("enabled") ? true : nil,
            clickable: fieldSet.contains("clickable") ? !node.actions.isEmpty : nil,
            value: fieldSet.contains("value") ? nil : nil,
            extra: fieldSet.contains("extra") ? nil : nil,
            bounds: fieldSet.contains("bounds")
                ? DebugBounds(left: node.x, top: node.y, width: node.width, height: node.height)
                : nil
        )
    }

    private func matches(_ expected: String?, value: String?) -> Bool {
        guard let expected, !expected.isEmpty else {
            return true
        }
        guard let value else {
            return false
        }
        return value == expected
    }

    private func matchesBool(_ expected: Bool?, value: Bool) -> Bool {
        guard let expected else {
            return true
        }
        return expected == value
    }

    private func matchesTypes(_ expectedTypes: [String], node: DebugNodeSnapshot) -> Bool {
        guard !expectedTypes.isEmpty else {
            return true
        }
        let lowered = Set(expectedTypes.map { $0.lowercased() })
        return lowered.contains(displayType(for: node).lowercased())
            || lowered.contains(node.role.lowercased())
    }

    private func matchesText(_ keyword: String?, node: DebugNodeSnapshot) -> Bool {
        guard let keyword, !keyword.isEmpty else {
            return true
        }
        return node.label.localizedCaseInsensitiveContains(keyword)
    }

    private func matchesTime(_ time: String, from: String?, to: String?) -> Bool {
        if let from, time < from {
            return false
        }
        if let to, time > to {
            return false
        }
        return true
    }

    private func matchesKeyword(_ keyword: String?, entry: DebugLogEntry) -> Bool {
        guard let keyword, !keyword.isEmpty else {
            return true
        }
        if entry.summary.localizedCaseInsensitiveContains(keyword) {
            return true
        }
        return entry.data.contains { key, value in
            key.localizedCaseInsensitiveContains(keyword) || value.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func displayType(for node: DebugNodeSnapshot?) -> String {
        guard let node else {
            return "Node"
        }
        switch node.role.lowercased() {
        case "button":
            return "Button"
        case "text":
            return "Text"
        case "container":
            return "Container"
        case "panel":
            return "Panel"
        default:
            return node.role.prefix(1).uppercased() + node.role.dropFirst()
        }
    }

    private func countBy(_ items: [String]) -> [String: Int] {
        items.reduce(into: [String: Int]()) { result, item in
            result[item, default: 0] += 1
        }
    }

    private func defaultSummary(source: String, targetId: String?, action: String) -> String {
        if let targetId {
            return "\(source) \(action) \(targetId)"
        }
        return "\(source) \(action)"
    }

    private var snapshotFieldCatalog: [String] {
        [
            "id",
            "parentId",
            "type",
            "text",
            "role",
            "backgroundColor",
            "contentColor",
            "visible",
            "enabled",
            "clickable",
            "value",
            "extra",
            "bounds",
        ]
    }
}
