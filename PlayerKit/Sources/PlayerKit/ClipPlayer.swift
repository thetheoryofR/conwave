import AVFoundation
import Foundation

/// Wraps an AVPlayer for a single clip, with timeline-aware seeking and activation.
///
/// A clip is "active" when the shared timeline position falls within its
/// `[globalStartMs, globalEndMs)` window. Outside that window the player is
/// paused and hidden.
@MainActor
public final class ClipPlayer: ObservableObject, Identifiable {

    // MARK: - State

    public let id:     String
    public let player: AVPlayer
    public let slot:   TimelineLayout.ClipSlot

    @Published public private(set) var isReady:  Bool = false
    @Published public private(set) var isActive: Bool = false

    private var statusObservation: NSKeyValueObservation?

    // MARK: - Init

    public init(id: String, url: URL, slot: TimelineLayout.ClipSlot) {
        self.id   = id
        self.slot = slot
        let item  = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)
        self.player.actionAtItemEnd = .pause

        // Observe readiness on whichever thread KVO fires, then hop to MainActor.
        statusObservation = item.observe(\.status, options: [.new, .initial]) { item, _ in
            let ready = item.status == .readyToPlay
            Task { @MainActor [weak self] in
                self?.isReady = ready
            }
        }
    }

    // MARK: - Transport

    /// Seek all internal state to match `tMs` on the shared timeline.
    /// Does NOT call `play()` — the pool handles that after seeking all clips.
    public func seek(toTimelineMs tMs: Double) {
        let nowActive = slot.isActive(at: tMs)
        isActive = nowActive

        guard nowActive else {
            player.pause()
            return
        }

        let target = CMTime(seconds: slot.localSeconds(for: tMs), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func play() {
        guard isActive else { return }
        player.play()
    }

    public func pause() {
        player.pause()
    }

    /// Current local playback position in milliseconds.
    public var currentLocalMs: Double {
        player.currentTime().seconds * 1_000.0
    }

    /// Current position on the shared timeline in milliseconds.
    public var currentTimelineMs: Double {
        slot.globalStartMs + currentLocalMs
    }
}
