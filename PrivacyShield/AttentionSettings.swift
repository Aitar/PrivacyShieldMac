import Foundation

// MARK: - Settings model (M4-T01, plan M4-A)
//
// One value struct holding every user-facing attention/shield setting,
// persisted by `AttentionSettingsStore` so settings survive an app restart
// and first launch starts on valid defaults.
//
// Deliberately NOT duplicated here (single source of truth):
// - Screen center yaw/pitch — owned by `ScreenCenterStore` (M3-T01, keys
//   `screenCenterYaw` / `screenCenterPitch` / `screenCenterCalibratedAt`).
//   Duplicating it here would create two writers for one calibrated value;
//   readers keep going through `ScreenCenterStore.load(from:)`.
// - Debug logging — the `debugLoggingEnabled` key is owned by
//   `DiagnosticsLog.isDebugLoggingEnabled`; this struct only carries the
//   separate `debugPreviewEnabled` overlay flag (M4-T05).

/// User-facing sensitivity level (plan M4-A). `.balanced` carries the
/// M3-tuned values (`DistanceAttentionProfiles.standard`); `.conservative`
/// and `.sensitive` re-map the same knobs — the preset-to-values mapping is
/// implemented by M4-T02, the setting only records the user's choice.
///
/// Persisted as its `rawValue` string, so new cases can be added later
/// without invalidating previously stored values.
enum SensitivityPreset: String {
    case conservative
    /// M3 tuned values (M3-T06 tuned profiles).
    case balanced
    case sensitive
}

/// All user-facing attention/shield settings in one value struct (M4-T01).
/// Field defaults are the valid first-launch configuration.
struct AttentionSettings: Equatable {

    /// Master switch for shoulder-surfing detection.
    var shoulderSurfDetectionEnabled: Bool = true

    /// Which sensitivity preset the user picked (M4-T02 maps it to values).
    var sensitivityPreset: SensitivityPreset = .balanced

    /// User override for the sustained-looking trigger duration, in seconds.
    /// `nil` = use the preset/band value (the base config passed to
    /// `effectiveTimingConfig(base:)`). A non-nil override WINS over band
    /// profiles.
    var triggerDurationOverride: Double? = nil

    /// User override for the alert release duration, in seconds. `nil` =
    /// use the preset/band value. A non-nil override WINS over band
    /// profiles.
    var releaseDurationOverride: Double? = nil

    // Distance-band boundaries, M3-T03 defaults (mirroring the initial
    // `DistanceBandConfig` values). Wired into the band classifier by the
    // M4-T06 settings wiring.
    /// Width above this → `.near` (normalized face width, M3-T03).
    var nearMaxFaceWidth: Double = 0.28
    /// Width in (midMaxFaceWidth, nearMaxFaceWidth] → `.mid` (M3-T03).
    var midMaxFaceWidth: Double = 0.16
    /// Width in (farMaxFaceWidth, midMaxFaceWidth] → `.far` (M3-T03).
    var farMaxFaceWidth: Double = 0.09

    /// Debug bounding-box/pose preview overlay (M4-T05). Independent of the
    /// debug log flag (`debugLoggingEnabled`, owned by `DiagnosticsLog`).
    var debugPreviewEnabled: Bool = false

    /// Legacy shield behavior: blur the screen when the owner is absent.
    var blurWhenOwnerAbsent: Bool = true

    /// Blur the screen when a shoulder surfer is detected.
    var blurWhenShoulderSurferDetected: Bool = true

    /// Applies the user's trigger/release duration overrides over a base
    /// timing config (M4-T06 wiring). Callers pass the distance-band timing
    /// config (e.g. `AdaptiveAttentionPolicy.timingConfig(for:)`); a
    /// non-nil override REPLACES the base value, `nil` leaves it untouched.
    ///
    /// Range validation of overrides (sane minimum durations, and the
    /// `maxDelta < triggerDuration` invariant documented on
    /// `AttentionTimingConfig`) is the settings UI's responsibility; this
    /// function applies the stored values as-is so persistence round-trips
    /// faithfully and the effective config always reflects what the user
    /// (and the band profile) asked for.
    func effectiveTimingConfig(base: AttentionTimingConfig) -> AttentionTimingConfig {
        var effective = base
        if let trigger = triggerDurationOverride {
            effective.triggerDuration = trigger
        }
        if let release = releaseDurationOverride {
            effective.releaseDuration = release
        }
        return effective
    }
}

// MARK: - Persistence

/// Persists `AttentionSettings` in UserDefaults (M4-T01): one explicit key
/// per field, all prefixed `attention.`, so a saved settings snapshot always
/// round-trips field-for-field.
///
/// Persistence approach — missing keys mean struct defaults: `load()` reads
/// a key only when it is present (`object(forKey:) != nil`) and otherwise
/// keeps the `AttentionSettings()` initial value. First launch therefore
/// yields valid defaults with NO registration step (no `register(defaults:)`
/// call a future refactor could forget), mirroring `ScreenCenterStore`,
/// which likewise treats absent keys as "nothing stored". Consequences:
/// `save` writes every field unconditionally, and a nil override REMOVES
/// its key so `load()` reproduces the "no override" state exactly
/// (UserDefaults cannot store a nil double).
///
/// Update strategy — load-modify-save, in one place: menu toggles (M4-T03)
/// use `update(defaults:_:)`, which funnels every write through the same
/// save path so key names can never drift between writers. No per-field
/// setters.
///
/// `defaults` is injectable so unit tests run against isolated suites;
/// production call sites use the `.standard` default.
enum AttentionSettingsStore {

    // MARK: Keys (one explicit key per field)

    static let shoulderSurfDetectionEnabledKey = "attention.shoulderSurfDetectionEnabled"
    static let sensitivityPresetKey = "attention.sensitivityPreset"
    static let triggerDurationOverrideKey = "attention.triggerDurationOverride"
    static let releaseDurationOverrideKey = "attention.releaseDurationOverride"
    static let nearMaxFaceWidthKey = "attention.nearMaxFaceWidth"
    static let midMaxFaceWidthKey = "attention.midMaxFaceWidth"
    static let farMaxFaceWidthKey = "attention.farMaxFaceWidth"
    static let debugPreviewEnabledKey = "attention.debugPreviewEnabled"
    static let blurWhenOwnerAbsentKey = "attention.blurWhenOwnerAbsent"
    static let blurWhenShoulderSurferDetectedKey = "attention.blurWhenShoulderSurferDetected"

    /// Loads the stored settings; absent keys fall back to the struct
    /// defaults (first launch = valid defaults, see the type docs). An
    /// unknown stored preset raw value (e.g. written by a different app
    /// version) falls back to `.balanced`.
    static func load(defaults: UserDefaults = .standard) -> AttentionSettings {
        var settings = AttentionSettings()

        // Bools and Doubles must NOT be read with defaults.bool/double
        // directly: a MISSING key reads as false / 0.0, which would clobber
        // the non-zero struct defaults on first launch. Presence check first.
        if defaults.object(forKey: shoulderSurfDetectionEnabledKey) != nil {
            settings.shoulderSurfDetectionEnabled = defaults.bool(forKey: shoulderSurfDetectionEnabledKey)
        }
        if let raw = defaults.string(forKey: sensitivityPresetKey) {
            settings.sensitivityPreset = SensitivityPreset(rawValue: raw) ?? .balanced
        }
        settings.triggerDurationOverride = optionalDouble(defaults, forKey: triggerDurationOverrideKey)
        settings.releaseDurationOverride = optionalDouble(defaults, forKey: releaseDurationOverrideKey)

        if defaults.object(forKey: nearMaxFaceWidthKey) != nil {
            settings.nearMaxFaceWidth = defaults.double(forKey: nearMaxFaceWidthKey)
        }
        if defaults.object(forKey: midMaxFaceWidthKey) != nil {
            settings.midMaxFaceWidth = defaults.double(forKey: midMaxFaceWidthKey)
        }
        if defaults.object(forKey: farMaxFaceWidthKey) != nil {
            settings.farMaxFaceWidth = defaults.double(forKey: farMaxFaceWidthKey)
        }
        if defaults.object(forKey: debugPreviewEnabledKey) != nil {
            settings.debugPreviewEnabled = defaults.bool(forKey: debugPreviewEnabledKey)
        }
        if defaults.object(forKey: blurWhenOwnerAbsentKey) != nil {
            settings.blurWhenOwnerAbsent = defaults.bool(forKey: blurWhenOwnerAbsentKey)
        }
        if defaults.object(forKey: blurWhenShoulderSurferDetectedKey) != nil {
            settings.blurWhenShoulderSurferDetected = defaults.bool(forKey: blurWhenShoulderSurferDetectedKey)
        }

        return settings
    }

    /// Overwrites the stored settings with every field of `settings`.
    /// `nil` overrides remove their keys (see the type docs).
    static func save(_ settings: AttentionSettings, defaults: UserDefaults = .standard) {
        defaults.set(settings.shoulderSurfDetectionEnabled, forKey: shoulderSurfDetectionEnabledKey)
        defaults.set(settings.sensitivityPreset.rawValue, forKey: sensitivityPresetKey)
        storeOptionalDouble(settings.triggerDurationOverride,
                            forKey: triggerDurationOverrideKey,
                            defaults: defaults)
        storeOptionalDouble(settings.releaseDurationOverride,
                            forKey: releaseDurationOverrideKey,
                            defaults: defaults)
        defaults.set(settings.nearMaxFaceWidth, forKey: nearMaxFaceWidthKey)
        defaults.set(settings.midMaxFaceWidth, forKey: midMaxFaceWidthKey)
        defaults.set(settings.farMaxFaceWidth, forKey: farMaxFaceWidthKey)
        defaults.set(settings.debugPreviewEnabled, forKey: debugPreviewEnabledKey)
        defaults.set(settings.blurWhenOwnerAbsent, forKey: blurWhenOwnerAbsentKey)
        defaults.set(settings.blurWhenShoulderSurferDetected, forKey: blurWhenShoulderSurferDetectedKey)
    }

    /// Load-modify-save convenience for menu toggles (M4-T03): applies one
    /// mutation to the currently stored settings and persists the result,
    /// so callers never build key strings themselves.
    static func update(defaults: UserDefaults = .standard,
                       _ mutate: (inout AttentionSettings) -> Void) {
        var settings = load(defaults: defaults)
        mutate(&settings)
        save(settings, defaults: defaults)
    }

    // MARK: Optional-double helpers

    /// Reads a `Double` that may be absent: `nil` when the key is missing
    /// ("no override"), the stored value otherwise.
    private static func optionalDouble(_ defaults: UserDefaults, forKey key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    /// Writes a `Double?`: a value is stored, `nil` removes the key so
    /// `load()` reads back "no override" (UserDefaults has no nil double).
    private static func storeOptionalDouble(_ value: Double?, forKey key: String, defaults: UserDefaults) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
