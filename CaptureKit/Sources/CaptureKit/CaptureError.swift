import Foundation

public enum CaptureError: Error, LocalizedError, Equatable, Identifiable {
    case permissionDenied
    case noCameraAvailable
    case noMicrophoneAvailable
    case sessionConfiguration(String)
    case writerFailed(String)
    case transcodeFailed(String)
    case noActiveRecording

    public var id: String { errorDescription ?? "unknown" }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera and microphone access is required. Grant access in Settings."
        case .noCameraAvailable:
            return "No rear camera found on this device."
        case .noMicrophoneAvailable:
            return "No microphone found on this device."
        case .sessionConfiguration(let detail):
            return "Could not configure capture session: \(detail)"
        case .writerFailed(let detail):
            return "Recording failed: \(detail)"
        case .transcodeFailed(let detail):
            return "Transcoding failed: \(detail)"
        case .noActiveRecording:
            return "stopRecording() called while not recording."
        }
    }
}
