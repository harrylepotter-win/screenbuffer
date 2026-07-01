import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = CaptureEngine()
    private var statusItem: NSStatusItem!

    private enum State { case recording, paused, needsPermission }
    private var state: State = .paused

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        engine.onError = { [weak self] error in
            self?.handleError(error)
        }

        rebuildMenu()
        startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort synchronous-ish stop; the buffer is transient anyway.
        let sem = DispatchSemaphore(value: 0)
        Task { await engine.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: - Capture control

    private func startCapture() {
        Task { @MainActor in
            do {
                try await engine.start()
                state = .recording
            } catch {
                handleError(error)
            }
            rebuildMenu()
        }
    }

    private func pauseCapture() {
        Task { @MainActor in
            await engine.stop()
            state = .paused
            rebuildMenu()
        }
    }

    private func handleError(_ error: Error) {
        // A capture failure almost always means Screen Recording isn't granted.
        state = .needsPermission
        rebuildMenu()
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
        case .recording: pauseCapture()
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
