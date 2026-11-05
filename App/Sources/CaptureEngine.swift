import AVFoundation
import CoreMediaIO

enum ScreenCaptureDevices {
    /// The same switch QuickTime flips: exposes USB-connected iOS/iPadOS screens as AVCaptureDevices.
    static func enable() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }
}

struct RecordingInfo {
    /// Host-clock seconds (mach time) of video frame 0 — used to put touch events on the video timeline.
    var t0Host: Double
    var width: Int, height: Int, fps: Int32
}

enum RecError: LocalizedError {
    case noVideo, writer(String)
    var errorDescription: String? {
        switch self {
        case .noVideo: return "No iPad video yet — select an iPad and wait for the preview."
        case .writer(let s): return s
        }
    }
}

private final class Recording {
    let writer: AVAssetWriter
    let video: VideoTrackWriter
    let mic: AudioTrackWriter?
    let ipadAudio: AudioTrackWriter?
    let clock: CMClock
    let t0: CMTime
    var timer: DispatchSourceTimer?

    init(writer: AVAssetWriter, video: VideoTrackWriter, mic: AudioTrackWriter?,
         ipadAudio: AudioTrackWriter?, clock: CMClock, t0: CMTime) {
        self.writer = writer; self.video = video; self.mic = mic
        self.ipadAudio = ipadAudio; self.clock = clock; self.t0 = t0
    }

    func relative(_ t: CMTime) -> Double { CMTimeSubtract(t, t0).seconds }
}

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "rec.session")
    private let videoQueue = DispatchQueue(label: "rec.video")
    private let writerQueue = DispatchQueue(label: "rec.writer") // audio callbacks + all writer work

    private let videoOut = AVCaptureVideoDataOutput()
    private let ipadAudioOut = AVCaptureAudioDataOutput()
    private let micAudioOut = AVCaptureAudioDataOutput()

    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?
    private var latestFrame: CVPixelBuffer? {
        get { frameLock.lock(); defer { frameLock.unlock() }; return _latestFrame }
        set { frameLock.lock(); _latestFrame = newValue; frameLock.unlock() }
    }

    // writerQueue state
    private var recording: Recording?
    private var micSelection: [Bool] = []
    private var includeIPadAudio = false
    private var lastLevelPost = CFAbsoluteTimeGetCurrent()

    /// Peak level per interface input (0...1), throttled, delivered on main.
    var onMicLevels: (([Float]) -> Void)?

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        previewLayer.videoGravity = .resizeAspect
        super.init()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.setSampleBufferDelegate(self, queue: videoQueue)
        ipadAudioOut.setSampleBufferDelegate(self, queue: writerQueue)
        micAudioOut.setSampleBufferDelegate(self, queue: writerQueue)
    }

    static func channelCount(of device: AVCaptureDevice) -> Int {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)
        else { return 2 }
        return max(1, Int(asbd.pointee.mChannelsPerFrame))
    }

    private static func floatPCMSettings(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM,
         AVSampleRateKey: 48000,
         AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 32,
         AVLinearPCMIsFloatKey: true,
         AVLinearPCMIsNonInterleaved: true,
         AVLinearPCMIsBigEndianKey: false]
    }

    // MARK: Session

    func configure(ipad: AVCaptureDevice?, mic: AVCaptureDevice?) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            latestFrame = nil

            if let ipad, let input = try? AVCaptureDeviceInput(device: ipad), session.canAddInput(input) {
                session.addInputWithNoConnections(input)
                if let vp = input.ports.first(where: { $0.mediaType == .video }) {
                    session.addOutputWithNoConnections(videoOut)
                    let c = AVCaptureConnection(inputPorts: [vp], output: videoOut)
                    if session.canAddConnection(c) { session.addConnection(c) }
                    let pc = AVCaptureConnection(inputPort: vp, videoPreviewLayer: previewLayer)
                    if session.canAddConnection(pc) { session.addConnection(pc) }
                }
                if let ap = input.ports.first(where: { $0.mediaType == .audio }) {
                    ipadAudioOut.audioSettings = Self.floatPCMSettings(channels: 2)
                    session.addOutputWithNoConnections(ipadAudioOut)
                    let c = AVCaptureConnection(inputPorts: [ap], output: ipadAudioOut)
                    if session.canAddConnection(c) { session.addConnection(c) }
                }
            }

            if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInputWithNoConnections(input)
                if let ap = input.ports.first(where: { $0.mediaType == .audio }) {
                    micAudioOut.audioSettings = Self.floatPCMSettings(channels: Self.channelCount(of: mic))
                    session.addOutputWithNoConnections(micAudioOut)
                    let c = AVCaptureConnection(inputPorts: [ap], output: micAudioOut)
                    if session.canAddConnection(c) { session.addConnection(c) }
                }
            }

            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func setMicSelection(_ sel: [Bool]) { writerQueue.async { self.micSelection = sel } }
    func setIncludeIPadAudio(_ on: Bool) { writerQueue.async { self.includeIPadAudio = on } }

    // MARK: Recording

    func start(url: URL, fps: Int32, withMic: Bool, completion: @escaping (Result<RecordingInfo, Error>) -> Void) {
        writerQueue.async { [self] in
            do {
                guard let frame = latestFrame else { throw RecError.noVideo }
                let w = CVPixelBufferGetWidth(frame) & ~1, h = CVPixelBufferGetHeight(frame) & ~1
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let video = VideoTrackWriter(writer: writer, width: w, height: h, fps: fps)
                let mic = withMic ? AudioTrackWriter(writer: writer) : nil
                let ipadA = includeIPadAudio && session.outputs.contains(ipadAudioOut)
                    ? AudioTrackWriter(writer: writer) : nil
                guard writer.startWriting() else {
                    throw RecError.writer(writer.error?.localizedDescription ?? "Could not start writer")
                }
                writer.startSession(atSourceTime: .zero)

                let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
                let t0 = CMClockGetTime(clock)
                let rec = Recording(writer: writer, video: video, mic: mic, ipadAudio: ipadA,
                                    clock: clock, t0: t0)
                let info = RecordingInfo(t0Host: CMSyncConvertTime(t0, from: clock, to: CMClockGetHostTimeClock()).seconds,
                                         width: w, height: h, fps: fps)
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: writerQueue)
                timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps * 2), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                rec.timer = timer
                recording = rec
                timer.resume()
                DispatchQueue.main.async { completion(.success(info)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func tick() {
        guard let rec = recording, let frame = latestFrame else { return }
        let now = rec.relative(CMClockGetTime(rec.clock))
        rec.video.emit(upTo: Int64((now * Double(rec.video.fps)).rounded(.down)), frame: frame)
    }

    func stop(completion: @escaping (Error?) -> Void) {
        writerQueue.async { [self] in
            guard let rec = recording else { DispatchQueue.main.async { completion(nil) }; return }
            tick()
            rec.timer?.cancel()
            recording = nil
            rec.video.input.markAsFinished()
            rec.mic?.input.markAsFinished()
            rec.ipadAudio?.input.markAsFinished()
            rec.writer.endSession(atSourceTime: CMTime(value: rec.video.nextFrame, timescale: rec.video.fps))
            rec.writer.finishWriting {
                let err = rec.writer.status == .failed ? rec.writer.error : nil
                DispatchQueue.main.async { completion(err) }
            }
        }
    }

    // MARK: Delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOut {
            if let pb = CMSampleBufferGetImageBuffer(sb) { latestFrame = pb }
            return
        }
        // Audio — we're on writerQueue.
        guard let pcm = PCM(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        if output === micAudioOut {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLevelPost > 0.05, let cb = onMicLevels {
                lastLevelPost = now
                let peaks = pcm.peaks
                DispatchQueue.main.async { cb(peaks) }
            }
            if let rec = recording, let w = rec.mic {
                w.append(interleavedStereo: pcm.dualMono(selected: micSelection),
                         sampleRate: pcm.sampleRate, relativeTime: rec.relative(pts))
            }
        } else if output === ipadAudioOut, let rec = recording, let w = rec.ipadAudio {
            w.append(interleavedStereo: pcm.stereo(), sampleRate: pcm.sampleRate, relativeTime: rec.relative(pts))
        }
    }
}
