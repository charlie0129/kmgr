import AppKit
import KmgrCore

@MainActor
final class ClusterConnectionActivityView: NSView {
    private let receiveLight = NSView()
    private let sendLight = NSView()
    private let stateLabel = NSTextField(labelWithString: "Connected")
    private let rateLabel = NSTextField(labelWithString: "↓ 0 B/s  ↑ 0 B/s")
    private var receiveFadeTask: Task<Void, Never>?
    private var sendFadeTask: Task<Void, Never>?
    private var rateResetTask: Task<Void, Never>?
    private var stateAccessibilityValue = "Connected"
    private var rateAccessibilityValue = "Download 0 B/s, upload 0 B/s"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for light in [receiveLight, sendLight] {
            light.wantsLayer = true
            light.layer?.cornerRadius = 3
            light.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            light.translatesAutoresizingMaskIntoConstraints = false
            light.widthAnchor.constraint(equalToConstant: 6).isActive = true
            light.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
        receiveLight.identifier = .init("connection-receive-indicator")
        sendLight.identifier = .init("connection-send-indicator")
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rateLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1,
            weight: .regular
        )
        rateLabel.textColor = .secondaryLabelColor
        let lights = NSStackView(views: [receiveLight, sendLight])
        lights.orientation = .horizontal
        lights.alignment = .centerY
        lights.spacing = 3
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        rateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [stateLabel, lights, rateLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Kubernetes API connection activity")
        setState(.connected)
        update(rate: ClusterConnectionRate())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override var intrinsicContentSize: NSSize {
        let content = subviews.first?.fittingSize ?? NSSize(width: 176, height: 16)
        return NSSize(
            width: min(280, max(176, content.width)),
            height: max(16, content.height)
        )
    }

    func setState(_ state: ClusterConnectionState, detail: String? = nil) {
        let presentation: (String, NSColor) = switch state {
        case .connecting: ("Connecting…", .secondaryLabelColor)
        case .connected: ("Connected", .secondaryLabelColor)
        case .reconnecting: ("Reconnecting…", .systemOrange)
        case .disconnected: ("Disconnected", .systemOrange)
        case .failed: ("Connection failed", .systemRed)
        case .closed: ("Closed", .tertiaryLabelColor)
        }
        stateLabel.stringValue = presentation.0
        stateLabel.textColor = presentation.1
        toolTip = detail
        stateAccessibilityValue = detail.map {
            "\(presentation.0), \($0)"
        } ?? presentation.0
        updateAccessibilityValue()
        invalidateIntrinsicContentSize()
    }

    func update(rate: ClusterConnectionRate) {
        setRateLabel(rate)
        if rate.receivedActive { blink(receiveLight, color: .systemGreen, task: &receiveFadeTask) }
        if rate.sentActive { blink(sendLight, color: .systemBlue, task: &sendFadeTask) }
        rateResetTask?.cancel()
        if rate.receivedActive || rate.sentActive {
            rateResetTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.setRateLabel(ClusterConnectionRate())
            }
        }
    }

    private func setRateLabel(_ rate: ClusterConnectionRate) {
        rateLabel.stringValue = "↓ \(Self.rate(rate.bytesReceivedPerSecond))  ↑ \(Self.rate(rate.bytesSentPerSecond))"
        let value = "Download \(Self.rate(rate.bytesReceivedPerSecond)), upload \(Self.rate(rate.bytesSentPerSecond))"
        rateLabel.setAccessibilityLabel("Kubernetes API transfer rate")
        rateLabel.setAccessibilityValue(value)
        rateAccessibilityValue = value
        updateAccessibilityValue()
        invalidateIntrinsicContentSize()
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue("\(stateAccessibilityValue), \(rateAccessibilityValue)")
    }

    private func blink(
        _ light: NSView,
        color: NSColor,
        task: inout Task<Void, Never>?
    ) {
        task?.cancel()
        light.layer?.backgroundColor = color.cgColor
        task = Task { [weak light] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            light?.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        }
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(scaled.rounded())) \(units[index])" }
        return String(format: scaled < 10 ? "%.1f %@" : "%.0f %@", scaled, units[index])
    }
}
