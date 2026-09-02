// Action ledger entry (docs/specs/proximity-domain.md §6.4, architecture.md §6).
//
// One entry per dispatched action, carrying the effect lifecycle stage it has reached.
// Entries are created and advanced only by `PolicyEngine`: the setters are internal so a
// consumer can read the ledger for diagnostics but can never forge or rewrite history.

public struct LedgerEntry: Sendable, Equatable {
    public let id: ActionID
    public let kind: ActionKind
    /// The presence episode this action belongs to. An outcome naming any other episode
    /// is stale and must not touch this entry (security.md §2.6).
    public let episode: EpisodeID
    public internal(set) var stage: ActionStage
    /// Dispatch count, starting at 1 for the first proposal. Bounded by `PolicySettings.maxAttempts`.
    public internal(set) var attempts: Int
    /// When the current attempt was handed to the controller. Retry timing is measured from
    /// here, so it is re-stamped on every re-proposal.
    public internal(set) var issuedAt: MonotonicInstant

    init(id: ActionID, kind: ActionKind, episode: EpisodeID, stage: ActionStage, attempts: Int, issuedAt: MonotonicInstant) {
        self.id = id
        self.kind = kind
        self.episode = episode
        self.stage = stage
        self.attempts = attempts
        self.issuedAt = issuedAt
    }

    public var isLock: Bool {
        if case .lock = kind { return true }
        return false
    }

    /// Stages from which a further dispatch is still conceivable. `confirmed`, `gaveUp` and
    /// `stale` are terminal.
    var isLive: Bool {
        switch stage {
        case .proposed, .issued, .acknowledged, .failed: return true
        case .confirmed, .gaveUp, .stale: return false
        }
    }
}
