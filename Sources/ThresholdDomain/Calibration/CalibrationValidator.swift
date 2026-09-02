/// Outcome of a near-only revalidation run (docs/specs/proximity-domain.md §7.3).
///
/// The record is never deleted: a failed revalidation asks for a full calibration, it does not
/// throw the old profile away.
public enum RevalidationResult: Sendable, Equatable {
    /// The stored profile still describes this room. Re-arm with it, unchanged.
    case rearmed(CalibrationProfile)
    /// The near baseline has moved too far to trust. Ask for both phases again.
    case requiresFullCalibration
}

/// Decides whether a stored calibration may drive automation (docs/specs/proximity-domain.md §7.3).
///
/// `notArmed` does not stop the engine — Presence still scores, so the UI can show what it
/// believes — it only withholds Policy actions (ADR-003 §6). Every rejection carries a reason
/// the user can act on.
public enum CalibrationValidator {

    /// §7.3, in order: no record → device → mac → OS major → age → armed.
    ///
    /// The order encodes how wrong the record is. A record for another device or another Mac is
    /// not stale, it is foreign, so it can never be repaired by revalidating; an OS-major change
    /// or an over-age profile is merely suspect, and a near-only run can rescue it.
    ///
    /// - Parameter nowUnixSeconds: wall-clock, used only for the optional age check. Monotonic
    ///   time never reaches here — a `CalibrationRecord` is persisted and must not carry one.
    public static func gate(
        record: CalibrationRecord?,
        device: DeviceID,
        macIdentity: String,
        osMajorVersion: Int,
        nowUnixSeconds: Int64,
        policy: CalibrationPolicy
    ) -> CalibrationGate {
        guard let record else { return .notArmed(.noProfile) }

        // `CalibrationProfile.default` is display-only and, by its own contract, never appears
        // inside `.armed`. A stored record holding it is a placeholder, not a calibration —
        // and it is not even self-consistent (its slope does not follow from its baselines),
        // so no real session could have produced it.
        guard record.profile != CalibrationProfile.default else { return .notArmed(.noProfile) }

        guard record.device == device else { return .notArmed(.deviceMismatch) }
        guard record.macIdentity == macIdentity else { return .notArmed(.macMismatch) }
        guard record.osMajorVersion == osMajorVersion else {
            return .notArmed(.needsRevalidation(osMajorChanged: true))
        }

        if let maxProfileAge = policy.maxProfileAge {
            // A record stamped in the future means the wall clock moved, not that the profile
            // aged; a negative age must not disarm.
            let ageSeconds = nowUnixSeconds - record.createdAtUnixSeconds
            if ageSeconds > maxProfileAge.components.seconds {
                return .notArmed(.needsRevalidation(osMajorChanged: false))
            }
        }

        return .armed(record.profile)
    }

    /// Near-only revalidation (§7.3): if the near median still sits within
    /// `nearBaseline ± max(revalidationToleranceDB, 2 × noise)`, re-arm the *original* profile.
    ///
    /// The tolerance widens with the noise the original session measured — a room that was
    /// already 5 dB jittery cannot be held to a 6 dB band.
    public static func revalidate(
        record: CalibrationRecord,
        nearSamples: [Int],
        policy: CalibrationPolicy
    ) -> RevalidationResult {
        guard nearSamples.count >= policy.minSamples else { return .requiresFullCalibration }
        guard let median = CalibrationStats.median(nearSamples.map { Double($0) }) else {
            return .requiresFullCalibration
        }
        let tolerance = max(policy.revalidationToleranceDB, 2 * record.profile.noise)
        guard abs(median - record.profile.nearBaseline) <= tolerance else {
            return .requiresFullCalibration
        }
        return .rearmed(record.profile)
    }
}
