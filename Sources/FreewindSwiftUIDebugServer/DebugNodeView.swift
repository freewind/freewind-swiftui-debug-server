import AppKit
import SwiftUI

// 点击后记一条节点事件。
private struct DebugTapRecorderModifier: ViewModifier {
    let id: String
    let action: String
    let source: String
    let metadata: [String: String]
    @Environment(DebugRegistry.self) private var registry

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded {
                registry.recordNodeEvent(source: source, id: id, action: action, metadata: metadata)
            }
        )
    }
}

// 长按后记一条节点事件。
private struct DebugLongPressRecorderModifier: ViewModifier {
    let id: String
    let action: String
    let source: String
    let minimumDuration: Double
    let metadata: [String: String]
    @Environment(DebugRegistry.self) private var registry

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: minimumDuration).onEnded { _ in
                registry.recordNodeEvent(source: source, id: id, action: action, metadata: metadata)
            }
        )
    }
}

// 任意 Equatable 值变化时记日志。
private struct DebugValueChangeModifier<Value: Equatable>: ViewModifier {
    let id: String
    let value: Value
    let action: String
    let source: String
    let metadata: [String: String]
    let describe: (Value) -> String
    @Environment(DebugRegistry.self) private var registry

    func body(content: Content) -> some View {
        content
            .onChange(of: value) { oldValue, newValue in
                registry.recordValueChange(
                    source: source,
                    id: id,
                    action: action,
                    oldValue: describe(oldValue),
                    newValue: describe(newValue),
                    metadata: metadata
                )
            }
    }
}

// 透明追踪视图，负责回传 frame 与销毁事件。
final class DebugTrackingView: NSView {
    // 当前节点 id。
    var debugNodeID: String?
    // 布局更新回调。
    var onUpdate: ((NSView) -> Void)?
    // 移除回调。
    var onRemove: (() -> Void)?

    // 初始构造。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
    }

    // storyboard 不走这里。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 挂窗后更新。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onUpdate?(self)
    }

    // 布局变化时更新。
    override func layout() {
        super.layout()
        onUpdate?(self)
    }

    // 移除前清理。
    override func removeFromSuperview() {
        onRemove?()
        super.removeFromSuperview()
    }
}

// 通过 NSViewRepresentable 读真实 frame。
struct DebugFrameReporter: NSViewRepresentable {
    // 节点 id。
    let id: String
    // 节点角色。
    let role: String
    // 节点标签。
    let label: String
    // 动作列表。
    let actions: [String]
    // registry。
    let registry: DebugRegistry

    // 创建追踪 view。
    func makeNSView(context: Context) -> DebugTrackingView {
        let view = DebugTrackingView()
        view.debugNodeID = id
        view.onUpdate = { trackedView in
            updateSnapshot(from: trackedView)
        }
        view.onRemove = {
            registry.remove(id: id)
        }
        DispatchQueue.main.async {
            updateSnapshot(from: view)
        }
        return view
    }

    // 刷新追踪 view。
    func updateNSView(_ nsView: DebugTrackingView, context: Context) {
        nsView.debugNodeID = id
        nsView.onUpdate = { trackedView in
            updateSnapshot(from: trackedView)
        }
        nsView.onRemove = {
            registry.remove(id: id)
        }
        DispatchQueue.main.async {
            updateSnapshot(from: nsView)
        }
    }

    // 拆 view 时同步清理。
    static func dismantleNSView(_ nsView: DebugTrackingView, coordinator: ()) {
        nsView.onRemove?()
    }

    // 采集 frame 并写回 registry。
    private func updateSnapshot(from view: NSView) {
        guard let window = view.window else {
            return
        }
        let frame = view.convert(view.bounds, to: nil)
        let windowHeight = window.contentLayoutRect.height
        let topLeftY = windowHeight - frame.maxY
        registry.upsert(
            DebugNodeSnapshot(
                id: id,
                parentID: parentDebugNodeID(from: view.superview),
                role: role,
                label: label,
                x: frame.minX,
                y: topLeftY,
                width: frame.width,
                height: frame.height,
                isVisible: !view.isHidden && view.alphaValue > 0.001,
                actions: actions
            )
        )
    }

    // 沿 superview 找最近的 debug 父节点。
    private func parentDebugNodeID(from view: NSView?) -> String? {
        var current = view
        while let current {
            if let trackingView = current as? DebugTrackingView, trackingView.debugNodeID != id {
                return trackingView.debugNodeID
            }
            current = current.superview
        }
        return nil
    }
}

// 收口成统一 modifier。
public struct DebugNodeModifier: ViewModifier {
    // 节点 id。
    let id: String
    // 角色。
    let role: String
    // 标签。
    let label: String
    // 动作列表。
    let actions: [String]
    // 从环境拿 registry。
    @Environment(DebugRegistry.self) private var registry

    // 在目标 view 后挂透明采集层。
    public func body(content: Content) -> some View {
        content.background(
            DebugFrameReporter(
                id: id,
                role: role,
                label: label,
                actions: actions,
                registry: registry
            )
        )
    }

    // 对外构造。
    public init(id: String, role: String, label: String, actions: [String]) {
        self.id = id
        self.role = role
        self.label = label
        self.actions = actions
    }
}

// 提供简洁埋点入口。
public extension View {
    // 给关键节点挂稳定 debug 信息。
    func debugNode(id: String, role: String, label: String, actions: [String] = []) -> some View {
        modifier(
            DebugNodeModifier(
                id: id,
                role: role,
                label: label,
                actions: actions
            )
        )
    }

    // 记录常见 tap。
    func debugTapAction(
        id: String,
        action: String = "tap",
        source: String = "human",
        metadata: [String: String] = [:]
    ) -> some View {
        modifier(
            DebugTapRecorderModifier(
                id: id,
                action: action,
                source: source,
                metadata: metadata
            )
        )
    }

    // 记录常见 long press。
    func debugLongPressAction(
        id: String,
        action: String = "long_press",
        source: String = "human",
        minimumDuration: Double = 0.5,
        metadata: [String: String] = [:]
    ) -> some View {
        modifier(
            DebugLongPressRecorderModifier(
                id: id,
                action: action,
                source: source,
                minimumDuration: minimumDuration,
                metadata: metadata
            )
        )
    }

    // 记录任意状态变化。
    func debugValueChange<Value: Equatable>(
        id: String,
        value: Value,
        action: String = "change",
        source: String = "human",
        metadata: [String: String] = [:],
        describe: @escaping (Value) -> String = { String(describing: $0) }
    ) -> some View {
        modifier(
            DebugValueChangeModifier(
                id: id,
                value: value,
                action: action,
                source: source,
                metadata: metadata,
                describe: describe
            )
        )
    }
}

public extension Binding {
    // 包装 Binding，适合 Toggle / TextField / Picker / Stepper。
    func debugTracked(
        by registry: DebugRegistry,
        id: String,
        action: String = "change",
        source: String = "human",
        metadata: [String: String] = [:],
        describe: @escaping (Value) -> String = { String(describing: $0) }
    ) -> Binding<Value> {
        let base = self
        return Binding(
            get: {
                base.wrappedValue
            },
            set: { newValue in
                let oldValue = base.wrappedValue
                base.wrappedValue = newValue
                registry.recordValueChange(
                    source: source,
                    id: id,
                    action: action,
                    oldValue: describe(oldValue),
                    newValue: describe(newValue),
                    metadata: metadata
                )
            }
        )
    }
}
