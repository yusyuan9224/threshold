import Testing
@testable import ThresholdDomain

/// Seconds → `MonotonicInstant`. Fixtures and specs speak in seconds; the Domain speaks in nanoseconds.
func instant(_ seconds: Double) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: Int64(seconds * 1_000_000_000))
}

/// Calibrated so that the RSSI values used by the tests sit unambiguously on one side or the other:
/// −45 dBm scores 0.95 (well above enter), −95 dBm scores 0.001 (well below exit), −62 dBm scores
/// 0.40 (in the uncertain band, so it can never by itself confirm anything).
let testProfile = CalibrationProfile(nearBaseline: -50, farBaseline: -70, noise: 3, midpoint: -60, slope: 5)

let nearRSSI = -45
let farRSSI = -95

/// One presence transition, reduced to the two things the transition table specifies.
struct Step: Equatable, CustomStringConvertible {
    let to: String
    let cause: TransitionCause
    init(_ to: String, _ cause: TransitionCause) { self.to = to; self.cause = cause }
    var description: String { "\(to) via \(cause)" }
}

/// Drives a `ProximityEngine` and records every transition it emits.
struct Harness {
    var engine: ProximityEngine
    private(set) var transitions: [ProximityTransition] = []

    init(
        configuration: EngineConfiguration = EngineConfiguration(),
        gate: CalibrationGate = .armed(testProfile),
        devices: [String] = ["device-A"],
        sensorAvailableAt: Double? = 0
    ) {
        engine = ProximityEngine(
            configuration: configuration,
            fusion: AnyDeviceFusion(),
            devices: Set(devices.map(DeviceID.init)),
            gate: gate
        )
        if let sensorAvailableAt {
            send(.sensor(.available, at: instant(sensorAvailableAt)))
        }
    }

    @discardableResult
    mutating func send(_ input: EngineInput) -> [ProximityTransition] {
        let emitted = engine.handle(input)
        transitions.append(contentsOf: emitted)
        return emitted
    }

    mutating func observe(_ rssi: Int, at seconds: Double, device: String = "device-A") {
        send(.observation(BLEObservation(device: DeviceID(device), at: instant(seconds), rssi: rssi)))
    }

    /// One observation per second, inclusive of both ends.
    mutating func drive(_ rssi: Int, from: Double, through: Double, device: String = "device-A") {
        var t = from
        while t <= through + 1e-9 {
            observe(rssi, at: t, device: device)
            t += 1
        }
    }

    mutating func tick(_ seconds: Double) {
        send(.tick(at: instant(seconds)))
    }

    var snapshot: ProximitySnapshot { engine.snapshot }
    var presence: PresenceState { engine.snapshot.presence }

    var presenceTransitions: [ProximityTransition] {
        transitions.filter { $0.axis == .presence }
    }

    /// `(to-state label, cause)` for every presence transition — the shape assertions read best in.
    var presenceSteps: [Step] {
        presenceTransitions.map { Step($0.to, $0.cause) }
    }

    func transitions(on axis: Axis) -> [ProximityTransition] {
        transitions.filter { $0.axis == axis }
    }
}

/// Reaches `present` at t = 6 s: seven 1 Hz near samples, where sample four first crosses the
/// enter threshold and the confirm duration expires three seconds later.
func harnessAtPresent() -> Harness {
    var harness = Harness()
    harness.drive(nearRSSI, from: 0, through: 6)
    return harness
}
