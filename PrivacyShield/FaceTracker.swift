import CoreGraphics
import Foundation

// MARK: - Identity contract (M2-T01)

/// Recognition label carried ON a face track (M2-T01 contract).
///
/// `.unknown` means "not yet recognized" — it is the initial state of every
/// new track and is kept explicit so the detector can distinguish "never
/// checked" from a negative recognition result (`.other`).
enum IdentityState {
    case owner
    case trusted
    case other
    case unknown
}

// MARK: - Track contract (M2-T01)

/// One visible person. Created by `FaceTracker.process`, updated in place by
/// the tracker, and handed to the detector as an immutable snapshot (the
/// struct is a value copy — the live state stays inside the tracker).
///
/// Bounding boxes are normalized Vision coordinates (origin bottom-left, each
/// axis in 0...1 of the frame); all association math is coordinate-system
/// agnostic, so the origin convention does not matter here.
struct FaceTrack {
    /// Stable identity across frames. This UUID replaces the per-frame face
    /// index the M1 prototype logged as `trackID`.
    let id: UUID
    /// Latest matched detection, normalized Vision coordinates.
    var boundingBox: CGRect
    /// Recognition label; written by the detector via `updateIdentity`.
    var identity: IdentityState
    /// Latest continuous attention score in [0, 1] (0 until first evaluation).
    var attentionScore: Double
    /// Latest discrete attention classification (`.uncertain` until first
    /// evaluation, so an unevaluated track never counts as clearly safe or
    /// clearly looking).
    var attentionState: AttentionState
    /// Start of the current sustained-looking episode; `nil` while the track
    /// is not in an active looking episode.
    var lookingSince: Date?
    /// Timestamp of the most recent frame in which this track was matched to
    /// a detection. Drives the expiry policy.
    var lastSeen: Date
    /// When the identity was last (re-)evaluated — `nil` until the first
    /// recognition pass. The detector's caching policy (M2-T05/T06) reads
    /// this to decide WHEN to re-recognize.
    var lastIdentityCheck: Date?
    /// Most recent `.looking` evaluation (M2-T03/T04 state machine input).
    /// A historical marker: absence never clears it, only a newer positive
    /// overwrites it.
    var lastPositiveAt: Date?
    /// Most recent `.notLooking` evaluation. Same marker semantics as
    /// `lastPositiveAt`.
    var lastNegativeAt: Date?
    /// Creation time. Used for deterministic ordering and tie-breaks.
    var createdAt: Date
    /// Total number of matched detections (starts at 1 on creation) — a
    /// cheap stability measure for sorting and diagnostics.
    var hitCount: Int
    /// Consecutive frames (process calls) in which this track went
    /// unmatched. Reset to 0 on every match.
    var consecutiveMisses: Int
    /// Latest head-pose reading for this track (M2-T03). `nil` until the
    /// first evaluation; `.unavailable` is a distinct, explicit state (Vision
    /// supplied no complete pose) and is never conflated with a frontal
    /// pose. Written by the detector via `updateHeadPose`. Defaulted so
    /// existing memberwise initializers keep compiling.
    var latestHeadPose: HeadPoseResult? = nil
    /// Hysteresis-stabilized distance band for this track (M3-T04), derived
    /// from the normalized bounding-box width. `nil` until the detector's
    /// first band classification; the previous value is the hysteresis state
    /// `DistanceBandHysteresis.refined` needs across frames. Defaulted so
    /// existing memberwise initializers keep compiling. Written by the
    /// detector via `updateDistanceBand`.
    var distanceBand: DistanceBand? = nil
}

// MARK: - Tunables (M2-T01, X-T01: all knobs in one place)

/// All FaceTracker tunables. Durations are wall-clock seconds (never frame
/// counts) so behavior is independent of camera frame rate, matching
/// `AttentionTimingConfig`.
struct FaceTrackerConfig {
    /// Maximum SHORT missed-detection gap a track survives while unseen.
    /// Unseen time up to this value is a normal detection hiccup: the track
    /// stays in `missedTrackIDs` and re-associates as soon as the face
    /// reappears (default 0.5 s).
    var maxDetectionGap: TimeInterval = 0.5
    /// Total unseen time after which a track expires and its UUID (and with
    /// it the cached identity and attention history) is gone for good
    /// (default 1.0 s). The window between `maxDetectionGap` and this value
    /// is a gray zone: the track is still alive and may re-associate, but it
    /// is no longer reported as a short-gap miss.
    var trackExpiryInterval: TimeInterval = 1.0

    // Association weights: combined =
    //   iouWeight·IoU + centerDistanceWeight·centerSim + sizeSimilarityWeight·sizeSim.
    // They conventionally sum to 1.0 so the combined score stays in [0, 1].
    /// Weight of the bounding-box IoU term (default 0.5).
    var iouWeight: Double = 0.5
    /// Weight of the center-distance similarity term (default 0.3).
    var centerDistanceWeight: Double = 0.3
    /// Weight of the face-size similarity term (default 0.2).
    var sizeSimilarityWeight: Double = 0.2
    /// Minimum combined score for a detection–track pair to be considered at
    /// all (default 0.4). Pairs below it are never matched, so a lone
    /// detection that only weakly resembles a track leaves that track missed
    /// and creates a fresh one instead.
    var associationMatchThreshold: Double = 0.4
}

// MARK: - Association result (M2-T01)

/// Outcome of one `process` pass: how detections were bound to tracks. One
/// detection matches at most one track and one track claims at most one
/// detection; every other box lands in exactly one of the remaining lists.
struct TrackAssociationResult {
    /// A detection (by index into the `process` input) bound to an existing
    /// track, with the combined score that won the pairing.
    struct Match {
        let detectionIndex: Int
        let trackID: UUID
        let score: Double
    }

    /// Mutually-exclusive detection↔track pairs, unordered (use
    /// `detectionIndex` to sort).
    var matched: [Match] = []
    /// Tracks created this pass for unmatched detections, in detection order.
    var newTracks: [UUID] = []
    /// Tracks removed this pass because they were unseen for longer than
    /// `trackExpiryInterval`.
    var expiredTrackIDs: [UUID] = []
    /// Unmatched live tracks retained across a SHORT gap (unseen for at most
    /// `maxDetectionGap`); they will re-associate on reappearance.
    var missedTrackIDs: [UUID] = []
}

// MARK: - Tracker (M2-T02)

/// Lightweight detection-to-track association — a greedy IoU/center/size
/// matcher. NO DeepSORT, no Kalman filter, no motion model, no external
/// dependencies: each pass re-scores every (detection, live track) pair
/// geometrically and takes the mutually-best pairs. At 5–30 fps with the
/// frame-skipping detector this is more than enough for faces that move a
/// few percent of the frame per processed frame.
///
/// Identity cache ownership (M2-T01): the `FaceTracker` owns track LIFECYCLE —
/// it creates, geometrically updates and expires tracks, and the identity
/// state lives ON the track so it survives per-frame detection churn (boxes
/// flicker, identities must not). It does NOT decide when to re-recognize and
/// never runs recognition itself: `FaceDetector`/`FaceRecognizer` (integrated
/// in M2-T05/T06) own that policy — they read `track.lastIdentityCheck`, apply
/// their staleness policy, and write the outcome back through
/// `updateIdentity(id:identity:checkedAt:)`; attention results flow through
/// `updateAttention(...)` the same way. In short: the tracker answers "which
/// box is which person", the detector/recognizer answer "who is this person
/// and when do we re-check". Recognition results therefore stay bound to a
/// stable UUID across frames instead of a per-frame index, which is exactly
/// what the per-track attention timers (M2-T03/T04) key off.
///
/// Threading: NOT internally synchronized — thread-confined by design.
/// Create the tracker, call `process`/`expire`/`update*` and read `tracks`
/// from ONE queue only (the queue that also owns the detector's results,
/// matching how `FaceDetector` already confines its state).
final class FaceTracker {

    private let config: FaceTrackerConfig

    /// Snapshot of all live tracks after the most recent pass, ordered by
    /// that pass's association: matched tracks in detection-index order,
    /// then newly created tracks in detection-index order, then retained
    /// (unmatched) tracks oldest-first (stability order). Treat as
    /// read-only; it is a value copy, live state stays inside the tracker.
    private(set) var tracks: [FaceTrack] = []

    /// Outcome of the most recent association pass (diagnostics/tests).
    /// `expire(asOf:)` deliberately does not touch it.
    private(set) var lastAssociationResult: TrackAssociationResult?

    /// Live tracks keyed by id. The single source of truth; `tracks` is the
    /// ordered snapshot of it.
    private var records: [UUID: FaceTrack] = [:]

    init(config: FaceTrackerConfig = FaceTrackerConfig()) {
        self.config = config
    }

    // MARK: Per-frame association

    /// Associates `detections` (normalized Vision boxes) with live tracks at
    /// timestamp `date` and returns the live tracks afterwards.
    ///
    /// Pipeline, in order:
    /// 1. Expire every track unseen for more than `trackExpiryInterval`
    ///    (time-first, so a stale track can neither claim a detection nor
    ///    come back — with `detections: []` this step alone cleans up).
    /// 2. Score every (detection, live track) pair; keep pairs scoring at
    ///    least `associationMatchThreshold`.
    /// 3. Greedy one-to-one matching: take the globally best-scoring pair,
    ///    then the next best whose detection AND track are both still free,
    ///    and so on (see `Self.associationScore` for the formula and the
    ///    class docs for greedy limitations).
    /// 4. Matched tracks: update `boundingBox`, `lastSeen`, reset
    ///    `consecutiveMisses`. Identity/attention fields are NOT touched
    ///    here — the detector writes those through `updateIdentity`/
    ///    `updateAttention`.
    /// 5. Unmatched detections: new tracks (identity `.unknown`, attention
    ///    `.uncertain`, `hitCount` 1).
    /// 6. Unmatched live tracks: retained with `consecutiveMisses += 1`; if
    ///    the unseen gap is at most `maxDetectionGap` they are also reported
    ///    in `missedTrackIDs` (beyond that, up to expiry, they linger
    ///    silently in the gray zone).
    ///
    /// `frameSize` is the frame's pixel size, used only to normalize the
    /// center distance (see `centerSimilarity`).
    @discardableResult
    func process(detections: [CGRect], at date: Date, frameSize: CGSize) -> [FaceTrack] {
        var result = TrackAssociationResult()

        // 1) Expiry before association.
        expireTracks(asOf: date, into: &result)

        // 2) Score all pairs above threshold.
        struct Candidate {
            let detectionIndex: Int
            let trackID: UUID
            let score: Double
            let trackCreatedAt: Date
        }
        var candidates: [Candidate] = []
        for (detectionIndex, detection) in detections.enumerated() {
            for track in records.values {
                let score = Self.associationScore(
                    detection: detection,
                    trackBox: track.boundingBox,
                    in: frameSize,
                    config: config
                )
                if score >= config.associationMatchThreshold {
                    candidates.append(Candidate(
                        detectionIndex: detectionIndex,
                        trackID: track.id,
                        score: score,
                        trackCreatedAt: track.createdAt
                    ))
                }
            }
        }

        // 3) Greedy mutually-best matching. Deterministic tie-breaks:
        //    score desc → detection index asc → track age asc (oldest wins)
        //    → UUID (last resort, keeps the sort a strict weak ordering).
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.detectionIndex != rhs.detectionIndex { return lhs.detectionIndex < rhs.detectionIndex }
            if lhs.trackCreatedAt != rhs.trackCreatedAt { return lhs.trackCreatedAt < rhs.trackCreatedAt }
            return lhs.trackID.uuidString < rhs.trackID.uuidString
        }
        var matchedDetectionIndexes = Set<Int>()
        var matchedTrackIDs = Set<UUID>()
        for candidate in candidates {
            guard !matchedDetectionIndexes.contains(candidate.detectionIndex),
                  !matchedTrackIDs.contains(candidate.trackID) else { continue }
            matchedDetectionIndexes.insert(candidate.detectionIndex)
            matchedTrackIDs.insert(candidate.trackID)
            result.matched.append(TrackAssociationResult.Match(
                detectionIndex: candidate.detectionIndex,
                trackID: candidate.trackID,
                score: candidate.score
            ))
        }

        // 4) Update matched tracks; remember this frame's ordering.
        var orderedIDs: [UUID] = []
        for match in result.matched.sorted(by: { $0.detectionIndex < $1.detectionIndex }) {
            guard var track = records[match.trackID] else { continue }
            track.boundingBox = detections[match.detectionIndex]
            track.lastSeen = date
            track.consecutiveMisses = 0
            track.hitCount += 1
            records[track.id] = track
            orderedIDs.append(track.id)
        }

        // 5) New tracks for unmatched detections, in detection order.
        for (detectionIndex, detection) in detections.enumerated()
        where !matchedDetectionIndexes.contains(detectionIndex) {
            let track = FaceTrack(
                id: UUID(),
                boundingBox: detection,
                identity: .unknown,
                attentionScore: 0,
                attentionState: .uncertain,
                lookingSince: nil,
                lastSeen: date,
                lastIdentityCheck: nil,
                lastPositiveAt: nil,
                lastNegativeAt: nil,
                createdAt: date,
                hitCount: 1,
                consecutiveMisses: 0,
                latestHeadPose: nil
            )
            records[track.id] = track
            result.newTracks.append(track.id)
            orderedIDs.append(track.id)
        }

        // 6) Retain unmatched live tracks across the gap (gray zone between
        //    maxDetectionGap and expiry stays alive but is not "missed").
        let newTrackIDs = Set(result.newTracks)
        var retained: [(createdAt: Date, id: UUID)] = []
        let unmatched = records.values.filter {
            !matchedTrackIDs.contains($0.id) && !newTrackIDs.contains($0.id)
        }
        for track in unmatched {
            var updated = track
            updated.consecutiveMisses += 1
            records[updated.id] = updated
            let gap = max(0, date.timeIntervalSince(track.lastSeen))
            if gap <= config.maxDetectionGap {
                result.missedTrackIDs.append(track.id)
            }
            retained.append((track.createdAt, track.id))
        }
        retained.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Report the short-gap subset in the same deterministic order.
        let missedSet = Set(result.missedTrackIDs)
        result.missedTrackIDs = retained.filter { missedSet.contains($0.id) }.map(\.id)
        orderedIDs.append(contentsOf: retained.map(\.id))

        lastAssociationResult = result
        rebuildSnapshot(ordered: orderedIDs)
        return tracks
    }

    /// Expiry-only cleanup for frames with no detections at all (or any other
    /// moment the detector wants to age tracks out). Same policy as `process`
    /// step 1; does not modify `lastAssociationResult`. Returns expired IDs.
    ///
    /// Note: `process(detections: [], at:frameSize:)` runs the same expiry, so
    /// a "no faces this frame" frame still keeps the tracker converging to an
    /// empty state once the expiry interval has passed.
    @discardableResult
    func expire(asOf date: Date) -> [UUID] {
        var result = TrackAssociationResult()
        expireTracks(asOf: date, into: &result)
        rebuildSnapshot(ordered: [])
        return result.expiredTrackIDs
    }

    // MARK: Detector write-back API

    /// Writes a recognition result onto the track. `checkedAt` stamps
    /// `lastIdentityCheck` so the detector's caching policy (M2-T05/T06) can
    /// decide when the next re-recognition is due. Returns `false` (and does
    /// nothing) if the track no longer exists — e.g. it expired between the
    /// recognition request and the result.
    @discardableResult
    func updateIdentity(id: UUID, identity: IdentityState, checkedAt: Date) -> Bool {
        guard var track = records[id] else { return false }
        track.identity = identity
        track.lastIdentityCheck = checkedAt
        records[id] = track
        syncSnapshot(track)
        return true
    }

    /// Writes one attention evaluation onto the track.
    ///
    /// - `result`: becomes the track's `attentionState`/`attentionScore`.
    /// - `lookingSince`: episode state — written as given; `nil` clears the
    ///   active looking episode.
    /// - `positiveAt` / `negativeAt`: historical markers — a non-nil date
    ///   overwrites `lastPositiveAt`/`lastNegativeAt`, `nil` leaves the
    ///   previous marker untouched (pass the date only on the matching
    ///   evaluation, e.g. `positiveAt: state == .looking ? date : nil`).
    ///
    /// Returns `false` (and does nothing) if the track no longer exists.
    @discardableResult
    func updateAttention(
        id: UUID,
        result: AttentionResult,
        lookingSince: Date?,
        positiveAt: Date?,
        negativeAt: Date?
    ) -> Bool {
        guard var track = records[id] else { return false }
        track.attentionState = result.state
        track.attentionScore = result.score
        track.lookingSince = lookingSince
        if let positiveAt { track.lastPositiveAt = positiveAt }
        if let negativeAt { track.lastNegativeAt = negativeAt }
        records[id] = track
        syncSnapshot(track)
        return true
    }

    /// Writes one head-pose reading onto the track (M2-T03). Unlike the
    /// marker semantics of `updateAttention`, `nil`-lessness does not apply:
    /// every call overwrites, and `.unavailable` is a real value that must
    /// replace a stale `.valid` pose so debug output never shows an old
    /// reading as current. Returns `false` if the track no longer exists.
    @discardableResult
    func updateHeadPose(id: UUID, headPose: HeadPoseResult) -> Bool {
        guard var track = records[id] else { return false }
        track.latestHeadPose = headPose
        records[id] = track
        syncSnapshot(track)
        return true
    }

    /// Writes the hysteresis-refined distance band onto the track (M3-T04).
    /// The tracker only STORES the band (band policy lives in the detector);
    /// persisting it here is what lets `DistanceBandHysteresis.refined` see
    /// the previous band on the next frame. Returns `false` if the track no
    /// longer exists.
    @discardableResult
    func updateDistanceBand(id: UUID, band: DistanceBand) -> Bool {
        guard var track = records[id] else { return false }
        track.distanceBand = band
        records[id] = track
        syncSnapshot(track)
        return true
    }

    /// Current snapshot of one track, or `nil` once it expired.
    func track(withID id: UUID) -> FaceTrack? {
        records[id]
    }

    /// Drops every track immediately (enrollment/calibration pauses, camera
    /// restarts). Identities and attention histories do not survive it.
    func reset() {
        records.removeAll()
        tracks = []
        lastAssociationResult = nil
    }

    // MARK: - Association score

    /// Combined association score in [0, 1]:
    ///
    ///     score = iouWeight·IoU
    ///           + centerDistanceWeight·centerSim
    ///           + sizeSimilarityWeight·sizeSim
    ///
    /// - `IoU`: intersection-over-union of the two boxes (0 for disjoint or
    ///   degenerate boxes, 1 for identical non-empty boxes).
    /// - `centerSim = clamp(1 − d/D, 0, 1)` where `d` is the Euclidean
    ///   distance between box centers scaled into pixels per axis
    ///   (`Δx·frameWidth`, `Δy·frameHeight`) and `D` is the frame diagonal
    ///   `hypot(frameWidth, frameHeight)` — i.e. the center offset as a
    ///   fraction of the frame diagonal. Degenerate `frameSize` falls back to
    ///   the unit-square diagonal √2. Identical centers → 1.
    /// - `sizeSim = clamp(1 − |ln(areaRatio)|, 0, 1)` where
    ///   `areaRatio = area(detection)/area(trackBox)`. Equal areas → 1; the
    ///   score reaches 0 at a ~2.72× area change (ln e = 1) and decays ~0.69
    ///   per halving/doubling. Symmetric in its arguments.
    ///
    /// With the default weights (0.5/0.3/0.2, summing to 1) two identical
    /// boxes score exactly 1.0.
    static func associationScore(
        detection: CGRect,
        trackBox: CGRect,
        in frameSize: CGSize,
        config: FaceTrackerConfig = FaceTrackerConfig()
    ) -> Double {
        config.iouWeight * iou(trackBox, detection)
            + config.centerDistanceWeight * centerSimilarity(trackBox, detection, in: frameSize)
            + config.sizeSimilarityWeight * sizeSimilarity(trackBox, detection)
    }

    /// Intersection-over-union of two boxes; 0 for disjoint or empty boxes.
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = Double(intersection.width) * Double(intersection.height)
        let areaA = Double(a.width) * Double(a.height)
        let areaB = Double(b.width) * Double(b.height)
        let unionArea = areaA + areaB - intersectionArea
        guard unionArea > 0 else { return 0 }
        return clamp(intersectionArea / unionArea)
    }

    /// Center-distance similarity; see `associationScore` for the formula.
    static func centerSimilarity(_ a: CGRect, _ b: CGRect, in frameSize: CGSize) -> Double {
        let dx = Double(a.midX - b.midX)
        let dy = Double(a.midY - b.midY)
        let width = Double(frameSize.width)
        let height = Double(frameSize.height)
        let diagonal = (width * width + height * height).squareRoot()
        let distanceOverDiagonal: Double
        if diagonal > 0 {
            // Offset in pixels per axis, as a fraction of the pixel diagonal.
            let distance = ((dx * width) * (dx * width) + (dy * height) * (dy * height)).squareRoot()
            distanceOverDiagonal = distance / diagonal
        } else {
            // Degenerate frame size: plain normalized distance over the
            // unit-square diagonal.
            distanceOverDiagonal = (dx * dx + dy * dy).squareRoot() / 2.0.squareRoot()
        }
        return clamp(1 - distanceOverDiagonal)
    }

    /// Face-size similarity; see `associationScore` for the formula.
    static func sizeSimilarity(_ a: CGRect, _ b: CGRect) -> Double {
        let areaA = Double(a.width) * Double(a.height)
        let areaB = Double(b.width) * Double(b.height)
        guard areaA > 0, areaB > 0 else { return 0 }
        return clamp(1 - abs(log(areaA / areaB)))
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    // MARK: - Internals

    /// Removes every track whose unseen time exceeds `trackExpiryInterval`,
    /// appending their IDs (deterministically ordered) to `result`.
    private func expireTracks(asOf date: Date, into result: inout TrackAssociationResult) {
        var expired: [(createdAt: Date, id: UUID)] = []
        for track in records.values
        where date.timeIntervalSince(track.lastSeen) > config.trackExpiryInterval {
            records.removeValue(forKey: track.id)
            expired.append((track.createdAt, track.id))
        }
        expired.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        result.expiredTrackIDs = expired.map(\.id)
    }

    /// Refreshes `tracks` from `records`: first the IDs of this frame's
    /// association order, then anything left (expired-asOf cleanup paths)
    /// oldest-first.
    private func rebuildSnapshot(ordered orderedIDs: [UUID]) {
        var remaining = records
        var snapshot: [FaceTrack] = []
        snapshot.reserveCapacity(records.count)
        for id in orderedIDs {
            if let track = remaining.removeValue(forKey: id) {
                snapshot.append(track)
            }
        }
        let rest = remaining.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        snapshot.append(contentsOf: rest)
        tracks = snapshot
    }

    /// Pushes a mutated track into the ordered snapshot (`tracks` holds value
    /// copies, so in-place writes must be mirrored).
    private func syncSnapshot(_ track: FaceTrack) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        }
    }
}
