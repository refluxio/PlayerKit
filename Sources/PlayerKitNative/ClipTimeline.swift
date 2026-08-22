// Sources/PlayerKitNative/ClipTimeline.swift

/// Maps an ordered sequence of clips (each with its own real duration) onto
/// one continuous presentation timeline. Pure value type — no ffmpeg/reader
/// dependency. See docs/superpowers/specs/2026-08-22-disc-multiclip-pts-
/// continuity-design.md in the reflux repo for the full design rationale.
struct ClipTimeline: Equatable {
    /// Each clip's own real duration (caller-supplied — e.g. from BD
    /// playlist metadata — not ffmpeg-probed). Every entry must be > 0.
    let durationsSecs: [Double]

    /// Cumulative offset where each clip starts on the continuous timeline.
    /// startOffsets[0] == 0.
    let startOffsets: [Double]

    let totalDurationSecs: Double

    init?(durationsSecs: [Double]) {
        guard !durationsSecs.isEmpty, durationsSecs.allSatisfy({ $0 > 0 }) else { return nil }
        self.durationsSecs = durationsSecs
        var offsets: [Double] = []
        var cursor = 0.0
        for d in durationsSecs {
            offsets.append(cursor)
            cursor += d
        }
        self.startOffsets = offsets
        self.totalDurationSecs = cursor
    }

    /// Which clip index a global timeline position falls into, and that
    /// position expressed relative to the clip's own start (what to pass
    /// to that clip's own FFmpegDemuxer.seek(to:)). Clamps out-of-range
    /// input to the first/last clip instead of trapping — a seek target
    /// from UI/scrubber input can't fully guarantee it's in-range.
    func locate(globalSecs: Double) -> (clipIndex: Int, localSecs: Double) {
        if globalSecs <= 0 { return (0, 0) }
        if globalSecs >= totalDurationSecs {
            let lastIdx = durationsSecs.count - 1
            return (lastIdx, durationsSecs[lastIdx])
        }
        // startOffsets is sorted ascending — binary search for the largest
        // index whose start <= globalSecs.
        var lo = 0, hi = startOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if startOffsets[mid] <= globalSecs { lo = mid } else { hi = mid - 1 }
        }
        return (lo, globalSecs - startOffsets[lo])
    }
}
