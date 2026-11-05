import AVFoundation
import CoreImage

/// Constant-frame-rate H.264 writer. Frame n is always stamped n/fps; when the iPad
/// hasn't sent a new frame (static screen) the previous frame is repeated.
final class VideoTrackWriter {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int, height: Int, fps: Int32
    private(set) var nextFrame: Int64 = 0

    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var lastSource: CVPixelBuffer?
    private var lastConformed: CVPixelBuffer?

    init(writer: AVAssetWriter, width: Int, height: Int, fps: Int32) {
        self.width = width; self.height = height; self.fps = fps
        let bitrate = min(max(Double(width * height) * Double(fps) * 0.12, 8_000_000), 60_000_000)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
    }

    /// Append every frame slot up to and including `target`.
    func emit(upTo target: Int64, frame: CVPixelBuffer) {
        guard nextFrame <= target, let buf = conform(frame) else { return }
        while nextFrame <= target {
            guard input.isReadyForMoreMediaData else { return } // retry next tick; timestamps stay on the grid
            if !adaptor.append(buf, withPresentationTime: CMTime(value: nextFrame, timescale: fps)) { return }
            nextFrame += 1
        }
    }

    /// Pass through if the size matches; otherwise (e.g. iPad rotated) aspect-fit onto the fixed canvas.
    private func conform(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(src) == width && CVPixelBufferGetHeight(src) == height { return src }
        if src === lastSource, let lastConformed { return lastConformed }
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let img = CIImage(cvPixelBuffer: src)
        let sw = img.extent.width, sh = img.extent.height
        let s = min(CGFloat(width) / sw, CGFloat(height) / sh)
        let fitted = img
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: (CGFloat(width) - sw * s) / 2,
                                               y: (CGFloat(height) - sh * s) / 2))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let composed = fitted.composited(over: CIImage(color: .black).cropped(to: canvas))
        ci.render(composed, to: out, bounds: canvas, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        lastSource = src; lastConformed = out
        return out
    }
}
