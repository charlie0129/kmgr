import AppKit
import KmgrCore

private final class FlippedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

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
    private let maximumRenderedLogTextField = NSTextField()
    private let maximumDisplayedLogLineField = NSTextField()
    private let completedOperationHistoryLimitField = NSTextField()
    private let defaultDeleteConcurrencyField = NSTextField()
    private let nodeShellImageField = NSTextField()
    private let metricsRefreshField = NSTextField()
    private let viewportOverscanField = NSTextField()
    private let viewReleaseGraceField = NSTextField()
    private let globalWarmViewLimitField = NSTextField()
    private let globalWarmObjectLimitField = NSTextField()
    private let globalWarmMemoryPercentField = NSTextField()
    private let authorityWarmViewLimitField = NSTextField()
    private let authorityWarmObjectLimitField = NSTextField()
    private let authorityWarmMemoryPercentField = NSTextField()
    private let kubernetesQPSField = NSTextField()
    private let kubernetesBurstField = NSTextField()
    private let kubernetesListPageSizeField = NSTextField()
    private let clusterConnectionTimeoutField = NSTextField()
    private let kubernetesRequestTimeoutField = NSTextField()
    private let idleMetricProviderLimitField = NSTextField()
    private let idleMetricSampleLimitField = NSTextField()
    private let exactPodMetricsEntryLimitField = NSTextField()
    private let exactPodMetricsSampleLimitField = NSTextField()
    private let exactPodMetricsDetailEntryLimitField = NSTextField()
    private let exactPodMetricsGETConcurrencyField = NSTextField()
    private let logQueueRecordLimitField = NSTextField()
    private let logQueueByteLimitField = NSTextField()
    private let logSourceOpenConcurrencyField = NSTextField()
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
    private let openColumnsButton = NSButton(title: "Open in Editor", target: nil, action: nil)
    private var columnsFileTask: Task<Void, Never>?

    var onPreferencesChanged: ((AppPreferences, AppPreferencesDelta) -> Void)?

    init(
        preferencesStore: AppPreferencesStore,
        frameAutosaveName: String = "Settings"
    ) {
        self.preferencesStore = preferencesStore
        loadedPreferences = preferencesStore.current
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings — \(Product.applicationName)"
        window.minSize = NSSize(width: 640, height: 520)
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
            maximumDisplayedLogLineField, completedOperationHistoryLimitField,
            nodeShellImageField,
            metricsRefreshField,
            viewportOverscanField,
            viewReleaseGraceField,
            globalWarmViewLimitField, globalWarmObjectLimitField,
            globalWarmMemoryPercentField, authorityWarmViewLimitField,
            authorityWarmObjectLimitField, authorityWarmMemoryPercentField,
            kubernetesQPSField, kubernetesBurstField,
            idleMetricProviderLimitField, idleMetricSampleLimitField,
            exactPodMetricsEntryLimitField, exactPodMetricsSampleLimitField,
            exactPodMetricsDetailEntryLimitField,
            exactPodMetricsGETConcurrencyField, logSourceOpenConcurrencyField,
            columnsPathField,
        ] {
            field.delegate = self
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
        }
        for field in [
            logRecordLimitField, logByteLimitField, renderBatchField,
            maximumDisplayedLogLineField, completedOperationHistoryLimitField,
            metricsRefreshField,
            viewportOverscanField,
            viewReleaseGraceField,
            globalWarmViewLimitField, globalWarmObjectLimitField,
            globalWarmMemoryPercentField, authorityWarmViewLimitField,
            authorityWarmObjectLimitField, authorityWarmMemoryPercentField,
            kubernetesQPSField, kubernetesBurstField,
            idleMetricProviderLimitField, idleMetricSampleLimitField,
            exactPodMetricsEntryLimitField, exactPodMetricsSampleLimitField,
            exactPodMetricsDetailEntryLimitField,
            exactPodMetricsGETConcurrencyField, logSourceOpenConcurrencyField,
        ] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        globalWarmViewLimitField.setAccessibilityIdentifier(
            "settings.performance.globalWarmViews"
        )
        viewportOverscanField.setAccessibilityIdentifier(
            "settings.performance.viewportOverscanScreensPerSide"
        )
        viewReleaseGraceField.setAccessibilityIdentifier(
            "settings.performance.viewReleaseGraceSeconds"
        )
        globalWarmObjectLimitField.setAccessibilityIdentifier(
            "settings.performance.globalWarmObjects"
        )
        globalWarmMemoryPercentField.setAccessibilityIdentifier(
            "settings.performance.globalWarmMemoryPercent"
        )
        authorityWarmViewLimitField.setAccessibilityIdentifier(
            "settings.performance.authorityWarmViews"
        )
        authorityWarmObjectLimitField.setAccessibilityIdentifier(
            "settings.performance.authorityWarmObjects"
        )
        authorityWarmMemoryPercentField.setAccessibilityIdentifier(
            "settings.performance.authorityWarmMemoryPercent"
        )
        kubernetesQPSField.setAccessibilityIdentifier(
            "settings.performance.kubernetesQPS"
        )
        kubernetesBurstField.setAccessibilityIdentifier(
            "settings.performance.kubernetesBurst"
        )
        kubernetesListPageSizeField.setAccessibilityIdentifier(
            "settings.performance.kubernetesListPageSize"
        )
        clusterConnectionTimeoutField.setAccessibilityIdentifier(
            "settings.performance.clusterConnectionTimeoutSeconds"
        )
        kubernetesRequestTimeoutField.setAccessibilityIdentifier(
            "settings.performance.kubernetesRequestTimeoutSeconds"
        )
        idleMetricProviderLimitField.setAccessibilityIdentifier(
            "settings.performance.idleMetricProviders"
        )
        idleMetricSampleLimitField.setAccessibilityIdentifier(
            "settings.performance.idleMetricSamples"
        )
        exactPodMetricsEntryLimitField.setAccessibilityIdentifier(
            "settings.performance.exactPodMetricsEntries"
        )
        exactPodMetricsSampleLimitField.setAccessibilityIdentifier(
            "settings.performance.exactPodMetricsSamples"
        )
        exactPodMetricsDetailEntryLimitField.setAccessibilityIdentifier(
            "settings.performance.exactPodMetricsDetails"
        )
        exactPodMetricsGETConcurrencyField.setAccessibilityIdentifier(
            "settings.performance.exactPodMetricsGETConcurrency"
        )
        logSourceOpenConcurrencyField.setAccessibilityIdentifier(
            "settings.performance.logSourceOpenConcurrency"
        )
        logQueueRecordLimitField.setAccessibilityIdentifier(
            "settings.performance.logQueueRecordLimit"
        )
        logQueueByteLimitField.setAccessibilityIdentifier(
            "settings.performance.logQueueByteLimitMiB"
        )
        maximumRenderedLogTextField.setAccessibilityIdentifier(
            "settings.logs.maximumRenderedTextMiB"
        )
        maximumDisplayedLogLineField.setAccessibilityIdentifier(
            "settings.logs.maximumDisplayedLineKiB"
        )
        completedOperationHistoryLimitField.setAccessibilityIdentifier(
            "settings.diagnostics.completedOperationHistoryLimit"
        )
        defaultDeleteConcurrencyField.setAccessibilityIdentifier(
            "settings.operations.defaultDeleteConcurrency"
        )
        nodeShellImageField.setAccessibilityIdentifier(
            "settings.nodeShell.globalImage"
        )
        nodeShellImageField.lineBreakMode = .byTruncatingMiddle
        nodeShellImageField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 360
        ).isActive = true
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
                labeledRow(
                    "Rendered text",
                    control: maximumRenderedLogTextField,
                    suffix: "MiB maximum"
                ),
                labeledRow(
                    "Logical line preview",
                    control: maximumDisplayedLogLineField,
                    suffix: "KiB maximum"
                ),
            ]
        )
        let diagnosticsHelp = NSTextField(wrappingLabelWithString:
            "Active operations are always shown. Completed entries are kept only for the current cluster session; zero disables completed history."
        )
        diagnosticsHelp.textColor = .secondaryLabelColor
        diagnosticsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let diagnostics = section(
            title: "Diagnostics",
            rows: [
                labeledRow(
                    "Completed operations",
                    control: completedOperationHistoryLimitField,
                    suffix: "per cluster session"
                ),
                diagnosticsHelp,
            ]
        )

        let resourceOperations = section(
            title: "Resource Operations",
            rows: [
                labeledRow(
                    "Delete concurrency",
                    control: defaultDeleteConcurrencyField,
                    suffix: "default (1–16)"
                ),
            ]
        )

        let nodeShellHelp = NSTextField(wrappingLabelWithString:
            "S on a Node creates a temporary privileged helper Pod, enters the host namespaces, and removes the Pod when the terminal ends. Shift-S can override this image for one cluster."
        )
        nodeShellHelp.textColor = .secondaryLabelColor
        nodeShellHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let nodeShell = section(
            title: "Node Shell",
            rows: [
                labeledRow("Default image", control: nodeShellImageField),
                nodeShellHelp,
            ]
        )

        let warmCacheHelp = NSTextField(wrappingLabelWithString:
            "Warm-cache limits govern retained raw resource queries, not total engine memory. The global limits are aggregate ceilings; each cluster is also bounded independently."
        )
        warmCacheHelp.textColor = .secondaryLabelColor
        warmCacheHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let viewReleaseHelp = NSTextField(wrappingLabelWithString:
            "After the last window leaves a resource view, its LIST/WATCH pipeline remains active for this grace period. A longer grace improves quick returns but retains network and cache work longer."
        )
        viewReleaseHelp.textColor = .secondaryLabelColor
        viewReleaseHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let relaunchWarning = NSTextField(wrappingLabelWithString:
            "These engine-owned settings apply after quitting and relaunching the application. Existing cluster sessions keep their current limits."
        )
        relaunchWarning.textColor = .systemOrange
        relaunchWarning.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .medium
        )
        relaunchWarning.setAccessibilityIdentifier(
            "settings.performance.relaunchWarning"
        )
        let advancedPerformance = section(
            title: "Advanced Performance",
            rows: [
                groupHeading("Virtual list"),
                labeledRow(
                    "Overscan",
                    control: viewportOverscanField,
                    suffix: "screens per side"
                ),
                groupHeading("Resource pipelines"),
                labeledRow(
                    "View release grace",
                    control: viewReleaseGraceField,
                    suffix: "seconds"
                ),
                viewReleaseHelp,
                warmCacheHelp,
                groupHeading("Warm cache — global aggregate"),
                labeledRow("Retained queries", control: globalWarmViewLimitField),
                labeledRow("Retained objects", control: globalWarmObjectLimitField),
                labeledRow(
                    "Physical memory",
                    control: globalWarmMemoryPercentField,
                    suffix: "%"
                ),
                groupHeading("Warm cache — per cluster"),
                labeledRow("Retained queries", control: authorityWarmViewLimitField),
                labeledRow("Retained objects", control: authorityWarmObjectLimitField),
                labeledRow(
                    "Physical memory",
                    control: authorityWarmMemoryPercentField,
                    suffix: "%"
                ),
                groupHeading("Kubernetes API — aggregate per cluster"),
                labeledRow("Sustained QPS", control: kubernetesQPSField),
                labeledRow("Burst", control: kubernetesBurstField),
                labeledRow(
                    "LIST page size",
                    control: kubernetesListPageSizeField,
                    suffix: "objects"
                ),
                labeledRow(
                    "Connection timeout",
                    control: clusterConnectionTimeoutField,
                    suffix: "seconds"
                ),
                labeledRow(
                    "Request timeout",
                    control: kubernetesRequestTimeoutField,
                    suffix: "seconds"
                ),
                groupHeading("Metrics LIST cache — process-wide"),
                labeledRow(
                    "Idle providers",
                    control: idleMetricProviderLimitField
                ),
                labeledRow("Idle samples", control: idleMetricSampleLimitField),
                groupHeading("Exact PodMetrics cache — per cluster"),
                labeledRow(
                    "Result entries",
                    control: exactPodMetricsEntryLimitField
                ),
                labeledRow(
                    "Positive samples",
                    control: exactPodMetricsSampleLimitField
                ),
                labeledRow(
                    "Raw detail entries",
                    control: exactPodMetricsDetailEntryLimitField
                ),
                labeledRow(
                    "GET concurrency",
                    control: exactPodMetricsGETConcurrencyField
                ),
                groupHeading("Log engine — per stream"),
                labeledRow(
                    "Queued records",
                    control: logQueueRecordLimitField
                ),
                labeledRow(
                    "Queued data",
                    control: logQueueByteLimitField,
                    suffix: "MiB"
                ),
                groupHeading("Log engine — process-wide"),
                labeledRow(
                    "Concurrent source opens",
                    control: logSourceOpenConcurrencyField
                ),
                relaunchWarning,
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

        openColumnsButton.target = self
        openColumnsButton.action = #selector(openColumnsInEditor)
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

        let contentStack = NSStackView(views: [
            general, logs, diagnostics, resourceOperations, nodeShell, advancedPerformance,
            confirmations, columns, shortcuts,
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for section in [
            general, logs, diagnostics, resourceOperations, nodeShell, advancedPerformance,
            confirmations, columns, shortcuts,
        ] {
            section.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        }

        let documentView = FlippedSettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
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
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor
            ),
            documentView.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor
            ),
            documentView.widthAnchor.constraint(
                equalTo: scrollView.contentView.widthAnchor
            ),
        ])

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

    private func groupHeading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func install(_ preferences: AppPreferences) {
        appearanceButton.selectItem(at: AppearancePreference.allCases.firstIndex(of: preferences.appearance) ?? 0)
        namespaceButton.selectItem(at: DefaultNamespacePreference.allCases.firstIndex(of: preferences.defaultNamespace) ?? 0)
        logRecordLimitField.integerValue = preferences.logs.recordLimit
        logByteLimitField.integerValue = preferences.logs.byteLimit / (1 << 20)
        renderBatchField.integerValue = preferences.logs.renderBatchMilliseconds
        maximumRenderedLogTextField.integerValue =
            preferences.logs.maximumRenderedUTF8Bytes / (1 << 20)
        maximumDisplayedLogLineField.integerValue =
            preferences.logs.maximumDisplayedLineUTF8Bytes / (1 << 10)
        completedOperationHistoryLimitField.integerValue =
            preferences.diagnostics.completedOperationHistoryLimit
        defaultDeleteConcurrencyField.integerValue =
            preferences.resourceOperations.defaultDeleteConcurrency
        nodeShellImageField.stringValue = preferences.nodeShell.globalImage
        metricsRefreshField.integerValue = preferences.metricsRefreshSeconds
        viewportOverscanField.integerValue =
            preferences.advancedPerformance.viewportOverscanScreensPerSide
        viewReleaseGraceField.integerValue =
            preferences.advancedPerformance.viewReleaseGraceSeconds
        globalWarmViewLimitField.integerValue =
            preferences.advancedPerformance.globalWarmCacheViewLimit
        globalWarmObjectLimitField.integerValue =
            preferences.advancedPerformance.globalWarmCacheObjectLimit
        globalWarmMemoryPercentField.integerValue =
            preferences.advancedPerformance.globalWarmCacheMemoryPercent
        authorityWarmViewLimitField.integerValue =
            preferences.advancedPerformance.authorityWarmCacheViewLimit
        authorityWarmObjectLimitField.integerValue =
            preferences.advancedPerformance.authorityWarmCacheObjectLimit
        authorityWarmMemoryPercentField.integerValue =
            preferences.advancedPerformance.authorityWarmCacheMemoryPercent
        kubernetesQPSField.doubleValue =
            preferences.advancedPerformance.kubernetesQPS
        kubernetesBurstField.integerValue =
            preferences.advancedPerformance.kubernetesBurst
        kubernetesListPageSizeField.integerValue =
            preferences.advancedPerformance.kubernetesListPageSize
        clusterConnectionTimeoutField.integerValue =
            preferences.advancedPerformance.clusterConnectionTimeoutSeconds
        kubernetesRequestTimeoutField.integerValue =
            preferences.advancedPerformance.kubernetesRequestTimeoutSeconds
        idleMetricProviderLimitField.integerValue =
            preferences.advancedPerformance.idleMetricProviderLimit
        idleMetricSampleLimitField.integerValue =
            preferences.advancedPerformance.idleMetricSampleLimit
        exactPodMetricsEntryLimitField.integerValue =
            preferences.advancedPerformance.exactPodMetricsEntryLimit
        exactPodMetricsSampleLimitField.integerValue =
            preferences.advancedPerformance.exactPodMetricsSampleLimit
        exactPodMetricsDetailEntryLimitField.integerValue =
            preferences.advancedPerformance.exactPodMetricsDetailEntryLimit
        exactPodMetricsGETConcurrencyField.integerValue =
            preferences.advancedPerformance.exactPodMetricsGETConcurrency
        logQueueRecordLimitField.integerValue =
            preferences.advancedPerformance.logQueueRecordLimit
        logQueueByteLimitField.integerValue =
            preferences.advancedPerformance.logQueueByteLimit / (1 << 20)
        logSourceOpenConcurrencyField.integerValue =
            preferences.advancedPerformance.logSourceOpenConcurrency
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
        let byteLimit = parsedScaledInteger(logByteLimitField, multiplier: 1 << 20)
        let maximumRenderedUTF8Bytes = parsedScaledInteger(
            maximumRenderedLogTextField,
            multiplier: 1 << 20
        )
        let maximumDisplayedLineUTF8Bytes = parsedScaledInteger(
            maximumDisplayedLogLineField,
            multiplier: 1 << 10
        )
        return AppPreferences(
            appearance: AppearancePreference.allCases[safe: appearanceIndex] ?? .system,
            logs: LogDisplayPreferences(
                recordLimit: parsedInteger(logRecordLimitField),
                byteLimit: byteLimit,
                renderBatchMilliseconds: parsedInteger(renderBatchField),
                maximumRenderedUTF8Bytes: maximumRenderedUTF8Bytes,
                maximumDisplayedLineUTF8Bytes: maximumDisplayedLineUTF8Bytes
            ),
            metricsRefreshSeconds: parsedInteger(metricsRefreshField),
            defaultNamespace: DefaultNamespacePreference.allCases[safe: namespaceIndex] ?? .contextDefault,
            restoreOpenClusterWindows: restoreWindowsButton.state == .on,
            confirmations: ConfirmationPreferences(
                confirmWorkloadRestart: confirmRestartButton.state == .on,
                confirmScaling: confirmScaleButton.state == .on
            ),
            resourceOperations: ResourceOperationPreferences(
                defaultDeleteConcurrency: parsedInteger(defaultDeleteConcurrencyField)
            ),
            columnsConfigurationPath: columnsPathField.stringValue,
            diagnostics: DiagnosticsPreferences(
                completedOperationHistoryLimit: parsedInteger(
                    completedOperationHistoryLimitField
                )
            ),
            nodeShell: NodeShellPreferences(
                globalImage: nodeShellImageField.stringValue,
                clusterImagesByContextReference: preferencesStore.current.nodeShell
                    .clusterImagesByContextReference
            ),
            advancedPerformance: AdvancedPerformancePreferences(
                viewportOverscanScreensPerSide: parsedInteger(
                    viewportOverscanField
                ),
                viewReleaseGraceSeconds: parsedInteger(viewReleaseGraceField),
                globalWarmCacheViewLimit: parsedInteger(globalWarmViewLimitField),
                globalWarmCacheObjectLimit: parsedInteger(globalWarmObjectLimitField),
                globalWarmCacheMemoryPercent: parsedInteger(
                    globalWarmMemoryPercentField
                ),
                authorityWarmCacheViewLimit: parsedInteger(
                    authorityWarmViewLimitField
                ),
                authorityWarmCacheObjectLimit: parsedInteger(
                    authorityWarmObjectLimitField
                ),
                authorityWarmCacheMemoryPercent: parsedInteger(
                    authorityWarmMemoryPercentField
                ),
                kubernetesQPS: parsedDouble(kubernetesQPSField),
                kubernetesBurst: parsedInteger(kubernetesBurstField),
                kubernetesListPageSize: parsedInteger(kubernetesListPageSizeField),
                clusterConnectionTimeoutSeconds: parsedInteger(
                    clusterConnectionTimeoutField
                ),
                kubernetesRequestTimeoutSeconds: parsedInteger(
                    kubernetesRequestTimeoutField
                ),
                idleMetricProviderLimit: parsedInteger(
                    idleMetricProviderLimitField
                ),
                idleMetricSampleLimit: parsedInteger(idleMetricSampleLimitField),
                exactPodMetricsEntryLimit: parsedInteger(
                    exactPodMetricsEntryLimitField
                ),
                exactPodMetricsSampleLimit: parsedInteger(
                    exactPodMetricsSampleLimitField
                ),
                exactPodMetricsDetailEntryLimit: parsedInteger(
                    exactPodMetricsDetailEntryLimitField
                ),
                exactPodMetricsGETConcurrency: parsedInteger(
                    exactPodMetricsGETConcurrencyField
                ),
                logQueueRecordLimit: parsedInteger(logQueueRecordLimitField),
                logQueueByteLimit: parsedScaledInteger(
                    logQueueByteLimitField,
                    multiplier: 1 << 20
                ),
                logSourceOpenConcurrency: parsedInteger(
                    logSourceOpenConcurrencyField
                )
            )
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

    private func parsedScaledInteger(_ field: NSTextField, multiplier: Int) -> Int {
        let value = parsedInteger(field)
        guard value > 0 else { return 0 }
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? 0 : result.partialValue
    }

    private func parsedDouble(_ field: NSTextField) -> Double {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(value) { return number }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = true
        formatter.isLenient = false
        return formatter.number(from: value)?.doubleValue ?? .nan
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
        guard columnsFileTask == nil else { return }
        let store = ColumnConfigurationFileStore(path: columnsPathField.stringValue)
        showStatus("Preparing column configuration…", error: false)
        openColumnsButton.isEnabled = false
        columnsFileTask = Task { [weak self] in
            defer {
                self?.columnsFileTask = nil
                self?.openColumnsButton.isEnabled = true
            }
            do {
                let url = try await store.ensureFileExistsOffMain()
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(url) else {
                    throw ColumnConfigurationFileIssue("No application could open \(url.path).")
                }
                self?.showStatus("Opened \(url.lastPathComponent) in the default editor.", error: false)
            } catch is CancellationError {
                return
            } catch {
                self?.showStatus(error.localizedDescription, error: true)
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
