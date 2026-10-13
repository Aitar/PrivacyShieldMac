import CoreGraphics
import XCTest
@testable import PrivacyShieldCore

/// Deterministic tracker tests (M2-T01/M2-T02): synthetic bounding boxes and
/// injected `Date`s only — no camera, no Vision, no wall clock.
///
/// Traces use the default `FaceTrackerConfig` (maxDetectionGap 0.5 s,
/// trackExpiryInterval 1.0 s, weights 0.5/0.3/0.2, threshold 0.4) and a
/// 1920×1080 frame with normalized Vision boxes. Per-frame motion is 2% of
/// the frame width, so the correct detection↔track pair always outscores the
/// cross pair and greedy matching follows the person.
final class FaceTrackerTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 100.0)
    private let frame = CGSize(width: 1920, height: 1080)

    private func date(_ offsetSeconds: TimeInterval) -> Date {
        return start.addingTimeInterval(offsetSeconds)
    }

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0.2, _ h: CGFloat = 0.25) -> CGRect {
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Config invariants (X-T01)

    func testDefaultConfigMatchesPlanDefaults() {
        let config = FaceTrackerConfig()
        XCTAssertEqual(config.maxDetectionGap, 0.5, accuracy: 1e-12)
        XCTAssertEqual(config.trackExpiryInterval, 1.0, accuracy: 1e-12)
        XCTAssertEqual(config.iouWeight, 0.5, accuracy: 1e-12)
        XCTAssertEqual(config.centerDistanceWeight, 0.3, accuracy: 1e-12)
        XCTAssertEqual(config.sizeSimilarityWeight, 0.2, accuracy: 1e-12)
        // Weights sum to 1 so the combined score stays a similarity in [0, 1].
        XCTAssertEqual(
            config.iouWeight + config.centerDistanceWeight + config.sizeSimilarityWeight,
            1.0, accuracy: 1e-12
        )
        XCTAssertEqual(config.associationMatchThreshold, 0.4, accuracy: 1e-12)
    }

    // MARK: - Two stationary faces keep separate, stable IDs

    func testTwoStationaryFacesKeepStableIDsAcross20Iterations() {
        let tracker = FaceTracker()
        let boxA = box(0.2, 0.3)
        let boxB = box(0.6, 0.3)
        var idA: UUID?
        var idB: UUID?

        for step in 0...20 {
            let live = tracker.process(detections: [boxA, boxB], at: date(Double(step) * 0.1), frameSize: frame)
            XCTAssertEqual(live.count, 2, "step \(step)")

            let association = tracker.lastAssociationResult
            let match0 = association?.matched.first { $0.detectionIndex == 0 }
            let match1 = association?.matched.first { $0.detectionIndex == 1 }

            if step == 0 {
                // Step 0 has no matched pairs — both detections become new
                // tracks, returned in detection order.
                XCTAssertEqual(association?.newTracks.count, 2)
                XCTAssertEqual(association?.matched.count, 0)
                idA = live[0].id
                idB = live[1].id
                XCTAssertNotEqual(idA, idB)
            } else {
                // Stationary faces: identical boxes re-match with a perfect
                // score and the one-to-one pairing covers both detections.
                XCTAssertNotNil(match0, "step \(step)")
                XCTAssertNotNil(match1, "step \(step)")
                XCTAssertEqual(match0?.score ?? 0, 1.0, accuracy: 1e-9, "step \(step)")
                XCTAssertEqual(match1?.score ?? 0, 1.0, accuracy: 1e-9, "step \(step)")
                XCTAssertTrue(association?.newTracks.isEmpty ?? false, "step \(step)")
                XCTAssertEqual(match0?.trackID, idA, "detection 0 drifted to another track at step \(step)")
                XCTAssertEqual(match1?.trackID, idB, "detection 1 drifted to another track at step \(step)")
            }
            // Returned tracks keep detection order: the track bound to
            // detection 0 comes first.
            XCTAssertEqual(live.first?.id, idA, "step \(step)")
        }
        XCTAssertEqual(Set(tracker.tracks.map(\.id)), Set([idA!, idB!]))
    }

    // MARK: - Small movement does not create new IDs

    func testSmallMovementDoesNotCreateNewID() {
        let tracker = FaceTracker()
        var trackID: UUID?

        // 2% rightward drift per processed frame, 21 frames → 42% total.
        for step in 0...20 {
            let moved = box(0.2 + 0.02 * CGFloat(step), 0.3)
            let live = tracker.process(detections: [moved], at: date(Double(step) * 0.1), frameSize: frame)
            XCTAssertEqual(live.count, 1, "step \(step)")

            let association = tracker.lastAssociationResult
            if step == 0 {
                trackID = association?.newTracks.first
                XCTAssertNotNil(trackID)
            } else {
                XCTAssertTrue(association?.newTracks.isEmpty ?? false,
                              "step \(step) created a spurious new track")
                XCTAssertEqual(association?.matched.count, 1, "step \(step)")
                XCTAssertEqual(association?.matched.first?.trackID, trackID, "step \(step)")
            }
        }
        XCTAssertEqual(tracker.tracks.count, 1)
        XCTAssertEqual(tracker.tracks.first?.id, trackID)
    }

    // MARK: - Short missed-detection gap retained, long gap expired

    func testOneFrameMissRetainsTrackAndReassociates() {
        let tracker = FaceTracker()
        let face = box(0.2, 0.3)
        _ = tracker.process(detections: [face], at: date(0), frameSize: frame)
        let id = tracker.tracks[0].id

        // One empty frame 0.1 s later (< maxDetectionGap 0.5): retained.
        var live = tracker.process(detections: [], at: date(0.1), frameSize: frame)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].id, id)
        XCTAssertEqual(live[0].consecutiveMisses, 1)
        XCTAssertEqual(tracker.lastAssociationResult?.missedTrackIDs, [id])
        XCTAssertTrue(tracker.lastAssociationResult?.expiredTrackIDs.isEmpty ?? false)

        // Face reappears → same track, miss counter reset.
        live = tracker.process(detections: [face], at: date(0.2), frameSize: frame)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].id, id)
        XCTAssertEqual(live[0].consecutiveMisses, 0)
        XCTAssertEqual(live[0].hitCount, 2)
        XCTAssertEqual(tracker.lastAssociationResult?.missedTrackIDs, [])
    }

    func testGapBetweenMaxDetectionGapAndExpiryKeepsTrackAliveButNotMissed() {
        let tracker = FaceTracker()
        let face = box(0.2, 0.3)
        _ = tracker.process(detections: [face], at: date(0), frameSize: frame)
        let id = tracker.tracks[0].id

        // 0.7 s unseen: beyond the short gap (0.5) but within expiry (1.0) —
        // the gray zone: alive, may still re-associate, but not reported as
        // a short-gap miss.
        let live = tracker.process(detections: [], at: date(0.7), frameSize: frame)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].id, id)
        XCTAssertEqual(live[0].consecutiveMisses, 1)
        XCTAssertTrue(tracker.lastAssociationResult?.missedTrackIDs.isEmpty ?? false)
        XCTAssertTrue(tracker.lastAssociationResult?.expiredTrackIDs.isEmpty ?? false)
    }

    func testMissBeyondTrackExpiryIntervalExpiresTrack() {
        let tracker = FaceTracker()
        let face = box(0.2, 0.3)
        _ = tracker.process(detections: [face], at: date(0), frameSize: frame)
        let id = tracker.tracks[0].id

        // 1.1 s unseen (> trackExpiryInterval 1.0): gone.
        let live = tracker.process(detections: [], at: date(1.1), frameSize: frame)
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(tracker.tracks.isEmpty)
        XCTAssertEqual(tracker.lastAssociationResult?.expiredTrackIDs, [id])

        // A face reappearing after expiry starts a fresh track (fresh UUID,
        // fresh identity cache — the old person's state is gone).
        let liveAgain = tracker.process(detections: [face], at: date(1.2), frameSize: frame)
        XCTAssertEqual(liveAgain.count, 1)
        XCTAssertNotEqual(liveAgain[0].id, id)
        XCTAssertEqual(liveAgain[0].identity, .unknown)
    }

    func testExpiryOnEmptyDetectionsArray() {
        let tracker = FaceTracker()

        // Two faces at t=0.
        _ = tracker.process(detections: [box(0.2, 0.3), box(0.6, 0.3)], at: date(0), frameSize: frame)
        let ids = Set(tracker.tracks.map(\.id))
        XCTAssertEqual(ids.count, 2)

        // Explicit expire() past the interval removes both.
        let expired = tracker.expire(asOf: date(2.0))
        XCTAssertEqual(Set(expired), ids)
        XCTAssertTrue(tracker.tracks.isEmpty)

        // Same policy via process(detections: []): the "no faces at all"
        // frame still expires tracks once the interval has passed.
        _ = tracker.process(detections: [box(0.2, 0.3)], at: date(10.0), frameSize: frame)
        let id2 = tracker.tracks[0].id
        let live = tracker.process(detections: [], at: date(11.5), frameSize: frame)
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(tracker.tracks.isEmpty)
        XCTAssertEqual(tracker.lastAssociationResult?.expiredTrackIDs, [id2])
    }

    func testExpiryRunsEvenWhenDetectionsArePresent() {
        let tracker = FaceTracker()
        let face = box(0.2, 0.3)
        _ = tracker.process(detections: [face], at: date(0), frameSize: frame)
        let oldID = tracker.tracks[0].id

        // Expiry is time-first: a detection arriving after the interval can
        // not resurrect the expired track; it starts a new one.
        let live = tracker.process(detections: [face], at: date(1.2), frameSize: frame)
        let association = tracker.lastAssociationResult
        XCTAssertEqual(association?.expiredTrackIDs, [oldID])
        XCTAssertEqual(association?.newTracks.count, 1)
        XCTAssertEqual(live.count, 1)
        XCTAssertNotEqual(live.first?.id, oldID)
    }

    // MARK: - Gradual position swap keeps IDs bound to their person

    func testGradualSwapKeepsIDsBoundToTheirPerson() {
        let tracker = FaceTracker()
        var idA: UUID?
        var idB: UUID?

        // A walks right (0.2 → 0.6) while B walks left (0.6 → 0.2), 2% of
        // the frame per step, 21 steps — they pass each other around the
        // middle. B carries a 0.04 vertical offset so the two never occupy
        // the same box.
        //
        // Greedy limitation (documented): if the two boxes coincided EXACTLY
        // at the midpoint, the globally best pair could transiently bind the
        // wrong track for that one frame (ties are broken toward the older
        // track). Real faces never land on the identical box, and the offset
        // here guarantees the correct pair strictly outscores the cross pair
        // at every step, so greedy matching follows each person through the
        // crossing. (A Hungarian solver would only differ in such exact-tie
        // degenerate cases.)
        for step in 0...20 {
            let a = box(0.2 + 0.02 * CGFloat(step), 0.30)
            let b = box(0.6 - 0.02 * CGFloat(step), 0.34)
            let live = tracker.process(detections: [a, b], at: date(Double(step) * 0.1), frameSize: frame)
            XCTAssertEqual(live.count, 2, "step \(step)")

            let association = tracker.lastAssociationResult
            let match0 = association?.matched.first { $0.detectionIndex == 0 }
            let match1 = association?.matched.first { $0.detectionIndex == 1 }
            if step == 0 {
                // Step 0 has no matched pairs — both detections become new
                // tracks, returned in detection order.
                XCTAssertEqual(association?.newTracks.count, 2)
                idA = live[0].id
                idB = live[1].id
            } else {
                XCTAssertTrue(association?.newTracks.isEmpty ?? false,
                              "step \(step) created a spurious new track")
                XCTAssertEqual(match0?.trackID, idA, "A's track lost detection 0 at step \(step)")
                XCTAssertEqual(match1?.trackID, idB, "B's track lost detection 1 at step \(step)")
            }
        }

        // After the swap the long-lived tracks sit at the opposite x where
        // their person ended up: A's track followed A to 0.6, B's to 0.2.
        let trackA = tracker.track(withID: idA!)
        let trackB = tracker.track(withID: idB!)
        XCTAssertEqual(trackA?.boundingBox.minX ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(trackB?.boundingBox.minX ?? -1, 0.2, accuracy: 1e-9)
    }

    // MARK: - One-to-one enforcement

    func testOneDetectionCannotMatchTwoTracks() {
        let tracker = FaceTracker()
        _ = tracker.process(detections: [box(0.2, 0.3), box(0.55, 0.3)], at: date(0), frameSize: frame)
        let idA = tracker.tracks[0].id
        let idB = tracker.tracks[1].id

        // A single detection overlapping both tracks, much closer to A. B's
        // pair still clears the threshold, so the greedy one-to-one rule —
        // not the threshold — is what stops the double claim.
        let single = box(0.3, 0.3)
        let live = tracker.process(detections: [single], at: date(0.1), frameSize: frame)

        let association = tracker.lastAssociationResult
        XCTAssertEqual(association?.matched.count, 1)
        XCTAssertEqual(association?.matched.first?.trackID, idA)
        XCTAssertGreaterThanOrEqual(association?.matched.first?.score ?? 0,
                                    FaceTrackerConfig().associationMatchThreshold)
        XCTAssertTrue(association?.newTracks.isEmpty ?? false)
        XCTAssertEqual(association?.missedTrackIDs, [idB])
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(live[0].id, idA)
        XCTAssertEqual(live[1].id, idB)
    }

    func testOneTrackCannotClaimTwoDetections() {
        let tracker = FaceTracker()
        _ = tracker.process(detections: [box(0.3, 0.3)], at: date(0), frameSize: frame)
        let id = tracker.tracks[0].id

        // Two detections both overlapping the same track: the track claims
        // only the better one; the other becomes a new track.
        let d1 = box(0.32, 0.3)
        let d2 = box(0.34, 0.3)
        let live = tracker.process(detections: [d1, d2], at: date(0.1), frameSize: frame)

        let association = tracker.lastAssociationResult
        XCTAssertEqual(association?.matched.count, 1)
        XCTAssertEqual(association?.matched.first?.trackID, id)
        XCTAssertEqual(association?.matched.first?.detectionIndex, 0, "the closer detection must win")
        XCTAssertEqual(association?.newTracks.count, 1)
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(live.first?.id, id)
    }

    // MARK: - Association score formula

    func testAssociationScoreIdenticalBoxesIsOne() {
        let face = box(0.2, 0.3)
        let score = FaceTracker.associationScore(detection: face, trackBox: face, in: frame)
        XCTAssertEqual(score, 1.0, accuracy: 1e-12)
    }

    func testAssociationScoreDisjointBoxesIsBelowMatchThreshold() {
        let score = FaceTracker.associationScore(
            detection: box(0.0, 0.0, 0.2, 0.2),
            trackBox: box(0.8, 0.8, 0.2, 0.2),
            in: CGSize(width: 1, height: 1)
        )
        XCTAssertLessThan(score, FaceTrackerConfig().associationMatchThreshold)
    }

    func testAssociationComponentScores() {
        let face = box(0.2, 0.3)
        // IoU: 1 for identical boxes, 0 for disjoint ones.
        XCTAssertEqual(FaceTracker.iou(face, face), 1.0, accuracy: 1e-12)
        XCTAssertEqual(FaceTracker.iou(box(0.0, 0.0, 0.2, 0.2), box(0.8, 0.8, 0.2, 0.2)), 0.0, accuracy: 1e-12)

        // Center similarity: 1 for identical centers, and exactly
        // 1 − offset/frameDiagonal otherwise (offset scaled per axis).
        XCTAssertEqual(FaceTracker.centerSimilarity(face, face, in: frame), 1.0, accuracy: 1e-12)
        let offset = box(0.3, 0.3)
        let expected = 1.0 - 0.1 * 1920.0 / (1920.0 * 1920.0 + 1080.0 * 1080.0).squareRoot()
        XCTAssertEqual(FaceTracker.centerSimilarity(face, offset, in: frame), expected, accuracy: 1e-9)

        // Size similarity: 1 for equal areas, 1 − |ln(areaRatio)| otherwise
        // (a 2× area drop → 1 − ln 2).
        XCTAssertEqual(FaceTracker.sizeSimilarity(face, face), 1.0, accuracy: 1e-12)
        let doubled = box(0.2, 0.3, 0.2 * 2.0.squareRoot(), 0.25 * 2.0.squareRoot())
        XCTAssertEqual(FaceTracker.sizeSimilarity(face, doubled), 1.0 - log(2.0), accuracy: 1e-9)
    }

    // MARK: - New-track contract state

    func testNewTrackInitialContractState() {
        let tracker = FaceTracker()
        let live = tracker.process(detections: [box(0.2, 0.3)], at: date(0), frameSize: frame)
        XCTAssertEqual(live.count, 1)
        let track = live[0]
        XCTAssertEqual(track.identity, .unknown)
        XCTAssertEqual(track.attentionState, .uncertain)
        XCTAssertEqual(track.attentionScore, 0.0, accuracy: 1e-12)
        XCTAssertNil(track.lookingSince)
        XCTAssertNil(track.lastIdentityCheck)
        XCTAssertNil(track.lastPositiveAt)
        XCTAssertNil(track.lastNegativeAt)
        XCTAssertEqual(track.lastSeen, date(0))
        XCTAssertEqual(track.createdAt, date(0))
        XCTAssertEqual(track.hitCount, 1)
        XCTAssertEqual(track.consecutiveMisses, 0)
    }

    // MARK: - Detector write-back API

    func testUpdateIdentityAndAttentionWriteThrough() {
        let tracker = FaceTracker()
        _ = tracker.process(detections: [box(0.2, 0.3)], at: date(0), frameSize: frame)
        let id = tracker.tracks[0].id

        XCTAssertTrue(tracker.updateIdentity(id: id, identity: .owner, checkedAt: date(0.5)))
        var track = tracker.track(withID: id)
        XCTAssertEqual(track?.identity, .owner)
        XCTAssertEqual(track?.lastIdentityCheck, date(0.5))

        XCTAssertTrue(tracker.updateAttention(
            id: id,
            result: AttentionResult(state: .looking, score: 0.8),
            lookingSince: date(0.5),
            positiveAt: date(0.5),
            negativeAt: nil
        ))
        track = tracker.track(withID: id)
        XCTAssertEqual(track?.attentionState, .looking)
        XCTAssertEqual(track?.attentionScore ?? 0, 0.8, accuracy: 1e-12)
        XCTAssertEqual(track?.lookingSince, date(0.5))
        XCTAssertEqual(track?.lastPositiveAt, date(0.5))
        XCTAssertNil(track?.lastNegativeAt)

        // A negative evaluation clears the looking episode but never erases
        // the "last positive" marker — only a newer positive overwrites it.
        XCTAssertTrue(tracker.updateAttention(
            id: id,
            result: AttentionResult(state: .notLooking, score: 0.1),
            lookingSince: nil,
            positiveAt: nil,
            negativeAt: date(1.0)
        ))
        track = tracker.track(withID: id)
        XCTAssertNil(track?.lookingSince)
        XCTAssertEqual(track?.lastPositiveAt, date(0.5))
        XCTAssertEqual(track?.lastNegativeAt, date(1.0))

        // The `tracks` snapshot mirrors the writes too.
        XCTAssertEqual(tracker.tracks.first?.identity, .owner)
        XCTAssertEqual(tracker.tracks.first?.attentionState, .notLooking)

        // Writes to unknown (e.g. expired) IDs are rejected, not crashed on.
        XCTAssertFalse(tracker.updateIdentity(id: UUID(), identity: .owner, checkedAt: date(2.0)))
        XCTAssertFalse(tracker.updateAttention(
            id: UUID(),
            result: AttentionResult(state: .looking, score: 1.0),
            lookingSince: nil,
            positiveAt: nil,
            negativeAt: nil
        ))
    }
}
