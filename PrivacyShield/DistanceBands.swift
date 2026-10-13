import Foundation

// MARK: - Distance-band model (M3-T03)
//
// Phase 8 of the development plan ("Distance / Face-Size Confidence Bands"):
// within the 1–4 m operating range, normalized face width (bounding-box width
// as a fraction of frame width, straight from VNDetectFaceRectanglesRequest)
// is a practical distance proxy. Monotonic mapping, documented explicitly:
//
//     larger width ⇒ nearer band.  1 m ⇒ width ≫ far-band widths,
//     4 m ⇒ width ≪ near-band widths. For one fixed camera the mapping
//     distance → band is monotonic (the M3-T03 acceptance criterion).
//
// The width boundaries below are PLACEHOLDERS until M3-T06 tuning. They are
// camera-dependent — focal length, sensor crop and resolution all change the
// normalized width at a given distance — so they must NOT be assumed
// universal, and the legacy fixed `minFaceSize = 0.25` in `FaceDetector` is
// not reused here as a band boundary (a later integration task replaces it).
// `docs/evaluation_protocol_1_4m.md` records the raw face-width distributions
// measured at 1/2/3/4 m; M3-T06 will set the final boundaries from them.
//
// `DistanceBandConfig` is a plain value struct precisely so a future
// calibration flow can persist customized boundaries (e.g. via
// `Codable`/UserDefaults) — persistence itself is deliberately NOT
// implemented in this task. All tunables live in this one place (X-T01).

/// Coarse distance band for one face, derived from its normalized width.
enum DistanceBand: Equatable, CaseIterable {

    /// Approximately 1–2 m: face fills a large fraction of the frame.
    case near
    /// Approximately 2–3 m.
    case mid
    /// Approximately 3–4 m: face small in frame, judgments get noisier.
    case far
    /// Too small to judge reliably (beyond ~4 m or a spurious detection).
    case tooFarOrUnreliable

    /// Ordinal for monotonicity checks and comparisons: farther bands have
    /// lower ordinals (`tooFarOrUnreliable` = 0 … `near` = 3). Larger face
    /// width ⇒ larger (or equal) ordinal.
    var ordinal: Int {
        switch self {
        case .tooFarOrUnreliable: return 0
        case .far: return 1
        case .mid: return 2
        case .near: return 3
        }
    }
}

/// All distance-band tunables in one place (X-T01). Defaults are placeholders
/// until M3-T06 sets final values from the measured 1/2/3/4 m width
/// distributions recorded in `docs/evaluation_protocol_1_4m.md`.
///
/// Invariant the logic relies on:
/// `nearMaxWidth > midMaxWidth > farMaxWidth > 0`, and
/// `hysteresisMargin` smaller than half the gap between adjacent boundaries
/// (otherwise some widths can never confirm a band switch). Keep `hysteresisMargin`
/// meaningfully smaller than the smallest gap between adjacent boundaries,
/// otherwise no width can ever confirm a switch across that gap.
struct DistanceBandConfig {

    /// Width above this → `.near`. Widths are camera-dependent; never treat
    /// this number as universal (see M3-T06 calibration).
    var nearMaxWidth: Double = 0.28
    /// Width in (midMaxWidth, nearMaxWidth] → `.mid`.
    var midMaxWidth: Double = 0.16
    /// Width in (farMaxWidth, midMaxWidth] → `.far`; width ≤ farMaxWidth →
    /// `.tooFarOrUnreliable`.
    var farMaxWidth: Double = 0.09

    /// Hysteresis margin (M3-T04 needs band transitions that do not oscillate
    /// frame-to-frame). A face already assigned a band keeps it until the
    /// width crosses the relevant boundary BY more than this margin — see
    /// `DistanceBandHysteresis.refined`.
    var hysteresisMargin: Double = 0.015

    /// The single source of truth for placeholder defaults.
    static let `default` = DistanceBandConfig()
}

/// Stateless classifier: normalized face width → distance band.
///
/// Interval convention (half-open, tested): each band owns the interval
/// `(lowerBoundary, ownBoundary]` — a width exactly ON a boundary belongs to
/// the FARTHER band. So for the default config: `(0.16, 0.28]` is `.mid`,
/// `(0.09, 0.16]` is `.far`, `≤ 0.09` is `.tooFarOrUnreliable`, and `> 0.28`
/// is `.near`. Equivalently: the boundary value itself is never classified as
/// the nearer band.
struct DistanceBandClassifier {

    var config: DistanceBandConfig = .default

    /// Stateless classification of a single normalized face width.
    ///
    /// Monotonic by construction: strictly larger width never yields a
    /// farther band (see `DistanceBand.ordinal`).
    func band(forNormalizedFaceWidth width: Double) -> DistanceBand {
        if width > config.nearMaxWidth { return .near }
        if width > config.midMaxWidth { return .mid }
        if width > config.farMaxWidth { return .far }
        return .tooFarOrUnreliable
    }
}

/// Stateless-per-call hysteresis wrapper: the CALLER supplies the previous
/// band per face/track (this module keeps no state, so multi-face frames and
/// tracker lifecycles stay outside its responsibility).
enum DistanceBandHysteresis {

    /// If a previous band exists for the face/track, require the width to
    /// cross the relevant boundary BY more than `config.hysteresisMargin`
    /// before the band may switch; otherwise the previous band is kept.
    /// `previous == nil` (new track) → pure classification (`current`).
    ///
    /// Direction semantics:
    /// - Switching nearer (current ordinal higher): confirmed only when
    ///   `width > boundary + margin`, where `boundary` is the upper edge of
    ///   the previous band (the boundary that must be exceeded to leave it
    ///   toward a closer band).
    /// - Switching farther (current ordinal lower): confirmed only when
    ///   `width < boundary - margin`, where `boundary` is the lower edge of
    ///   the previous band.
    /// - A multi-band jump (e.g. `.near` → `.far` in one frame) is evaluated
    ///   against the boundary adjacent to the previous band; because the raw
    ///   classification already placed the width deep in the new band, such
    ///   jumps confirm immediately, as intended.
    /// - "Crosses by exactly the margin" does NOT switch; the margin must be
    ///   exceeded strictly (symmetric with the classifier's on-boundary →
    ///   farther convention).
    static func refined(previous: DistanceBand?,
                        current: DistanceBand,
                        width: Double,
                        config: DistanceBandConfig) -> DistanceBand {
        // New track (or first observation): no band to stabilize — raw result.
        guard let previous = previous else { return current }

        let margin = config.hysteresisMargin

        if current.ordinal > previous.ordinal {
            // Moving nearer: must clearly exceed the upper boundary of the
            // previous band. (.near has no nearer neighbor, and `current`
            // cannot be nearer than `.near`, so the guard is a formality.)
            guard let boundary = boundaryLeavingTowardNearer(from: previous, config: config) else {
                return current
            }
            return width > boundary + margin ? current : previous
        } else if current.ordinal < previous.ordinal {
            // Moving farther: must clearly drop below the lower boundary of
            // the previous band.
            guard let boundary = boundaryLeavingTowardFarther(from: previous, config: config) else {
                return current
            }
            return width < boundary - margin ? current : previous
        }
        // Same band as before: keep it (no oscillation possible).
        return previous
    }

    /// Upper boundary of `band` — the width that must be exceeded (beyond
    /// margin) to leave `band` toward a NEARER band. `nil` for `.near`.
    private static func boundaryLeavingTowardNearer(from band: DistanceBand,
                                                    config: DistanceBandConfig) -> Double? {
        switch band {
        case .tooFarOrUnreliable: return config.farMaxWidth
        case .far: return config.midMaxWidth
        case .mid: return config.nearMaxWidth
        case .near: return nil
        }
    }

    /// Lower boundary of `band` — the width that must fall below (beyond
    /// margin) to leave `band` toward a FARTHER band. `nil` for
    /// `.tooFarOrUnreliable`.
    private static func boundaryLeavingTowardFarther(from band: DistanceBand,
                                                     config: DistanceBandConfig) -> Double? {
        switch band {
        case .near: return config.nearMaxWidth
        case .mid: return config.midMaxWidth
        case .far: return config.farMaxWidth
        case .tooFarOrUnreliable: return nil
        }
    }
}
