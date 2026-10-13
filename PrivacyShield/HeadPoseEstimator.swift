import Foundation
import Vision

// MARK: - Types

/// A single head-pose reading for one face, converted to degrees.
///
/// Angle semantics follow Vision's own conventions; see the sign-convention
/// discussion on `HeadPoseEstimator` for the authoritative description and
/// the parts that still need empirical validation.
struct HeadPose {
    let yaw: Double      // degrees
    let pitch: Double    // degrees
    let roll: Double     // degrees
    let confidence: Double
}

/// Outcome of head-pose extraction for one face observation.
///
/// `.unavailable` is returned whenever Vision did not supply the complete
/// pose (any of yaw/pitch/roll missing). Unavailable pose is NEVER mapped to
/// a zero pose: a silent zero would make a face with unknown orientation
/// look like a perfectly frontal, camera-facing face to the attention
/// classifier, which is the exact failure mode this module must avoid.
/// Missing pose must remain distinguishable from frontal pose.
enum HeadPoseResult {
    case valid(HeadPose)
    case unavailable
}

// MARK: - HeadPoseEstimator

/// Extracts head pose from `VNFaceObservation` results produced by
/// `VNDetectFaceRectanglesRequest`.
///
/// Coordinate and sign conventions
/// -------------------------------
/// Vision reports yaw/pitch/roll in RADIANS as optional `NSNumber`s; a nil
/// value means the angle was not computed for that observation. We convert
/// to degrees. Ranges per the Vision SDK header (VNObservation.h):
///
/// - yaw:   [-π/2, π/2]. SDK: "positive angle corresponds to counterclockwise
///          direction" (rotation about the vertical axis). Working mapping
///          used for the sanity labels: positive yaw = face turned toward
///          its own left as seen by the camera.
/// - pitch: [-π/2, π/2]. SDK: "positive angle corresponds to nodding head
///          down direction". NOTE: the original plan assumed "positive =
///          looking up", while the SDK header states the opposite. The
///          sanity labels below follow the plan's assumption, so a systematic
///          inversion during manual checks is exactly what they are designed
///          to expose — flip the labels (or classifier thresholds) once
///          confirmed, never silently.
/// - roll:  [-π, π). SDK: "positive angle corresponds to counterclockwise
///          direction", i.e. a counterclockwise tilt in the image plane.
///
/// All three sign mappings are provisional until validated: verify
/// empirically via M1-T08 sanity logs (turn the head left/right, up/down and
/// tilt in front of the camera, and record which sign Vision reports per
/// axis). The `sanityDescription` helper prints exactly the lines needed for
/// this check.
///
/// Note: `VNFaceObservation.pitch` requires macOS 12+ (the app target is far
/// beyond that), and pose values require a face-rectangles request revision
/// of at least 2 (yaw/roll) and 3 (pitch).
struct HeadPoseEstimator {

    /// Extracts the head pose from a Vision face observation.
    ///
    /// Policy: all-or-nothing. If ANY of yaw/pitch/roll is nil the result is
    /// `.unavailable`, even when the other two axes are present. Rationale:
    /// a pose with a missing axis cannot be interpreted by the rule-based
    /// attention classifier, and substituting 0 for a missing axis would
    /// fabricate a "frontal" reading — unavailable data must never be mapped
    /// to zero.
    func pose(from observation: VNFaceObservation) -> HeadPoseResult {
        guard
            let yawRadians = observation.yaw?.doubleValue,
            let pitchRadians = observation.pitch?.doubleValue,
            let rollRadians = observation.roll?.doubleValue
        else {
            return .unavailable
        }

        let pose = HeadPose(
            yaw: Self.degrees(fromRadians: yawRadians),
            pitch: Self.degrees(fromRadians: pitchRadians),
            roll: Self.degrees(fromRadians: rollRadians),
            confidence: Double(observation.confidence)
        )
        return .valid(pose)
    }

    /// Converts radians to degrees. Pure function, exercised by unit tests.
    static func degrees(fromRadians radians: Double) -> Double {
        return radians * 180.0 / .pi
    }

    // MARK: Manual sanity logging (M1-T08)

    /// One-line, human-readable summary for manual left/right/up/down checks.
    ///
    /// Example output:
    ///   "yaw: +12.3° (right) · pitch: -5.0° (down) · roll: +3.2° (ccw) · confidence: 0.87"
    ///   "head pose: unavailable (Vision supplied no complete yaw/pitch/roll)"
    ///
    /// Direction labels follow the plan's working sign convention (yaw:
    /// + right / - left; pitch: + up / - down; roll: + ccw / - cw; zero is
    /// grouped with positive). If live logs during M1-T08 consistently show
    /// the opposite sign for an axis, update the labels there and in the
    /// sign-convention comment above.
    static func sanityDescription(_ result: HeadPoseResult) -> String {
        switch result {
        case .unavailable:
            return "head pose: unavailable (Vision supplied no complete yaw/pitch/roll)"
        case .valid(let pose):
            return "yaw: \(signed(pose.yaw))° (\(yawDirection(pose.yaw)))"
                 + " · pitch: \(signed(pose.pitch))° (\(pitchDirection(pose.pitch)))"
                 + " · roll: \(signed(pose.roll))° (\(rollDirection(pose.roll)))"
                 + " · confidence: \(String(format: "%.2f", pose.confidence))"
        }
    }

    private static func signed(_ degrees: Double) -> String {
        return String(format: "%+.1f", degrees)
    }

    private static func yawDirection(_ degrees: Double) -> String {
        return degrees < 0 ? "left" : "right"
    }

    private static func pitchDirection(_ degrees: Double) -> String {
        return degrees < 0 ? "down" : "up"
    }

    private static func rollDirection(_ degrees: Double) -> String {
        return degrees < 0 ? "cw" : "ccw"
    }
}
