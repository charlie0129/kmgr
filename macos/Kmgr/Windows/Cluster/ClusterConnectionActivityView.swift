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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for light in [receiveLight, sendLight] {
            light.wantsLayer = true
            light.layer?.cornerRadius = 3
            light.translatesAutoresizingMaskIntoConstraints = false
            light.widthAnchor.constraint(equalToConstant: 6).isActive = true
            light.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rateLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1,
            weight: .regular
        )
        rateLabel.textColor = .secondaryLabelColor
        let lights = NSStackView(views: [receiveLight, sendLight])
        lights.orientation = .vertical
        lights.alignment = .centerX
        lights.spacing = 3
        let labels = NSStackView(views: [stateLabel, rateLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let stack = NSStackView(views: [lights, labels])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setState(.connected)
        update(rate: ClusterConnectionRate())
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Kubernetes API connection activity")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override var intrinsicContentSize: NSSize {
        let content = subviews.first?.fittingSize ?? NSSize(width: 140, height: 26)
        return NSSize(
            width: min(190, max(140, content.width)),
            height: max(26, content.height)
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
        setAccessibilityValue(detail.map { "\(presentation.0), \($0)" } ?? presentation.0)
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
        rateLabel.setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
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
