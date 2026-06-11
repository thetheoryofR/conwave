import Foundation

/// Metadata for a video clip captured inside the app.
///
/// Produced by `CaptureSession.stopRecording()`. The `previewURL` is initially nil
/// and populated asynchronously once `VideoTranscoder` finishes the 720p encode.
public struct ClipMetadata: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Full-resolution MOV on disk. May be several GB for a 60-minute concert.
    public let originalURL: URL
    /// 720p MP4 preview for sharing / playback. Nil until transcoding completes.
    public var previewURL: URL?
    public let duration: TimeInterval
    public let recordedAt: Date
    /// CloudKit event this clip belongs to (set when the user associates it with an event).
    public var eventId: String?

    public init(
        id: UUID = .init(),
        originalURL: URL,
        previewURL: URL? = nil,
        duration: TimeInterval,
        recordedAt: Date = .now,
        eventId: String? = nil
    ) {
        self.id          = id
        self.originalURL = originalURL
        self.previewURL  = previewURL
        self.duration    = duration
        self.recordedAt  = recordedAt
        self.eventId     = eventId
    }
}
