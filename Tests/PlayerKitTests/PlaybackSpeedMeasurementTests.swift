import XCTest
@testable import PlayerKitNative

/// Measurement (regression) test for the "MKV plays ~2x speed" bug.
///
/// Plays each fixture through a real NativeBackend (ffmpeg demux/decode +
/// AudioUnitOutput audio clock + SyncController pacing) for ~8s of wall clock,
/// sampling `state.position` at 1Hz.  Playback speed is correct iff the
/// position advance ≈ wall-clock advance.
///
/// Fixtures (generated with ffmpeg testsrc2/sine — synthetic, no network):
///   - speed_dts48_51.mkv : h264 23.976fps + DTS 48kHz 5.1 (mirrors the
///     reported broken source: i.saw.the.devil BluRay MKV)
///   - speed_aac44_stereo.mp4 : h264 25fps + AAC 44.1kHz stereo (control,
///     mirrors the known-good source)
final class PlaybackSpeedMeasurementTests: XCTestCase {

    /// Tolerance for "plays at 1x".  Generous so CI load / buffering hiccups
    /// don't flake; a 2x-speed bug blows far past it.
    private static let tolerance: Double = 0.30

    private func fixtureURL(_ name: String, _ ext: String) -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: ext,
                                    subdirectory: "Fixtures")!
        return url
    }

    /// Plays `url` for `wallSeconds` of wall clock; returns (positionAdvance,
    /// wallAdvance, samples) measured from the moment position first leaves 0.
    private func measurePlaybackSpeed(url: URL, wallSeconds: Double) async throws
        -> (positionAdvance: Double, wallAdvance: Double, samples: [(Double, Double)]) {
        let backend = try await MainActor.run { try NativeBackend() }
        defer { Task { @MainActor in backend.stop() } }

        await MainActor.run { backend.play(url: url, headers: [:], seekTo: nil) }

        var samples: [(Double, Double)] = []   // (wall, positionSecs)
        let start = Date()
        var lastPosition: Double = -1
        var firstMovingWall: Double?
        var firstMovingPosition: Double?

        while Date().timeIntervalSince(start) < wallSeconds {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let wall = Date().timeIntervalSince(start)
            let pos: Double = await MainActor.run {
                Double(backend.state.position.components.seconds)
                    + Double(backend.state.position.components.attoseconds) / 1e18
            }
            if pos > 0 {
                if firstMovingWall == nil {
                    firstMovingWall = wall
                    firstMovingPosition = pos
                }
                lastPosition = pos
                samples.append((wall, pos))
            }
        }

        let wallAdvance = (firstMovingWall != nil) ? Date().timeIntervalSince(start) - firstMovingWall! : 0
        let positionAdvance = (firstMovingPosition != nil) ? lastPosition - firstMovingPosition! : 0
        return (positionAdvance, wallAdvance, samples)
    }

    private func assertApproximatelyRealtime(
        _ name: String, _ result: (positionAdvance: Double, wallAdvance: Double, samples: [(Double, Double)]),
        file: StaticString = #filePath, line: UInt = #line) {
        guard result.wallAdvance > 1.0 else {
            XCTFail("\(name): playback never started (position stayed at 0); samples=\(result.samples.count)",
                    file: file, line: line)
            return
        }
        let speed = result.positionAdvance / result.wallAdvance
        print("[speed-test] \(name): position +\(String(format: "%.2f", result.positionAdvance))s "
            + "over wall +\(String(format: "%.2f", result.wallAdvance))s → \(String(format: "%.2f", speed))x "
            + "(\(result.samples.count) samples)")
        XCTAssertLessThanOrEqual(abs(speed - 1.0), Self.tolerance,
            "\(name) plays at \(String(format: "%.2f", speed))x — position must advance ≈ wall clock",
            file: file, line: line)
    }

    /// MKV + DTS 48kHz 5.1 — the reported broken configuration.
    func testDTS_MKV_PlaysAtRealtimeSpeed() async throws {
        let r = try await measurePlaybackSpeed(
            url: fixtureURL("speed_dts48_51", "mkv"), wallSeconds: 9.0)
        assertApproximatelyRealtime("DTS/MKV", r)
    }

    /// MP4 + AAC 44.1kHz stereo — the known-good control.
    func testAAC_MP4_PlaysAtRealtimeSpeed() async throws {
        let r = try await measurePlaybackSpeed(
            url: fixtureURL("speed_aac44_stereo", "mp4"), wallSeconds: 9.0)
        assertApproximatelyRealtime("AAC/MP4", r)
    }
}
