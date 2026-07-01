import Foundation

/// Central tuning knobs and paths for ScreenBuffer.
enum Config {
    /// How much history the rolling buffer keeps.
    static let bufferDuration: TimeInterval = 10 * 60      // 10 minutes

    /// Length of each on-disk segment file. Shorter = finer retention granularity
    /// but more files; 15s balances both.
    static let segmentDuration: TimeInterval = 15

    /// Number of *finalized* segments we retain. We keep one extra beyond the
    /// strict window so a dump always covers the full `bufferDuration` even while
    /// the newest segment is still being written.
    static var retainedSegmentCount: Int {
        Int((bufferDuration / segmentDuration).rounded(.up)) + 1
    }

    /// Frame-rate cap. Screen content rarely needs more; keeps files small.
    static let framesPerSecond: Int = 30

    /// Encode with HEVC (H.265). Great compression on Apple Silicon.
    /// Bits-per-second target for the video encoder.
    static let bitrate: Int = 8_000_000                    // 8 Mbps

    // MARK: - Paths

    /// Project root: ~/dev/screenbuffer
    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/screenbuffer", isDirectory: true)
    }

    /// Where dumped clips land: ~/dev/screenbuffer/recordings
    static var recordingsDirectory: URL {
        rootDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Hidden working dir for the rolling segment files.
    static var bufferDirectory: URL {
        recordingsDirectory.appendingPathComponent(".buffer", isDirectory: true)
    }

    static let bundleIdentifier = "com.bdavey.screenbuffer"
}
