import AVFoundation
import Foundation

/// Transcodes a full-resolution MOV to a 720p MP4 preview using AVAssetExportSession.
///
/// The 720p preview is what gets shared, uploaded to CloudKit, and used for
/// audio fingerprinting. The original MOV stays on device for full-quality edits.
public enum VideoTranscoder {

    // MARK: - Errors

    public struct TranscodeError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - Public API

    /// Transcode `inputURL` to a 720p H.264 MP4 in the system temporary directory.
    ///
    /// - Parameter progress: Optional callback (on an arbitrary thread) with 0.0…1.0 progress.
    /// - Returns: URL of the transcoded MP4.
    public static func transcode(
        inputURL: URL,
        outputURL: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        // Duration check — catch bad input early
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else {
            throw TranscodeError(message: "Input video has zero duration: \(inputURL.lastPathComponent)")
        }

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ) else {
            throw TranscodeError(message: "AVAssetExportSession unavailable for preset 1280×720 — device may not support this preset")
        }

        let outURL = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        session.outputURL                 = outURL
        session.outputFileType            = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Poll progress while export runs
        let progressTask = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        await session.export()
        progress?(1.0)

        if let error = session.error { throw error }
        guard session.status == .completed else {
            throw TranscodeError(message: "Export ended with status \(session.status.rawValue)")
        }
        return outURL
    }

    // MARK: - Convenience: extract audio for fingerprinting

    /// Export only the audio track as an AAC M4A file (faster than full video transcode,
    /// used by AudioSyncKit when the video preview isn't needed yet).
    public static func extractAudio(
        inputURL: URL,
        outputURL: URL? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscodeError(message: "AVAssetExportSession unavailable for audio export")
        }

        let outURL = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        session.outputURL      = outURL
        session.outputFileType = .m4a

        await session.export()

        if let error = session.error { throw error }
        guard session.status == .completed else {
            throw TranscodeError(message: "Audio export ended with status \(session.status.rawValue)")
        }
        return outURL
    }
}
