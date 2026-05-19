# FreewindSwiftUIDebugServer

给 `SwiftUI macOS` 应用提供一套最小 `debug bridge`：

- 收集显式标记节点的 `id / role / label / frame / visible / actions`
- 通过本地 `HTTP server` 暴露 `snapshot`
- 记录最近 `human / ai / system` 操作事件
- 通过 `action` 接口回调到你自己的业务入口

## 适用边界

- 只适合 `DEBUG` / 本机开发
- 只暴露“显式标过的关键节点”
- 不试图自动扒出全部 SwiftUI 私有 view tree

## 你在业务代码里主要多写什么

1. 顶层持有一个 `DebugBridge`
2. 根 view 注入 `.environment(bridge.registry)`
3. 关键组件加 `.debugNode(...)`
4. 常见人类交互尽量经 `.debugTapAction(...)` / `.debugValueChange(...)` / `Binding.debugTracked(...)`
5. 启动时注册可被外部调用的动作

## 最小接入示例

```swift
import SwiftUI
import FreewindSwiftUIDebugServer

@Observable
@MainActor
final class DemoStore {
    var counter = 0

    func increment() {
        counter += 1
    }

    func debugState() -> [String: String] {
        ["counter": "\(counter)"]
    }
}

@Observable
@MainActor
final class DemoShell {
    let store = DemoStore()
    let debugBridge = DebugBridge()

    func start() {
        debugBridge.registerIntent(name: "increment_counter") { [store] in
            store.increment()
            return .ok("Counter incremented")
        }

        debugBridge.start(
            port: 7878,
            appState: { [store] in
                store.debugState()
            }
        )
    }
}

struct ContentView: View {
    @Environment(DemoShell.self) private var shell
    @Environment(DebugRegistry.self) private var registry

    var body: some View {
        Button("Increment") {
            shell.store.increment()
        }
        .debugNode(
            id: "increment_button",
            role: "button",
            label: "Increment button",
            actions: ["press"]
        )
        .debugTapAction(id: "increment_button", action: "tap")
        .onAppear {
            shell.debugBridge.registerNodeAction(id: "increment_button", action: "press") { [store = shell.store] in
                store.increment()
                return .ok("Pressed increment")
            }
        }
    }
}
```

## 接口

- `GET /snapshot`
- `POST /snapshot/query`
- `GET /events`
- `POST /action`

`POST /action` body:

```json
{"type":"node","id":"increment_button","action":"press","source":"ai","metadata":{"task":"increment"}}
```

或：

```json
{"type":"intent","name":"increment_counter","source":"ai"}
```

`POST /snapshot/query` body，适合省 token 拉取：

```json
{
  "includeNodes": true,
  "includeAppState": true,
  "appStateKeys": ["counter"],
  "nodeIDs": ["increment_button"],
  "includeAncestors": true,
  "nodeFields": ["role", "label", "x", "y", "width", "height", "actions"],
  "limit": 20
}
```

常用能力：

- `nodeIDs`: 指定 1 个或多个组件
- `roles`: 按角色筛
- `visibleOnly`: 只拿可见节点
- `includeAncestors + ancestorDepth`: 沿 `parentID` 往上拿到顶或限定层数
- `rect`: 按坐标范围拿节点
- `nodeFields`: 只投影需要字段，避免把 AI 撑爆
- `appStateKeys`: 只拿部分状态

`GET /events` 支持轮询增量：

```text
/events?after=12&limit=20&source=human,ai&id=increment_button
```

返回里每条事件都有：

- `sequence`: 单调递增游标
- `source`: `human / ai / system`
- `kind`: `node / intent / custom`
- `id / action / name`
- `ok / message`
- `metadata`

业务代码可在真实用户点击/拖动后显式记一条：

```swift
shell.debugBridge.recordEvent(
    source: "human",
    kind: "node",
    id: "increment_button",
    action: "press",
    message: "User pressed increment"
)
```

经 `POST /action` 触发的操作会自动记事件；未显式传 `source` 时默认记成 `ai`。

## 常见交互记录

高频做法：

- `Button` / 普通点击：`.debugTapAction(id: "save_button")`
- 长按：`.debugLongPressAction(id: "card_1")`
- 任意值变化：`.debugValueChange(id: "counter_text", value: store.counter, action: "counter_change")`
- `Toggle` / `TextField` / `Picker` / `Stepper` 这类 `Binding` 控件：`$value.debugTracked(by: registry, id: "username_field", action: "edit")`
- 手写 closure：`registry.wrapNodeAction(id: "save_button", action: "press") { save() }`

`Binding.debugTracked(...)` 示例：

```swift
@Environment(DebugRegistry.self) private var registry

Toggle(
    "Enabled",
    isOn: $store.enabled.debugTracked(
        by: registry,
        id: "enabled_toggle",
        action: "toggle"
    )
)

TextField(
    "Username",
    text: $store.username.debugTracked(
        by: registry,
        id: "username_field",
        action: "input"
    )
)
```

closure 包装示例：

```swift
Button(
    "Save",
    action: registry.wrapNodeAction(
        id: "save_button",
        action: "press"
    ) {
        shell.save()
    }
)
```

这层目的：尽量把常见 human 行为收口成统一事件，AI 先看 `/events`，再按需补抓最小 `snapshot/query`。
