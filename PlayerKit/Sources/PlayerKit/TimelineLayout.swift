import Foundation

/// Maps per-clip alignment offsets onto a shared timeline coordinate system.
///
/// The "shared timeline" runs from `startMs` (smallest globalStartMs) to `endMs`
/// (largest globalStartMs + durationMs). All seek/playback calculations use this
/// coordinate space.
///
///   Clip A  globalStart=0,    duration=15s  → active [0, 15000]
///   Clip B  globalStart=3000, duration=15s  → active [3000, 18000]
///   Timeline: startMs=0, endMs=18000, totalDuration=18s
public struct TimelineLayout: Sendable {

    // MARK: - Clip slot

    public struct ClipSlot: Identifiable, Sendable {
        public let id: String
        /// When this clip starts on the shared timeline (ms). May be negative.
        public let globalStartMs: Double
        public let durationMs: Double

        public var globalEndMs: Double { globalStartMs + durationMs }

        public func isActive(at tMs: Double) -> Bool {
            tMs >= globalStartMs && tMs < globalEndMs
        }

        /// Convert a shared-timeline position to this clip's local playback time.
        public func localMs(for tMs: Double) -> Double {
            tMs - globalStartMs
        }

        public func localSeconds(for tMs: Double) -> Double {
            max(0, localMs(for: tMs) / 1_000.0)
        }
    }

    // MARK: - Layout properties

    public let slots: [ClipSlot]
    public let startMs:  Double   // global timeline origin (usually ≤ 0)
    public let endMs:    Double   // latest clip end

    public var totalDurationMs: Double { max(endMs - startMs, 1) }
    public var totalDurationS:  Double { totalDurationMs / 1_000.0 }

    // MARK: - Init

    public init(clips: [(id: String, globalStartMs: Double, durationMs: Double)]) {
        let s       = clips.map { ClipSlot(id: $0.id, globalStartMs: $0.globalStartMs, durationMs: $0.durationMs) }
        self.slots   = s
        self.startMs = s.map(\.globalStartMs).min() ?? 0
        self.endMs   = s.map(\.globalEndMs).max()   ?? 0
    }

    // MARK: - Coordinate conversion

    /// Clamp then normalize timeline position to [0, 1].
    public func normalizedPosition(_ tMs: Double) -> Double {
        (clamp(tMs) - startMs) / totalDurationMs
    }

    /// Convert normalized [0, 1] to a timeline position in ms.
    public func timelineMs(from normalized: Double) -> Double {
        startMs + normalized.clamped(to: 0...1) * totalDurationMs
    }

    public func clamp(_ tMs: Double) -> Double {
        max(startMs, min(endMs, tMs))
    }

    public func slot(for clipId: String) -> ClipSlot? {
        slots.first { $0.id == clipId }
    }

    /// Active slots at the given timeline position.
    public func activeSlots(at tMs: Double) -> [ClipSlot] {
        slots.filter { $0.isActive(at: tMs) }
    }
}

// MARK: - Comparable helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
