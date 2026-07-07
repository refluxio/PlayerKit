import XCTest
@testable import PlayerKit

final class FrameQueueTests: XCTestCase {
    func testEmptyQueue() {
        let queue = FrameQueue()
        XCTAssertNil(queue.peek())
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
    }

    func testEnqueueDequeue() {
        let queue = FrameQueue()
        let frame = TimedFrame(pts: 1.0, duration: 0.04)
        queue.enqueue(frame)
        XCTAssertEqual(queue.count, 1)
        XCTAssertFalse(queue.isEmpty)

        let dequeued = queue.dequeue()
        XCTAssertEqual(dequeued?.pts, 1.0)
        XCTAssertTrue(queue.isEmpty)
    }

    func testFIFO() {
        let queue = FrameQueue()
        queue.enqueue(TimedFrame(pts: 1.0, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 1.04, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 1.08, duration: 0.04))

        XCTAssertEqual(queue.dequeue()?.pts, 1.0)
        XCTAssertEqual(queue.dequeue()?.pts, 1.04)
        XCTAssertEqual(queue.dequeue()?.pts, 1.08)
        XCTAssertNil(queue.dequeue())
    }

    func testPeekDoesNotRemove() {
        let queue = FrameQueue()
        queue.enqueue(TimedFrame(pts: 1.0, duration: 0.04))
        XCTAssertEqual(queue.count, 1)
        XCTAssertNotNil(queue.peek())
        XCTAssertEqual(queue.count, 1)
    }

    func testFlush() {
        let queue = FrameQueue()
        queue.enqueue(TimedFrame(pts: 1.0, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 2.0, duration: 0.04))
        queue.flush()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
    }

    func testDropUntil() {
        let queue = FrameQueue()
        queue.enqueue(TimedFrame(pts: 1.0, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 2.0, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 3.0, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 4.0, duration: 0.04))

        queue.dropUntil(pts: 3.0)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.peek()?.pts, 3.0)
    }

    func testDropUntilAllDropped() {
        let queue = FrameQueue()
        queue.enqueue(TimedFrame(pts: 1.0, duration: 0.04))
        queue.enqueue(TimedFrame(pts: 2.0, duration: 0.04))

        queue.dropUntil(pts: 10.0)
        XCTAssertTrue(queue.isEmpty)
    }

    func testDequeueEmptyReturnsNil() {
        let queue = FrameQueue()
        XCTAssertNil(queue.dequeue())
    }

    func testThreadSafety() {
        let queue = FrameQueue()
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            queue.enqueue(TimedFrame(pts: Double(i), duration: 0.04))
        }
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            _ = queue.dequeue()
        }
        // 不 crash 即通过
    }
}
