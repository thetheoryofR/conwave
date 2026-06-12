import AVFoundation
import Foundation

/// Manages N AVPlayers on a shared timeline and keeps them in sync.
///
/// Sync strategy:
///   - On `play()`: record a (Date, timelineMs) anchor, start all active players.
///   - A periodic timer advances `currentTimeMs` from the anchor and checks each
///     player for drift. If drift > `maxDriftMs`, it re-seeks that player.
///   - On `seek(to:)`: pause → seek all → update anchor. The caller can then `play()`.
@MainActor
public final class SyncedPlayerPool: ObservableObject {

    // MARK: - Types

    public struct PlayerEntry: Identifiable {
        public let id: String  // clipId
        public let player: ClipPlayer
    }

    // MARK: - State

    @Published public private(set) var entries:       [PlayerEntry] = []
    @Published public private(set) var isPlaying      = false
    @Published public private(set) var currentTimeMs: Double
    @Published public private(set) var focusedId:     String?

    public let layout: TimelineLayout

    // MARK: - Private

    private var syncTimer:           Timer?
    private var anchorDate:          Date?
    private var anchorMs:            Double = 0

    private let syncInterval: TimeInterval = 0.25  // check drift 4×/s
    private let maxDriftMs:   Double       = 60.0  // resync if off by >60ms

    // MARK: - Init

    public init(layout: TimelineLayout) {
        self.layout       = layout
        self.currentTimeMs = layout.startMs
    }

    // MARK: - Player management

    public func addPlayer(_ player: ClipPlayer) {
        entries.append(PlayerEntry(id: player.id, player: player))
        if focusedId == nil { focusedId = player.id }
    }

    public var players: [ClipPlayer] { entries.map(\.player) }

    public func player(for clipId: String) -> ClipPlayer? {
        entries.first { $0.id == clipId }?.player
    }

    // MARK: - Focus

    public func setFocus(clipId: String) {
        focusedId = clipId
    }

    // MARK: - Transport

    public func play() {
        guard !isPlaying else { return }
        isPlaying  = true
        anchorDate = .now
        anchorMs   = currentTimeMs
        for p in players { p.play() }
        startTimer()
    }

    public func pause() {
        guard isPlaying else { return }
        isPlaying = false
        stopTimer()
        for p in players { p.pause() }
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Seek all players to `tMs` on the shared timeline.
    public func seek(toMs tMs: Double) {
        let clamped    = layout.clamp(tMs)
        currentTimeMs  = clamped
        anchorMs       = clamped
        anchorDate     = .now
        for p in players { p.seek(toTimelineMs: clamped) }
    }

    public func seekToStart() {
        seek(toMs: layout.startMs)
    }

    // MARK: - Sync timer

    private func startTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncTick() }
        }
    }

    private func stopTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func syncTick() {
        guard isPlaying, let anchor = anchorDate else { return }

        let elapsed   = Date.now.timeIntervalSince(anchor) * 1_000.0
        let expected  = anchorMs + elapsed

        // Reached end — stop and rewind
        if expected >= layout.endMs {
            pause()
            seek(toMs: layout.startMs)
            return
        }

        currentTimeMs = expected

        for p in players {
            let shouldBeActive = layout.slot(for: p.id)?.isActive(at: expected) ?? false
            if shouldBeActive != p.isActive {
                p.seek(toTimelineMs: expected)
                if isPlaying { p.play() }
                continue
            }
            guard shouldBeActive else { continue }

            // Check drift
            let expectedLocal = layout.slot(for: p.id)?.localMs(for: expected) ?? 0
            let drift = abs(p.currentLocalMs - expectedLocal)
            if drift > maxDriftMs {
                p.seek(toTimelineMs: expected)
                if isPlaying { p.play() }
            }
        }
    }
}
