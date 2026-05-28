import Foundation
import Observation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@Observable
@MainActor
public final class DebugBridge {
    public let registry = DebugRegistry()
    public let appName: String
    public let buildVersion: Int
    public let consoleTitle: String?
    public let host: String

    private var httpBridge: DebugHTTPBridge?
    #if canImport(AppKit)
    private var willTerminateObserver: NSObjectProtocol?
    #endif
    public private(set) var port: UInt16?
    public private(set) var statusMessage: String = "Not started"

    public init(
        appName: String = "App",
        buildVersion: Int = debugBundleBuildVersion(),
        consoleTitle: String? = nil,
        host: String = "127.0.0.1"
    ) {
        self.appName = appName
        self.buildVersion = buildVersion
        self.consoleTitle = consoleTitle
        self.host = host
    }

    @discardableResult
    public func registerIntent(
        name: String,
        args: [String] = [],
        perform: @escaping @MainActor (DebugActionRequest) -> DebugActionResponse
    ) -> DebugRegistry.RegistrationToken {
        registry.registerIntent(name: name, args: args, perform: perform)
    }

    @discardableResult
    public func registerNodeAction(
        id: String,
        action: String,
        args: [String] = [],
        perform: @escaping @MainActor (DebugActionRequest) -> DebugActionResponse
    ) -> DebugRegistry.RegistrationToken {
        registry.registerNodeAction(id: id, action: action, args: args, perform: perform)
    }

    public func unregisterIntent(name: String) {
        registry.unregisterIntent(name: name)
    }

    public func unregisterNodeAction(id: String, action: String) {
        registry.unregisterNodeAction(id: id, action: action)
    }

    public func publishTargetState(id: String, state: [String: String]) {
        registry.publishTargetState(id: id, state: state)
    }

    public func clearTargetState(id: String) {
        registry.clearTargetState(id: id)
    }

    public func start(
        port: UInt16,
        screenName: @escaping @MainActor () -> String = { "MainScreen" },
        appState: @escaping @MainActor () -> [String: String]
    ) {
        stop()
        self.port = port
        installLifecycleHooks()

        httpBridge = DebugHTTPBridge(
            port: port,
            getMeta: { [weak self] in
                await MainActor.run {
                    guard let self else {
                        return DebugMetaResponse(appName: "Unknown", buildVersion: 0)
                    }
                    return self.meta()
                }
            },
            getHelp: { [weak self] in
                await MainActor.run {
                    guard let self else {
                        return DebugHelpResponse(
                            appName: "Unknown",
                            consoleTitle: nil,
                            screenName: "Unknown",
                            serverTime: debugTimestampString(),
                            capabilities: [],
                            counts: DebugHelpCounts(
                                actionTargetCount: 0,
                                logCount: 0,
                                stateKeyCount: 0,
                                snapshotNodeCount: 0
                            ),
                            endpoints: [],
                            examples: []
                        )
                    }
                    let context = self.makeContext(screenName: screenName)
                    return self.registry.help(context: context, appState: appState())
                }
            },
            getActionCatalog: { [weak self] query in
                await MainActor.run {
                    guard let self else {
                        return DebugActionCatalogResponse(
                            summary: DebugActionCatalogSummary(targetCount: 0, actionCount: 0),
                            items: []
                        )
                    }
                    return self.registry.actionCatalog(
                        context: self.makeContext(screenName: screenName),
                        query: query
                    )
                }
            },
            getLogs: { [weak self] query in
                await MainActor.run {
                    guard let self else {
                        return DebugLogsResponse(summary: nil, items: [], nextAfterSeq: 0)
                    }
                    return self.registry.logs(query: query)
                }
            },
            clearLogs: { [weak self] in
                await MainActor.run {
                    guard let self else {
                        return DebugLogsClearResponse(
                            accepted: false,
                            message: "DebugBridge deallocated",
                            clearedCount: 0
                        )
                    }
                    return self.registry.clearLogs()
                }
            },
            getState: { [weak self] query in
                await MainActor.run {
                    guard let self else {
                        return DebugStateResponse(summary: nil, appState: [:], targetState: nil)
                    }
                    return self.registry.state(appState: appState(), query: query)
                }
            },
            getSnapshot: { [weak self] query in
                await MainActor.run {
                    guard let self else {
                        return DebugSnapshotResponse(summary: nil, fieldCatalog: nil, examples: nil, screen: "Unknown", nodes: [])
                    }
                    return self.registry.snapshot(
                        context: self.makeContext(screenName: screenName),
                        query: query
                    )
                }
            },
            performAction: { [weak self] request in
                await MainActor.run {
                    guard let self else {
                        return DebugActionResponse.fail("DebugBridge deallocated")
                    }
                    return self.registry.perform(request: request)
                }
            }
        )

        do {
            try httpBridge?.start()
            statusMessage = "Listening at http://\(host):\(port)"
        } catch {
            statusMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    public func stop() {
        httpBridge?.stop()
        httpBridge = nil
        removeLifecycleHooks()
        port = nil
        statusMessage = "Not started"
    }

    private func meta() -> DebugMetaResponse {
        DebugMetaResponse(appName: appName, buildVersion: buildVersion)
    }

    private func installLifecycleHooks() {
        #if canImport(AppKit)
        guard willTerminateObserver == nil else {
            return
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
        #endif
    }

    private func removeLifecycleHooks() {
        #if canImport(AppKit)
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
            self.willTerminateObserver = nil
        }
        #endif
    }

    public func log(
        event: String,
        level: String = "info",
        source: String = "system",
        targetId: String? = nil,
        summary: String,
        data: [String: String] = [:]
    ) {
        registry.log(
            event: event,
            level: level,
            source: source,
            targetId: targetId,
            summary: summary,
            data: data
        )
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
        registry.recordEvent(
            source: source,
            kind: kind,
            name: name,
            id: id,
            action: action,
            ok: ok,
            message: message,
            metadata: metadata
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
        registry.recordNodeEvent(
            source: source,
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
        registry.recordValueChange(
            source: source,
            id: id,
            action: action,
            oldValue: oldValue,
            newValue: newValue,
            message: message,
            metadata: metadata
        )
    }

    public func wrapNodeAction(
        source: String = "human",
        id: String,
        action: String,
        metadata: [String: String] = [:],
        perform: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        registry.wrapNodeAction(
            source: source,
            id: id,
            action: action,
            metadata: metadata,
            perform: perform
        )
    }

    public func wrapNodeAction(
        source: String = "human",
        id: String,
        action: String,
        metadata: [String: String] = [:],
        perform: @escaping @MainActor () -> DebugActionResponse
    ) -> @MainActor () -> DebugActionResponse {
        registry.wrapNodeAction(
            source: source,
            id: id,
            action: action,
            metadata: metadata,
            perform: perform
        )
    }

    public func tracked<Value>(
        _ binding: Binding<Value>,
        id: String,
        action: String = "change",
        source: String = "human",
        metadata: [String: String] = [:],
        describe: @escaping @Sendable (Value) -> String = { String(describing: $0) }
    ) -> Binding<Value> {
        binding.debugTracked(
            by: registry,
            id: id,
            action: action,
            source: source,
            metadata: metadata,
            describe: describe
        )
    }

    private func makeContext(screenName: @escaping @MainActor () -> String) -> DebugBridgeContext {
        DebugBridgeContext(
            appName: appName,
            consoleTitle: consoleTitle,
            screenName: screenName()
        )
    }
}
