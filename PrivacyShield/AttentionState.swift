import Foundation

/// Discrete attention classification used to drive the privacy shield.
///
/// A three-way state (instead of a boolean) provides a gray band between
/// "clearly looking" and "clearly not looking" so the shield state stays steady
/// instead of flickering when the user is near the edge of the attention zone.
enum AttentionState {
    case looking
    case notLooking
    case uncertain
}

/// One attention evaluation: the discrete `state` plus the continuous `score`
/// (always in [0, 1]) that produced it, so callers can log and tune thresholds
/// without recomputing the score themselves.
struct AttentionResult {
    let state: AttentionState
    let score: Double
}
