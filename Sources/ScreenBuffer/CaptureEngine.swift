import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit

/// Drives ScreenCaptureKit: captures the main display at a capped frame rate and
/// forwards complete frames into a `SegmentStore`. Video only — no audio inputs
/// are configured, so no Microphone permission is ever requested.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the main queue when capture stops unexpectedly or permission
    /// is missing, so the UI can prompt the user.
    var onError: ((Error) -> Void)?

    private(set) var isRunning = false
    private var stream: SCStream?
    private var store: SegmentStore?
    private let outputQueue = DispatchQueue(label: "com.bdavey.screenbuffer.capture")

    // MARK: - Control

    /// Start or resume capture. **Preserves** an existing rolling buffer if one is
    /// present (e.g. resuming after sleep) so pre-sleep footage survives. A fresh
    /// buffer is created only when none exists.
    func resume() async throws {
        guard !isRunning else { return }

        // Throws SCStreamError if Screen Recording permission hasn't been granted.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)

        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "ScreenBuffer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display available to capture"])
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = Int(CGFloat(display.width) * scale)
        let pixelHeight = Int(CGFloat(display.height) * scale)

        // If display geometry changed while suspended (e.g. a monitor was unplugged
        // during sleep), the buffered segments are incompatible — start fresh.
        if let existing = store, existing.width != pixelWidth || existing.height != pixelHeight {
            existing.teardown()
            store = nil
        }

        if store == nil {
            let fresh = SegmentStore(width: pixelWidth, height: pixelHeight)
            try fresh.prepare()
            store = fresh
        }

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Config.framesPerSecond))
        config.queueDepth = 6
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Empty exclusion list: capture the whole display.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        self.stream = stream
        isRunning = true
    }

    /// Suspend for sleep: stop the stream but KEEP the buffer and its segments, so
    /// a post-wake dump still includes what happened before sleep.
    func suspend() async {
        await stopStream()
        store?.flushCurrentSegment()
    }

    /// Stop capture and discard the rolling buffer (explicit user pause / quit).
    func stop() async {
        await stopStream()
        store?.teardown()
        store = nil
    }

    private func stopStream() async {
        isRunning = false
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
    }

    /// Stitch and save the buffered window. Fails cleanly if not recording.
    func dump(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let store else {
            completion(.failure(SegmentStore.DumpError.empty))
            return
        }
        store.dump(completion: completion)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isRunning else { return }
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return   // skip idle/blank/incomplete frames
        }
        store?.ingest(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }
}
