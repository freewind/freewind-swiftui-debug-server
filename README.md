# FreewindSwiftUIDebugServer

给 `SwiftUI macOS` 应用提供一套最小 `debug bridge`：

- 收集显式标记节点的 `id / role / label / frame / visible / actions`
- 通过本地 `HTTP server` 暴露 `snapshot`
- 通过 `action` 接口回调到你自己的业务入口

## 适用边界

- 只适合 `DEBUG` / 本机开发
- 只暴露“显式标过的关键节点”
- 不试图自动扒出全部 SwiftUI 私有 view tree

## 你在业务代码里主要多写什么

1. 顶层持有一个 `DebugBridge`
2. 根 view 注入 `.environment(bridge.registry)`
3. 关键组件加 `.debugNode(...)`
4. 启动时注册可被外部调用的动作

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
- `POST /action`

`POST /action` body:

```json
{"type":"node","id":"increment_button","action":"press"}
```

或：

```json
{"type":"intent","name":"increment_counter"}
```
