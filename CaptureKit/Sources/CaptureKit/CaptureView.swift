import AVFoundation
import SwiftUI

/// Full-screen recording UI: camera preview + record/stop button + duration timer.
///
/// Embed this in a sheet or NavigationStack. Pass an optional `eventId` to
/// associate the recorded clip with a CloudKit event.
///
///   .sheet(isPresented: $showCapture) {
///       CaptureView(eventId: event.id) { clip in
///           // clip is a ClipMetadata — upload it, fingerprint it, etc.
///           handleNewClip(clip)
///       }
///   }
public struct CaptureView: View {
    // MARK: - State

    @StateObject private var session = CaptureSession()
    @Environment(\.dismiss) private var dismiss

    private let eventId: String?
    private let onClipRecorded: ((ClipMetadata) -> Void)?

    // MARK: - Init

    public init(
        eventId: String? = nil,
        onClipRecorded: ((ClipMetadata) -> Void)? = nil
    ) {
        self.eventId         = eventId
        self.onClipRecorded  = onClipRecorded
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Camera preview
            if session.isPrepared {
                CapturePreviewView(previewLayer: session.previewLayer)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                placeholderMessage
            }

            // Controls overlay
            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await session.prepare()
        }
        .onDisappear {
            session.teardown()
        }
        .onChange(of: session.lastClip) { _, clip in
            guard let clip else { return }
            var mutable = clip
            mutable = ClipMetadata(
                id:          clip.id,
                originalURL: clip.originalURL,
                previewURL:  clip.previewURL,
                duration:    clip.duration,
                recordedAt:  clip.recordedAt,
                eventId:     eventId
            )
            onClipRecorded?(mutable)
        }
        .alert(item: $session.captureError) { err in
            Alert(
                title: Text("Camera Error"),
                message: Text(err.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if session.isRecording {
                durationBadge
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var durationBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(formattedDuration(session.recordingDuration))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var bottomControls: some View {
        VStack(spacing: 20) {
            // Hint text
            Text(session.isRecording ? "Tap to stop recording" : "Tap to start recording")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            // Record / stop button
            Button {
                if session.isRecording {
                    Task { await session.stopRecording() }
                } else {
                    session.startRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: 72, height: 72)
                    if session.isRecording {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 56, height: 56)
                    }
                }
            }
            .animation(.spring(duration: 0.25), value: session.isRecording)
            .disabled(!session.isPrepared)

            // Last clip indicator
            if let clip = session.lastClip, !session.isRecording {
                lastClipBanner(clip)
            } else {
                Color.clear.frame(height: 44)
            }
        }
        .padding(.bottom, 44)
    }

    private func lastClipBanner(_ clip: ClipMetadata) -> some View {
        HStack(spacing: 10) {
            Image(systemName: clip.previewURL != nil ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(clip.previewURL != nil ? .green : .yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.previewURL != nil ? "Clip saved" : "Processing preview…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(formattedDuration(clip.duration))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }

    private var placeholderMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.slash")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.4))
            Text(session.captureError?.localizedDescription ?? "Setting up camera…")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Formatting

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
