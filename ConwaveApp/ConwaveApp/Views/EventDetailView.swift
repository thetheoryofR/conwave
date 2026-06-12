import CaptureKit
import SwiftUI

struct EventDetailView: View {
    let event: Event
    @EnvironmentObject var ck: CloudKitManager
    @State private var showCapture     = false
    @State private var recordedClips   = [ClipMetadata]()
    @State private var showEditor      = false

    // Placeholder offsets: evenly spaced until AudioSyncKit alignment runs.
    // Phase 3 integration will replace this with real Aligner output.
    private var placeholderAlignedClips: [(clip: ClipMetadata, globalStartMs: Double)] {
        recordedClips.enumerated().map { idx, clip in
            (clip: clip, globalStartMs: Double(idx) * 500.0)
        }
    }

    var body: some View {
        List {
            // Event metadata
            Section {
                LabeledContent("Venue", value: event.venueName)
                LabeledContent("Show starts", value: event.startTime.formatted(date: .long, time: .shortened))
                if let endTime = event.endTime {
                    LabeledContent("Show ends", value: endTime.formatted(date: .omitted, time: .shortened))
                }
            }

            // Join code
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Join Code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.joinCode)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .tracking(4)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = event.joinCode
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)

                if let url = event.shareURL {
                    ShareLink(
                        item: url,
                        subject: Text("Join \(event.title) on Conwave"),
                        message: Text("Use code \(event.joinCode) or tap this link to join.")
                    ) {
                        Label("Share Invite Link", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("Invite Others")
            } footer: {
                Text("Share the code or link so others can contribute their clips.")
            }

            // Local clips recorded in this session
            Section("Clips") {
                if recordedClips.isEmpty {
                    ContentUnavailableView {
                        Label("No clips yet", systemImage: "video.slash")
                    } description: {
                        Text("Tap "Start Recording" to capture your angle.")
                    }
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(recordedClips) { clip in
                        ClipRow(clip: clip)
                    }
                }
            }

            // Record button (Phase 2 — live)
            Section {
                Button {
                    showCapture = true
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            // Open editor once 2+ clips are recorded
            if recordedClips.count >= 2 {
                Section {
                    NavigationLink {
                        SyncEditorView(alignedClips: placeholderAlignedClips)
                    } label: {
                        Label("Open Multi-Angle Editor", systemImage: "film.stack")
                    }
                } footer: {
                    Text("Clips are roughly aligned. For precise sync, fingerprinting runs in the background.")
                }
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView(eventId: event.id) { clip in
                recordedClips.append(clip)
            }
        }
    }
}

// MARK: - Clip row

private struct ClipRow: View {
    let clip: ClipMetadata

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: clip.previewURL != nil ? "video.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(clip.previewURL != nil ? .blue : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.recordedAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.weight(.medium))
                Text(formattedDuration(clip.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if clip.previewURL == nil {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.vertical, 2)
    }

    private func formattedDuration(_ s: TimeInterval) -> String {
        let t = Int(s)
        let m = t / 60, sec = t % 60
        return String(format: "%d:%02d", m, sec)
    }
}
