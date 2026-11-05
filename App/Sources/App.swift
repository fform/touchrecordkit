import SwiftUI
import AVFoundation

@main
struct TouchRecordApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("TouchRecordKit") {
            ContentView().environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
    }
}

@MainActor
final class Model: ObservableObject {
    let engine = CaptureEngine()
    let touchServer = TouchServer()

    @Published var ipads: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []
    @Published var ipadID: String? { didSet { if ipadID != oldValue { reconfigure() } } }
    @Published var micID: String? { didSet { if micID != oldValue { reconfigure() } } }

    @Published var channelEnabled: [Bool] = [] { didSet { engine.setMicSelection(channelEnabled) } }
    @Published var levels: [Float] = []
    @Published var includeIPadAudio = false { didSet { engine.setIncludeIPadAudio(includeIPadAudio) } }
    @Published var fps: Int32 = 60
    @Published var recordTouches = true

    // Alignment helper: last frame of the previous take, drawn over the preview only (never recorded).
    @Published var ghostEnabled = false { didSet { if ghostEnabled && !oldValue { loadGhost() } } }
    @Published var ghostOpacity = 0.5
    @Published var ghostImage: CGImage?
    @Published var ghostSource: String?
    @Published var touchStatus = TouchServer.Status()

    @Published var isRecording = false
    @Published var startedAt: Date?
    @Published var lastFile: URL?
    @Published var status = "Connect an iPad by USB, unlock it and tap Trust."

    private var observers: [NSObjectProtocol] = []

    init() {
        ScreenCaptureDevices.enable()
        touchServer.onStatus = { [weak self] s in Task { @MainActor in self?.touchStatus = s } }
        touchServer.start()
        engine.onMicLevels = { [weak self] peaks in
            Task { @MainActor in self?.levels = peaks }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            })
        }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshDevices()
        }
    }

    func refreshDevices() {
        let ext = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified).devices
        ipads = ext.filter { $0.hasMediaType(.muxed) }

        var seen = Set<String>()
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                position: .unspecified).devices
            .filter { !$0.hasMediaType(.muxed) && seen.insert($0.uniqueID).inserted }

        if ipadID == nil || !ipads.contains(where: { $0.uniqueID == ipadID }) { ipadID = ipads.first?.uniqueID }
        if let micID, !mics.contains(where: { $0.uniqueID == micID }) { self.micID = nil }
        if ipads.isEmpty { status = "No iPad found. Connect by USB, unlock it, tap Trust (can take a few seconds)." }
        else { status = "Ready" }
    }

    private func reconfigure() {
        guard !isRecording else { return }
        let ipad = ipads.first { $0.uniqueID == ipadID }
        let mic = mics.first { $0.uniqueID == micID }
        let n = mic.map(CaptureEngine.channelCount) ?? 0
        channelEnabled = (0..<n).map { $0 == 0 }
        levels = Array(repeating: 0, count: n)
        engine.configure(ipad: ipad, mic: mic)
    }

    static var recordingsFolder: URL { FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0] }

    static func latestRecording() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("iPad ") && $0.pathExtension.lowercased() == "mp4" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    func loadGhost() {
        guard let url = Self.latestRecording() else {
            ghostImage = nil; ghostSource = "No recordings in Movies yet"; return
        }
        ghostSource = "Loading \(url.lastPathComponent)…"
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceAfter = .zero
                gen.requestedTimeToleranceBefore = .zero
                let t = CMTimeSubtract(duration, CMTime(value: 1, timescale: 60))
                let (image, _) = try await gen.image(at: t)
                ghostImage = image
                ghostSource = url.lastPathComponent
            } catch {
                ghostImage = nil
                ghostSource = "Couldn't read \(url.lastPathComponent)"
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            touchServer.endRecording()
            engine.stop { [weak self] err in
                guard let self else { return }
                self.isRecording = false
                self.startedAt = nil
                self.status = err.map { "Error: \($0.localizedDescription)" } ?? "Saved \(self.lastFile?.lastPathComponent ?? "")"
                if self.ghostEnabled { self.loadGhost() } // the take we just finished is now the reference
            }
        } else {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("iPad \(df.string(from: Date())).mp4")
            engine.start(url: url, fps: fps, withMic: micID != nil) { [weak self] result in
                guard let self else { return }
                let info: RecordingInfo
                switch result {
                case .failure(let err): self.status = "Error: \(err.localizedDescription)"; return
                case .success(let i): info = i
                }
                if self.recordTouches {
                    self.touchServer.beginRecording(
                        url: url.deletingPathExtension().appendingPathExtension("touches.json"),
                        t0Host: info.t0Host,
                        video: ["file": url.lastPathComponent, "width": info.width,
                                "height": info.height, "fps": Int(info.fps)])
                }
                self.lastFile = url
                self.isRecording = true
                self.startedAt = Date()
                self.status = "Recording…"
            }
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(level > 0.9 ? .red : level > 0.5 ? .yellow : .green)
                    .frame(width: g.size.width * CGFloat(min(1, sqrt(level))))
            }
        }
        .frame(height: 6).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                PreviewView(layer: m.engine.previewLayer)
                if m.ghostEnabled, let img = m.ghostImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(m.ghostOpacity)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            controls.frame(width: 280).padding()
        }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("iPad", selection: $m.ipadID) {
                if m.ipads.isEmpty { Text("None found").tag(String?.none) }
                ForEach(m.ipads, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            .disabled(m.isRecording)
            Toggle("Include iPad audio (separate track)", isOn: $m.includeIPadAudio)

            Divider()
            Picker("Audio in", selection: $m.micID) {
                Text("None").tag(String?.none)
                ForEach(m.mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            .disabled(m.isRecording)
            if !m.channelEnabled.isEmpty {
                Text("Inputs to record (mixed to mono, both L/R)").font(.caption).foregroundStyle(.secondary)
                ForEach(m.channelEnabled.indices, id: \.self) { i in
                    HStack {
                        Toggle("Input \(i + 1)", isOn: $m.channelEnabled[i]).frame(width: 90, alignment: .leading)
                        LevelBar(level: i < m.levels.count ? m.levels[i] : 0)
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Circle().fill(m.touchStatus.connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(m.touchStatus.connected
                     ? "Touch data: \(m.touchStatus.app.isEmpty ? m.touchStatus.device : m.touchStatus.app)"
                     : "Touch data: no app connected")
                    .font(.callout).lineLimit(1)
            }
            if m.touchStatus.connected {
                Text(String(format: "Clock sync ±%.1f ms", m.touchStatus.rttMs / 2))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Save touches/keys (.touches.json)", isOn: $m.recordTouches)
                .disabled(m.isRecording)

            Divider()
            Toggle("Overlay last frame of previous take", isOn: $m.ghostEnabled)
            if m.ghostEnabled {
                HStack {
                    Slider(value: $m.ghostOpacity, in: 0.1...0.9)
                    Button { m.loadGhost() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reload newest recording")
                }
                if let src = m.ghostSource {
                    Text(src).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Divider()
            Picker("Frame rate", selection: $m.fps) {
                Text("30 fps").tag(Int32(30))
                Text("60 fps").tag(Int32(60))
            }
            .pickerStyle(.segmented)
            .disabled(m.isRecording)

            Spacer()

            if let start = m.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(start))
                    Text(String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60))
                        .font(.system(.title2, design: .monospaced))
                }
            }
            Button(action: m.toggleRecording) {
                Label(m.isRecording ? "Stop" : "Record", systemImage: m.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(m.isRecording ? .red : .accentColor)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)

            Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if let f = m.lastFile, !m.isRecording {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
        }
    }
}
