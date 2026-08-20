import AppKit
import KmgrCore

@MainActor
final class ClusterConnectionActivityView: NSView {
    private let stateLabel = NSTextField(labelWithString: "Connected")
    private let rateLabel = NSTextField(labelWithString: "↑↓ 0 B/s")
    private var displayedRate = ClusterConnectionRate()
    private var receiveArrowIsActive = false
    private var sendArrowIsActive = false
    private var stateAccessibilityValue = "Connected"
    private var rateAccessibilityValue = "Download 0 B/s, upload 0 B/s"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateLabel.maximumNumberOfLines = 1
        stateLabel.lineBreakMode = .byTruncatingTail
        let rateFont = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1,
            weight: .regular
        )
        rateLabel.font = rateFont
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.maximumNumberOfLines = 1
        rateLabel.lineBreakMode = .byClipping
        rateLabel.alignment = .right
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rateLabel.setContentHuggingPriority(.required, for: .horizontal)
        rateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        rateLabel.widthAnchor.constraint(
            equalToConstant: Self.maximumRateLabelWidth(font: rateFont)
        ).isActive = true
        let stack = NSStackView(views: [stateLabel, rateLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
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
        displayedRate = rate
        receiveArrowIsActive = rate.receivedActive
        sendArrowIsActive = rate.sentActive
        renderRateLabel()
    }

    private func renderRateLabel() {
        let aggregateRate = Self.rate(
            displayedRate.bytesReceivedPerSecond + displayedRate.bytesSentPerSecond
        )
        let font = rateLabel.font ?? .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1,
            weight: .regular
        )
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let presentation = NSMutableAttributedString()
        presentation.append(NSAttributedString(
            string: "↑",
            attributes: baseAttributes.merging([
                .foregroundColor: sendArrowIsActive
                    ? NSColor.systemRed
                    : NSColor.secondaryLabelColor,
            ]) { _, active in active }
        ))
        presentation.append(NSAttributedString(
            string: "↓",
            attributes: baseAttributes.merging([
                .foregroundColor: receiveArrowIsActive
                    ? NSColor.systemGreen
                    : NSColor.secondaryLabelColor,
            ]) { _, active in active }
        ))
        presentation.append(NSAttributedString(
            string: " \(aggregateRate)",
            attributes: baseAttributes
        ))
        rateLabel.attributedStringValue = presentation
        let value = "Aggregate \(aggregateRate), download \(receiveArrowIsActive ? "active" : "idle"), upload \(sendArrowIsActive ? "active" : "idle")"
        rateLabel.setAccessibilityLabel("Kubernetes API transfer rate")
        rateLabel.setAccessibilityValue(value)
        rateAccessibilityValue = value
        updateAccessibilityValue()
        invalidateIntrinsicContentSize()
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue("\(stateAccessibilityValue), \(rateAccessibilityValue)")
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        let maximumCounterRate = Double(UInt64.max) * 2
        let value: Double
        if bytesPerSecond.isNaN || bytesPerSecond <= 0 {
            value = 0
        } else {
            value = min(bytesPerSecond, maximumCounterRate)
        }
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s", "PiB/s", "EiB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(scaled.rounded())) \(units[index])" }
        return String(format: scaled < 10 ? "%.1f %@" : "%.0f %@", scaled, units[index])
    }

    private static func maximumRateLabelWidth(font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s", "PiB/s", "EiB/s"]
            .map { unit in
                ("↑↓ 1024 \(unit)" as NSString).size(withAttributes: attributes).width
            }
            .max().map { ceil($0) + 2 } ?? 92
    }
}
