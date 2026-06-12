import CaptureKit
import PlayerKit
import SwiftUI

/// Multi-angle synchronized editor.
///
/// Takes an array of recorded clips with their alignment offsets and presents:
///  - A primary "focus" player (full width)
///  - A thumbnail strip of other angles
///  - A scrubber on the shared timeline
///  - Play/pause + seek-to-start controls
///
/// Usage:
///   SyncEditorView(clips: alignedClips)
///       // where alignedClips: [(ClipMetadata, globalStartMs: Double)]
public struct SyncEditorView: View {

    // MARK: - Input

    /// Each element: (clip metadata, globalStartMs on shared timeline in ms)
    public let alignedClips: [(clip: ClipMetadata, globalStartMs: Double)]

    // MARK: - State

    @StateObject private var pool: SyncedPlayerPool

    public init(alignedClips: [(clip: ClipMetadata, globalStartMs: Double)]) {
        self.alignedClips = alignedClips
        let layout = TimelineLayout(clips: alignedClips.map {
            (id:           $0.clip.id.uuidString,
             globalStartMs: $0.globalStartMs,
             durationMs:    $0.clip.duration * 1_000.0)
        })
        _pool = StateObject(wrappedValue: SyncedPlayerPool(layout: layout))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Primary focus player
            focusPlayer
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)

            // Angle selector strip
            if alignedClips.count > 1 {
                angleStrip
                    .frame(height: 80)
                    .background(Color(uiColor: .secondarySystemBackground))
            }

            // Timeline scrubber + transport
            VStack(spacing: 12) {
                TimelineScrubber(pool: pool)
                TransportBar(pool: pool)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .task { await setupPlayers() }
        .onDisappear { pool.pause() }
        .navigationTitle("Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - Focus player

    @ViewBuilder
    private var focusPlayer: some View {
        if let focusId = pool.focusedId,
           let entry   = pool.entries.first(where: { $0.id == focusId }) {
            PlayerView(player: entry.player.player, gravity: .resizeAspect)
        } else {
            Color.black.overlay {
                ProgressView().tint(.white)
            }
        }
    }

    // MARK: - Angle strip

    private var angleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pool.entries) { entry in
                    AngleThumbnail(
                        entry: entry,
                        isFocused: pool.focusedId == entry.id
                    ) {
                        pool.setFocus(clipId: entry.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Setup

    private func setupPlayers() async {
        // Build ClipPlayers from alignedClips + layout slots
        for item in alignedClips {
            let clipId = item.clip.id.uuidString
            guard let url  = item.clip.previewURL ?? {
                // Fall back to original if no preview yet
                item.clip.originalURL
            }() as URL?,
                  let slot = pool.layout.slot(for: clipId) else { continue }

            let player = ClipPlayer(id: clipId, url: url, slot: slot)
            pool.addPlayer(player)
        }
        // Seek to start so preview frames are visible
        pool.seekToStart()
    }
}

// MARK: - Angle thumbnail

private struct AngleThumbnail: View {
    let entry:     SyncedPlayerPool.PlayerEntry
    let isFocused: Bool
    let onTap:     () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                PlayerView(player: entry.player.player, gravity: .resizeAspectFill)
                    .frame(width: 120, height: 67.5)  // 16:9 at 120pt
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Active-clip indicator
                if entry.player.isActive {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }
}
