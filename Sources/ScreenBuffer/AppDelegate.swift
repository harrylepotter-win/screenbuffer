import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = CaptureEngine()
    private var statusItem: NSStatusItem!

    private enum State { case recording, resuming, paused, needsPermission }
    private var state: State = .paused

    /// The user's intent — true whenever recording *should* be happening. Sleep,
    /// display reconfiguration, or a dropped stream can knock `engine.isRunning`
    /// false while this stays true; that gap is what the auto-resume logic closes.
    /// Only an explicit Pause sets this back to false.
    private var wantsRecording = false

    /// Pending backoff restart, so we never stack overlapping attempts.
    private var restartWork: DispatchWorkItem?
    private var restartAttempts = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        engine.onError = { [weak self] _ in
            // The stream stopped on its own (e.g. system sleep). Don't assume it's
            // a permission problem — try to bring it back.
            self?.resumeIfNeeded(afterDelay: 1)
        }

        // Wake / display-change events: the reliable trigger for post-sleep resume.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            nc.addObserver(self, selector: #selector(systemDidWake), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        rebuildMenu()
        startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        restartWork?.cancel()
        // Best-effort synchronous-ish stop; the buffer is transient anyway.
        let sem = DispatchSemaphore(value: 0)
        Task { await engine.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: - Capture control

    /// User-initiated start/resume. Resets backoff and declares intent to record.
    private func startCapture() {
        wantsRecording = true
        restartAttempts = 0
        attemptStart(afterDelay: 0)
    }

    private func pauseCapture() {
        wantsRecording = false
        restartWork?.cancel()
        restartWork = nil
        Task { @MainActor in
            await engine.stop()
            state = .paused
            rebuildMenu()
        }
    }

    /// Woke from sleep (or displays changed). If we're supposed to be recording
    /// but the stream isn't live, kick off a resume. The small delay lets the
    /// window server settle before ScreenCaptureKit tries to attach.
    @objc private func systemDidWake() {
        resumeIfNeeded(afterDelay: 2)
    }

    private func resumeIfNeeded(afterDelay delay: TimeInterval) {
        guard wantsRecording, !engine.isRunning else { return }
        if state != .needsPermission { state = .resuming; rebuildMenu() }
        attemptStart(afterDelay: delay)
    }

    /// Try to (re)start capture. On failure, distinguish a real permission denial
    /// (park in `.needsPermission`) from a transient failure (retry with capped
    /// exponential backoff — indefinitely, so a still-waking display self-heals).
    private func attemptStart(afterDelay delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.wantsRecording, !self.engine.isRunning else { return }
            Task { @MainActor in
                do {
                    try await self.engine.start()
                    self.restartAttempts = 0
                    self.state = .recording
                    self.rebuildMenu()
                } catch {
                    if !CGPreflightScreenCaptureAccess() {
                        // Genuinely not permitted — stop retrying and ask the user.
                        self.restartAttempts = 0
                        self.state = .needsPermission
                        self.rebuildMenu()
                    } else {
                        // Transient (e.g. display not ready yet after wake). Back off.
                        self.restartAttempts += 1
                        let backoff = min(pow(2.0, Double(min(self.restartAttempts, 5))), 30)
                        self.state = .resuming
                        self.rebuildMenu()
                        self.attemptStart(afterDelay: backoff)
                    }
                }
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        updateButton()

        let menu = NSMenu()

        switch state {
        case .recording:
            menu.addItem(disabledItem("● Recording — last \(minutes) min buffered"))
            menu.addItem(.separator())
            menu.addItem(action("Save last \(minutes) minutes", #selector(saveClip), key: "s"))
            menu.addItem(action("Pause recording", #selector(togglePause)))
        case .resuming:
            menu.addItem(disabledItem("↻ Resuming recording…"))
            menu.addItem(.separator())
            menu.addItem(action("Pause recording", #selector(togglePause)))
        case .paused:
            menu.addItem(disabledItem("❙❙ Paused — not recording"))
            menu.addItem(.separator())
            menu.addItem(action("Resume recording", #selector(togglePause), key: "r"))
        case .needsPermission:
            menu.addItem(disabledItem("⚠︎ Screen Recording permission needed"))
            menu.addItem(.separator())
            menu.addItem(action("Open Screen Recording settings…", #selector(openPrivacySettings)))
            menu.addItem(action("Try again", #selector(retryCapture)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Open recordings folder", #selector(openRecordingsFolder)))
        menu.addItem(.separator())
        menu.addItem(action("Quit ScreenBuffer", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let (symbol, fallback): (String, String)
        switch state {
        case .recording:      (symbol, fallback) = ("record.circle", "●")
        case .resuming:       (symbol, fallback) = ("arrow.clockwise.circle", "↻")
        case .paused:         (symbol, fallback) = ("pause.circle", "❙❙")
        case .needsPermission:(symbol, fallback) = ("exclamationmark.triangle", "⚠︎")
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenBuffer") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallback
        }
    }

    private var minutes: Int { Int(Config.bufferDuration / 60) }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func saveClip() {
        // Briefly reflect that a save is in progress.
        statusItem.button?.appearsDisabled = true
        engine.dump { [weak self] result in
            guard let self else { return }
            self.statusItem.button?.appearsDisabled = false
            switch result {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                self.showAlert("Couldn’t save clip", error.localizedDescription)
            }
        }
    }

    @objc private func togglePause() {
        switch state {
        case .recording, .resuming: pauseCapture()
        case .paused, .needsPermission: startCapture()
        }
    }

    @objc private func retryCapture() { startCapture() }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Config.recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.recordingsDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
