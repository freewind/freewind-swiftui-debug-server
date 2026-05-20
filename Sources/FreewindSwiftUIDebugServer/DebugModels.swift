import Foundation

// 单个调试节点快照。
public struct DebugNodeSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let parentID: String?
    public let role: String
    public let label: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let isVisible: Bool
    public let actions: [String]

    public init(
        id: String,
        parentID: String? = nil,
        role: String,
        label: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isVisible: Bool,
        actions: [String]
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isVisible = isVisible
        self.actions = actions
    }
}

// server 运行时上下文。
public struct DebugServerContext: Sendable {
    public let appName: String
    public let consoleTitle: String?
    public let screenName: String
    public let serverTime: String

    public init(
        appName: String,
        consoleTitle: String? = nil,
        screenName: String,
        serverTime: String = debugTimestampString()
    ) {
        self.appName = appName
        self.consoleTitle = consoleTitle
        self.screenName = screenName
        self.serverTime = serverTime
    }
}

public struct DebugMetaResponse: Codable, Sendable {
    public let appName: String
    public let buildVersion: Int

    public init(appName: String, buildVersion: Int) {
        self.appName = appName
        self.buildVersion = buildVersion
    }
}

// 外部动作请求。
// 这里是 server ↔ 独立协议仓 的协议面；字段/语义变更时，需同步 freewind-debug-bridge-web 与 openapi 契约。
public struct DebugActionRequest: Codable, Sendable {
    public let action: String
    public let targetId: String
    public let text: String?
    public let dx: Double?
    public let dy: Double?
    public let args: [String: String]?
    public let source: String?

    public init(
        action: String,
        targetId: String,
        text: String? = nil,
        dx: Double? = nil,
        dy: Double? = nil,
        args: [String: String]? = nil,
        source: String? = nil
    ) {
        self.action = action
        self.targetId = targetId
        self.text = text
        self.dx = dx
        self.dy = dy
        self.args = args
        self.source = source
    }
}

// 动作响应。
public struct DebugActionResponse: Codable, Sendable {
    public let accepted: Bool
    public let message: String
    public let action: String?
    public let targetId: String?
    public let errorType: String?
    public let timedOut: Bool?
    public let durationMs: Int?

    public init(
        accepted: Bool,
        message: String,
        action: String? = nil,
        targetId: String? = nil,
        errorType: String? = nil,
        timedOut: Bool? = nil,
        durationMs: Int? = nil
    ) {
        self.accepted = accepted
        self.message = message
        self.action = action
        self.targetId = targetId
        self.errorType = errorType
        self.timedOut = timedOut
        self.durationMs = durationMs
    }

    public static func ok(
        _ message: String,
        action: String? = nil,
        targetId: String? = nil,
        durationMs: Int? = nil
    ) -> Self {
        Self(
            accepted: true,
            message: message,
            action: action,
            targetId: targetId,
            durationMs: durationMs
        )
    }

    public static func fail(
        _ message: String,
        action: String? = nil,
        targetId: String? = nil,
        errorType: String? = nil,
        timedOut: Bool? = nil,
        durationMs: Int? = nil
    ) -> Self {
        Self(
            accepted: false,
            message: message,
            action: action,
            targetId: targetId,
            errorType: errorType,
            timedOut: timedOut,
            durationMs: durationMs
        )
    }
}

// 清空日志响应。
public struct DebugLogsClearResponse: Codable, Sendable {
    public let accepted: Bool
    public let message: String
    public let clearedCount: Int

    public init(accepted: Bool, message: String, clearedCount: Int) {
        self.accepted = accepted
        self.message = message
        self.clearedCount = clearedCount
    }
}

// action query。
public struct DebugActionCatalogQuery: Sendable {
    public let targetId: String?
    public let action: String?
    public let screen: String?

    public init(
        targetId: String? = nil,
        action: String? = nil,
        screen: String? = nil
    ) {
        self.targetId = targetId
        self.action = action
        self.screen = screen
    }

    public var hasFilters: Bool {
        targetId != nil || action != nil || screen != nil
    }
}

// /action item。
public struct DebugActionCatalogResponse: Codable, Sendable {
    public let summary: DebugActionCatalogSummary
    public let items: [DebugActionCatalogItem]

    public init(summary: DebugActionCatalogSummary, items: [DebugActionCatalogItem]) {
        self.summary = summary
        self.items = items
    }
}

public struct DebugActionCatalogSummary: Codable, Sendable {
    public let targetCount: Int
    public let actionCount: Int

    public init(targetCount: Int, actionCount: Int) {
        self.targetCount = targetCount
        self.actionCount = actionCount
    }
}

public struct DebugActionCatalogItem: Codable, Sendable, Identifiable {
    public let targetId: String
    public let targetType: String
    public let screen: String
    public let actions: [DebugActionDescriptor]

    public var id: String { targetId }

    public init(
        targetId: String,
        targetType: String,
        screen: String,
        actions: [DebugActionDescriptor]
    ) {
        self.targetId = targetId
        self.targetType = targetType
        self.screen = screen
        self.actions = actions
    }
}

public struct DebugActionDescriptor: Codable, Sendable {
    public let name: String
    // args 直接驱动 web 的动态表单；新增/改名后，web 会尽量自适应，但保留字段语义仍需同步确认。
    public let args: [String]
    public let summary: String
    public let example: DebugActionRequest

    public init(
        name: String,
        args: [String],
        summary: String,
        example: DebugActionRequest
    ) {
        self.name = name
        self.args = args
        self.summary = summary
        self.example = example
    }
}

// log entry。
public struct DebugLogEntry: Codable, Sendable {
    public let seq: Int
    public let time: String
    public let source: String
    public let level: String
    public let event: String
    public let targetId: String?
    public let summary: String
    public let data: [String: String]

    public init(
        seq: Int,
        time: String,
        source: String,
        level: String,
        event: String,
        targetId: String? = nil,
        summary: String,
        data: [String: String] = [:]
    ) {
        self.seq = seq
        self.time = time
        self.source = source
        self.level = level
        self.event = event
        self.targetId = targetId
        self.summary = summary
        self.data = data
    }
}

// logs query。
public struct DebugLogsQuery: Sendable {
    public let isQueryRequest: Bool
    public let event: String?
    public let level: String?
    public let source: String?
    public let targetId: String?
    public let screen: String?
    public let from: String?
    public let to: String?
    public let limit: Int
    public let keyword: String?

    public init(
        isQueryRequest: Bool = false,
        event: String? = nil,
        level: String? = nil,
        source: String? = nil,
        targetId: String? = nil,
        screen: String? = nil,
        from: String? = nil,
        to: String? = nil,
        limit: Int = 20,
        keyword: String? = nil
    ) {
        self.isQueryRequest = isQueryRequest
        self.event = event
        self.level = level
        self.source = source
        self.targetId = targetId
        self.screen = screen
        self.from = from
        self.to = to
        self.limit = limit
        self.keyword = keyword
    }

    public var hasFilters: Bool {
        isQueryRequest
            || event != nil
            || level != nil
            || source != nil
            || targetId != nil
            || screen != nil
            || from != nil
            || to != nil
            || keyword != nil
    }
}

public struct DebugLogsResponse: Codable, Sendable {
    public let summary: DebugLogsSummary?
    public let items: [DebugLogEntry]?
    public let nextAfterSeq: Int?

    public init(
        summary: DebugLogsSummary? = nil,
        items: [DebugLogEntry]? = nil,
        nextAfterSeq: Int? = nil
    ) {
        self.summary = summary
        self.items = items
        self.nextAfterSeq = nextAfterSeq
    }
}

public struct DebugLogsSummary: Codable, Sendable {
    public let total: Int
    public let timeRange: DebugTimeRange?
    public let levelCounts: [String: Int]
    public let sourceCounts: [String: Int]
    public let eventCountsTop: [String: Int]

    public init(
        total: Int,
        timeRange: DebugTimeRange?,
        levelCounts: [String: Int],
        sourceCounts: [String: Int],
        eventCountsTop: [String: Int]
    ) {
        self.total = total
        self.timeRange = timeRange
        self.levelCounts = levelCounts
        self.sourceCounts = sourceCounts
        self.eventCountsTop = eventCountsTop
    }
}

public struct DebugTimeRange: Codable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

// state query。
public struct DebugStateQuery: Sendable {
    public let isQueryRequest: Bool
    public let keys: [String]
    public let targetId: String?
    public let scope: String?

    public init(
        isQueryRequest: Bool = false,
        keys: [String] = [],
        targetId: String? = nil,
        scope: String? = nil
    ) {
        self.isQueryRequest = isQueryRequest
        self.keys = keys
        self.targetId = targetId
        self.scope = scope
    }

    public var hasFilters: Bool {
        isQueryRequest || !keys.isEmpty || targetId != nil || scope != nil
    }
}

public struct DebugStateResponse: Codable, Sendable {
    public let summary: DebugStateSummary?
    public let appState: [String: String]?
    public let targetState: [String: String]?

    public init(
        summary: DebugStateSummary? = nil,
        appState: [String: String]? = nil,
        targetState: [String: String]? = nil
    ) {
        self.summary = summary
        self.appState = appState
        self.targetState = targetState
    }
}

public struct DebugStateSummary: Codable, Sendable {
    public let appStateKeys: [DebugStateKeySample]
    public let targetStateTargets: [String]

    public init(appStateKeys: [DebugStateKeySample], targetStateTargets: [String]) {
        self.appStateKeys = appStateKeys
        self.targetStateTargets = targetStateTargets
    }
}

public struct DebugStateKeySample: Codable, Sendable {
    public let key: String
    public let sample: String

    public init(key: String, sample: String) {
        self.key = key
        self.sample = sample
    }
}

// snapshot query。
public struct DebugSnapshotQuery: Sendable {
    public let isQueryRequest: Bool
    public let targetId: String?
    public let scope: String?
    public let depth: Int?
    public let types: [String]
    public let textKeyword: String?
    public let visible: Bool?
    public let enabled: Bool?
    public let clickable: Bool?
    public let fields: [String]
    public let limit: Int

    public init(
        isQueryRequest: Bool = false,
        targetId: String? = nil,
        scope: String? = nil,
        depth: Int? = nil,
        types: [String] = [],
        textKeyword: String? = nil,
        visible: Bool? = nil,
        enabled: Bool? = nil,
        clickable: Bool? = nil,
        fields: [String] = [],
        limit: Int = 20
    ) {
        self.isQueryRequest = isQueryRequest
        self.targetId = targetId
        self.scope = scope
        self.depth = depth
        self.types = types
        self.textKeyword = textKeyword
        self.visible = visible
        self.enabled = enabled
        self.clickable = clickable
        self.fields = fields
        self.limit = limit
    }

    public var hasFilters: Bool {
        isQueryRequest
            || targetId != nil
            || scope != nil
            || depth != nil
            || !types.isEmpty
            || textKeyword != nil
            || visible != nil
            || enabled != nil
            || clickable != nil
            || !fields.isEmpty
    }
}

public struct DebugSnapshotResponse: Codable, Sendable {
    public let summary: DebugSnapshotSummary?
    public let fieldCatalog: [String]?
    public let examples: [String]?
    public let screen: String?
    public let nodes: [DebugSnapshotNodePayload]?

    public init(
        summary: DebugSnapshotSummary? = nil,
        fieldCatalog: [String]? = nil,
        examples: [String]? = nil,
        screen: String? = nil,
        nodes: [DebugSnapshotNodePayload]? = nil
    ) {
        self.summary = summary
        self.fieldCatalog = fieldCatalog
        self.examples = examples
        self.screen = screen
        self.nodes = nodes
    }
}

public struct DebugSnapshotSummary: Codable, Sendable {
    public let screen: String
    public let nodeCount: Int
    public let rootIds: [String]
    public let typeCounts: [String: Int]
    public let clickableCount: Int

    public init(
        screen: String,
        nodeCount: Int,
        rootIds: [String],
        typeCounts: [String: Int],
        clickableCount: Int
    ) {
        self.screen = screen
        self.nodeCount = nodeCount
        self.rootIds = rootIds
        self.typeCounts = typeCounts
        self.clickableCount = clickableCount
    }
}

public struct DebugSnapshotNodePayload: Codable, Sendable, Identifiable {
    public let id: String
    public let parentId: String?
    public let type: String?
    public let text: String?
    public let role: String?
    public let backgroundColor: String?
    public let contentColor: String?
    public let visible: Bool?
    public let enabled: Bool?
    public let clickable: Bool?
    public let value: String?
    public let extra: [String: String]?
    public let bounds: DebugBounds?

    public init(
        id: String,
        parentId: String? = nil,
        type: String? = nil,
        text: String? = nil,
        role: String? = nil,
        backgroundColor: String? = nil,
        contentColor: String? = nil,
        visible: Bool? = nil,
        enabled: Bool? = nil,
        clickable: Bool? = nil,
        value: String? = nil,
        extra: [String: String]? = nil,
        bounds: DebugBounds? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.type = type
        self.text = text
        self.role = role
        self.backgroundColor = backgroundColor
        self.contentColor = contentColor
        self.visible = visible
        self.enabled = enabled
        self.clickable = clickable
        self.value = value
        self.extra = extra
        self.bounds = bounds
    }
}

public struct DebugBounds: Codable, Sendable {
    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double

    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

// /help。
public struct DebugHelpResponse: Codable, Sendable {
    public let appName: String
    public let consoleTitle: String?
    public let screenName: String
    public let serverTime: String
    public let capabilities: [String]
    public let counts: DebugHelpCounts
    public let endpoints: [DebugEndpointDescriptor]
    public let examples: [String]

    public init(
        appName: String,
        consoleTitle: String? = nil,
        screenName: String,
        serverTime: String,
        capabilities: [String],
        counts: DebugHelpCounts,
        endpoints: [DebugEndpointDescriptor],
        examples: [String]
    ) {
        self.appName = appName
        self.consoleTitle = consoleTitle
        self.screenName = screenName
        self.serverTime = serverTime
        self.capabilities = capabilities
        self.counts = counts
        self.endpoints = endpoints
        self.examples = examples
    }
}

public struct DebugHelpCounts: Codable, Sendable {
    public let actionTargetCount: Int
    public let logCount: Int
    public let stateKeyCount: Int
    public let snapshotNodeCount: Int

    public init(
        actionTargetCount: Int,
        logCount: Int,
        stateKeyCount: Int,
        snapshotNodeCount: Int
    ) {
        self.actionTargetCount = actionTargetCount
        self.logCount = logCount
        self.stateKeyCount = stateKeyCount
        self.snapshotNodeCount = snapshotNodeCount
    }
}

public struct DebugEndpointDescriptor: Codable, Sendable {
    public let method: String
    public let path: String
    public let summary: String
    public let queryFields: [String]?
    public let bodyFields: [String]?

    public init(
        method: String,
        path: String,
        summary: String,
        queryFields: [String]? = nil,
        bodyFields: [String]? = nil
    ) {
        self.method = method
        self.path = path
        self.summary = summary
        self.queryFields = queryFields
        self.bodyFields = bodyFields
    }
}

public func debugTimestampString(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
}

public func debugBundleBuildVersion(bundle: Bundle = .main) -> Int {
    if let number = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? NSNumber {
        return number.intValue
    }

    if let string = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(normalized) {
            return value
        }
        if let head = normalized.split(separator: ".").first, let value = Int(head) {
            return value
        }
    }

    return 0
}
