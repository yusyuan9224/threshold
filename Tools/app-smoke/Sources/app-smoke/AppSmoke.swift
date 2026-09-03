import Foundation

/// Entry point. Exit codes: 0 for a completed run, 1 for anything that stopped it.
///
/// One code for every failure on purpose. A smoke run either produced a transcript or it did
/// not; splitting "bad arguments" from "the container threw" would invite a CI script to
/// treat one of them as a pass.
@main
struct AppSmoke {

    static let defaultSeconds = 20
    static let maxSeconds = 600

    static func main() async {
        do {
            let seconds = try parse(Array(CommandLine.arguments.dropFirst()))
            guard let seconds else {
                print(usage)
                exit(0)
            }
            try await SmokeRun.run(seconds: seconds)
            exit(0)
        } catch {
            // The error goes out as a JSON line like everything else, so a captured run is
            // still one parseable stream when it fails.
            emit("error", [("message", JSONLine.str(String(describing: error)))])
            emit("end", [("ok", JSONLine.bool(false))])
            exit(1)
        }
    }

    /// `nil` means "the caller asked for help", not "no argument".
    private static func parse(_ arguments: [String]) throws -> Int? {
        switch arguments.first {
        case nil:
            return defaultSeconds
        case "--help", "-h", "help":
            return nil
        case .some(let raw):
            guard let seconds = Int(raw), seconds >= 1, seconds <= maxSeconds else {
                throw SmokeError("usage: app-smoke [seconds]  (1–\(maxSeconds), default \(defaultSeconds))")
            }
            return seconds
        }
    }

    private static let usage = """
        app-smoke [seconds]

        Boots the real AppContainer with production adapters, runs onboarding discovery for
        <seconds> (default \(defaultSeconds), max \(maxSeconds)), and prints one JSON object per line
        to stdout: the app model, the discovery states and table, the live system provider
        readings, and the CoordinatorEvent kinds the run produced.

        Stores are pointed at a throwaway directory under $TMPDIR/\(StorageDirectory.folderName)/.
        Your real ~/Library/Application Support folder is never read or written.

        The tool never locks the screen, never wakes the display, and opens no window.
        """
}
