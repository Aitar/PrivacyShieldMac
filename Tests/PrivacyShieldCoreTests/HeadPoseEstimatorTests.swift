import XCTest
import Vision
@testable import PrivacyShieldCore

/// Unit tests for HeadPoseEstimator.
///
/// Fully deterministic: no camera, no Vision request execution. Face
/// observations are constructed directly:
/// - `VNFaceObservation()` produces an observation whose yaw/pitch/roll are
///   nil (nothing populates them), which covers the `.unavailable` path.
/// - `VNFaceObservation(requestRevision:boundingBox:roll:yaw:pitch:)`
///   (macOS 12+) accepts exact radian values or nil per axis, which covers
///   the `.valid` conversion path and the "any missing axis -> unavailable"
///   policy. Note the factory argument order is roll, yaw, pitch.
/// Both constructors were verified against the macOS 26 SDK; they perform no
/// inference of any kind.
final class HeadPoseEstimatorTests: XCTestCase {

    private let accuracy = 1e-9

    // MARK: - Radians -> degrees conversion

    func testDegreesFromRadiansZero() {
        XCTAssertEqual(HeadPoseEstimator.degrees(fromRadians: 0.0), 0.0, accuracy: accuracy)
    }

    func testDegreesFromRadiansPiOverTwo() {
        XCTAssertEqual(HeadPoseEstimator.degrees(fromRadians: .pi / 2), 90.0, accuracy: accuracy)
    }

    func testDegreesFromRadiansPi() {
        XCTAssertEqual(HeadPoseEstimator.degrees(fromRadians: .pi), 180.0, accuracy: accuracy)
    }

    func testDegreesFromRadiansNegativePiOverTwo() {
        XCTAssertEqual(HeadPoseEstimator.degrees(fromRadians: -.pi / 2), -90.0, accuracy: accuracy)
    }

    func testDegreesFromRadiansTwoPi() {
        XCTAssertEqual(HeadPoseEstimator.degrees(fromRadians: 2 * .pi), 360.0, accuracy: accuracy)
    }

    // MARK: - Sanity description formatting (pure string logic)

    func testSanityDescriptionPositiveYawNegativePitch() {
        let result = HeadPoseResult.valid(HeadPose(yaw: 12.3, pitch: -5.0, roll: 0.0, confidence: 0.9))
        let text = HeadPoseEstimator.sanityDescription(result)
        XCTAssertTrue(text.contains("yaw: +12.3° (right)"), "got: \(text)")
        XCTAssertTrue(text.contains("pitch: -5.0° (down)"), "got: \(text)")
        XCTAssertTrue(text.contains("roll: +0.0° (ccw)"), "got: \(text)")
        XCTAssertTrue(text.contains("confidence: 0.90"), "got: \(text)")
    }

    func testSanityDescriptionNegativeYawPositivePitch() {
        let result = HeadPoseResult.valid(HeadPose(yaw: -12.3, pitch: 5.0, roll: -3.4, confidence: 0.8))
        let text = HeadPoseEstimator.sanityDescription(result)
        XCTAssertTrue(text.contains("yaw: -12.3° (left)"), "got: \(text)")
        XCTAssertTrue(text.contains("pitch: +5.0° (up)"), "got: \(text)")
        XCTAssertTrue(text.contains("roll: -3.4° (cw)"), "got: \(text)")
    }

    func testSanityDescriptionZeroValuesCarryExplicitPositiveSign() {
        let result = HeadPoseResult.valid(HeadPose(yaw: 0.0, pitch: 0.0, roll: 0.0, confidence: 1.0))
        let text = HeadPoseEstimator.sanityDescription(result)
        XCTAssertTrue(text.contains("yaw: +0.0°"), "got: \(text)")
        XCTAssertTrue(text.contains("pitch: +0.0°"), "got: \(text)")
        XCTAssertTrue(text.contains("roll: +0.0°"), "got: \(text)")
    }

    func testSanityDescriptionUnavailableMentionsUnavailable() {
        let text = HeadPoseEstimator.sanityDescription(.unavailable)
        XCTAssertTrue(text.contains("unavailable"), "got: \(text)")
    }

    // MARK: - VNFaceObservation -> HeadPoseResult (constructed, no inference)

    func testObservationWithoutPoseYieldsUnavailable() {
        // Plain init: no Vision request ran, so yaw/pitch/roll are nil.
        // The estimator must NOT map the missing pose to zero/frontal.
        let observation = VNFaceObservation()
        let result = HeadPoseEstimator().pose(from: observation)
        if case .valid = result {
            XCTFail("expected .unavailable for an observation without yaw/pitch/roll")
        }
    }

    func testObservationMissingAnyAxisYieldsUnavailable() {
        // All-or-nothing policy: even a single missing axis must yield
        // .unavailable, never a partially zero-filled pose.
        // Factory argument order is roll, yaw, pitch.
        let cases: [(String, NSNumber?, NSNumber?, NSNumber?)] = [
            ("roll only", NSNumber(value: 0.1), nil, nil),
            ("yaw only", nil, NSNumber(value: 0.1), nil),
            ("pitch only", nil, nil, NSNumber(value: 0.1)),
            ("roll+yaw", NSNumber(value: 0.1), NSNumber(value: 0.1), nil),
            ("roll+pitch", NSNumber(value: 0.1), nil, NSNumber(value: 0.1)),
            ("yaw+pitch", nil, NSNumber(value: 0.1), NSNumber(value: 0.1)),
        ]
        for (label, roll, yaw, pitch) in cases {
            let observation = VNFaceObservation(
                requestRevision: 3,
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                roll: roll,
                yaw: yaw,
                pitch: pitch
            )
            let result = HeadPoseEstimator().pose(from: observation)
            if case .valid = result {
                XCTFail("expected .unavailable when pose is incomplete (\(label))")
            }
        }
    }

    func testObservationWithFullPoseYieldsValidDegrees() {
        // π/6 rad -> 30°, -π/6 rad -> -30°, π/4 rad -> 45°.
        let observation = VNFaceObservation(
            requestRevision: 3,
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            roll: NSNumber(value: Double.pi / 4),
            yaw: NSNumber(value: Double.pi / 6),
            pitch: NSNumber(value: -Double.pi / 6)
        )
        let result = HeadPoseEstimator().pose(from: observation)
        guard case .valid(let pose) = result else {
            return XCTFail("expected .valid for an observation with complete yaw/pitch/roll")
        }
        XCTAssertEqual(pose.yaw, 30.0, accuracy: accuracy)
        XCTAssertEqual(pose.pitch, -30.0, accuracy: accuracy)
        XCTAssertEqual(pose.roll, 45.0, accuracy: accuracy)
        // Hand-built observations carry no real detection confidence; only
        // the forwarding itself matters here.
        XCTAssertEqual(pose.confidence, Double(observation.confidence), accuracy: accuracy)
    }
}
