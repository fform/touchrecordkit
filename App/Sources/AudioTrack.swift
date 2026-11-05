import AVFoundation

/// Deinterleaved float PCM pulled out of a capture CMSampleBuffer.
struct PCM {
    var channels: [[Float]]
    var frames: Int
    var sampleRate: Double

    init?(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        let ch = Int(asbd.mChannelsPerFrame)
        let n = CMSampleBufferGetNumSamples(sb)
        guard ch > 0, n > 0 else { return nil }

        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)

        func read(_ p: UnsafeRawPointer, _ i: Int) -> Float {
            if isFloat && bits == 32 { return p.load(fromByteOffset: i * 4, as: Float.self) }
            if isFloat && bits == 64 { return Float(p.load(fromByteOffset: i * 8, as: Double.self)) }
            if bits == 16 { return Float(p.load(fromByteOffset: i * 2, as: Int16.self)) / 32768 }
            if bits == 32 { return Float(p.load(fromByteOffset: i * 4, as: Int32.self)) / 2147483648 }
            return 0
        }

        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
        if nonInterleaved {
            for c in 0..<min(ch, abl.count) {
                guard let d = abl[c].mData else { continue }
                for i in 0..<n { out[c][i] = read(d, i) }
            }
        } else if let d = abl.first?.mData {
            for i in 0..<n { for c in 0..<ch { out[c][i] = read(d, i * ch + c) } }
        }
        channels = out
        frames = n
        sampleRate = asbd.mSampleRate
    }

    var peaks: [Float] { channels.map { $0.reduce(0) { max($0, abs($1)) } } }

    /// Sum the selected channels into mono and duplicate to L/R (interleaved).
    func dualMono(selected: [Bool]) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for (c, data) in channels.enumerated() where c < selected.count && selected[c] {
            for i in 0..<frames { out[i * 2] += data[i] }
        }
        for i in 0..<frames { out[i * 2 + 1] = out[i * 2] }
        return out
    }

    /// Channels 0/1 straight to L/R (mono sources duplicated).
    func stereo() -> [Float] {
        let l = channels[0], r = channels.count > 1 ? channels[1] : channels[0]
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { out[i * 2] = l[i]; out[i * 2 + 1] = r[i] }
        return out
    }
}

/// Writes stereo audio to one AAC track with continuous, gap-free timestamps that start at 0.
/// Incoming timestamps are only used to align with video (pad / trim when drift exceeds 40 ms).
final class AudioTrackWriter {
    let input: AVAssetWriterInput
    private var framesWritten: Int64 = 0
    private var sampleRate: Double = 48000
    private var started = false

    init(writer: AVAssetWriter) {
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    /// `relativeTime` = capture PTS minus recording start, in seconds.
    func append(interleavedStereo samplesIn: [Float], sampleRate sr: Double, relativeTime: Double) {
        var samples = samplesIn
        if !started { sampleRate = sr }
        let expected = Double(framesWritten) / sampleRate
        let drift = relativeTime - expected
        if !started || abs(drift) > 0.04 {
            started = true
            if drift > 0 {
                let pad = Int((drift * sampleRate).rounded())
                samples = [Float](repeating: 0, count: pad * 2) + samples
            } else if drift < 0 {
                let drop = Int((-drift * sampleRate).rounded())
                if drop * 2 >= samples.count { return }
                samples.removeFirst(drop * 2)
            }
        }
        let frames = samples.count / 2
        guard frames > 0, input.isReadyForMoreMediaData,
              let sb = makeSampleBuffer(samples, frames: frames,
                                        pts: CMTime(value: framesWritten, timescale: CMTimeScale(sampleRate)))
        else { return }
        if input.append(sb) { framesWritten += Int64(frames) }
    }

    private func makeSampleBuffer(_ samples: [Float], frames: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        let len = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: len) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
