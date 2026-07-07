import Foundation
import CoreVideo

public struct TimedFrame {
    public let pixelBuffer: CVPixelBuffer?
    public let pts: Double
    public let duration: Double

    public init(pixelBuffer: CVPixelBuffer? = nil, pts: Double, duration: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
    }
}

public final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [TimedFrame] = []

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return frames.isEmpty }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    public init() {}

    public func enqueue(_ frame: TimedFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    public func peek() -> TimedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first
    }

    public func dequeue() -> TimedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    public func flush() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    public func dropUntil(pts target: Double) {
        lock.lock()
        while let first = frames.first, first.pts < target {
            frames.removeFirst()
        }
        lock.unlock()
    }
}
