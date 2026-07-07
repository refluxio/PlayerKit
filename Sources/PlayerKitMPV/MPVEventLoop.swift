import PlayerKit
import Foundation
import Mpv

// MARK: - MPVEventLoop

/// 在独立线程调用 mpv_wait_event(-1)，将 C 事件转为 Swift MPVEvent 输出到 AsyncStream。
/// 使用独立 Thread 而非 Swift Concurrency Task，避免占用 GCD 线程池。
final class MPVEventLoop: @unchecked Sendable {

    private let handle: OpaquePointer
    private var continuation: AsyncStream<MPVEvent>.Continuation?

    let events: AsyncStream<MPVEvent>

    init(handle: OpaquePointer) {
        self.handle = handle
        let (stream, cont) = AsyncStream<MPVEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.events = stream
        self.continuation = cont
    }

    func start() {
        let h = handle
        let cont = continuation
        Thread.detachNewThread {
            while true {
                guard let event = mpv_wait_event(h, -1) else { continue }
                let mpvEvent = Self.convert(event)
                cont?.yield(mpvEvent)
                if case .shutdown = mpvEvent {
                    cont?.finish()
                    break
                }
            }
        }
    }

    private static func convert(_ event: UnsafeMutablePointer<mpv_event>) -> MPVEvent {
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_START_FILE:
            return .startFile
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_VIDEO_RECONFIG:
            return .videoReconfig
        case MPV_EVENT_AUDIO_RECONFIG:
            return .audioReconfig
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { return .endOfFile(reason: .eof) }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let reason = MPVEvent.EndReason(rawValue: endFile.reason.rawValue) ?? .eof
            return .endOfFile(reason: reason)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { return .unknown }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let nameCStr = prop.name,
                  let propName = MPVPropertyName(rawValue: String(cString: nameCStr)) else {
                return .unknown
            }
            let value = MPVValue(format: prop.format, data: prop.data)
            return .propertyChange(name: propName, value: value)
        default:
            return .unknown
        }
    }
}

// MARK: - MPVValue from C

extension MPVValue {
    init(format: mpv_format, data: UnsafeMutableRawPointer?) {
        guard let data else { self = .none; return }
        switch format {
        case MPV_FORMAT_DOUBLE:
            self = .double(data.load(as: Double.self))
        case MPV_FORMAT_INT64:
            self = .int64(data.load(as: Int64.self))
        case MPV_FORMAT_FLAG:
            self = .bool(data.load(as: Int32.self) != 0)
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            let ptr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
            self = ptr.map { .string(String(cString: $0)) } ?? .none
        default:
            self = .none
        }
    }
}
