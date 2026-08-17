import Foundation
import AVFoundation
import CoreMedia

/// Owns the rolling buffer: rotates `SegmentRecorder`s every `segmentDuration`,
/// keeps only the most recent segments on disk, and stitches the retained window
/// into a single clip on demand.
///
/// Frame ingestion runs on a private serial queue. Dumps stitch/export off that
/// queue but protect their source segments from retention deletion meanwhile.
final class SegmentStore {
    let width: Int
    let height: Int
    private let queue = DispatchQueue(label: "com.bdavey.screenbuffer.recording")

    private var current: SegmentRecorder?
    private var segments: [URL] = []              // finalized, oldest → newest
    private var protectedURLs: Set<URL> = []      // pinned during an active dump
    private var sequence = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    // MARK: - Lifecycle

    /// Create the buffer dir and wipe any leftovers from a previous run.
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Config.recordingsDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Config.bufferDirectory.path) {
            try? fm.removeItem(at: Config.bufferDirectory)
        }
        try fm.createDirectory(at: Config.bufferDirectory, withIntermediateDirectories: true)
    }

    /// Stop recording and discard the working buffer (call on quit/pause).
    func teardown() {
        queue.sync {
            current?.finish { _ in }
            current = nil
        }
    }

    /// Finalize the in-progress segment but KEEP it and all buffered segments.
    /// Used when suspending for sleep so post-wake dumps still include pre-sleep
    /// footage. A fresh segment begins on the next ingested frame after resume.
    func flushCurrentSegment() {
        queue.async { [self] in
            rotate()
        }
    }

    /// Re-apply the retention window now — used when the user shortens the buffer,
    /// so the excess is dropped immediately rather than at the next rotation.
    func applyRetentionNow() {
        queue.async { [self] in
            applyRetention()
        }
    }

    // MARK: - Ingestion

    /// Feed one captured frame into the rolling buffer.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if current == nil {
                current = try? makeRecorder()
            }
            if let seg = current, seg.duration(upTo: pts) >= Config.segmentDuration {
                rotate()
                current = try? makeRecorder()
            }
            current?.append(sampleBuffer)
        }
    }

    private func makeRecorder() throws -> SegmentRecorder {
        sequence += 1
        let url = Config.bufferDirectory
            .appendingPathComponent(String(format: "seg-%08d.mov", sequence))
        return try SegmentRecorder(url: url, width: width, height: height)
    }

    /// Finalize `current`, record it in order, and apply retention on completion.
    /// Must run on `queue`.
    private func rotate() {
        guard let finishing = current else { return }
        current = nil
        segments.append(finishing.url)             // keep ordering deterministic
        finishing.finish { [weak self] ok in
            guard let self else { return }
            self.queue.async {
                if !ok {
                    self.segments.removeAll { $0 == finishing.url }
                    try? FileManager.default.removeItem(at: finishing.url)
                }
                self.applyRetention()
            }
        }
    }

    /// Delete the oldest finalized segments beyond the retention window.
    /// Skips (and stops at) any segment pinned by an in-flight dump. On `queue`.
    private func applyRetention() {
        while segments.count > Config.retainedSegmentCount {
            guard let oldest = segments.first, !protectedURLs.contains(oldest) else { break }
            segments.removeFirst()
            try? FileManager.default.removeItem(at: oldest)
        }
    }

    // MARK: - Dump

    enum DumpError: Error, LocalizedError {
        case empty
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "Nothing has been recorded yet."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    /// Stitch the retained buffer (up to the last `bufferDuration`) into one
    /// timestamped clip in `recordings/`. Recording continues throughout.
    /// `completion` is called on the main queue.
    func dump(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            // Flush the in-progress segment so the clip runs right up to "now".
            forceRotate {
                let window = self.dumpWindow()
                guard !window.isEmpty else {
                    DispatchQueue.main.async { completion(.failure(DumpError.empty)) }
                    return
                }
                window.forEach { self.protectedURLs.insert($0) }

                Task {
                    let result: Result<URL, Error>
                    do {
                        result = .success(try await self.stitch(window))
                    } catch {
                        result = .failure(error)
                    }
                    self.queue.async {
                        window.forEach { self.protectedURLs.remove($0) }
                        self.applyRetention()
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    /// Finalize the current segment (if any), then continue on `queue`.
    private func forceRotate(then next: @escaping () -> Void) {
        guard let finishing = current else { next(); return }
        current = nil
        let url = finishing.url
        finishing.finish { [weak self] ok in
            guard let self else { return }
            self.queue.async {
                if ok {
                    self.segments.append(url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
                next()
            }
        }
    }

    /// The most recent segments spanning `bufferDuration`. On `queue`.
    private func dumpWindow() -> [URL] {
        let count = Int((Config.bufferDuration / Config.segmentDuration).rounded(.up))
        return Array(segments.suffix(count))
    }

    private func stitch(_ urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DumpError.exportFailed("could not create composition track")
        }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration > .zero else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor > .zero else { throw DumpError.empty }

        let outURL = Config.recordingsDirectory
            .appendingPathComponent("ScreenBuffer-\(Self.timestamp()).mov")

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough) else {
            throw DumpError.exportFailed("could not create export session")
        }
        export.outputURL = outURL
        export.outputFileType = .mov

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            throw DumpError.exportFailed(export.error?.localizedDescription ?? "unknown")
        }
        return outURL
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}
