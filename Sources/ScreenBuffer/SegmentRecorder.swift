import Foundation
import AVFoundation
import CoreMedia

/// Writes a single rolling-buffer segment: one `.mov` file backed by an
/// `AVAssetWriter` encoding HEVC. Deliberately "dumb" — rotation and retention
/// live in `SegmentStore`. All methods must be called on the store's serial
/// recording queue, except the `finish` completion which hops back on its own.
final class SegmentRecorder {
    let url: URL

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false

    /// Absolute presentation time of this segment's first frame.
    private(set) var startPTS: CMTime = .invalid

    init(url: URL, width: Int, height: Int) throws {
        self.url = url

        // .mov container plays nicely with HEVC + passthrough stitching later.
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Config.bitrate(pixelWidth: width, pixelHeight: height),
                AVVideoExpectedSourceFrameRateKey: Config.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: Config.segmentDuration,
            ],
        ]

        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "ScreenBuffer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to writer"])
        }
        writer.add(input)
    }

    /// Append one captured frame. The first successful append starts the
    /// writing session at that frame's timestamp. Returns whether it was taken.
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !started {
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            started = true
        }

        guard input.isReadyForMoreMediaData else { return false }
        return input.append(sampleBuffer)
    }

    /// How much wall-clock time this segment currently spans.
    func duration(upTo pts: CMTime) -> TimeInterval {
        guard started else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(pts, startPTS))
    }

    /// Finalize the file. `completion` is invoked (off the calling queue) once
    /// the `.mov` is fully written, with success = writer reached `.completed`.
    func finish(completion: @escaping (Bool) -> Void) {
        guard started else {
            // Never received a usable frame — nothing to flush.
            completion(false)
            return
        }
        input.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed)
        }
    }
}
