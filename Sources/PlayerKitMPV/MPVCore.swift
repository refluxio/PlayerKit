import PlayerKit
import AVFoundation
import Foundation
import Mpv

// MARK: - MPVCore

/// mpv_handle 的唯一持有者。所有 libmpv C API 调用经此类进出。
public final class MPVCore: @unchecked Sendable {

    let handle: OpaquePointer
    private let eventLoop: MPVEventLoop

    public var events: AsyncStream<MPVEvent> { eventLoop.events }

    public init() {
        guard let h = mpv_create() else {
            fatalError("[MPVKit] mpv_create() failed")
        }
        handle = h
        eventLoop = MPVEventLoop(handle: h)

        // iOS 需要先激活 AVAudioSession(.playback) 才能出声
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        mpv_set_option_string(h, "vo",           "libmpv")
        mpv_set_option_string(h, "hwdec",        "auto-safe")  // 默认自动；可通过 Player.setHwAccel() 运行时覆盖
        // audio-device 不设，让 MPV 自动选默认输出（coreaudio/default 在 iOS 构建里不是有效设备 ID）
        mpv_set_option_string(h, "sub-auto",     "fuzzy")
        // Subtitle size: relative to video content, not the full FBO/window.
        // Without this, portrait mode FBO is tall → subtitles appear huge.
        mpv_set_option_string(h, "sub-scale-by-window", "no")
        mpv_set_option_string(h, "sub-font-size",       "52")
        mpv_set_option_string(h, "keep-open",    "yes")
        mpv_set_option_string(h, "idle",         "yes")
        mpv_set_option_string(h, "video-sync",   "display-resample")  // 微调音频同步显示帧率，消除 24fps@60Hz judder
        // interpolation 关闭：帧插值虽然平滑但 CPU 开销大导致发热，display-resample 已足够消除 judder

        mpv_initialize(h)

        mpv_observe_property(h, 0, MPVPropertyName.timePos.rawValue,             MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, MPVPropertyName.duration.rawValue,            MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, MPVPropertyName.pause.rawValue,               MPV_FORMAT_FLAG)
        mpv_observe_property(h, 0, MPVPropertyName.cacheBufferingState.rawValue, MPV_FORMAT_INT64)
        mpv_observe_property(h, 0, MPVPropertyName.width.rawValue,               MPV_FORMAT_INT64)
        mpv_observe_property(h, 0, MPVPropertyName.height.rawValue,              MPV_FORMAT_INT64)
        mpv_observe_property(h, 0, MPVPropertyName.speed.rawValue,               MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, MPVPropertyName.demuxerCacheDuration.rawValue, MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, MPVPropertyName.cacheSpeed.rawValue,           MPV_FORMAT_INT64)

        eventLoop.start()
    }

    deinit {
        mpv_terminate_destroy(handle)
    }

    // MARK: - Commands

    public func command(_ args: [String]) {
        var ptrs = args.map { strdup($0) }   // [UnsafeMutablePointer<CChar>?]
        ptrs.append(nil)
        ptrs.withUnsafeMutableBufferPointer { buf in
            // mpv_command expects const char **, which is UnsafePointer<UnsafePointer<CChar>?>
            buf.baseAddress!.withMemoryRebound(
                to: UnsafePointer<CChar>?.self,
                capacity: buf.count
            ) { cArgs in
                _ = mpv_command(handle, cArgs)
            }
        }
        ptrs.dropLast().forEach { free($0) }
    }

    // MARK: - Properties

    public func setString(_ name: MPVPropertyName, _ value: String) {
        mpv_set_property_string(handle, name.rawValue, value)
    }

    public func setFlag(_ name: MPVPropertyName, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name.rawValue, MPV_FORMAT_FLAG, &v)
    }

    public func setDouble(_ name: MPVPropertyName, _ value: Double) {
        var v = value
        mpv_set_property(handle, name.rawValue, MPV_FORMAT_DOUBLE, &v)
    }

    public func getString(_ name: MPVPropertyName) -> String? {
        guard let ptr = mpv_get_property_string(handle, name.rawValue) else { return nil }
        let str = String(cString: ptr)
        mpv_free(ptr)
        return str
    }

    public func getDouble(_ name: MPVPropertyName) -> Double {
        var value = 0.0
        mpv_get_property(handle, name.rawValue, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    public func getInt64(_ name: MPVPropertyName) -> Int64 {
        var value: Int64 = 0
        mpv_get_property(handle, name.rawValue, MPV_FORMAT_INT64, &value)
        return value
    }

    public func setHTTPHeaders(_ headers: [String: String]) {
        guard !headers.isEmpty else { return }
        let headerStr = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        mpv_set_property_string(handle, "http-header-fields", headerStr)
    }

    public func getJSON(_ name: String) -> String? {
        guard let ptr = mpv_get_property_string(handle, name) else { return nil }
        let str = String(cString: ptr)
        mpv_free(ptr)
        return str
    }
}
