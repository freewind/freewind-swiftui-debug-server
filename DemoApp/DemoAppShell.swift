import FreewindSwiftUIDebugServer
import Observation

@Observable
@MainActor
final class DemoAppShell {
    let debugBridge = DebugBridge()
    var counter = 0
    private var didStart = false

    func startIfNeeded() {
        guard !didStart else {
            return
        }
        didStart = true

        debugBridge.registerIntent(name: "increment_counter") { [weak self] in
            guard let self else {
                return .fail("DemoAppShell released")
            }
            increment()
            return .ok("Counter incremented")
        }

        debugBridge.registerNodeAction(id: "increment_button", action: "press") { [weak self] in
            guard let self else {
                return .fail("DemoAppShell released")
            }
            increment()
            return .ok("Pressed increment button")
        }

        debugBridge.start(port: 7879) { [weak self] in
            guard let self else {
                return [:]
            }
            return [
                "counter": "\(counter)",
                "debugStatus": debugBridge.statusMessage,
            ]
        }
    }

    func increment() {
        counter += 1
    }
}
