import XCTest
@testable import PrivacyShieldCore

/// M4-T06: the pure settings→policy mappings the FaceDetector integration
/// uses, extracted into `PrivacySettingsMapping` (FaceDetector.swift) so
/// they are testable without instantiating the detector (which needs a
/// `ShieldManager` and a camera).
///
/// No singletons, no wall clock, no UserDefaults — every input is a plain
/// value built here, so the tests are fully deterministic.
final class PrivacySettingsMappingTests: XCTestCase {

    // MARK: - Reason → display state

    /// Every shield reason maps onto its 1:1 blur state; `.none` reports the
    /// safe state. The device states (`.calibrating`, `.cameraUnavailable`)
    /// are never produced by the mapping — the detector/app delegate report
    /// those directly.
    func testDisplayStateMapsEveryReason() {
        XCTAssertEqual(PrivacySettingsMapping.displayState(for: .none), .monitoringSafe)
        XCTAssertEqual(PrivacySettingsMapping.displayState(for: .ownerAbsent), .ownerAbsent)
        XCTAssertEqual(PrivacySettingsMapping.displayState(for: .shoulderSurfer), .shoulderSurferDetected)
        XCTAssertEqual(PrivacySettingsMapping.displayState(for: .both), .bothPoliciesActive)
    }

    /// The mapping preserves the shield semantics: the reported state
    /// demands the blur exactly when the reason does.
    func testDisplayStateShieldDemandMatchesReason() {
        let allReasons: [PrivacyShieldReason] = [.none, .ownerAbsent, .shoulderSurfer, .both]
        for reason in allReasons {
            let state = PrivacySettingsMapping.displayState(for: reason)
            XCTAssertEqual(state.isShieldShown, reason.isShieldShown,
                           "reason \(reason.description) changed its blur demand via the mapping")
        }
    }

    /// Distinct reasons map to distinct states (no two reasons can report
    /// the same display state and alias each other's notifications).
    func testDisplayStateMappingIsInjective() {
        let reasons: [PrivacyShieldReason] = [.none, .ownerAbsent, .shoulderSurfer, .both]
        let states = reasons.map { PrivacySettingsMapping.displayState(for: $0) }
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                XCTAssertNotEqual(states[i], states[j],
                                  "reasons \(reasons[i].description) and \(reasons[j].description) alias")
            }
        }
    }

    // MARK: - Settings → privacy state machine config

    /// Defaults: both blur toggles on → both policy toggles on, and the
    /// owner-presence window keeps its default (no settings knob for it).
    func testPrivacyConfigFromDefaultSettings() {
        let config = PrivacySettingsMapping.privacyConfig(from: AttentionSettings())
        XCTAssertTrue(config.blurWhenOwnerAbsent)
        XCTAssertTrue(config.blurWhenShoulderSurferDetected)
        XCTAssertEqual(config.ownerPresenceWindow,
                       PrivacyStateMachineConfig.default.ownerPresenceWindow)
    }

    /// The two settings toggles map 1:1 and independently in all four
    /// combinations.
    func testPrivacyConfigMapsTogglesIndependently() {
        var settings = AttentionSettings()

        settings.blurWhenOwnerAbsent = false
        settings.blurWhenShoulderSurferDetected = true
        var config = PrivacySettingsMapping.privacyConfig(from: settings)
        XCTAssertFalse(config.blurWhenOwnerAbsent)
        XCTAssertTrue(config.blurWhenShoulderSurferDetected)

        settings.blurWhenOwnerAbsent = true
        settings.blurWhenShoulderSurferDetected = false
        config = PrivacySettingsMapping.privacyConfig(from: settings)
        XCTAssertTrue(config.blurWhenOwnerAbsent)
        XCTAssertFalse(config.blurWhenShoulderSurferDetected)

        settings.blurWhenOwnerAbsent = false
        settings.blurWhenShoulderSurferDetected = false
        config = PrivacySettingsMapping.privacyConfig(from: settings)
        XCTAssertFalse(config.blurWhenOwnerAbsent)
        XCTAssertFalse(config.blurWhenShoulderSurferDetected)
    }

    /// Turning both toggles off collapses the machine to `.none` for every
    /// input combination — the settings really are the policy's master
    /// switches end-to-end.
    func testPrivacyConfigBothOffNeverShields() {
        var settings = AttentionSettings()
        settings.blurWhenOwnerAbsent = false
        settings.blurWhenShoulderSurferDetected = false
        let machine = PrivacyStateMachine(config: PrivacySettingsMapping.privacyConfig(from: settings))
        for ownerPresent in [true, false] {
            for surfer in [true, false] {
                XCTAssertEqual(machine.evaluate(ownerPresent: ownerPresent,
                                                shoulderSurferDetected: surfer),
                               .none)
            }
        }
    }

    // MARK: - Settings → distance-band config

    /// The settings' default boundaries equal the DistanceBandConfig
    /// defaults, so first-launch behavior is unchanged by the wiring.
    func testBandConfigFromDefaultSettingsMatchesDistanceBandDefaults() {
        let config = PrivacySettingsMapping.bandConfig(from: AttentionSettings())
        let defaults = DistanceBandConfig.default
        XCTAssertEqual(config.nearMaxWidth, defaults.nearMaxWidth, accuracy: 1e-12)
        XCTAssertEqual(config.midMaxWidth, defaults.midMaxWidth, accuracy: 1e-12)
        XCTAssertEqual(config.farMaxWidth, defaults.farMaxWidth, accuracy: 1e-12)
        XCTAssertEqual(config.hysteresisMargin, defaults.hysteresisMargin, accuracy: 1e-12)
    }

    /// Custom boundaries flow through untouched (future tuning inputs).
    func testBandConfigUsesSettingsBoundaries() {
        var settings = AttentionSettings()
        settings.nearMaxFaceWidth = 0.50
        settings.midMaxFaceWidth = 0.30
        settings.farMaxFaceWidth = 0.10
        let config = PrivacySettingsMapping.bandConfig(from: settings)
        XCTAssertEqual(config.nearMaxWidth, 0.50, accuracy: 1e-12)
        XCTAssertEqual(config.midMaxWidth, 0.30, accuracy: 1e-12)
        XCTAssertEqual(config.farMaxWidth, 0.10, accuracy: 1e-12)
    }

    /// A classifier built from the mapped config classifies with the
    /// settings' boundaries (end-to-end sanity of the wiring).
    func testBandConfigDrivesClassifierBoundaries() {
        var settings = AttentionSettings()
        settings.nearMaxFaceWidth = 0.40
        settings.midMaxFaceWidth = 0.20
        settings.farMaxFaceWidth = 0.05
        let classifier = DistanceBandClassifier(
            config: PrivacySettingsMapping.bandConfig(from: settings))
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.45), .near)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.30), .mid)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.10), .far)
        XCTAssertEqual(classifier.band(forNormalizedFaceWidth: 0.04), .tooFarOrUnreliable)
    }

    // MARK: - Settings → effective profiles (wiring entry point sanity)

    /// The timing override the Looking Duration menu writes wins over the
    /// preset/band values through `effectiveProfiles` — the exact call the
    /// detector's `rebuildDerivedState` makes.
    func testEffectiveProfilesApplyTriggerOverride() {
        var settings = AttentionSettings()
        settings.sensitivityPreset = .conservative
        settings.triggerDurationOverride = 0.8

        let profiles = settings.effectiveProfiles(base: .standard)
        XCTAssertEqual(profiles.nearTiming.triggerDuration, 0.8, accuracy: 1e-12)
        XCTAssertEqual(profiles.midTiming.triggerDuration, 0.8, accuracy: 1e-12)
        XCTAssertEqual(profiles.farTiming.triggerDuration, 0.8, accuracy: 1e-12)
        // The preset's release shift (+0.2 s) is untouched by the trigger
        // override.
        XCTAssertEqual(profiles.midTiming.releaseDuration,
                       DistanceAttentionProfiles.standard.midTiming.releaseDuration + 0.2,
                       accuracy: 1e-12)
    }

    /// No override → the preset values pass through unchanged.
    func testEffectiveProfilesWithoutOverrideMatchPreset() {
        let settings = AttentionSettings()  // balanced, no overrides
        let profiles = settings.effectiveProfiles(base: .standard)
        XCTAssertEqual(profiles.midTiming.triggerDuration,
                       DistanceAttentionProfiles.standard.midTiming.triggerDuration,
                       accuracy: 1e-12)
        XCTAssertEqual(profiles.mid.yawTolerance,
                       DistanceAttentionProfiles.standard.mid.yawTolerance,
                       accuracy: 1e-12)
    }
}
