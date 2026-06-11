import AVFoundation
import Foundation

/// Receives sample buffers from AVCapture outputs and writes them to a MOV file.
///
/// Thread-safety: `appendVideo` and `appendAudio` may be called from any thread
/// (AVCapture delivers them on dedicated serial queues). `start`, `finish` are
/// called from the `CaptureSession` actor.
final class VideoWriter: @unchecked Sendable {

    // MARK: - Video / audio codec settings

    static let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey:  1920,
        AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey:  8_000_000,   // 8 Mbps — sufficient for concert footage
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 60,
        ] as [String: Any],
    ]

    static let audioSettings: [String: Any] = [
        AVFormatIDKey:             kAudioFormatMPEG4AAC,
        AVSampleRateKey:           44_100,
        AVNumberOfChannelsKey:     2,
        AVEncoderBitRateKey:       192_000,
    ]

    // MARK: - State

    let outputURL: URL
    private let assetWriter: AVAssetWriter
    private let videoInput:  AVAssetWriterInput
    private let audioInput:  AVAssetWriterInput

    private var sessionStarted    = false
    private var firstVideoTime:    CMTime?

    // MARK: - Init

    init(outputURL: URL? = nil) throws {
        let url = outputURL ?? FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        self.outputURL  = url
        self.assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)

        self.videoInput = AVAssetWriterInput(mediaType: .video,
                                             outputSettings: Self.videoSettings)
        self.videoInput.expectsMediaDataInRealTime = true

        self.audioInput = AVAssetWriterInput(mediaType: .audio,
                                             outputSettings: Self.audioSettings)
        self.audioInput.expectsMediaDataInRealTime = true

        assetWriter.add(videoInput)
        assetWriter.add(audioInput)
    }

    // MARK: - Recording lifecycle

    /// Call before appending the first sample buffer.
    func start() {
        guard assetWriter.startWriting() else { return }
        sessionStarted = true
    }

    /// Append a video sample buffer. Starts the AVAssetWriter session on the first call.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstVideoTime == nil {
            assetWriter.startSession(atSourceTime: pts)
            firstVideoTime = pts
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, firstVideoTime != nil else { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Stop the write session and flush to disk.
    func finish() async throws -> URL {
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        return try await withCheckedThrowingContinuation { continuation in
            assetWriter.finishWriting {
                if self.assetWriter.status == .completed {
                    continuation.resume(returning: self.outputURL)
                } else {
                    continuation.resume(throwing: self.assetWriter.error
                        ?? CaptureError.writerFailed("Unknown write error"))
                }
            }
        }
    }
}
