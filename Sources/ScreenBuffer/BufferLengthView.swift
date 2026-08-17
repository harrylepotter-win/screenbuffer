import AppKit

/// Menu-item view: a slider that sets `Config.bufferDuration`.
///
/// The slider snaps to a fixed list of sensible stops rather than sweeping
/// linearly over 1–180 minutes — a linear sweep makes the short end (where the
/// useful settings live) almost impossible to hit.
final class BufferLengthView: NSView {
    /// Minute stops, shortest → longest.
    static let steps: [Int] = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180]

    /// Called with the new duration whenever the user moves the slider.
    var onChange: ((TimeInterval) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 56))

        label.frame = NSRect(x: 14, y: 30, width: 232, height: 16)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        slider.frame = NSRect(x: 12, y: 8, width: 236, height: 20)
        slider.minValue = 0
        slider.maxValue = Double(Self.steps.count - 1)
        slider.numberOfTickMarks = Self.steps.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel("Buffer length")
        addSubview(slider)

        syncFromConfig()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pull the current setting back out of `Config` — the menu is rebuilt on every
    /// open, but this keeps a reused view honest.
    func syncFromConfig() {
        let minutes = Int((Config.bufferDuration / 60).rounded())
        slider.doubleValue = Double(Self.nearestStepIndex(toMinutes: minutes))
        updateLabel(minutes: Self.steps[Self.nearestStepIndex(toMinutes: minutes)])
    }

    @objc private func sliderMoved() {
        let minutes = Self.steps[Self.clampedIndex(slider.doubleValue)]
        updateLabel(minutes: minutes)
        let duration = TimeInterval(minutes * 60)
        Config.bufferDuration = duration
        onChange?(duration)
    }

    private func updateLabel(minutes: Int) {
        let size = ByteCountFormatter.string(
            fromByteCount: Config.estimatedBytes(forDuration: TimeInterval(minutes * 60)),
            countStyle: .file)
        label.stringValue = "Buffer length: \(Config.durationLabel(minutes: minutes)) · ~\(size)"
        toolTip = "How much history to keep. Longer buffers use more disk (about \(size) here)."
    }

    private static func clampedIndex(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), steps.count - 1)
    }

    private static func nearestStepIndex(toMinutes minutes: Int) -> Int {
        var best = 0
        for (i, step) in steps.enumerated()
        where abs(step - minutes) < abs(steps[best] - minutes) {
            best = i
        }
        return best
    }
}
