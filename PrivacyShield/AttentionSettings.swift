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
/// and `.sensitive` re-map the same knobs — the preset-to-values mapping
/// lives in `profilesWithPreset(_:base:)` below (M4-T02); the setting only
/// records the user's choice.
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

// MARK: - Sensitivity preset mapping (M4-T02, plan section 16)

/// Applies a sensitivity preset to a whole set of distance-band profiles and
/// returns the adjusted copy (pure function: `base` is never mutated).
///
/// The mapping shifts each band's tolerances and durations by fixed offsets
/// relative to the base passed in, so the band relationships survive any
/// future retuning of the base (M3-T06+): within every preset, near stays
/// the strictest and fastest band and far the loosest and slowest; across
/// presets, conservative < balanced < sensitive in strictness for every
/// band. Applied to `DistanceAttentionProfiles.standard`, each preset's MID
/// band reproduces the plan's headline numbers exactly — the settings menu
/// displays those values (see `SensitivityPreset.classifierTolerances` /
/// `baseTriggerDuration`).
///
/// Exact mapping (base = `DistanceAttentionProfiles.standard`):
///
///     Balanced — identity, the base profiles pass through unchanged:
///
///         band   yaw   pitch   trigger  release
///         near   18°   15°     0.7 s    0.6 s
///         mid    22°   18°     0.9 s    0.6 s
///         far    27°   22°     1.2 s    0.6 s
///
///     Conservative — yaw −7° / pitch −6° (floored at 10°/8°),
///     trigger +0.6 s, release +0.2 s (holds the shield longer, too):
///
///         band   yaw   pitch   trigger  release
///         near   11°   9°      1.3 s    0.8 s
///         mid    15°   12°     1.5 s    0.8 s
///         far    20°   16°     1.8 s    0.8 s
///
///     Sensitive — yaw +8° / pitch +7°, trigger max(0.55, band − 0.3) s,
///     release unchanged:
///
///         band   yaw   pitch   trigger  release
///         near   26°   22°     0.55 s   0.6 s
///         mid    30°   25°     0.6 s    0.6 s
///         far    35°   29°     0.9 s    0.6 s
///
/// The floors are monotone — they can equalize two bands but never invert
/// their order — and never activate on the standard profiles except the
/// sensitive near trigger, which lands exactly on its 0.55 s floor. That
/// floor is deliberately 0.55 s (not the 0.4 s first sketched in the plan
/// notes) so every preset trigger stays strictly above the default `maxDelta`
/// (0.5 s), honoring `AttentionTimingConfig`'s invariant that a single
/// update can never raise the alert by itself.
///
/// Deliberately untouched by every preset: roll tolerance (±30°), the axis
/// weights, the looking/notLooking thresholds, `uncertainGrace`, `maxDelta`,
/// and the calibrated screen-center fields of every band config (calibration
/// is owned by `ScreenCenterStore` and must never be corrupted by a preset
/// change; `AdaptiveAttentionPolicy.classifierConfig` overlays the calibrated
/// center afterwards, outside the preset path). The distance-band boundary
/// fields (`nearMaxFaceWidth` / `midMaxFaceWidth` / `farMaxFaceWidth` on
/// `AttentionSettings`) are likewise not consulted or modified here.
func profilesWithPreset(_ preset: SensitivityPreset,
                        base: DistanceAttentionProfiles) -> DistanceAttentionProfiles {
    var profiles = base
    profiles.near = preset.adjusted(base.near)
    profiles.mid = preset.adjusted(base.mid)
    profiles.far = preset.adjusted(base.far)
    profiles.nearTiming = preset.adjusted(base.nearTiming)
    profiles.midTiming = preset.adjusted(base.midTiming)
    profiles.farTiming = preset.adjusted(base.farTiming)
    return profiles
}

/// Headline per-preset values for the settings menu (plan section 16).
extension SensitivityPreset {

    /// Classifier tolerances for the preset (yaw/pitch) — the MID-band
    /// values the menu displays. Roll stays ±30°, weights and looking/
    /// notLooking thresholds unchanged. Derived from the band mapping
    /// (`profilesWithPreset` on the standard profiles) so the headline
    /// values can never drift from the actual per-band values.
    func classifierTolerances() -> (yaw: Double, pitch: Double) {
        let mid = profilesWithPreset(self, base: .standard).mid
        return (mid.yawTolerance, mid.pitchTolerance)
    }

    /// Base trigger duration for the preset (seconds) — the MID-band value,
    /// before per-band adaptation toward near/far and before any user
    /// override (see `AttentionSettings.effectiveTimingConfig`).
    func baseTriggerDuration() -> Double {
        profilesWithPreset(self, base: .standard).midTiming.triggerDuration
    }
}

/// Per-band adjustment underlying `profilesWithPreset`: fixed offsets per
/// preset, documented there. Private so the mapping has exactly one
/// description and one caller.
private extension SensitivityPreset {

    /// Tolerance shift for one band's classifier config. Only the yaw/pitch
    /// tolerances move; roll, weights, thresholds and the screen center pass
    /// through untouched.
    func adjusted(_ config: AttentionClassifierConfig) -> AttentionClassifierConfig {
        var adjusted = config
        switch self {
        case .balanced:
            break  // identity: the base profiles ARE the M3-tuned values
        case .conservative:
            adjusted.yawTolerance = max(10.0, adjusted.yawTolerance - 7.0)
            adjusted.pitchTolerance = max(8.0, adjusted.pitchTolerance - 6.0)
        case .sensitive:
            adjusted.yawTolerance += 8.0
            adjusted.pitchTolerance += 7.0
        }
        return adjusted
    }

    /// Trigger/release shift for one band's timing config. `uncertainGrace`
    /// and `maxDelta` pass through untouched.
    func adjusted(_ config: AttentionTimingConfig) -> AttentionTimingConfig {
        var adjusted = config
        switch self {
        case .balanced:
            break
        case .conservative:
            adjusted.triggerDuration += 0.6
            adjusted.releaseDuration += 0.2
        case .sensitive:
            // Floor 0.55 s keeps the trigger strictly above the default
            // maxDelta (0.5 s) — see profilesWithPreset's docs.
            adjusted.triggerDuration = max(0.55, adjusted.triggerDuration - 0.3)
        }
        return adjusted
    }
}

// MARK: - Effective configuration (M4-T02)

extension AttentionSettings {

    /// Single entry point for the M4-T06 settings wiring: resolves this
    /// settings value onto a full set of distance-band profiles.
    ///
    /// Precedence, later stages win:
    ///
    ///     preset → band adaptation → user override
    ///
    /// 1. The preset (`sensitivityPreset`) shifts every band's tolerances
    ///    and durations coherently (`profilesWithPreset`).
    /// 2. Band adaptation is baked into `base` — callers normally pass
    ///    `DistanceAttentionProfiles.standard`, whose near/mid/far variants
    ///    already encode the distance behavior the preset shifts.
    /// 3. A non-nil `triggerDurationOverride` / `releaseDurationOverride`
    ///    REPLACES the resulting band timing (`effectiveTimingConfig`),
    ///    winning over both preset and band.
    ///
    /// Pure and calibration-safe: never mutates `base`, never touches
    /// `ScreenCenterStore`, leaves the calibrated screen-center fields of
    /// every band config and the distance-band boundary fields
    /// (`nearMaxFaceWidth` / `midMaxFaceWidth` / `farMaxFaceWidth`) of this
    /// settings value untouched.
    func effectiveProfiles(base: DistanceAttentionProfiles) -> DistanceAttentionProfiles {
        var profiles = profilesWithPreset(sensitivityPreset, base: base)
        profiles.nearTiming = effectiveTimingConfig(base: profiles.nearTiming)
        profiles.midTiming = effectiveTimingConfig(base: profiles.midTiming)
        profiles.farTiming = effectiveTimingConfig(base: profiles.farTiming)
        return profiles
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
