import Foundation

/// Entry point. Exit codes: 0 success, 1 the run produced nothing usable
/// (permission denied, radio off, bad arguments), 2 an unexpected error.
@main
struct RSSIRecord {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try await dispatch(arguments)
        } catch let error as ToolError {
            note("error: \(error.description)")
            exit(1)
        } catch {
            note("error: \(error)")
            exit(2)
        }
    }

    private static func dispatch(_ arguments: [String]) async throws {
        switch arguments.first {
        case "discover":
            guard let raw = arguments[safe: 1], let duration = Int(raw), duration >= 1,
                  duration <= RecordOptions.maxSeconds
            else {
                throw ToolError("usage: rssi-record discover <seconds>\n\n\(usage)")
            }
            try await DiscoverCommand.run(seconds: duration)

        case "record":
            try await RecordCommand.run(RecordOptions.parse(Array(arguments.dropFirst())))

        case "--help", "-h", "help", nil:
            print(usage)

        case .some(let command):
            throw ToolError("unknown command \(command)\n\n\(usage)")
        }
    }
}
