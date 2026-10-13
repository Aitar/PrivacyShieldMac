import XCTest
@testable import PrivacyShieldCore

/// Deterministic unit tests for ScreenDirectionCalibrationCollector and
/// ScreenCenterStore (M3-T01).
///
/// No camera, no Vision, no wall clock: every observation is constructed
/// directly and every timestamp is a fixed base date plus exact offsets, so
/// results are fully reproducible.
final class ScreenDirectionCalibrationTests: XCTestCase {

    private let accuracy = 1e-9
    private let baseDate = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Fixtures

    /// Valid pose cycling yaw 5/6/7 and pitch −5/−4/−3 so the expected
    /// medians are exactly 6 and −4 for the sample counts used here.
    private func cleanPose(index: Int) -> HeadPoseResult {
        let yaws = [5.0, 6.0, 7.0]
        let pitches = [-5.0, -4.0, -3.0]
        return .valid(HeadPose(
            yaw: yaws[index % 3],
            pitch: pitches[index % 3],
            roll: 0.0,
            confidence: 1.0
        ))
    }

    private func cleanObservations(count: Int) -> [HeadPoseResult] {
        return (0..<count).map { cleanPose(index: $0) }
    }

    /// Feeds observations at a fixed 0.1 s cadence starting at `baseDate`
    /// (well inside the default 3 s collection window).
    private func feed(_ collector: ScreenDirectionCalibrationCollector, _ observations: [HeadPoseResult]) {
        for (index, observation) in observations.enumerated() {
            collector.add(observation, at: baseDate.addingTimeInterval(Double(index) * 0.1))
        }
    }

    private func makeCollector() -> ScreenDirectionCalibrationCollector {
        return ScreenDirectionCalibrationCollector(config: .default)
    }

    // MARK: - Clean session

    func testCleanSamplesProduceMedianResultAndCompleteFlag() throws {
        let collector = makeCollector()
        XCTAssertFalse(collector.isComplete)

        feed(collector, Array(cleanObservations(count: 14)))
        XCTAssertEqual(collector.sampleCount, 14)
        XCTAssertFalse(collector.isComplete, "14 < 15 required valid samples")

        collector.add(cleanPose(index: 14), at: baseDate.addingTimeInterval(1.4))
        XCTAssertEqual(collector.sampleCount, 15)
        XCTAssertTrue(collector.isComplete)

        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.centerYaw, 6.0, accuracy: accuracy)
        XCTAssertEqual(result.centerPitch, -4.0, accuracy: accuracy)
        XCTAssertEqual(result.sampleCount, 15)
        XCTAssertEqual(result.validityRate, 1.0, accuracy: accuracy)

        // finish() is non-mutating: a second call returns the same result.
        XCTAssertEqual(collector.finish(), result)
    }

    // MARK: - Unavailable samples

    func testUnavailableSamplesLowerValidityRateButCalibrationSucceeds() throws {
        // 20 observations, every 4th unavailable → 15 valid, 5 unavailable.
        var observations: [HeadPoseResult] = []
        var validIndex = 0
        for slot in 0..<20 {
            if slot % 4 == 3 {
                observations.append(.unavailable)
            } else {
                observations.append(cleanPose(index: validIndex))
                validIndex += 1
            }
        }
        XCTAssertEqual(validIndex, 15)

        let collector = makeCollector()
        feed(collector, observations)

        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.centerYaw, 6.0, accuracy: accuracy)
        XCTAssertEqual(result.centerPitch, -4.0, accuracy: accuracy)
        XCTAssertEqual(result.sampleCount, 15)
        XCTAssertEqual(result.validityRate, 0.75, accuracy: accuracy)
    }

    // MARK: - Outlier rejection

    func testStrongYawOutlierIsRejectedAndMedianUnaffected() throws {
        var observations = cleanObservations(count: 15)
        observations.append(.valid(HeadPose(yaw: 60.0, pitch: -4.0, roll: 0.0, confidence: 1.0)))

        let collector = makeCollector()
        feed(collector, observations)
        XCTAssertEqual(collector.sampleCount, 16, "all 16 observations were valid")

        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.centerYaw, 6.0, accuracy: accuracy, "60° outlier must not shift the median")
        XCTAssertEqual(result.centerPitch, -4.0, accuracy: accuracy)
        XCTAssertEqual(result.sampleCount, 15, "exactly the outlier sample was dropped")
        XCTAssertEqual(result.validityRate, 1.0, accuracy: accuracy)
    }

    func testStrongPitchOutlierIsRejectedAndMedianUnaffected() throws {
        var observations = cleanObservations(count: 15)
        observations.append(.valid(HeadPose(yaw: 6.0, pitch: 50.0, roll: 0.0, confidence: 1.0)))

        let collector = makeCollector()
        feed(collector, observations)

        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.centerYaw, 6.0, accuracy: accuracy)
        XCTAssertEqual(result.centerPitch, -4.0, accuracy: accuracy, "50° pitch outlier must not shift the median")
        XCTAssertEqual(result.sampleCount, 15, "exactly the outlier sample was dropped")
    }

    // MARK: - Graceful failure

    func testTooFewValidSamplesFailGracefully() {
        let collector = makeCollector()
        feed(collector, cleanObservations(count: 10))

        XCTAssertFalse(collector.isComplete)
        XCTAssertNil(collector.finish(), "10 < 15 required valid samples → caller shows failure toast")
    }

    func testValidityRateBelowMinimumFailsGracefully() {
        // 15 valid + 16 unavailable → rate 15/31 ≈ 0.484 < 0.5. The valid
        // count alone (15 ≥ 15) would pass, so this isolates the rate gate.
        var observations = cleanObservations(count: 15)
        observations.append(contentsOf: Array(repeating: HeadPoseResult.unavailable, count: 16))

        let collector = makeCollector()
        feed(collector, observations)

        XCTAssertNil(collector.finish())
    }

    func testValidityRateExactlyAtMinimumSucceeds() throws {
        // 15 valid + 15 unavailable → rate exactly 0.5; the gate is
        // `rate < minimum`, so the boundary value must succeed.
        var observations = cleanObservations(count: 15)
        observations.append(contentsOf: Array(repeating: HeadPoseResult.unavailable, count: 15))

        let collector = makeCollector()
        feed(collector, observations)

        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.validityRate, 0.5, accuracy: accuracy)
        XCTAssertEqual(result.sampleCount, 15)
    }

    // MARK: - Collection window

    func testSamplesOutsideCollectionWindowAreIgnored() throws {
        let collector = makeCollector()
        feed(collector, cleanObservations(count: 15))
        XCTAssertEqual(collector.sampleCount, 15)

        // A sample exactly at the window boundary (3.0 s after the first
        // sample) is still accepted.
        collector.add(cleanPose(index: 15), at: baseDate.addingTimeInterval(3.0))
        XCTAssertEqual(collector.sampleCount, 16)

        // Samples past the window are ignored entirely: they count neither
        // as valid nor as observed.
        collector.add(cleanPose(index: 16), at: baseDate.addingTimeInterval(10.0))
        collector.add(.unavailable, at: baseDate.addingTimeInterval(10.1))
        XCTAssertEqual(collector.sampleCount, 16)

        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.sampleCount, 16)
        XCTAssertEqual(result.validityRate, 1.0, accuracy: accuracy, "late samples must not distort the rate")
        XCTAssertEqual(result.centerYaw, 6.0, accuracy: accuracy)
        XCTAssertEqual(result.centerPitch, -4.0, accuracy: accuracy)
    }

    // MARK: - Reset / reuse

    func testResetClearsStateAndAllowsNewSession() throws {
        let collector = makeCollector()
        feed(collector, cleanObservations(count: 15))
        XCTAssertTrue(collector.isComplete)

        collector.reset()
        XCTAssertEqual(collector.sampleCount, 0)
        XCTAssertFalse(collector.isComplete)
        XCTAssertNil(collector.finish())

        feed(collector, cleanObservations(count: 15))
        let result = try XCTUnwrap(collector.finish())
        XCTAssertEqual(result.centerYaw, 6.0, accuracy: accuracy)
        XCTAssertEqual(result.sampleCount, 15)
    }

    // MARK: - Config overrides

    func testCustomConfigValuesAreHonored() {
        // Lower requirement: 3 valid samples suffice.
        let small = ScreenDirectionCalibrationCollector(
            config: ScreenCalibrationConfig(requiredValidSamples: 3)
        )
        feed(small, cleanObservations(count: 3))
        XCTAssertTrue(small.isComplete)
        XCTAssertNotNil(small.finish())

        // Stricter validity rate: 0.75 < 0.9 → fail.
        let strict = ScreenDirectionCalibrationCollector(
            config: ScreenCalibrationConfig(minimumValidityRate: 0.9)
        )
        feed(strict, cleanObservations(count: 15) + [.unavailable, .unavailable, .unavailable, .unavailable, .unavailable])
        XCTAssertEqual(strict.sampleCount, 15)
        XCTAssertNil(strict.finish())

        // Shorter window: samples past 1.0 s are ignored.
        let shortWindow = ScreenDirectionCalibrationCollector(
            config: ScreenCalibrationConfig(collectionWindow: 1.0)
        )
        shortWindow.add(cleanPose(index: 0), at: baseDate)
        shortWindow.add(cleanPose(index: 1), at: baseDate.addingTimeInterval(0.5))
        shortWindow.add(cleanPose(index: 2), at: baseDate.addingTimeInterval(2.0))
        XCTAssertEqual(shortWindow.sampleCount, 2)
        XCTAssertNil(shortWindow.finish())
    }

    // MARK: - ScreenCenterStore

    private func makeIsolatedSuite(_ name: String) throws -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: name)
        return try XCTUnwrap(UserDefaults(suiteName: name), "suite name is a fixed non-empty string")
    }

    func testStoreSaveLoadRoundTrip() throws {
        let suiteName = "PrivacyShieldCoreTests.ScreenCenterStore.roundtrip"
        let defaults = try makeIsolatedSuite(suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(ScreenCenterStore.load(from: defaults), "fresh suite has no stored center")

        let result = ScreenCalibrationResult(
            centerYaw: 6.5,
            centerPitch: -4.25,
            sampleCount: 15,
            validityRate: 0.9
        )
        ScreenCenterStore.save(result, defaults: defaults)

        let loaded = try XCTUnwrap(ScreenCenterStore.load(from: defaults))
        XCTAssertEqual(loaded.yaw, 6.5, accuracy: accuracy)
        XCTAssertEqual(loaded.pitch, -4.25, accuracy: accuracy)
        XCTAssertNotNil(defaults.object(forKey: ScreenCenterStore.calibratedAtKey))
    }

    func testStoreSaveOverwritesPreviousValues() throws {
        let suiteName = "PrivacyShieldCoreTests.ScreenCenterStore.overwrite"
        let defaults = try makeIsolatedSuite(suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        ScreenCenterStore.save(
            ScreenCalibrationResult(centerYaw: 1.0, centerPitch: 2.0, sampleCount: 15, validityRate: 1.0),
            defaults: defaults
        )
        // Recalibration replaces the old values (plan acceptance criterion).
        ScreenCenterStore.save(
            ScreenCalibrationResult(centerYaw: 6.5, centerPitch: -4.25, sampleCount: 16, validityRate: 1.0),
            defaults: defaults
        )

        let loaded = try XCTUnwrap(ScreenCenterStore.load(from: defaults))
        XCTAssertEqual(loaded.yaw, 6.5, accuracy: accuracy)
        XCTAssertEqual(loaded.pitch, -4.25, accuracy: accuracy)
    }

    func testStoreLoadOnEmptySuiteReturnsNil() throws {
        let suiteName = "PrivacyShieldCoreTests.ScreenCenterStore.empty"
        let defaults = try makeIsolatedSuite(suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(ScreenCenterStore.load(from: defaults))
    }

    func testStoreClearRemovesPersistedValues() throws {
        let suiteName = "PrivacyShieldCoreTests.ScreenCenterStore.clear"
        let defaults = try makeIsolatedSuite(suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        ScreenCenterStore.save(
            ScreenCalibrationResult(centerYaw: 6.0, centerPitch: -4.0, sampleCount: 15, validityRate: 1.0),
            defaults: defaults
        )
        XCTAssertNotNil(ScreenCenterStore.load(from: defaults))

        ScreenCenterStore.clear(defaults: defaults)

        XCTAssertNil(ScreenCenterStore.load(from: defaults))
        XCTAssertNil(defaults.object(forKey: ScreenCenterStore.calibratedAtKey))
    }
}
