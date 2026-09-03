import Foundation

/// Where this run's three JSON stores are allowed to live.
///
/// A smoke run boots the production graph, which means production stores. It must not be
/// able to read, rewrite or delete the trusted device, the calibration profile or the
/// settings of whoever is running it — a verification tool that can damage the thing it is
/// verifying is worse than no tool.
///
/// So the directory is a throwaway under `$TMPDIR`, and the choice is checked rather than
/// trusted: `resolve()` refuses to hand back anything inside Application Support at all,
/// not just the app's own folder there. Nothing is created here — `JSONFileStore` creates
/// the directory on its first save, and this tool never saves — so a run leaves nothing
/// behind on disk.
enum StorageDirectory {

    static let folderName = "threshold-app-smoke"

    /// A fresh directory for one run: `$TMPDIR/threshold-app-smoke/run-<unix seconds>`.
    ///
    /// Per-run rather than shared, so a file left by an earlier run can never change what
    /// this one reports. The registry a smoke run reads is empty because nothing ever wrote
    /// to this path, not because something happened to be cleaned up first.
    static func resolve(startedAt: Date = Date()) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("run-\(Int64(startedAt.timeIntervalSince1970))", isDirectory: true)

        // Belt and braces. `temporaryDirectory` honours `TMPDIR`, and a `TMPDIR` pointing
        // into Application Support would be perverse — but "perverse" is not "impossible",
        // and the cost of checking is one string comparison.
        if let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ), directory.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path) {
            throw SmokeError(
                "refusing to run: the temporary store path resolves inside Application Support. "
                    + "Check $TMPDIR."
            )
        }
        return directory
    }
}
