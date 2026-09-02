import Foundation

/// Owns the opaque observer tokens returned by `NotificationCenter.addObserver(forName:object:queue:using:)`
/// so a provider can unregister them when it goes away.
///
/// `@unchecked Sendable` invariant (ADR-006 requires the invariant in writing):
/// - `entries` is appended to only by `add(...)`, which every provider calls exclusively from its own
///   `init`, before the instance can be reached by any other thread;
/// - `entries` is read only by `removeAll()`, which every provider calls from `deinit`, which by
///   definition runs when the last reference is gone and no other thread can reach the object;
/// - the tokens themselves are opaque: they are never dereferenced here, only handed back to
///   `removeObserver(_:)`.
///
/// There is therefore no window in which two threads touch this object, and no lock is needed. The
/// alternative — putting `any NSObjectProtocol` inside an `OSAllocatedUnfairLock` — is impossible,
/// because that type is not `Sendable`.
final class NotificationObservers: @unchecked Sendable {
    private struct Entry {
        let center: NotificationCenter
        let token: any NSObjectProtocol
    }

    private var entries: [Entry] = []

    /// Registers `body` for `name` on `center`. The delivered `Notification` is deliberately not
    /// passed through: these signals carry no payload the providers use, and `Notification` is not
    /// `Sendable`.
    ///
    /// Must only be called from the owning provider's `init`.
    func add(_ center: NotificationCenter, name: Notification.Name, body: @escaping @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in body() }
        entries.append(Entry(center: center, token: token))
    }

    /// Must only be called from the owning provider's `deinit`.
    func removeAll() {
        for entry in entries { entry.center.removeObserver(entry.token) }
        entries.removeAll()
    }
}
