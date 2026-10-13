import XCTest
@testable import PrivacyShieldCore

/// Deterministic unit tests for the centralized sensitivity presets (M4-T02):
/// the preset→profiles mapping (`profilesWithPreset`), the headline values
/// (`classifierTolerances` / `baseTriggerDuration`), the precedence chain
/// preset → band adaptation → user override (`effectiveProfiles` /
/// `effectiveTimingConfig`), and the calibration-safety guarantees (a preset
/// change never touches the screen-center fields, the distance-band
/// boundaries, or the base profiles).
///
/// Pure value-struct logic only — no UserDefaults, no singletons, so every
/// test is order-independent by construction.
final class SensitivityPresetTests: XCTestCase {

    // MARK: - Fixtures and helpers

    private let allPresets: [SensitivityPreset] = [.conservative, .balanced, .sensitive]
    private let accuracy = 1e-12

    /// The three bands in strictness order (near → mid → far).
    private func bands(of profiles: DistanceAttentionProfiles)
        -> [(name: String, config: AttentionClassifierConfig, timing: AttentionTimingConfig)] {
        [("near", profiles.near, profiles.nearTiming),
         ("mid", profiles.mid, profiles.midTiming),
         ("far", profiles.far, profiles.farTiming)]
    }

    // DistanceAttentionProfiles and its nested configs do not declare
    // Equatable, so exactness is asserted field by field.

    private func assertEqual(_ a: AttentionClassifierConfig,
                             _ b: AttentionClassifierConfig,
                             _ message: String = "",
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(a.screenCenterYaw, b.screenCenterYaw, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.screenCenterPitch, b.screenCenterPitch, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.yawTolerance, b.yawTolerance, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.pitchTolerance, b.pitchTolerance, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.rollTolerance, b.rollTolerance, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.yawWeight, b.yawWeight, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.pitchWeight, b.pitchWeight, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.rollWeight, b.rollWeight, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.lookingThreshold, b.lookingThreshold, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.notLookingThreshold, b.notLookingThreshold, accuracy: accuracy, message, file: file, line: line)
    }

    private func assertEqual(_ a: AttentionTimingConfig,
                             _ b: AttentionTimingConfig,
                             _ message: String = "",
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(a.triggerDuration, b.triggerDuration, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.releaseDuration, b.releaseDuration, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.uncertainGrace, b.uncertainGrace, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.maxDelta, b.maxDelta, accuracy: accuracy, message, file: file, line: line)
    }

    private func assertEqual(_ a: DistanceAttentionProfiles,
                             _ b: DistanceAttentionProfiles,
                             _ message: String = "",
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        assertEqual(a.near, b.near, message, file: file, line: line)
        assertEqual(a.mid, b.mid, message, file: file, line: line)
        assertEqual(a.far, b.far, message, file: file, line: line)
        assertEqual(a.nearTiming, b.nearTiming, message, file: file, line: line)
        assertEqual(a.midTiming, b.midTiming, message, file: file, line: line)
        assertEqual(a.farTiming, b.farTiming, message, file: file, line: line)
    }

    // MARK: - Balanced == base, exactly

    func testBalancedLeavesStandardProfilesUnchanged() {
        let effective = profilesWithPreset(.balanced, base: .standard)

        assertEqual(effective, .standard)
    }

    func testBalancedEffectiveProfilesEqualBaseExactly() {
        var settings = AttentionSettings()  // preset .balanced, no overrides
        settings.sensitivityPreset = .balanced

        let effective = settings.effectiveProfiles(base: .standard)

        assertEqual(effective, .standard)
    }

    // MARK: - Strictness direction vs balanced

    func testConservativeIsStricterThanBalancedInEveryBand() {
        let conservative = profilesWithPreset(.conservative, base: .standard)
        let balanced = DistanceAttentionProfiles.standard

        for (cb, bb) in zip(bands(of: conservative), bands(of: balanced)) {
            XCTAssertLessThan(cb.config.yawTolerance, bb.config.yawTolerance, "\(cb.name) yaw")
            XCTAssertLessThan(cb.config.pitchTolerance, bb.config.pitchTolerance, "\(cb.name) pitch")
            XCTAssertGreaterThan(cb.timing.triggerDuration, bb.timing.triggerDuration, "\(cb.name) trigger")
        }
    }

    func testSensitiveIsLooserAndFasterThanBalancedInEveryBand() {
        let sensitive = profilesWithPreset(.sensitive, base: .standard)
        let balanced = DistanceAttentionProfiles.standard

        for (sb, bb) in zip(bands(of: sensitive), bands(of: balanced)) {
            XCTAssertGreaterThan(sb.config.yawTolerance, bb.config.yawTolerance, "\(sb.name) yaw")
            XCTAssertGreaterThan(sb.config.pitchTolerance, bb.config.pitchTolerance, "\(sb.name) pitch")
            XCTAssertLessThan(sb.timing.triggerDuration, bb.timing.triggerDuration, "\(sb.name) trigger")
        }
    }

    // MARK: - Band relationships within each preset

    func testBandOrderingPreservedWithinEveryPreset() {
        for preset in allPresets {
            let bands = bands(of: profilesWithPreset(preset, base: .standard))

            // Tolerances: near strictest < mid < far loosest.
            XCTAssertLessThan(bands[0].config.yawTolerance, bands[1].config.yawTolerance, "\(preset) near<mid yaw")
            XCTAssertLessThan(bands[1].config.yawTolerance, bands[2].config.yawTolerance, "\(preset) mid<far yaw")
            XCTAssertLessThan(bands[0].config.pitchTolerance, bands[1].config.pitchTolerance, "\(preset) near<mid pitch")
            XCTAssertLessThan(bands[1].config.pitchTolerance, bands[2].config.pitchTolerance, "\(preset) mid<far pitch")

            // Triggers: near fastest < mid < far slowest.
            XCTAssertLessThan(bands[0].timing.triggerDuration, bands[1].timing.triggerDuration, "\(preset) near<mid trigger")
            XCTAssertLessThan(bands[1].timing.triggerDuration, bands[2].timing.triggerDuration, "\(preset) mid<far trigger")
        }
    }

    // MARK: - Exact mapping (pins the documented tables)

    func testHeadlineValuesMatchPlanSection16() {
        // Plan section 16 headline numbers (the MID band of each preset).
        XCTAssertEqual(SensitivityPreset.conservative.classifierTolerances().yaw, 15.0, accuracy: accuracy)
        XCTAssertEqual(SensitivityPreset.conservative.classifierTolerances().pitch, 12.0, accuracy: accuracy)
        XCTAssertEqual(SensitivityPreset.conservative.baseTriggerDuration(), 1.5, accuracy: accuracy)

        XCTAssertEqual(SensitivityPreset.balanced.classifierTolerances().yaw, 22.0, accuracy: accuracy)
        XCTAssertEqual(SensitivityPreset.balanced.classifierTolerances().pitch, 18.0, accuracy: accuracy)
        XCTAssertEqual(SensitivityPreset.balanced.baseTriggerDuration(), 0.9, accuracy: accuracy)

        XCTAssertEqual(SensitivityPreset.sensitive.classifierTolerances().yaw, 30.0, accuracy: accuracy)
        XCTAssertEqual(SensitivityPreset.sensitive.classifierTolerances().pitch, 25.0, accuracy: accuracy)
        XCTAssertEqual(SensitivityPreset.sensitive.baseTriggerDuration(), 0.6, accuracy: accuracy)
    }

    func testConservativeExactBandValues() {
        let profiles = profilesWithPreset(.conservative, base: .standard)

        // Near: 18−7=11° / 15−6=9° (floors at 10°/8° not reached), 0.7+0.6 s.
        XCTAssertEqual(profiles.near.yawTolerance, 11.0, accuracy: accuracy)
        XCTAssertEqual(profiles.near.pitchTolerance, 9.0, accuracy: accuracy)
        XCTAssertEqual(profiles.nearTiming.triggerDuration, 1.3, accuracy: accuracy)
        XCTAssertEqual(profiles.nearTiming.releaseDuration, 0.8, accuracy: accuracy)

        // Mid: the plan headline 15°/12°/1.5 s.
        XCTAssertEqual(profiles.mid.yawTolerance, 15.0, accuracy: accuracy)
        XCTAssertEqual(profiles.mid.pitchTolerance, 12.0, accuracy: accuracy)
        XCTAssertEqual(profiles.midTiming.triggerDuration, 1.5, accuracy: accuracy)
        XCTAssertEqual(profiles.midTiming.releaseDuration, 0.8, accuracy: accuracy)

        // Far: 27−7=20° / 22−6=16°, 1.2+0.6 s.
        XCTAssertEqual(profiles.far.yawTolerance, 20.0, accuracy: accuracy)
        XCTAssertEqual(profiles.far.pitchTolerance, 16.0, accuracy: accuracy)
        XCTAssertEqual(profiles.farTiming.triggerDuration, 1.8, accuracy: accuracy)
        XCTAssertEqual(profiles.farTiming.releaseDuration, 0.8, accuracy: accuracy)
    }

    func testSensitiveExactBandValues() {
        let profiles = profilesWithPreset(.sensitive, base: .standard)

        // Near: 18+8=26° / 15+7=22°, trigger floored at 0.55 s (0.7−0.3=0.4
        // would sit below the default maxDelta of 0.5 s).
        XCTAssertEqual(profiles.near.yawTolerance, 26.0, accuracy: accuracy)
        XCTAssertEqual(profiles.near.pitchTolerance, 22.0, accuracy: accuracy)
        XCTAssertEqual(profiles.nearTiming.triggerDuration, 0.55, accuracy: accuracy)

        // Mid: the plan headline 30°/25°/0.6 s.
        XCTAssertEqual(profiles.mid.yawTolerance, 30.0, accuracy: accuracy)
        XCTAssertEqual(profiles.mid.pitchTolerance, 25.0, accuracy: accuracy)
        XCTAssertEqual(profiles.midTiming.triggerDuration, 0.6, accuracy: accuracy)

        // Far: 27+8=35° / 22+7=29°, 1.2−0.3=0.9 s (no floor).
        XCTAssertEqual(profiles.far.yawTolerance, 35.0, accuracy: accuracy)
        XCTAssertEqual(profiles.far.pitchTolerance, 29.0, accuracy: accuracy)
        XCTAssertEqual(profiles.farTiming.triggerDuration, 0.9, accuracy: accuracy)

        // Release unchanged for sensitive.
        XCTAssertEqual(profiles.nearTiming.releaseDuration, 0.6, accuracy: accuracy)
        XCTAssertEqual(profiles.midTiming.releaseDuration, 0.6, accuracy: accuracy)
        XCTAssertEqual(profiles.farTiming.releaseDuration, 0.6, accuracy: accuracy)
    }

    // MARK: - Untouched knobs and invariants

    func testPresetsLeaveRollWeightsThresholdsCenterGraceAndMaxDeltaUntouched() {
        let base = DistanceAttentionProfiles.standard

        for preset in allPresets {
            let profiles = profilesWithPreset(preset, base: base)
            for (pb, bb) in zip(bands(of: profiles), bands(of: base)) {
                // Roll tolerance, weights and thresholds stay shared.
                XCTAssertEqual(pb.config.rollTolerance, bb.config.rollTolerance, accuracy: accuracy)
                XCTAssertEqual(pb.config.yawWeight, bb.config.yawWeight, accuracy: accuracy)
                XCTAssertEqual(pb.config.pitchWeight, bb.config.pitchWeight, accuracy: accuracy)
                XCTAssertEqual(pb.config.rollWeight, bb.config.rollWeight, accuracy: accuracy)
                XCTAssertEqual(pb.config.lookingThreshold, bb.config.lookingThreshold, accuracy: accuracy)
                XCTAssertEqual(pb.config.notLookingThreshold, bb.config.notLookingThreshold, accuracy: accuracy)
                // The calibrated screen center is never touched by a preset
                // (owned by ScreenCenterStore; the placeholders pass through).
                XCTAssertEqual(pb.config.screenCenterYaw, bb.config.screenCenterYaw, accuracy: accuracy)
                XCTAssertEqual(pb.config.screenCenterPitch, bb.config.screenCenterPitch, accuracy: accuracy)
                // Grace and maxDelta are not preset knobs either.
                XCTAssertEqual(pb.timing.uncertainGrace, bb.timing.uncertainGrace, accuracy: accuracy)
                XCTAssertEqual(pb.timing.maxDelta, bb.timing.maxDelta, accuracy: accuracy)
            }
        }
    }

    func testEveryPresetBandTriggerStaysAboveDefaultMaxDelta() {
        for preset in allPresets {
            for band in bands(of: profilesWithPreset(preset, base: .standard)) {
                XCTAssertGreaterThan(band.timing.triggerDuration, band.timing.maxDelta,
                                     "\(preset)/\(band.name): a single update must never raise the alert")
            }
        }
    }

    // MARK: - Purity (base struct never mutated)

    func testProfilesWithPresetDoesNotMutateBase() {
        let original = DistanceAttentionProfiles.standard
        var base = original

        var conservative = profilesWithPreset(.conservative, base: base)
        conservative.far.yawTolerance = 99
        conservative.midTiming.triggerDuration = 99

        assertEqual(base, original)
    }

    func testEffectiveProfilesDoesNotMutateBase() {
        let original = DistanceAttentionProfiles.standard
        var base = original
        var settings = AttentionSettings()
        settings.sensitivityPreset = .sensitive

        var effective = settings.effectiveProfiles(base: base)
        // The returned profiles are fresh configs carrying the preset shift...
        XCTAssertEqual(effective.mid.yawTolerance, 30.0, accuracy: accuracy)
        // ...and mutating them cannot leak into the base struct.
        effective.near.yawTolerance = 0
        effective.farTiming.triggerDuration = 0

        assertEqual(base, original)
    }

    // MARK: - Precedence: preset → band → user override

    func testTriggerOverrideWinsOverEveryPresetAndBand() {
        var settings = AttentionSettings()
        settings.triggerDurationOverride = 2.0

        for preset in allPresets {
            settings.sensitivityPreset = preset
            for band in bands(of: profilesWithPreset(preset, base: .standard)) {
                let effective = settings.effectiveTimingConfig(base: band.timing)
                XCTAssertEqual(effective.triggerDuration, 2.0, accuracy: accuracy,
                               "\(preset)/\(band.name): override replaces the band trigger")
                XCTAssertEqual(effective.releaseDuration, band.timing.releaseDuration, accuracy: accuracy,
                               "\(preset)/\(band.name): release stays on the band value")
                XCTAssertEqual(effective.uncertainGrace, band.timing.uncertainGrace, accuracy: accuracy)
                XCTAssertEqual(effective.maxDelta, band.timing.maxDelta, accuracy: accuracy)
            }
        }
    }

    func testEffectiveProfilesAppliesPresetThenOverrides() {
        var settings = AttentionSettings()
        settings.sensitivityPreset = .conservative
        settings.triggerDurationOverride = 2.0
        settings.releaseDurationOverride = 1.0

        let effective = settings.effectiveProfiles(base: .standard)
        let presetOnly = profilesWithPreset(.conservative, base: .standard)

        // Classifier side: preset applied to every band.
        assertEqual(effective.near, presetOnly.near)
        assertEqual(effective.mid, presetOnly.mid)
        assertEqual(effective.far, presetOnly.far)

        // Timing side: the user override replaces every band's
        // preset-adjusted timing; grace stays on the band value.
        for band in bands(of: effective) {
            XCTAssertEqual(band.timing.triggerDuration, 2.0, accuracy: accuracy, band.name)
            XCTAssertEqual(band.timing.releaseDuration, 1.0, accuracy: accuracy, band.name)
            XCTAssertEqual(band.timing.uncertainGrace, 0.35, accuracy: accuracy, band.name)
            XCTAssertEqual(band.timing.maxDelta, 0.5, accuracy: accuracy, band.name)
        }
    }

    func testEffectiveProfilesWithoutOverridesMatchesPresetProfiles() {
        var settings = AttentionSettings()
        settings.sensitivityPreset = .sensitive

        let effective = settings.effectiveProfiles(base: .standard)

        assertEqual(effective, profilesWithPreset(.sensitive, base: .standard))
    }

    // MARK: - Calibration safety at the settings level

    func testChangingPresetLeavesOtherSettingsFieldsUntouched() {
        var settings = AttentionSettings()
        settings.nearMaxFaceWidth = 0.31
        settings.midMaxFaceWidth = 0.19
        settings.farMaxFaceWidth = 0.11
        settings.triggerDurationOverride = 1.1
        settings.blurWhenOwnerAbsent = false
        let before = settings

        settings.sensitivityPreset = .sensitive

        // Only the preset field moved; the distance-band boundaries (and
        // every other field) survive the change, so calibration and the
        // band classifier can never be corrupted by switching presets.
        var expected = before
        expected.sensitivityPreset = .sensitive
        XCTAssertEqual(settings, expected)
        XCTAssertEqual(settings.nearMaxFaceWidth, 0.31, accuracy: accuracy)
        XCTAssertEqual(settings.midMaxFaceWidth, 0.19, accuracy: accuracy)
        XCTAssertEqual(settings.farMaxFaceWidth, 0.11, accuracy: accuracy)
    }
}
