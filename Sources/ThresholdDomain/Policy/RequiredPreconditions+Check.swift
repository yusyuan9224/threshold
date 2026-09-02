// Fail-closed precondition gate (docs/specs/security.md §2.1, proximity-domain.md §6.1).
//
// Two distinct failures, deliberately not collapsed into one:
//   - `.indeterminate(field)` — we do not know the value, or we cannot trust the subsystem
//     that would tell us. Retrying later may succeed.
//   - `.unsatisfied(field)`   — we know the value and it is wrong for this action.
//
// Both forbid the action. The distinction exists for diagnostics and UI: "paused, Bluetooth
// unavailable" reads very differently from "nothing to do, the screen is already locked".

extension RequiredPreconditions {
    /// Fields are evaluated in a fixed order — sensor, session, power, screen, calibration —
    /// so a snapshot failing several of them always yields the same, stable diagnosis.
    public func check(for kind: ActionKind) -> PreconditionResult {
        // Sensor. A subsystem that is not healthy invalidates every belief downstream of it,
        // so even a *definite* failure such as `poweredOff` is indeterminate about the user
        // (ADR-008: absence of evidence is not evidence of absence).
        guard case .healthy = sensor else { return .indeterminate(.sensor) }

        switch session {
        case .active: break
        case .unknown: return .indeterminate(.session)
        case .inactive: return .unsatisfied(.session)
        }

        let requiredPower: PowerState
        let requiredScreen: ScreenState
        switch kind {
        case .lock: requiredPower = .awake; requiredScreen = .unlocked
        case .wake: requiredPower = .displayAsleep; requiredScreen = .locked
        }

        if power == .unknown { return .indeterminate(.power) }
        if power != requiredPower { return .unsatisfied(.power) }

        if screen == .unknown { return .indeterminate(.screen) }
        if screen != requiredScreen { return .unsatisfied(.screen) }

        // Not armed is a definite "no": the profile is known to be missing or unusable.
        guard calibration.isArmed else { return .unsatisfied(.calibration) }

        return .satisfied
    }
}
