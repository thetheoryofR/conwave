import PlayerKit
import SwiftUI

/// Draggable scrubber bar showing the shared timeline position and per-clip activity strips.
struct TimelineScrubber: View {
    @ObservedObject var pool: SyncedPlayerPool

    @State private var isDragging     = false
    @State private var dragNormalized = 0.0   // drag position [0,1]

    private var displayTimeMs: Double {
        isDragging ? pool.layout.timelineMs(from: dragNormalized) : pool.currentTimeMs
    }

    var body: some View {
        VStack(spacing: 6) {
            // Time label
            HStack {
                Text(formatMs(displayTimeMs - pool.layout.startMs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatMs(pool.layout.totalDurationMs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Clip activity strips + playhead
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(height: 28)

                    // Per-clip strips
                    ForEach(Array(pool.layout.slots.enumerated()), id: \.element.id) { idx, slot in
                        clipStrip(slot: slot, width: geo.size.width, color: angleColor(idx))
                    }

                    // Playhead
                    let x = pool.layout.normalizedPosition(displayTimeMs) * geo.size.width
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 2, height: 36)
                        .offset(x: x - 1)
                        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging      = true
                            dragNormalized  = (value.location.x / geo.size.width)
                                .clamped(to: 0...1)
                        }
                        .onEnded { _ in
                            let tMs = pool.layout.timelineMs(from: dragNormalized)
                            pool.seek(toMs: tMs)
                            isDragging = false
                        }
                )
            }
            .frame(height: 36)
        }
    }

    // MARK: - Clip strip

    private func clipStrip(slot: TimelineLayout.ClipSlot, width: CGFloat, color: Color) -> some View {
        let startNorm = pool.layout.normalizedPosition(slot.globalStartMs)
        let endNorm   = pool.layout.normalizedPosition(slot.globalEndMs)
        let stripW    = CGFloat(endNorm - startNorm) * width
        let stripX    = CGFloat(startNorm) * width

        return RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.55))
            .frame(width: max(stripW, 2), height: 16)
            .offset(x: stripX)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func formatMs(_ ms: Double) -> String {
        let totalS = Int(ms / 1_000)
        let m = totalS / 60
        let s = totalS % 60
        return String(format: "%d:%02d", m, s)
    }

    private func angleColor(_ index: Int) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan]
        return palette[index % palette.count]
    }
}

// MARK: -

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
