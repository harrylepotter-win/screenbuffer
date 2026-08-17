import Foundation

/// Central tuning knobs and paths for ScreenBuffer.
enum Config {
    /// How much history the rolling buffer keeps. User-settable from the menu and
    /// persisted, so the choice survives relaunch. Always clamped to
    /// `minBufferDuration ... maxBufferDuration`.
    static var bufferDuration: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: bufferDurationKey)
            guard stored > 0 else { return defaultBufferDuration }
            return clampBufferDuration(stored)
        }
        set {
            UserDefaults.standard.set(clampBufferDuration(newValue), forKey: bufferDurationKey)
        }
    }

    static let minBufferDuration: TimeInterval = 60             // 1 minute
    static let maxBufferDuration: TimeInterval = 3 * 60 * 60    // 3 hours
    static let defaultBufferDuration: TimeInterval = 10 * 60    // 10 minutes

    private static let bufferDurationKey = "bufferDuration"

    static func clampBufferDuration(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minBufferDuration), maxBufferDuration)
    }

    /// Human-readable buffer length, e.g. "10 min", "1 hr", "1 hr 30 min".
    static var formattedBufferDuration: String {
        durationLabel(minutes: Int((bufferDuration / 60).rounded()))
    }

    static func durationLabel(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// Rough on-disk cost of a buffer of `duration`, at the live encoder ceiling.
    /// Handy next to the slider — the number doubles-ish with 2× capture on.
    static func estimatedBytes(forDuration duration: TimeInterval) -> Int64 {
        Int64(duration * Double(activeBitrate) / 8)
    }

    // MARK: - Capture scale

    /// Capture at 2× the display's point size even when the display itself is 1×.
    /// On a genuinely Retina display the native scale is already 2 and this is a
    /// no-op; on a 1× panel it supersamples (bigger files, no extra detail — the
    /// window server only ever composites that screen at 1×).
    static var retinaCapture: Bool {
        get { UserDefaults.standard.bool(forKey: retinaCaptureKey) }
        set { UserDefaults.standard.set(newValue, forKey: retinaCaptureKey) }
    }

    private static let retinaCaptureKey = "retinaCapture"

    /// The scale to capture a display at, given its own backing scale factor.
    static func captureScale(nativeScale: CGFloat) -> CGFloat {
        retinaCapture ? max(nativeScale, 2) : nativeScale
    }

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
    ///
    /// The encoder ceiling is derived from the frame size rather than fixed, so
    /// quality-per-pixel stays constant when 2× capture quadruples the pixel
    /// count — a flat cap would spread the same bits over 4× the pixels and make
    /// zoomed-in text look *worse*. It's a ceiling, not a floor: a static screen
    /// still encodes at a fraction of it.
    ///
    /// 0.054 bits/pixel/frame ≈ 8 Mbps at 3440×1440@30.
    static let bitsPerPixelPerFrame: Double = 0.054

    static func bitrate(pixelWidth: Int, pixelHeight: Int) -> Int {
        Int(Double(pixelWidth * pixelHeight * framesPerSecond) * bitsPerPixelPerFrame)
    }

    /// Encoder ceiling of the live capture, published by `CaptureEngine` so the
    /// menu's disk estimate matches what's actually being written. UI-only — the
    /// encoder itself derives its rate from each segment's own dimensions.
    static var activeBitrate: Int = 8_000_000

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
