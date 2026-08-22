struct PTSValidator {
    var frameDuration: Double
    let jumpThreshold: Double = 5.0
    let recoveryWindow: Double = 1.0

    private var lastValidPTS: Double = .nan
    private var predictPTS: Double = 0
    private var usingBlindClock = false

    init(frameDuration: Double = 1.0 / 25.0) {
        self.frameDuration = frameDuration
    }

    mutating func validate(_ pts: Double) -> Double {
        let isAnomalous = pts.isNaN
            || pts < 0
            || (!lastValidPTS.isNaN && abs(pts - lastValidPTS) > jumpThreshold)

        if isAnomalous {
            if !usingBlindClock {
                usingBlindClock = true
                if !lastValidPTS.isNaN { predictPTS = lastValidPTS }
            }
            predictPTS += frameDuration
            return predictPTS
        }

        if usingBlindClock {
            if abs(pts - predictPTS) < recoveryWindow {
                usingBlindClock = false
            } else {
                predictPTS += frameDuration
                return predictPTS
            }
        }

        lastValidPTS = pts
        predictPTS = pts
        return pts
    }

    mutating func reset() {
        lastValidPTS = .nan
        predictPTS = 0
        usingBlindClock = false
    }

    /// Adopt `pts` as the new trusted baseline without anomaly detection.
    /// Used when the caller knows the timeline jumped deliberately — e.g.
    /// MultiClipDemuxer's first packet after a clip boundary, whose PTS is
    /// already rebased onto the continuous global timeline. Bypassing
    /// validate() here avoids misreading the known switch as a >5s glitch.
    mutating func forceRebase(to pts: Double) {
        lastValidPTS = pts
        predictPTS = pts
        usingBlindClock = false
    }
}
