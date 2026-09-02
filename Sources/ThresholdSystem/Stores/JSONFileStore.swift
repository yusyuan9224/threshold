import Foundation

/// The on-disk envelope every store writes.
///
/// The version is explicit so an older build meets a newer file with a clear error rather than a
/// half-decoded record.
struct StoredDocument<Body: Codable & Sendable>: Codable, Sendable {
    let schemaVersion: Int
    let body: Body
}

/// A single JSON file holding one `Codable` payload.
///
/// Reads treat an absent file as "nothing saved yet" and everything else as an error. Writes are
/// atomic, so an interrupted save leaves the previous file intact rather than a truncated one.
struct JSONFileStore<Body: Codable & Sendable>: Sendable {
    /// Bump only together with a migration path.
    static var supportedSchemaVersion: Int { 1 }

    let url: URL

    var fileName: String { url.lastPathComponent }

    /// - Returns: `nil` when the file does not exist yet.
    func load() throws -> Body? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw StoreError.readFailed(file: fileName, message: storeErrorMessage(for: error))
        }

        let document: StoredDocument<Body>
        do {
            document = try JSONDecoder().decode(StoredDocument<Body>.self, from: data)
        } catch {
            throw StoreError.decodeFailed(file: fileName, message: storeErrorMessage(for: error))
        }

        guard document.schemaVersion == Self.supportedSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(
                file: fileName,
                found: document.schemaVersion,
                supported: Self.supportedSchemaVersion
            )
        }
        return document.body
    }

    func save(_ body: Body) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.writeFailed(file: fileName, message: storeErrorMessage(for: error))
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            // Sorted and indented so a support request can paste the file and a diff is readable.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(StoredDocument(schemaVersion: Self.supportedSchemaVersion, body: body))
        } catch {
            throw StoreError.encodeFailed(file: fileName, message: storeErrorMessage(for: error))
        }

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.writeFailed(file: fileName, message: storeErrorMessage(for: error))
        }
    }
}

/// Resolves `~/Library/Application Support/<bundle id>/` (system-integration.md §3).
public enum ApplicationSupportDirectory {
    /// - Parameter bundleIdentifier: used verbatim as the directory name, so it is checked here
    ///   rather than trusted: a value containing a path separator or a relative component would
    ///   write outside Application Support.
    public static func url(bundleIdentifier: String) throws -> URL {
        guard !bundleIdentifier.isEmpty,
              !bundleIdentifier.contains("/"),
              bundleIdentifier != ".",
              bundleIdentifier != ".."
        else {
            throw StoreError.directoryUnavailable("unusable bundle identifier")
        }

        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw StoreError.directoryUnavailable(storeErrorMessage(for: error))
        }
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}
