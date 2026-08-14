import AppKit
import KmgrCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
    NSTextFieldDelegate
{
    private let preferencesStore: AppPreferencesStore
    private var loadedPreferences: AppPreferences
    private let shouldCenterOnFirstPresentation: Bool
    private var hasPresentedWindow = false

    private let appearanceButton = NSPopUpButton()
    private let namespaceButton = NSPopUpButton()
    private let logRecordLimitField = NSTextField()
    private let logByteLimitField = NSTextField()
    private let renderBatchField = NSTextField()
    private let metricsRefreshField = NSTextField()
    private let restoreWindowsButton = NSButton(
        checkboxWithTitle: "Restore open cluster windows when Kmgr launches",
        target: nil,
        action: nil
    )
    private let confirmRestartButton = NSButton(checkboxWithTitle: "Confirm workload restarts", target: nil, action: nil)
    private let confirmScaleButton = NSButton(checkboxWithTitle: "Confirm scaling changes", target: nil, action: nil)
    private let columnsPathField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    var onPreferencesChanged: ((AppPreferences, AppPreferencesDelta) -> Void)?

    init(
        preferencesStore: AppPreferencesStore,
        frameAutosaveName: String = "Settings"
    ) {
        self.preferencesStore = preferencesStore
        loadedPreferences = preferencesStore.current
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings — \(Product.applicationName)"
        window.minSize = NSSize(width: 610, height: 500)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let restoredSavedFrame = window.setFrameUsingName(frameAutosaveName)
        window.setFrameAutosaveName(frameAutosaveName)
        shouldCenterOnFirstPresentation = !restoredSavedFrame
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
        install(loadedPreferences)
        if let issue = preferencesStore.loadIssue {
            showStatus(issue.message, error: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        if !hasPresentedWindow {
            hasPresentedWindow = true
            if shouldCenterOnFirstPresentation { window?.center() }
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func controlTextDidChange(_ obj: Notification) {
        validateControls(showSuccess: false)
    }

    private func configureContent(in window: NSWindow) {
        appearanceButton.addItems(withTitles: AppearancePreference.allCases.map(\.title))
        appearanceButton.target = self
        appearanceButton.action = #selector(controlValueChanged)
        namespaceButton.addItems(withTitles: DefaultNamespacePreference.allCases.map(\.title))
        namespaceButton.target = self
        namespaceButton.action = #selector(controlValueChanged)
        restoreWindowsButton.target = self
        restoreWindowsButton.action = #selector(controlValueChanged)
        restoreWindowsButton.setAccessibilityIdentifier("settings.restoreOpenClusterWindows")

        for field in [
            logRecordLimitField, logByteLimitField, renderBatchField,
            metricsRefreshField, columnsPathField,
        ] {
            field.delegate = self
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
        }
        for field in [logRecordLimitField, logByteLimitField, renderBatchField, metricsRefreshField] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        columnsPathField.lineBreakMode = .byTruncatingMiddle
        columnsPathField.setAccessibilityLabel("External column configuration path")

        confirmRestartButton.target = self
        confirmRestartButton.action = #selector(controlValueChanged)
        confirmScaleButton.target = self
        confirmScaleButton.action = #selector(controlValueChanged)

        let general = section(
            title: "General",
            rows: [
                labeledRow("Appearance", control: appearanceButton),
                labeledRow("Default namespace", control: namespaceButton),
                labeledRow("Metrics refresh", control: metricsRefreshField, suffix: "seconds"),
                restoreWindowsButton,
            ]
        )
        let logs = section(
            title: "Logs",
            rows: [
                labeledRow("Retained records", control: logRecordLimitField),
                labeledRow("Retained data", control: logByteLimitField, suffix: "MiB"),
                labeledRow("Render batching", control: renderBatchField, suffix: "milliseconds"),
            ]
        )

        let safetyText = NSTextField(wrappingLabelWithString:
            "Deletion, active terminal close, and non-loopback port-forward confirmations remain enabled. Cluster and namespace identity is always shown for high-risk actions."
        )
        safetyText.textColor = .secondaryLabelColor
        safetyText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let confirmationControls = NSStackView(views: [
            confirmRestartButton,
            confirmScaleButton,
            safetyText,
        ])
        confirmationControls.orientation = .vertical
        confirmationControls.alignment = .leading
        confirmationControls.spacing = 6
        let confirmations = section(title: "Confirmations", rows: [confirmationControls])

        let openColumnsButton = NSButton(
            title: "Open in Editor",
            target: self,
            action: #selector(openColumnsInEditor)
        )
        let columnsRow = NSStackView(views: [columnsPathField, openColumnsButton])
        columnsRow.orientation = .horizontal
        columnsRow.alignment = .centerY
        columnsRow.spacing = 8
        columnsPathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let columnsHelp = NSTextField(wrappingLabelWithString:
            "Definitions are shared across clusters and matched by exact group/version/resource. The file schema and CEL environment are versioned."
        )
        columnsHelp.textColor = .secondaryLabelColor
        columnsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let columnControls = NSStackView(views: [columnsRow, columnsHelp])
        columnControls.orientation = .vertical
        columnControls.alignment = .leading
        columnControls.spacing = 5
        columnsRow.widthAnchor.constraint(equalTo: columnControls.widthAnchor).isActive = true
        let columns = section(title: "Programmable Columns", rows: [columnControls])

        let shortcutGrid = NSGridView(views: KeyboardShortcutReference.defaults.map { shortcut in
            let keys = NSTextField(labelWithString: shortcut.keys)
            keys.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            keys.alignment = .right
            keys.setContentHuggingPriority(.required, for: .horizontal)
            let action = NSTextField(labelWithString: shortcut.action)
            action.textColor = .secondaryLabelColor
            return [keys, action]
        })
        shortcutGrid.rowSpacing = 4
        shortcutGrid.columnSpacing = 14
        shortcutGrid.column(at: 0).xPlacement = .trailing
        shortcutGrid.column(at: 1).xPlacement = .leading
        let shortcuts = section(title: "Keyboard Shortcuts", rows: [shortcutGrid])

        let contentStack = NSStackView(views: [general, logs, confirmations, columns, shortcuts])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for section in [general, logs, confirmations, columns, shortcuts] {
            section.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        }

        let documentView = NSView()
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 580),
        ])

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.maximumNumberOfLines = 4
        statusLabel.lineBreakMode = .byWordWrapping

        let defaultsButton = NSButton(title: "Use Defaults", target: self, action: #selector(useDefaults))
        let revertButton = NSButton(title: "Revert", target: self, action: #selector(revert))
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [
            statusLabel, NSView(), defaultsButton, revertButton, applyButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -5),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        window.contentView = root
    }

    private func section(title: String, rows: [NSView]) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = NSView()
        box.contentView?.addSubview(stack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        return box
    }

    private func labeledRow(_ title: String, control: NSView, suffix: String? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let views: [NSView]
        if let suffix {
            let suffixLabel = NSTextField(labelWithString: suffix)
            suffixLabel.textColor = .secondaryLabelColor
            views = [label, control, suffixLabel, NSView()]
        } else {
            views = [label, control, NSView()]
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func install(_ preferences: AppPreferences) {
        appearanceButton.selectItem(at: AppearancePreference.allCases.firstIndex(of: preferences.appearance) ?? 0)
        namespaceButton.selectItem(at: DefaultNamespacePreference.allCases.firstIndex(of: preferences.defaultNamespace) ?? 0)
        logRecordLimitField.integerValue = preferences.logs.recordLimit
        logByteLimitField.integerValue = preferences.logs.byteLimit / (1 << 20)
        renderBatchField.integerValue = preferences.logs.renderBatchMilliseconds
        metricsRefreshField.integerValue = preferences.metricsRefreshSeconds
        restoreWindowsButton.state = preferences.restoreOpenClusterWindows ? .on : .off
        confirmRestartButton.state = preferences.confirmations.confirmWorkloadRestart ? .on : .off
        confirmScaleButton.state = preferences.confirmations.confirmScaling ? .on : .off
        columnsPathField.stringValue = preferences.columnsConfigurationPath
        applyAppearance(preferences.appearance)
        validateControls(showSuccess: false)
    }

    private func preferencesFromControls() -> AppPreferences {
        let appearanceIndex = max(0, appearanceButton.indexOfSelectedItem)
        let namespaceIndex = max(0, namespaceButton.indexOfSelectedItem)
        let mib = parsedInteger(logByteLimitField)
        let byteLimit: Int
        if mib > 0, !mib.multipliedReportingOverflow(by: 1 << 20).overflow {
            byteLimit = mib * (1 << 20)
        } else {
            byteLimit = 0
        }
        return AppPreferences(
            appearance: AppearancePreference.allCases[safe: appearanceIndex] ?? .system,
            logs: LogDisplayPreferences(
                recordLimit: parsedInteger(logRecordLimitField),
                byteLimit: byteLimit,
                renderBatchMilliseconds: parsedInteger(renderBatchField)
            ),
            metricsRefreshSeconds: parsedInteger(metricsRefreshField),
            defaultNamespace: DefaultNamespacePreference.allCases[safe: namespaceIndex] ?? .contextDefault,
            restoreOpenClusterWindows: restoreWindowsButton.state == .on,
            confirmations: ConfirmationPreferences(
                confirmWorkloadRestart: confirmRestartButton.state == .on,
                confirmScaling: confirmScaleButton.state == .on
            ),
            columnsConfigurationPath: columnsPathField.stringValue
        )
    }

    private func parsedInteger(_ field: NSTextField) -> Int {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let integer = Int(value) { return integer }

        // NSTextField may format an integerValue with the current locale's
        // grouping separator (for example "20,000"). Accept that exact
        // integer representation without accepting fractional input.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.isLenient = false
        return formatter.number(from: value)?.intValue ?? 0
    }

    private func validateControls(showSuccess: Bool) {
        let preferences = preferencesFromControls()
        let issues = preferences.validationIssues()
        applyButton.isEnabled = issues.isEmpty
        if let issue = issues.first {
            showStatus(issue.message, error: true)
        } else if showSuccess {
            showStatus("Settings are valid.", error: false)
        } else if preferencesStore.loadIssue == nil {
            statusLabel.stringValue = ""
        }
        applyAppearance(preferences.appearance)
    }

    private func applyAppearance(_ preference: AppearancePreference) {
        switch preference {
        case .system: window?.appearance = nil
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func showStatus(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = message
    }

    @objc private func controlValueChanged() {
        validateControls(showSuccess: false)
    }

    @objc private func apply() {
        do {
            let preferences = try preferencesFromControls().validated()
            let delta = AppPreferencesDelta(
                previous: preferencesStore.current,
                updated: preferences
            )
            try preferencesStore.save(preferences)
            loadedPreferences = preferencesStore.current
            install(loadedPreferences)
            showStatus(statusMessage(for: delta), error: false)
            onPreferencesChanged?(loadedPreferences, delta)
        } catch {
            showStatus(error.localizedDescription, error: true)
        }
    }

    private func statusMessage(for delta: AppPreferencesDelta) -> String {
        guard !delta.isEmpty else { return "Settings are already up to date." }

        var messages = ["Settings saved."]
        if delta.contains(.logDisplay) {
            messages.append("Open log windows were updated.")
        }
        if delta.contains(.defaultNamespace) {
            messages.append("The default namespace applies to new cluster windows.")
        }
        let relaunchChanges = delta.changes(activated: .applicationRelaunch)
        if !relaunchChanges.isEmpty {
            let names = relaunchChanges.map(\.title).joined(separator: " and ")
            let verb = relaunchChanges.count == 1 ? "applies" : "apply"
            messages.append("\(names) \(verb) after relaunching the app. The running helper was not restarted, and Kubernetes mutations were not replayed.")
        }
        return messages.joined(separator: " ")
    }

    @objc private func revert() {
        install(loadedPreferences)
        showStatus("Unsaved changes reverted.", error: false)
    }

    @objc private func useDefaults() {
        install(AppPreferences())
        showStatus("Defaults are ready to apply.", error: false)
    }

    @objc private func openColumnsInEditor() {
        let store = ColumnConfigurationFileStore(path: columnsPathField.stringValue)
        do {
            let url = try store.ensureFileExists()
            guard NSWorkspace.shared.open(url) else {
                throw ColumnConfigurationFileIssue("No application could open \(url.path).")
            }
            showStatus("Opened \(url.lastPathComponent) in the default editor.", error: false)
        } catch {
            showStatus(error.localizedDescription, error: true)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
