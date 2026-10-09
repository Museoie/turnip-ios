import Foundation

/// A FIFO with a hard capacity. On overflow it drops its *oldest* element and counts the drop, so
/// a consumer that falls behind loses the stalest work rather than stalling the producer or
/// growing without bound.
///
/// Sized in the live pose path to a few seconds of samples (`LivePoseSampleChannel.defaultCapacity`);
/// each element there is a ~196 KB tensor, so the bound is a memory safety valve, not steady state.
/// `maxDepth` and `dropCount` are what the acceptance gate reads: a queue that sits near empty means
/// inference is keeping up with capture.
///
/// Pure value semantics so the policy is unit-testable; `LivePoseSampleChannel` adds the lock and
/// the consumer hand-off.
struct BoundedSampleQueue<Element> {
    let capacity: Int
    private var elements: [Element] = []
    private(set) var dropCount = 0
    private(set) var maxDepth = 0
    private(set) var pushCount = 0

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedSampleQueue needs room for at least one element (got \(capacity))")
        self.capacity = capacity
    }

    /// Appends `element`, evicting the oldest queued element first when the queue is full.
    /// Returns the evicted element so a caller can account for it.
    @discardableResult
    mutating func push(_ element: Element) -> Element? {
        pushCount += 1
        var dropped: Element?
        if elements.count == capacity {
            dropped = elements.removeFirst()
            dropCount += 1
        }
        elements.append(element)
        maxDepth = max(maxDepth, elements.count)
        return dropped
    }

    mutating func pop() -> Element? {
        elements.isEmpty ? nil : elements.removeFirst()
    }

    mutating func removeAll() {
        elements.removeAll()
    }
}

extension BoundedSampleQueue: Sendable where Element: Sendable {}
