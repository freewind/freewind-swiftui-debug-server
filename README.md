# FreewindSwiftUIDebugServer

给 `SwiftUI macOS` app 提供一套给 AI 用的本地 debug server。

目标：

- 暴露简单 `HTTP API`
- 导出当前已注册节点的结构化快照
- 导出精简 `appState / targetState`
- 记录结构化 `logs`
- 通过统一 `POST /action` 驱动已注册动作

当前协议已对齐 Android 版的核心心智：

- `GET /help`
- `GET /action`
- `POST /action`
- `GET /logs`
- `DELETE /logs`
- `GET /state`
- `GET /snapshot`

说明：

- `GET /` 的 html console 先保留，暂未实现
- 这是“已注册关键节点”模型，不是自动穷举 SwiftUI 私有 view tree
- 推荐只在 `DEBUG` / 本机开发启用

## 代码侧最小接入

```swift
import SwiftUI
import FreewindSwiftUIDebugServer

@Observable
@MainActor
final class DemoStore {
    var counter = 0
}

@Observable
@MainActor
final class DemoShell {
    let store = DemoStore()
    let debugBridge = DebugBridge(appName: "Demo App")

    func start() {
        debugBridge.registerNodeAction(id: "increment_button", action: "press") { [store] in
            store.counter += 1
            return .ok("accepted")
        }

        debugBridge.registerIntent(name: "increment_counter") { [store] in
            store.counter += 1
            return .ok("accepted")
        }

        debugBridge.start(
            port: 7879,
            screenName: { "DemoScreen" }
        ) { [store, debugBridge] in
            debugBridge.publishTargetState(
                id: "increment_button",
                state: ["count": "\(store.counter)"]
            )
            return [
                "counter": "\(store.counter)",
                "debugStatus": debugBridge.statusMessage,
            ]
        }
    }
}

struct ContentView: View {
    @Environment(DemoShell.self) private var shell

    var body: some View {
        Button(
            "Increment",
            action: shell.debugBridge.wrapNodeAction(
                id: "increment_button",
                action: "press"
            ) {
                shell.store.counter += 1
            }
        )
        .debugNode(
            id: "increment_button",
            role: "button",
            label: "Increment counter button",
            actions: ["press"]
        )
    }
}
```

## endpoint

基址：

```text
http://127.0.0.1:7879
```

### `GET /help`

返回当前能力、字段、示例。

```bash
curl http://127.0.0.1:7879/help
```

返回示例：

```json
{
  "appName": "Demo App",
  "screenName": "DemoScreen",
  "serverTime": "20260519-220000",
  "capabilities": ["action", "logs", "state", "snapshot"],
  "counts": {
    "actionTargetCount": 2,
    "logCount": 0,
    "stateKeyCount": 2,
    "snapshotNodeCount": 5
  }
}
```

### `GET /action`

默认返回可执行目标与动作。

```bash
curl http://127.0.0.1:7879/action
curl "http://127.0.0.1:7879/action?targetId=increment_button"
```

返回示例：

```json
{
  "summary": {
    "targetCount": 2,
    "actionCount": 2
  },
  "items": [
    {
      "targetId": "increment_button",
      "targetType": "Button",
      "screen": "DemoScreen",
      "actions": [
        {
          "name": "press",
          "args": [],
          "summary": "trigger increment_button press",
          "example": {
            "action": "press",
            "targetId": "increment_button"
          }
        }
      ]
    }
  ]
}
```

intent 也收口到这里：

- `targetId = intent name`
- `action = invoke`

### `POST /action`

统一执行入口。

```bash
curl -X POST http://127.0.0.1:7879/action \
  -H 'Content-Type: application/json' \
  -d '{
    "action": "press",
    "targetId": "increment_button"
  }'
```

返回示例：

```json
{
  "accepted": true,
  "message": "Pressed increment button",
  "action": "press",
  "targetId": "increment_button"
}
```

调 intent：

```json
{
  "action": "invoke",
  "targetId": "increment_counter"
}
```

### `GET /logs`

默认返回 summary。

```bash
curl http://127.0.0.1:7879/logs
```

带 query 返回匹配日志：

```bash
curl "http://127.0.0.1:7879/logs?source=ai&targetId=increment_button&limit=10"
```

返回示例：

```json
{
  "items": [
    {
      "seq": 1,
      "time": "20260519-220014",
      "source": "ai",
      "level": "info",
      "event": "press",
      "targetId": "increment_button",
      "summary": "accepted increment_button press",
      "data": {
        "accepted": "true"
      }
    }
  ],
  "nextAfterSeq": 1
}
```

支持 query：

- `event`
- `level`
- `source`
- `targetId`
- `screen`
- `from`
- `to`
- `limit`
- `keyword`

### `DELETE /logs`

清空已有日志。

```bash
curl -X DELETE http://127.0.0.1:7879/logs
```

返回示例：

```json
{
  "accepted": true,
  "message": "cleared 1 logs",
  "clearedCount": 1
}
```

### `GET /state`

默认返回 `appState` key 摘要 + 已挂 targetState 的 target。

```bash
curl http://127.0.0.1:7879/state
curl "http://127.0.0.1:7879/state?keys=counter&scope=app"
curl "http://127.0.0.1:7879/state?targetId=increment_button&scope=target"
```

返回示例：

```json
{
  "appState": {
    "counter": "1"
  }
}
```

支持：

- `keys`
- `targetId`
- `scope=app|target|branch`

### `GET /snapshot`

默认返回 tree summary。

```bash
curl http://127.0.0.1:7879/snapshot
```

带 query 返回 detail：

```bash
curl "http://127.0.0.1:7879/snapshot?targetId=increment_button&scope=self&fields=id,type,text,bounds,clickable"
curl "http://127.0.0.1:7879/snapshot?targetId=increment_button&scope=branchToRoot&fields=id,type,text,bounds"
curl "http://127.0.0.1:7879/snapshot?types=Button&clickable=true&limit=20"
```

返回示例：

```json
{
  "screen": "DemoScreen",
  "nodes": [
    {
      "id": "increment_button",
      "type": "Button",
      "text": "Increment counter button",
      "clickable": true,
      "bounds": {
        "left": 331.5,
        "top": 221,
        "width": 77,
        "height": 20
      }
    }
  ]
}
```

支持：

- `targetId`
- `scope=self|branchToRoot|subtree`
- `depth`
- `types`
- `textKeyword`
- `visible`
- `enabled`
- `clickable`
- `fields`
- `limit`
