import XCTest
@testable import PrivacyShieldCore

/// Deterministic distance-band tests (M3-T03): pure logic, no camera, no
/// Vision, no wall clock. Uses the default `DistanceBandConfig` (placeholders
/// until M3-T06 tuning: nearMaxWidth 0.28, midMaxWidth 0.16, farMaxWidth 0.09,
/// hysteresisMargin 0.015) unless a test overrides it.
///
/// Documented conventions under test:
/// - Half-open intervals: a width exactly ON a boundary belongs to the
///   FARTHER band (boundary value never classified as the nearer band).
/// - Monotonicity: larger width ⇒ ordinal ≥ (farther…nearer: 0…3).
/// - Hysteresis: an existing band is kept until the width crosses the
///   relevant boundary BY MORE THAN the margin; crossing by exactly the
///   margin does not switch.
final class DistanceBandsTests: XCTestCase {

    // MARK: - Stateless classification (default config)

    func testDefaultConfigKnownWidths() {
        let classifier = DistanceBandClassifier()
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.40), .near)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.22), .mid)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.11), .far)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.05), .tooFarOrUnreliable)
    }

    /// Exactly on a boundary → the FARTHER band (half-open interval
    /// convention: each band owns `(lower, upper]`, so the boundary value
    /// itself never lands in the nearer band).
    func testExactBoundaryClassifiesToFartherBand() {
        let classifier = DistanceBandClassifier()
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.28), .mid)   // == nearMaxWidth → not near
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.16), .far)   // == midMaxWidth → not mid
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.09), .tooFarOrUnreliable) // == farMaxWidth → not far
        // And just above a boundary → the nearer band.
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.2801), .near)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.1601), .mid)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.0901), .far)
    }

    // MARK: - Monotonicity (M3-T03 acceptance criterion)

    /// For widths sampled 0.02…0.5 step 0.01, the band ordinal (tooFar = 0 …
    /// near = 3) is non-decreasing: larger width never maps to a farther band.
    /// The sample spans all four bands, so nothing is trivially constant.
    func testBandOrdinalIsNonDecreasingWithWidth() {
        let classifier = DistanceBandClassifier()

        var previousOrdinal = -1
        var seenBands = Set<DistanceBand>()
        for i in 2...50 {
            let width = Double(i) * 0.01
            let band = classifier.band(forNormalizedFaceWidth: width)
            seenBands.insert(band)
            XCTAssertGreaterThanOrEqual(band.ordinal, previousOrdinal,
                                        "width \(width) mapped to \(band) (ordinal \(band.ordinal)), "
                                        + "which is farther than the previous width's band")
            previousOrdinal = band.ordinal
        }
        XCTAssertEqual(seenBands, [.tooFarOrUnreliable, .far, .mid, .near],
                       "sampled widths should exercise all four bands")
    }

    // MARK: - Hysteresis (M3-T04 prerequisite)

    /// Previous `.mid`, width drops into far range by LESS than the margin
    /// (0.16 − 0.01 = 0.15 < 0.16, gap 0.01 < margin 0.015) → stays `.mid`.
    func testHysteresisKeepsPreviousBandWhenCrossedByLessThanMargin() {
        let refined = DistanceBandHysteresis.refined(previous: .mid,
                                                     current: .far,
                                                     width: 0.15,
                                                     config: .default)
        XCTAssertEqual(refined, .mid)
    }

    /// Previous `.mid`, width drops into far range by MORE than the margin
    /// (0.14 < 0.16 − 0.015 = 0.145, gap 0.02 > margin) → switches to `.far`.
    func testHysteresisSwitchesWhenCrossedByMoreThanMargin() {
        let refined = DistanceBandHysteresis.refined(previous: .mid,
                                                     current: .far,
                                                     width: 0.14,
                                                     config: .default)
        XCTAssertEqual(refined, .far)
    }

    /// Crossing by EXACTLY the margin does not switch (strict inequality,
    /// symmetric with the classifier's on-boundary → farther convention).
    func testHysteresisDoesNotSwitchWhenCrossedByExactlyMargin() {
        let config = DistanceBandConfig.default
        let boundary = config.midMaxWidth
        let refined = DistanceBandHysteresis.refined(previous: .mid,
                                                     current: .far,
                                                     width: boundary - config.hysteresisMargin,
                                                     config: config)
        XCTAssertEqual(refined, .mid)
    }

    /// Mirror direction: moving NEARER also needs to exceed the boundary by
    /// more than the margin before leaving the previous band.
    func testHysteresisAppliesToNearerTransitionsToo() {
        let config = DistanceBandConfig.default
        // Just above nearMaxWidth (0.29, crossed by 0.01 < margin) → stays .mid.
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .mid, current: .near,
                                                      width: 0.29, config: config),
                       .mid)
        // Well above (0.30, crossed by 0.02 > margin) → switches to .near.
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .mid, current: .near,
                                                      width: 0.30, config: config),
                       .near)
    }

    /// Previous nil (new track / first observation) → pure classification is
    /// returned unchanged, even inside the hysteresis dead zone.
    func testHysteresisWithNilPreviousReturnsPureClassification() {
        let config = DistanceBandConfig.default
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: nil, current: .far,
                                                      width: 0.15, config: config),
                       .far)
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: nil, current: .near,
                                                      width: 0.40, config: config),
                       .near)
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: nil, current: .tooFarOrUnreliable,
                                                      width: 0.05, config: config),
                       .tooFarOrUnreliable)
    }

    /// Same band as before → kept regardless of width (no oscillation).
    func testHysteresisKeepsBandWhenPreviousEqualsCurrent() {
        let config = DistanceBandConfig.default
        for width in [0.01, 0.08, 0.12, 0.20, 0.30, 0.45] {
            XCTAssertEqual(DistanceBandHysteresis.refined(previous: .mid, current: .mid,
                                                          width: width, config: config),
                           .mid, "width \(width)")
        }
    }

    /// Multi-band jumps (raw classification already deep in the new band)
    /// confirm immediately: the width is far beyond the boundary adjacent to
    /// the previous band.
    func testHysteresisConfirmsMultiBandJumpsImmediately() {
        let config = DistanceBandConfig.default
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .near, current: .far,
                                                      width: 0.12, config: config),
                       .far)
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .tooFarOrUnreliable, current: .near,
                                                      width: 0.40, config: config),
                       .near)
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .far, current: .tooFarOrUnreliable,
                                                      width: 0.05, config: config),
                       .tooFarOrUnreliable)
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .tooFarOrUnreliable, current: .far,
                                                      width: 0.11, config: config),
                       .far)
    }

    // MARK: - Custom config (calibration-derived boundaries; X-T01)

    /// A customized config (as a future calibration flow would persist) is
    /// respected by both the classifier and the hysteresis.
    func testCustomConfigBoundariesRespected() {
        var config = DistanceBandConfig.default
        config.nearMaxWidth = 0.50
        config.midMaxWidth = 0.30
        config.farMaxWidth = 0.10
        config.hysteresisMargin = 0.03
        let classifier = DistanceBandClassifier(config: config)

        // Classification follows the custom boundaries, on-boundary → farther.
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.55), .near)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.50), .mid)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.45), .mid)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.30), .far)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.25), .far)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.10), .tooFarOrUnreliable)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.08), .tooFarOrUnreliable)

        // Hysteresis uses the custom margin: 0.28 is inside the custom far
        // range and 0.28 > 0.30 − 0.03 = 0.27, so previous .mid keeps .mid
        // (with the default margin 0.015 this same width would switch).
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .mid, current: .far,
                                                      width: 0.28, config: config),
                       .mid)
        XCTAssertEqual(DistanceBandHysteresis.refined(previous: .mid, current: .far,
                                                      width: 0.26, config: config),
                       .far)

        // Default-config classifier is unaffected by the custom one (value
        // semantics: config is copied per instance).
        XCTAssertEqual(DistanceBandClassifier().band(forNormalizedFaceWidth: 0.45), .near)
        XCTAssertEqual(DistanceBandClassifier().band(forNormalizedFaceWidth: 0.22), .mid)
    }
}
