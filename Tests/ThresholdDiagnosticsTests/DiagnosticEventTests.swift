import Testing
import Foundation
@testable import ThresholdDiagnostics

@Suite struct DiagnosticEventFieldValueTests {
    @Test func fieldValueRoundTripsAllCases() throws {
        let values: [DiagnosticEvent.FieldValue] = [.string("a"), .int(42), .double(1.5), .bool(true)]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(DiagnosticEvent.FieldValue.self, from: data)
            #expect(decoded == value)
        }
    }
}
