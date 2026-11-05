import Foundation
import Network
import CoreMedia

/// Receives touch / Pencil / key events from TouchRecordKit, keeps the iPad↔Mac clocks in sync,
/// and while recording writes them to a `.touches.json` sidecar on the video's timeline.
final class TouchServer {
    struct Status { var connected = false; var device = ""; var app = ""; var rttMs: Double = 0 }
    static let serviceType = "_touchrecordkit._tcp"

    /// Delivered on main.
    var onStatus: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "rec.touch")
    private var listener: NWListener?
    private var conn: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var pingID = 0
    private var hello: [String: Any]?
    /// Clock sync samples: offset = iPadUptime − macHostTime.
    private var samples: [(rtt: Double, offset: Double)] = []
    private var sink: SidecarWriter?

    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start() { queue.async { self.listen() } }

    private func listen() {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        guard let l = try? NWListener(using: params) else { return }
        l.service = NWListener.Service(type: Self.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.listener?.cancel(); self?.listener = nil
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.listen() }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel() // newest client wins
        conn = c
        buffer.removeAll(); samples.removeAll(); hello = nil
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.startPinging()
                self.receive(c)
            case .failed, .cancelled:
                guard self.conn === c else { return }
                self.conn = nil
                self.pingTimer?.cancel(); self.pingTimer = nil
                self.post(Status())
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func startPinging() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.25)
        t.setEventHandler { [weak self] in self?.ping() }
        pingTimer = t
        t.resume()
    }

    private func ping() {
        pingID += 1
        send(["type": "ping", "id": pingID, "t": Self.hostNow()])
    }

    private func send(_ msg: [String: Any]) {
        guard let c = conn, var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(0x0A)
        c.send(content: d, completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if done || err != nil { c.cancel(); return }
            self.receive(c)
        }
    }

    private func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(msg) }
        }
    }

    /// Best estimate: the sample with the lowest round trip among the recent ones (NTP-style).
    private var bestSync: (rtt: Double, offset: Double)? { samples.min { $0.rtt < $1.rtt } }

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "pong":
            guard let t1 = msg["t"] as? Double, let u = msg["u"] as? Double else { return }
            let t3 = Self.hostNow()
            samples.append((t3 - t1, u - (t1 + t3) / 2))
            if samples.count > 40 { samples.removeFirst() }
            if pingID % 4 == 0 || samples.count < 3 { postCurrent() }
        case "hello":
            hello = msg
            postCurrent()
            record(msg)
        default:
            record(msg)
        }
    }

    private func record(_ msg: [String: Any]) {
        guard let sink, let sync = bestSync, let t = msg["t"] as? Double else { return }
        var m = msg
        m["t"] = ((t - sync.offset) - sink.t0Host).rounded(toPlaces: 6)
        if sink.device == nil, let hello { sink.device = hello }
        sink.write(m)
    }

    private func postCurrent() {
        var s = Status()
        s.connected = conn != nil
        s.device = hello?["device"] as? String ?? "iPad"
        s.app = hello?["app"] as? String ?? ""
        s.rttMs = (bestSync?.rtt ?? 0) * 1000
        post(s)
    }

    private func post(_ s: Status) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
    }

    // MARK: Recording

    /// `t0Host`: host-clock seconds of video frame 0.
    func beginRecording(url: URL, t0Host: Double, video: [String: Any]) {
        queue.async { self.sink = SidecarWriter(url: url, t0Host: t0Host, video: video, device: self.hello) }
    }

    func endRecording() {
        queue.async {
            guard let sink = self.sink else { return }
            self.sink = nil
            sink.finish(syncRttMs: (self.bestSync?.rtt ?? 0) * 1000)
        }
    }
}

/// Streams `{ header..., "events": [ ... ] }`. The file is only created once an event arrives,
/// so recordings without a connected app don't get an empty sidecar.
final class SidecarWriter {
    let url: URL
    let t0Host: Double
    let video: [String: Any]
    var device: [String: Any]?
    private var handle: FileHandle?
    private var count = 0

    init(url: URL, t0Host: Double, video: [String: Any], device: [String: Any]?) {
        self.url = url; self.t0Host = t0Host; self.video = video; self.device = device
    }

    func write(_ event: [String: Any]) {
        if handle == nil {
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: url) else { return }
            handle = h
            var header: [String: Any] = ["format": "touchrecordkit", "version": 1, "video": video,
                                         "coordinates": "normalized screen, origin top-left",
                                         "time": "seconds from video frame 0"]
            if let device { header["device"] = device }
            let data = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{}".utf8)
            // Re-open the header object to append the events array.
            h.write(data.dropLast())
            h.write(Data(",\n\"events\":[\n".utf8))
        }
        guard let handle, let d = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        if count > 0 { handle.write(Data(",\n".utf8)) }
        handle.write(d)
        count += 1
    }

    func finish(syncRttMs: Double) {
        guard let handle else { return }
        write(["type": "end", "t": max(0, TouchServer.hostNow() - t0Host), "syncRttMs": syncRttMs])
        handle.write(Data("\n]}\n".utf8))
        try? handle.close()
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m }
}
