import XCTest
@testable import PlayerKit

final class TimelineLayoutTests: XCTestCase {

    // Clip A: 0..15s, Clip B: 3..18s (like the Python alignment test)
    static let twoClipLayout = TimelineLayout(clips: [
        (id: "A", globalStartMs: 0,    durationMs: 15_000),
        (id: "B", globalStartMs: 3_000, durationMs: 15_000),
    ])

    func testLayoutBounds() {
        let layout = Self.twoClipLayout
        XCTAssertEqual(layout.startMs, 0)
        XCTAssertEqual(layout.endMs,   18_000)
        XCTAssertEqual(layout.totalDurationMs, 18_000, accuracy: 0.1)
    }

    func testSlotLookup() {
        let layout = Self.twoClipLayout
        XCTAssertNotNil(layout.slot(for: "A"))
        XCTAssertNotNil(layout.slot(for: "B"))
        XCTAssertNil(layout.slot(for: "C"))
    }

    func testClipActivation() {
        let layout = Self.twoClipLayout
        let slotA  = layout.slot(for: "A")!
        let slotB  = layout.slot(for: "B")!

        // At t=0: A active, B not yet
        XCTAssertTrue(slotA.isActive(at: 0))
        XCTAssertFalse(slotB.isActive(at: 0))

        // At t=3000: both active
        XCTAssertTrue(slotA.isActive(at: 3_000))
        XCTAssertTrue(slotB.isActive(at: 3_000))

        // At t=15000: A done (15000 is the end, exclusive), B still running
        XCTAssertFalse(slotA.isActive(at: 15_000))
        XCTAssertTrue(slotB.isActive(at: 15_000))

        // At t=18000: both done
        XCTAssertFalse(slotA.isActive(at: 18_000))
        XCTAssertFalse(slotB.isActive(at: 18_000))
    }

    func testLocalTimeConversion() {
        let slotB = Self.twoClipLayout.slot(for: "B")!
        // B started at 3s on the timeline — local time is tMs - 3000
        XCTAssertEqual(slotB.localMs(for: 5_000), 2_000, accuracy: 0.01)
        XCTAssertEqual(slotB.localSeconds(for: 5_000), 2.0, accuracy: 0.001)
        // Clamped to 0 if before start
        XCTAssertEqual(slotB.localSeconds(for: 0), 0.0, accuracy: 0.001)
    }

    func testNormalizedPosition() {
        let layout = Self.twoClipLayout
        XCTAssertEqual(layout.normalizedPosition(0),      0.0, accuracy: 0.001)
        XCTAssertEqual(layout.normalizedPosition(18_000), 1.0, accuracy: 0.001)
        XCTAssertEqual(layout.normalizedPosition(9_000),  0.5, accuracy: 0.001)
    }

    func testTimelineFromNormalized() {
        let layout = Self.twoClipLayout
        XCTAssertEqual(layout.timelineMs(from: 0.0), 0,      accuracy: 0.01)
        XCTAssertEqual(layout.timelineMs(from: 1.0), 18_000, accuracy: 0.01)
        XCTAssertEqual(layout.timelineMs(from: 0.5), 9_000,  accuracy: 0.01)
    }

    func testNormalizedRoundTrip() {
        let layout  = Self.twoClipLayout
        let times   = [0.0, 3_000.0, 9_000.0, 15_000.0, 18_000.0]
        for t in times {
            let rt = layout.timelineMs(from: layout.normalizedPosition(t))
            XCTAssertEqual(rt, t, accuracy: 0.1, "Round-trip failed for t=\(t)")
        }
    }

    func testActiveSlots() {
        let layout = Self.twoClipLayout
        XCTAssertEqual(layout.activeSlots(at: 1_000).map(\.id), ["A"])
        XCTAssertEqual(Set(layout.activeSlots(at: 5_000).map(\.id)), ["A", "B"])
        XCTAssertEqual(layout.activeSlots(at: 17_000).map(\.id), ["B"])
        XCTAssertEqual(layout.activeSlots(at: 18_500).map(\.id), [])
    }

    // MARK: - Negative globalStartMs (anchor not the first clip)

    func testNegativeStartLayout() {
        // clip0 is anchor at 0, clip1 started 5s before clip0
        let layout = TimelineLayout(clips: [
            (id: "clip0", globalStartMs: 0,      durationMs: 15_000),
            (id: "clip1", globalStartMs: -5_000, durationMs: 15_000),
        ])
        XCTAssertEqual(layout.startMs, -5_000)
        XCTAssertEqual(layout.endMs,    15_000)
        XCTAssertEqual(layout.totalDurationMs, 20_000, accuracy: 0.1)

        let slot1 = layout.slot(for: "clip1")!
        XCTAssertTrue(slot1.isActive(at: -5_000))
        XCTAssertTrue(slot1.isActive(at: 9_999))
        XCTAssertFalse(slot1.isActive(at: 10_000))  // -5000 + 15000 = 10000
    }

    // MARK: - Single clip degenerate case

    func testSingleClipLayout() {
        let layout = TimelineLayout(clips: [
            (id: "solo", globalStartMs: 0, durationMs: 10_000),
        ])
        XCTAssertEqual(layout.startMs, 0)
        XCTAssertEqual(layout.endMs,   10_000)
        XCTAssertEqual(layout.normalizedPosition(5_000), 0.5, accuracy: 0.001)
    }

    // MARK: - Clamp

    func testClamp() {
        let layout = Self.twoClipLayout
        XCTAssertEqual(layout.clamp(-500),  0,      accuracy: 0.01)
        XCTAssertEqual(layout.clamp(20_000), 18_000, accuracy: 0.01)
        XCTAssertEqual(layout.clamp(9_000),  9_000,  accuracy: 0.01)
    }
}
