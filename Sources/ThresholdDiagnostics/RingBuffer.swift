/// A fixed-capacity circular buffer: O(1) append, O(n) ordered read.
///
/// `DiagnosticsRecorder` ingests from every producer in the app at BLE advertisement rates, so the
/// append path is the hot one. Holding the window in an `Array` and calling `removeFirst()` at
/// capacity costs O(n) per event — 10,000 element moves for each advertisement once the buffer is
/// full. Here the oldest slot is simply overwritten and `head` advances.
///
/// Invariant: `storage.count <= capacity`, and `head` is a valid index into `storage` whenever
/// `storage` is non-empty. `head` stays 0 until the buffer first fills, so a partially filled buffer
/// reads back as plain insertion order.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest element.
    private var head: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }

    var isEmpty: Bool { storage.isEmpty }

    /// Appends `element`, overwriting the oldest one once at capacity.
    /// - Returns: `true` if an older element was evicted to make room.
    @discardableResult
    mutating func append(_ element: Element) -> Bool {
        guard storage.count == capacity else {
            storage.append(element)
            return false
        }
        storage[head] = element
        head = (head + 1) % capacity
        return true
    }

    /// Every buffered element, oldest first.
    var elements: [Element] {
        guard !storage.isEmpty else { return [] }
        return Array(storage[head...] + storage[..<head])
    }

    /// The newest `maxLength` elements, oldest first. Fewer are returned if the buffer holds fewer.
    func suffix(_ maxLength: Int) -> [Element] {
        let wanted = Swift.min(Swift.max(maxLength, 0), storage.count)
        guard wanted > 0 else { return [] }
        let start = storage.count - wanted
        return (start..<storage.count).map { storage[(head + $0) % storage.count] }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
