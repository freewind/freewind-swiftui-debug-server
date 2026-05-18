import AppKit
import SwiftUI

// 透明追踪视图，负责回传 frame 与销毁事件。
final class DebugTrackingView: NSView {
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
}
