import AVFoundation
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The capture side of Instant Replay: one display streamed through a
/// hardware H.264 encoder into fragmented-MP4 segments that never touch the
/// disk until a replay is saved.
///
/// Everything mutable is confined to `queue`, which is also the queue the
/// stream delivers samples on and the writer calls its delegate on.
final class InstantReplayRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVAssetWriterDelegate, @unchecked Sendable {
    struct Settings: Sendable, Equatable {
        var window: TimeInterval
        var includesSystemAudio: Bool
        var pixelSize: CGSize
        static let framesPerSecond: Int32 = 30
        /// Longest edge of the encoded picture. A replay is for "what just
        /// happened", so it trades the last bit of sharpness on a 5K screen
        /// for an encoder that stays cool all day.
        static let maximumEdge: CGFloat = 1920
        /// An unchanged screen still has to produce frames, or the encoder
        /// never reaches the next keyframe and no segment is ever closed.
        static let idleRepeatInterval: TimeInterval = 0.5

        /// The display's pixel size scaled down to `maximumEdge`, in even
        /// numbers as the encoder requires.
        static func encodedSize(forDisplayPixels size: CGSize) -> CGSize {
            guard size.width > 0, size.height > 0 else { return CGSize(width: 1280, height: 720) }
            let scale = min(1, maximumEdge / max(size.width, size.height))
            func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
            return CGSize(width: even(size.width), height: even(size.height))
        }

        /// About a tenth of a bit per pixel per frame: clean text at rest,
        /// soft only in fast full-screen motion.
        var videoBitRate: Int {
            let bits = Double(pixelSize.width * pixelSize.height) * Double(Self.framesPerSecond) * 0.1
            return Int(min(max(bits, 3_000_000), 8_000_000))
        }
    }

    enum RecorderError: LocalizedError {
        case notRunning
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "Instant Replay isn't running."
            case .writerFailed(let reason): "Instant Replay stopped: \(reason)"
            }
        }
    }

    /// The stream or the encoder stopped without being asked to. Called on
    /// the recorder's queue.
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.notchshot.instant-replay", qos: .userInitiated)
    private let settings: Settings
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var buffer: InstantReplayBuffer
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastVideoTime: CMTime?
    private var isStopping = false
    private var segmentWaiters: [CheckedContinuation<Void, Never>] = []

    init(settings: Settings) {
        self.settings = settings
        buffer = InstantReplayBuffer(window: settings.window)
    }

    func start(filter: SCContentFilter) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(settings.pixelSize.width)
        configuration.height = Int(settings.pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Settings.framesPerSecond)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = settings.includesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.includesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        queue.sync { self.stream = stream }
        try await stream.startCapture()
    }

    func stop() async {
        let stream: SCStream? = queue.sync {
            isStopping = true
            let stream = self.stream
            self.stream = nil
            return stream
        }
        try? await stream?.stopCapture()
        queue.sync {
            writer?.cancelWriting()
            writer = nil
            videoInput = nil
            audioInput = nil
            adaptor = nil
            lastPixelBuffer = nil
            lastVideoTime = nil
            buffer.reset()
            releaseWaiters()
        }
    }

    var bufferedDuration: TimeInterval { queue.sync { buffer.bufferedDuration } }

    /// The buffered stretch as a playable fragmented MP4. With
    /// `includingNewest`, waits up to `timeout` for the segment being encoded
    /// right now, so the moment the user reacted to is in the clip.
    func movieData(includingNewest: Bool, timeout: TimeInterval = 1.6) async -> Data? {
        if includingNewest {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    guard self.writer != nil, !self.isStopping else {
                        continuation.resume()
                        return
                    }
                    self.segmentWaiters.append(continuation)
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.releaseWaiters() }
                }
            }
        }
        return queue.sync { buffer.movieData() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isStopping, sampleBuffer.isValid else { return }
        switch type {
        case .screen: appendVideo(sampleBuffer)
        case .audio: appendAudio(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.isStopping else { return }
            self.isStopping = true
            self.writer?.cancelWriting()
            self.releaseWaiters()
            self.onUnexpectedStop?(error)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let time = sampleBuffer.presentationTimeStamp
        let pixelBuffer: CVPixelBuffer
        if status == .complete, let image = sampleBuffer.imageBuffer {
            pixelBuffer = image
            lastPixelBuffer = image
        } else if status == .idle, let last = lastPixelBuffer, let lastVideoTime,
                  (time - lastVideoTime).seconds >= Settings.idleRepeatInterval {
            pixelBuffer = last
        } else {
            return
        }
        if writer == nil, !startWriter(at: time) { return }
        guard let videoInput, videoInput.isReadyForMoreMediaData, let adaptor else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
        } else {
            failWriter()
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard writer != nil, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(sampleBuffer) { failWriter() }
    }

    /// The writer starts on the first real frame, because a segmented writer
    /// has to know its first timestamp before it starts.
    private func startWriter(at time: CMTime) -> Bool {
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = time
        writer.delegate = self

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(settings.pixelSize.width),
            AVVideoHeightKey: Int(settings.pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitRate,
                // A keyframe every second is what lets segments be about a
                // second long, and so the clip be trimmed that finely.
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Int(Settings.framesPerSecond),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

        var audio: AVAssetWriterInput?
        if settings.includesSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }

        guard writer.startWriting() else {
            report(RecorderError.writerFailed(writer.error?.localizedDescription ?? "the encoder didn't start"))
            return false
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = video
        audioInput = audio
        self.adaptor = adaptor
        return true
    }

    private func failWriter() {
        guard let writer, writer.status == .failed else { return }
        report(RecorderError.writerFailed(writer.error?.localizedDescription ?? "the encoder failed"))
    }

    private func report(_ error: Error) {
        guard !isStopping else { return }
        isStopping = true
        writer?.cancelWriting()
        releaseWaiters()
        onUnexpectedStop?(error)
    }

    private func releaseWaiters() {
        let waiters = segmentWaiters
        segmentWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: AVAssetWriterDelegate

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        let reports = segmentReport?.trackReports ?? []
        let duration = (reports.first { $0.mediaType == .video } ?? reports.first)?.duration.seconds ?? 1
        // AVFoundation doesn't document which queue this arrives on, so the
        // buffer is only ever touched back on `queue`.
        queue.async { [self] in
            guard self.writer === writer else { return }
            switch segmentType {
            case .initialization:
                buffer.setInitialization(segmentData)
            case .separable:
                buffer.append(segmentData, duration: duration)
                releaseWaiters()
            @unknown default:
                break
            }
        }
    }
}
