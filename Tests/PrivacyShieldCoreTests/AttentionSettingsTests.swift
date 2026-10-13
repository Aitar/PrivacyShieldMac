import XCTest
@testable import PrivacyShieldCore

/// Deterministic unit tests for AttentionSettings and AttentionSettingsStore
/// (M4-T01). Every test runs against its own isolated UserDefaults suite
/// (unique per test, cleared before and after), so nothing touches
/// `.standard` and tests are order-independent.
final class AttentionSettingsTests: XCTestCase {

    // MARK: - Fixtures

    /// Persistent-domain name created by `makeDefaults()` for the running
    /// test; removed again in `tearDown`.
    private var suiteName: String?

    override func tearDown() {
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        super.tearDown()
    }

    /// A completely empty, isolated defaults domain unique to this test.
    private func makeDefaults() throws -> UserDefaults {
        let name = "AttentionSettingsTests." + UUID().uuidString
        suiteName = name
        UserDefaults.standard.removePersistentDomain(forName: name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// A second, independent UserDefaults instance over the same persistent
    /// domain — stands in for the next app launch, which re-reads the same
    /// plist from disk.
    private func reopenDefaults() throws -> UserDefaults {
        let name = try XCTUnwrap(suiteName)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// A fully customized settings value: every field differs from the
    /// struct defaults, both overrides non-nil and distinct. Band
    /// boundaries keep the near > mid > far invariant.
    private var customizedSettings: AttentionSettings {
        var settings = AttentionSettings()
        settings.shoulderSurfDetectionEnabled = false
        settings.sensitivityPreset = .sensitive
        settings.triggerDurationOverride = 1.5
        settings.releaseDurationOverride = 2.25
        settings.nearMaxFaceWidth = 0.31
        settings.midMaxFaceWidth = 0.19
        settings.farMaxFaceWidth = 0.11
        settings.debugPreviewEnabled = true
        settings.blurWhenOwnerAbsent = false
        settings.blurWhenShoulderSurferDetected = false
        return settings
    }

    // MARK: - First launch

    func testFreshSuiteLoadReturnsStructDefaults() throws {
        let defaults = try makeDefaults()  // empty domain

        let loaded = AttentionSettingsStore.load(defaults: defaults)

        XCTAssertEqual(loaded, AttentionSettings())
        // Explicit spot checks on the fields whose defaults are NOT zero
        // (a missing-key misread as false/0.0 would fail these):
        XCTAssertTrue(loaded.shoulderSurfDetectionEnabled)
        XCTAssertEqual(loaded.sensitivityPreset, .balanced)
        XCTAssertNil(loaded.triggerDurationOverride)
        XCTAssertNil(loaded.releaseDurationOverride)
        XCTAssertEqual(loaded.nearMaxFaceWidth, 0.28, accuracy: 1e-12)
        XCTAssertEqual(loaded.midMaxFaceWidth, 0.16, accuracy: 1e-12)
        XCTAssertEqual(loaded.farMaxFaceWidth, 0.09, accuracy: 1e-12)
        XCTAssertFalse(loaded.debugPreviewEnabled)
        XCTAssertTrue(loaded.blurWhenOwnerAbsent)
        XCTAssertTrue(loaded.blurWhenShoulderSurferDetected)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesEveryField() throws {
        let defaults = try makeDefaults()
        let settings = customizedSettings

        AttentionSettingsStore.save(settings, defaults: defaults)
        let loaded = AttentionSettingsStore.load(defaults: defaults)

        XCTAssertEqual(loaded, settings)
        // Optional distinctions, explicitly (unwrapped so the accuracy
        // variant applies — a nil would fail at XCTUnwrap instead):
        XCTAssertEqual(try XCTUnwrap(loaded.triggerDurationOverride), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(loaded.releaseDurationOverride), 2.25, accuracy: 1e-12)
    }

    func testSettingsSurviveRestartSimulation() throws {
        let defaults = try makeDefaults()
        let settings = customizedSettings

        AttentionSettingsStore.save(settings, defaults: defaults)

        // Simulated restart: a brand-new UserDefaults instance over the
        // same persistent domain (a new process would re-read the same
        // plist from disk).
        let reopened = try reopenDefaults()
        XCTAssertEqual(AttentionSettingsStore.load(defaults: reopened), settings)
    }

    func testNilOverridesRoundTripAndStayDistinctFromZero() throws {
        let defaults = try makeDefaults()

        // Struct defaults carry nil overrides: a load must give nil, never 0.
        AttentionSettingsStore.save(AttentionSettings(), defaults: defaults)
        var loaded = AttentionSettingsStore.load(defaults: defaults)
        XCTAssertNil(loaded.triggerDurationOverride)
        XCTAssertNil(loaded.releaseDurationOverride)

        // An explicit override survives, and stays distinct from the nil case.
        var withOverride = AttentionSettings()
        withOverride.triggerDurationOverride = 0.0   // zero is a VALUE, not "absent"
        withOverride.releaseDurationOverride = 0.75
        AttentionSettingsStore.save(withOverride, defaults: defaults)
        loaded = AttentionSettingsStore.load(defaults: defaults)
        XCTAssertEqual(try XCTUnwrap(loaded.triggerDurationOverride), 0.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(loaded.releaseDurationOverride), 0.75, accuracy: 1e-12)
    }

    func testClearingOverrideRemovesKeySoLoadReturnsNil() throws {
        let defaults = try makeDefaults()
        var settings = AttentionSettings()
        settings.triggerDurationOverride = 1.5
        AttentionSettingsStore.save(settings, defaults: defaults)
        XCTAssertNotNil(AttentionSettingsStore.load(defaults: defaults).triggerDurationOverride)

        settings.triggerDurationOverride = nil
        AttentionSettingsStore.save(settings, defaults: defaults)

        let reloaded = AttentionSettingsStore.load(defaults: defaults)
        XCTAssertNil(reloaded.triggerDurationOverride)
        XCTAssertNil(defaults.object(forKey: AttentionSettingsStore.triggerDurationOverrideKey),
                     "a cleared override must remove its key, not store 0")
        XCTAssertNil(reloaded.releaseDurationOverride)
    }

    // MARK: - Field independence

    func testMutatingOneFieldDoesNotDisturbOthers() throws {
        let defaults = try makeDefaults()

        // Persist the customized baseline...
        let baseline = customizedSettings
        AttentionSettingsStore.save(baseline, defaults: defaults)

        // ...flip exactly one field...
        var mutated = AttentionSettingsStore.load(defaults: defaults)
        mutated.debugPreviewEnabled = false
        AttentionSettingsStore.save(mutated, defaults: defaults)

        // ...and confirm everything else still matches the baseline.
        let reloaded = AttentionSettingsStore.load(defaults: defaults)
        XCTAssertFalse(reloaded.debugPreviewEnabled)
        var expected = baseline
        expected.debugPreviewEnabled = false
        XCTAssertEqual(reloaded, expected)
    }

    func testUpdateHelperAppliesSingleMutationAndPersists() throws {
        let defaults = try makeDefaults()

        AttentionSettingsStore.update(defaults: defaults) { $0.blurWhenOwnerAbsent = false }

        let loaded = AttentionSettingsStore.load(defaults: defaults)
        XCTAssertFalse(loaded.blurWhenOwnerAbsent)
        XCTAssertEqual(loaded.sensitivityPreset, .balanced)
        XCTAssertTrue(loaded.shoulderSurfDetectionEnabled)
        XCTAssertTrue(loaded.blurWhenShoulderSurferDetected)
        XCTAssertNil(loaded.triggerDurationOverride)
    }

    // MARK: - effectiveTimingConfig

    func testEffectiveTimingConfigNilOverridesLeaveBaseUnchanged() {
        let settings = AttentionSettings()  // both overrides nil
        let base = AttentionTimingConfig(triggerDuration: 1.2,
                                         releaseDuration: 0.6,
                                         uncertainGrace: 0.35)

        let effective = settings.effectiveTimingConfig(base: base)

        XCTAssertEqual(effective.triggerDuration, 1.2, accuracy: 1e-12)
        XCTAssertEqual(effective.releaseDuration, 0.6, accuracy: 1e-12)
        XCTAssertEqual(effective.uncertainGrace, 0.35, accuracy: 1e-12)
        XCTAssertEqual(effective.maxDelta, base.maxDelta, accuracy: 1e-12)
    }

    func testEffectiveTimingConfigTriggerOverrideWinsOverBandProfile() {
        var settings = AttentionSettings()
        settings.triggerDurationOverride = 1.5
        let nearBandBase = DistanceAttentionProfiles.standard.nearTiming  // trigger 0.7 s

        let effective = settings.effectiveTimingConfig(base: nearBandBase)

        XCTAssertEqual(effective.triggerDuration, 1.5, accuracy: 1e-12)
        XCTAssertEqual(effective.releaseDuration, nearBandBase.releaseDuration, accuracy: 1e-12)
        XCTAssertEqual(effective.uncertainGrace, nearBandBase.uncertainGrace, accuracy: 1e-12)
    }

    func testEffectiveTimingConfigBothOverridesApplied() {
        var settings = AttentionSettings()
        settings.triggerDurationOverride = 1.5
        settings.releaseDurationOverride = 2.25
        let farBandBase = DistanceAttentionProfiles.standard.farTiming  // trigger 1.2 s, release 0.6 s

        let effective = settings.effectiveTimingConfig(base: farBandBase)

        XCTAssertEqual(effective.triggerDuration, 1.5, accuracy: 1e-12)
        XCTAssertEqual(effective.releaseDuration, 2.25, accuracy: 1e-12)
        XCTAssertEqual(effective.uncertainGrace, farBandBase.uncertainGrace, accuracy: 1e-12)
        XCTAssertEqual(effective.maxDelta, farBandBase.maxDelta, accuracy: 1e-12)
    }

    // MARK: - Sensitivity preset

    func testSensitivityPresetRawValuesRoundTrip() {
        XCTAssertEqual(SensitivityPreset.conservative.rawValue, "conservative")
        XCTAssertEqual(SensitivityPreset.balanced.rawValue, "balanced")
        XCTAssertEqual(SensitivityPreset.sensitive.rawValue, "sensitive")

        for preset in [SensitivityPreset.conservative, .balanced, .sensitive] {
            XCTAssertEqual(SensitivityPreset(rawValue: preset.rawValue), preset)
        }
    }

    func testLoadFallsBackToBalancedOnUnknownPresetRawValue() throws {
        let defaults = try makeDefaults()
        defaults.set("megalith", forKey: AttentionSettingsStore.sensitivityPresetKey)

        let loaded = AttentionSettingsStore.load(defaults: defaults)

        XCTAssertEqual(loaded.sensitivityPreset, .balanced)
    }
}
