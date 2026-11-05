// TouchRecordKit — streams touches, Apple Pencil, hover and hardware-keyboard events
// to the TouchRecordKit Mac app so they can be redrawn over a screen recording.
//
// The implementation is only compiled into Debug builds (or when the `AlwaysOn` package
// trait is enabled). In Release builds `start()` is an empty function, so you can call it
// unconditionally and nothing ships in your App Store binary: no networking, no swizzling.

#if canImport(UIKit) && (DEBUG || TOUCHRECORDKIT_ENABLED)
import UIKit
import Network

/// Streams touches, Apple Pencil, hover and hardware-keyboard events to the TouchRecordKit Mac app.
///
///     TouchRecordKit.start()   // e.g. in App.init or application(_:didFinishLaunchingWithOptions:)
///
/// Your app's Info.plist needs (only used by builds that include the implementation):
///   NSLocalNetworkUsageDescription  – any string
///   NSBonjourServices               – ["_touchrecordkit._tcp"]
public enum TouchRecordKit {
    /// True when the streaming implementation is compiled into this build.
    public static let isCompiledIn = true

    /// Start streaming. With no host, the Mac app is discovered automatically via Bonjour.
    public static func start(host: String? = nil, port: UInt16 = 0) {
        if Thread.isMainThread { Streamer.shared.start(host: host, port: port) }
        else { DispatchQueue.main.async { Streamer.shared.start(host: host, port: port) } }
    }

    /// True while connected to the Mac app (main thread).
    public static var isConnected: Bool { Streamer.shared.connected }
}

final class Streamer {
    static let shared = Streamer()
    static let serviceType = "_touchrecordkit._tcp"

    private let queue = DispatchQueue(label: "com.fform.touchrecordkit")
    private var started = false

    // queue state
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var manualEndpoint: NWEndpoint?
    private var recvBuffer = Data()
    private var helloMessage: [String: Any] = [:]

    // main-thread state
    private(set) var connected = false
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextID = 1
    private var lastScreenSize: CGSize = .zero

    // MARK: Lifecycle

    func start(host: String?, port: UInt16) {
        guard !started else { return }
        started = true
        swizzleSendEvent()
        let hello = makeHello()
        queue.async { [self] in
            helloMessage = hello
            if let host, port > 0, let p = NWEndpoint.Port(rawValue: port) {
                manualEndpoint = .hostPort(host: NWEndpoint.Host(host), port: p)
                connect(to: manualEndpoint!)
            } else {
                browse()
            }
        }
    }

    private func browse() {
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let r = results.first else { return }
            self.connect(to: r.endpoint)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel(); self?.browser = nil
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.browse() }
            }
        }
        browser = b
        b.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let c = NWConnection(to: endpoint, using: params)
        connection = c
        recvBuffer.removeAll()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.sendRaw(self.helloMessage)
                self.receive(on: c)
                DispatchQueue.main.async { self.connected = true }
            case .failed, .cancelled:
                guard self.connection === c else { return }
                self.connection = nil
                DispatchQueue.main.async { self.connected = false }
                self.queue.asyncAfter(deadline: .now() + 2) { self.reconnect() }
            case .waiting:
                c.cancel()
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func reconnect() {
        guard connection == nil else { return }
        if let manualEndpoint { connect(to: manualEndpoint) }
        else if let r = browser?.browseResults.first { connect(to: r.endpoint) }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.recvBuffer.append(data); self.drainLines() }
            if done || error != nil { c.cancel(); return }
            self.receive(on: c)
        }
    }

    private func drainLines() {
        while let nl = recvBuffer.firstIndex(of: 0x0A) {
            let line = recvBuffer[recvBuffer.startIndex..<nl]
            recvBuffer.removeSubrange(recvBuffer.startIndex...nl)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if msg["type"] as? String == "ping" {
                // Clock sync: echo the Mac's timestamp alongside our uptime (same clock as UIEvent.timestamp).
                sendRaw(["type": "pong", "id": msg["id"] ?? 0, "t": msg["t"] ?? 0,
                         "u": ProcessInfo.processInfo.systemUptime])
            }
        }
    }

    private func sendRaw(_ msg: [String: Any]) {
        guard let c = connection, var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        c.send(content: data, completion: .idempotent)
    }

    /// Called on main.
    private func send(_ msg: [String: Any]) {
        queue.async { self.sendRaw(msg) }
    }

    // MARK: Device info

    private func currentScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }

    private func makeHello() -> [String: Any] {
        let d = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        var msg: [String: Any] = [
            "type": "hello", "protocol": 1,
            "device": d.name, "model": d.model, "system": "\(d.systemName) \(d.systemVersion)",
            "app": info["CFBundleDisplayName"] ?? info["CFBundleName"] ?? "",
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "t": ProcessInfo.processInfo.systemUptime,
        ]
        if let s = currentScreen() {
            lastScreenSize = s.bounds.size
            msg["screen"] = ["w": s.bounds.width, "h": s.bounds.height, "scale": s.scale]
        }
        return msg
    }

    private func checkScreen(_ screen: UIScreen?) {
        guard let screen, screen.bounds.size != lastScreenSize else { return }
        lastScreenSize = screen.bounds.size
        send(["type": "screen", "t": ProcessInfo.processInfo.systemUptime,
              "w": screen.bounds.width, "h": screen.bounds.height, "scale": screen.scale])
    }

    // MARK: Events (main thread)

    func handle(_ event: UIEvent) {
        guard connected else { return }
        if let presses = event as? UIPressesEvent {
            for p in presses.allPresses { handlePress(p) }
            return
        }
        switch event.type {
        case .touches:
            for t in event.allTouches ?? [] {
                checkScreen(t.window?.screen)
                let id = touchID(t)
                switch t.phase {
                case .began:
                    send(touchMessage(t, id: id, phase: "began", type: "touch"))
                case .moved:
                    // Coalesced touches give the full 120/240 Hz Pencil & finger sample rate.
                    let samples = event.coalescedTouches(for: t) ?? [t]
                    for s in (samples.isEmpty ? [t] : samples) {
                        send(touchMessage(s, id: id, phase: "moved", type: "touch", window: t.window))
                    }
                case .ended, .cancelled:
                    send(touchMessage(t, id: id, phase: t.phase == .ended ? "ended" : "cancelled", type: "touch"))
                    touchIDs[ObjectIdentifier(t)] = nil
                default: break
                }
            }
        case .hover:
            for t in event.allTouches ?? [] {
                let id = touchID(t)
                let phase: String
                switch t.phase {
                case .regionEntered: phase = "began"
                case .regionMoved: phase = "moved"
                case .regionExited: phase = "ended"
                default: continue
                }
                send(touchMessage(t, id: id, phase: phase, type: "hover"))
                if phase == "ended" { touchIDs[ObjectIdentifier(t)] = nil }
            }
        default: break
        }
    }

    private func touchID(_ t: UITouch) -> Int {
        let key = ObjectIdentifier(t)
        if let id = touchIDs[key] { return id }
        let id = nextID; nextID += 1
        touchIDs[key] = id
        return id
    }

    private func touchMessage(_ t: UITouch, id: Int, phase: String, type: String, window: UIWindow? = nil) -> [String: Any] {
        let win = window ?? t.window
        var x: CGFloat = 0, y: CGFloat = 0
        if let win {
            let p = win.convert(t.location(in: win), to: win.screen.coordinateSpace)
            x = p.x / win.screen.bounds.width
            y = p.y / win.screen.bounds.height
        }
        var m: [String: Any] = ["type": type, "t": t.timestamp, "id": id, "phase": phase,
                                "kind": kindName(t), "x": x, "y": y]
        switch t.type {
        case .pencil:
            m["force"] = t.force
            m["maxForce"] = t.maximumPossibleForce
            m["altitude"] = t.altitudeAngle
            m["azimuth"] = t.azimuthAngle(in: win)
            if #available(iOS 17.5, *) { m["roll"] = t.rollAngle }
        case .direct:
            if let win { m["radius"] = t.majorRadius / win.screen.bounds.height }
            if t.maximumPossibleForce > 0 { m["force"] = t.force; m["maxForce"] = t.maximumPossibleForce }
        default: break
        }
        return m
    }

    private func kindName(_ t: UITouch) -> String {
        switch t.type {
        case .direct: return "finger"
        case .pencil: return "pencil"
        case .indirectPointer: return "pointer"
        default: return "indirect"
        }
    }

    private func handlePress(_ p: UIPress) {
        guard let key = p.key else { return }
        let phase: String
        switch p.phase {
        case .began: phase = "down"
        case .ended, .cancelled: phase = "up"
        default: return
        }
        send(["type": "key", "t": p.timestamp, "phase": phase, "code": key.keyCode.rawValue,
              "label": Self.label(for: key), "chars": key.charactersIgnoringModifiers,
              "modifiers": Self.modifierNames(key.modifierFlags)])
    }

    static func modifierNames(_ f: UIKeyModifierFlags) -> [String] {
        var out: [String] = []
        if f.contains(.control) { out.append("control") }
        if f.contains(.alternate) { out.append("option") }
        if f.contains(.shift) { out.append("shift") }
        if f.contains(.command) { out.append("cmd") }
        if f.contains(.alphaShift) { out.append("capslock") }
        return out
    }

    static func label(for key: UIKey) -> String {
        switch key.keyCode {
        case .keyboardLeftShift, .keyboardRightShift: return "shift"
        case .keyboardLeftGUI, .keyboardRightGUI: return "cmd"
        case .keyboardLeftAlt, .keyboardRightAlt: return "option"
        case .keyboardLeftControl, .keyboardRightControl: return "control"
        case .keyboardCapsLock: return "capslock"
        case .keyboardReturnOrEnter, .keypadEnter: return "return"
        case .keyboardEscape: return "esc"
        case .keyboardDeleteOrBackspace: return "delete"
        case .keyboardDeleteForward: return "fwddelete"
        case .keyboardTab: return "tab"
        case .keyboardSpacebar: return "space"
        case .keyboardLeftArrow: return "left"
        case .keyboardRightArrow: return "right"
        case .keyboardUpArrow: return "up"
        case .keyboardDownArrow: return "down"
        case .keyboardF1: return "F1"
        case .keyboardF2: return "F2"
        case .keyboardF3: return "F3"
        case .keyboardF4: return "F4"
        case .keyboardF5: return "F5"
        case .keyboardF6: return "F6"
        case .keyboardF7: return "F7"
        case .keyboardF8: return "F8"
        case .keyboardF9: return "F9"
        case .keyboardF10: return "F10"
        case .keyboardF11: return "F11"
        case .keyboardF12: return "F12"
        default:
            let c = key.charactersIgnoringModifiers
            return c.isEmpty ? "key\(key.keyCode.rawValue)" : c.uppercased()
        }
    }

    // MARK: Hook

    private func swizzleSendEvent() {
        let cls: AnyClass = UIApplication.self
        guard let orig = class_getInstanceMethod(cls, #selector(UIApplication.sendEvent(_:))),
              let repl = class_getInstanceMethod(cls, #selector(UIApplication.touchrecordkit_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(orig, repl)
    }
}

extension UIApplication {
    @objc dynamic func touchrecordkit_sendEvent(_ event: UIEvent) {
        Streamer.shared.handle(event)
        touchrecordkit_sendEvent(event) // original implementation (swapped)
    }
}
#else

/// Release build: TouchRecordKit is compiled out. These calls do nothing.
public enum TouchRecordKit {
    public static let isCompiledIn = false
    @inlinable public static func start(host: String? = nil, port: UInt16 = 0) {}
    public static var isConnected: Bool { false }
}

#endif
