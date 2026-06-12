import PlayerKit
import SwiftUI

/// Play/pause, skip-to-start, and playback info for the synchronized player pool.
struct TransportBar: View {
    @ObservedObject var pool: SyncedPlayerPool

    var body: some View {
        HStack(spacing: 32) {
            // Skip to start
            Button {
                pool.seekToStart()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }

            // Play / Pause
            Button {
                pool.togglePlayback()
            } label: {
                Image(systemName: pool.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .contentTransition(.symbolEffect(.replace.offUp))
            }

            // Active clip count badge
            let activeCount = pool.entries.filter(\.player.isActive).count
            Text("\(activeCount) / \(pool.entries.count) active")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80)
        }
        .frame(maxWidth: .infinity)
    }
}
