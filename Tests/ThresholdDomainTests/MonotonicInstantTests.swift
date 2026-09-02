import Testing
@testable import ThresholdDomain

@Suite("MonotonicInstant")
struct MonotonicInstantTests {
    @Test func additionAndSubtractionAreIntegerExact() {
        let t0 = MonotonicInstant.zero
        let t1 = t0 + .seconds(3)
        #expect(t1.nanoseconds == 3_000_000_000)
        #expect(t1 - t0 == .seconds(3))
        #expect((t1 - .milliseconds(500)).nanoseconds == 2_500_000_000)
    }

    @Test func orderingIsByNanoseconds() {
        #expect(MonotonicInstant(nanoseconds: 1) < MonotonicInstant(nanoseconds: 2))
        #expect(!(MonotonicInstant(nanoseconds: 2) < MonotonicInstant(nanoseconds: 2)))
    }

    @Test func negativeElapsedWhenLhsPrecedesRhs() {
        let a = MonotonicInstant(nanoseconds: 10), b = MonotonicInstant(nanoseconds: 40)
        #expect(a - b == .nanoseconds(-30))
    }

    @Test func deadlineEqualityIsExact() {
        // Integer representation: no floating-point drift on repeated arithmetic.
        var t = MonotonicInstant.zero
        for _ in 0..<1_000 { t = t + .milliseconds(1) }
        #expect(t == MonotonicInstant.zero + .seconds(1))
    }
}
