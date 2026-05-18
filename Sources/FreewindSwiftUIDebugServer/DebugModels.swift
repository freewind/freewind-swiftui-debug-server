import Foundation

// 单个调试节点快照。
public struct DebugNodeSnapshot: Codable, Identifiable, Sendable {
    // 稳定节点 id。
    public let id: String
    // 节点角色，如 button / text / panel。
    public let role: String
    // 对外标签。
    public let label: String
    // 左上角 x。
    public let x: Double
    // 左上角 y。
    public let y: Double
    // 宽度。
    public let width: Double
    // 高度。
    public let height: Double
    // 是否可见。
    public let isVisible: Bool
    // 允许动作。
    public let actions: [String]

    // 对外构造。
    public init(
        id: String,
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

// 整体 snapshot。
public struct DebugSnapshot: Codable, Sendable {
    // 时间戳。
    public let timestamp: String
    // 业务状态，使用结构化 JSON 值承载。
    public let appState: [String: String]
    // 节点总数。
    public let nodeCount: Int
    // 所有节点。
    public let nodes: [DebugNodeSnapshot]
    // 所有 intent 名。
    public let actionNames: [String]

    // 对外构造。
    public init(
        timestamp: String,
        appState: [String: String],
        nodeCount: Int,
        nodes: [DebugNodeSnapshot],
        actionNames: [String]
    ) {
        self.timestamp = timestamp
        self.appState = appState
        self.nodeCount = nodeCount
        self.nodes = nodes
        self.actionNames = actionNames
    }
}

// 外部动作请求。
public struct DebugActionRequest: Codable, Sendable {
    // 请求类型：intent / node。
    public let type: String
    // intent 名。
    public let name: String?
    // 节点 id。
    public let id: String?
    // 节点动作名。
    public let action: String?

    // 对外构造。
    public init(type: String, name: String? = nil, id: String? = nil, action: String? = nil) {
        self.type = type
        self.name = name
        self.id = id
        self.action = action
    }
}

// 动作响应。
public struct DebugActionResponse: Codable, Sendable {
    // 是否成功。
    public let ok: Bool
    // 说明文本。
    public let message: String

    // 对外构造。
    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }

    // 成功快捷构造。
    public static func ok(_ message: String) -> Self {
        Self(ok: true, message: message)
    }

    // 失败快捷构造。
    public static func fail(_ message: String) -> Self {
        Self(ok: false, message: message)
    }
}
