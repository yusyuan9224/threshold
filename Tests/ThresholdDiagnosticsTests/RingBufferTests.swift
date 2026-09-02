import Testing
@testable import ThresholdDiagnostics

@Suite struct RingBufferTests {
    @Test func keepsInsertionOrderBelowCapacity() {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 1...3 { _ = buffer.append(value) }
        #expect(buffer.count == 3)
        #expect(buffer.elements == [1, 2, 3])
    }

    @Test func keepsTheNewestCapacityElementsInOrderAfterOverflow() {
        let capacity = 8
        var buffer = RingBuffer<Int>(capacity: capacity)
        for value in 1...(capacity + 5) { _ = buffer.append(value) }
        #expect(buffer.count == capacity)
        #expect(buffer.elements == Array(6...13))
    }

    @Test func reportsWhenAnAppendEvicted() {
        var buffer = RingBuffer<Int>(capacity: 2)
        #expect(buffer.append(1) == false)
        #expect(buffer.append(2) == false)
        #expect(buffer.append(3) == true)
        #expect(buffer.elements == [2, 3])
    }

    @Test func suffixReturnsTheNewestElementsInOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 1...6 { _ = buffer.append(value) }
        #expect(buffer.suffix(2) == [5, 6])
        #expect(buffer.suffix(10) == [3, 4, 5, 6])
        #expect(buffer.suffix(0) == [])
        #expect(buffer.suffix(-1) == [])
    }

    @Test func suffixOnAPartiallyFilledBufferIsOrdered() {
        var buffer = RingBuffer<Int>(capacity: 10)
        for value in 1...3 { _ = buffer.append(value) }
        #expect(buffer.suffix(2) == [2, 3])
        #expect(buffer.suffix(99) == [1, 2, 3])
    }

    @Test func emptyBufferHasNoElements() {
        let buffer = RingBuffer<Int>(capacity: 4)
        #expect(buffer.count == 0)
        #expect(buffer.elements.isEmpty)
        #expect(buffer.suffix(3).isEmpty)
    }

    @Test func wrapsRepeatedlyWithoutLosingOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...100 { _ = buffer.append(value) }
        #expect(buffer.elements == [98, 99, 100])
    }
}
