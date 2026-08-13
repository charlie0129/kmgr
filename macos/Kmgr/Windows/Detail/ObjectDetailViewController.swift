import AppKit
import KmgrCore

/// A fresh, UID-authoritative detail surface. It replaces the table area in a
/// workspace; no inspector or bottom drawer is introduced.
@MainActor
final class ObjectDetailViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate
{
    let identity: ResourceIdentity
    private let provider: any ObjectDetailProviding
    private let segmented = NSSegmentedControl(
        labels: ["Summary", "YAML", "Data"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private let contentContainer = NSView()
    private let summaryStack = NSStackView()
    private let yamlTextView = NSTextView()
    private let yamlScrollView = NSScrollView()
    private let yamlContainerView = NSView()
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let dataSplitView = NSSplitView()
    private let keysTable = NSTableView()
    private let dataValueTextView = NSTextView()
    private let dataValueScroll = NSScrollView()
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)

    private var detail: ObjectDetail?
    private var objectData: ObjectData?
    private var selectedDataEntry: ObjectDataEntry?
    private var originalYAML = Data()
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var secretRevealed = false
    private var isEditingYAML = false

    var onBack: (() -> Void)?

    init(identity: ResourceIdentity, provider: any ObjectDetailProviding) {
        self.identity = identity
        self.provider = provider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        operationTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        let backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            target: self,
            action: #selector(backPressed)
        )
        backButton.bezelStyle = .texturedRounded
        let breadcrumb = NSTextField(labelWithString: breadcrumbText)
        breadcrumb.font = .systemFont(ofSize: 15, weight: .semibold)
        breadcrumb.lineBreakMode = .byTruncatingMiddle
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(tabChanged)
        if !supportsDataEditor { segmented.setEnabled(false, forSegment: 2) }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [backButton, breadcrumb, NSView(), segmented, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        configureSummary()
        configureYAML()
        configureDataEditor()
        view = root
        show(summaryStack)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadObject()
    }

    func stop() {
        loadTask?.cancel()
        operationTask?.cancel()
    }

    private var breadcrumbText: String {
        let scope = identity.namespace.isEmpty ? "" : " · \(identity.namespace)"
        return "\(identity.resource)\(scope) · \(identity.name)"
    }

    private var supportsDataEditor: Bool {
        identity.group.isEmpty && identity.version == "v1"
            && (identity.resource == "configmaps" || identity.resource == "secrets")
    }

    private func configureSummary() {
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 7
        summaryStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
    }

    private func configureYAML() {
        yamlTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        yamlTextView.isRichText = false
        yamlTextView.isEditable = false
        yamlTextView.isSelectable = true
        yamlTextView.usesFindBar = true
        yamlTextView.isAutomaticQuoteSubstitutionEnabled = false
        yamlTextView.isAutomaticDashSubstitutionEnabled = false
        yamlTextView.allowsUndo = true
        yamlTextView.delegate = self
        yamlTextView.textContainerInset = NSSize(width: 10, height: 10)
        yamlScrollView.documentView = yamlTextView
        yamlScrollView.hasVerticalScroller = true
        yamlScrollView.hasHorizontalScroller = true

        editButton.target = self
        editButton.action = #selector(beginYAMLEdit)
        saveButton.target = self
        saveButton.action = #selector(saveYAML)
        cancelButton.target = self
        cancelButton.action = #selector(cancelYAMLEdit)
        saveButton.isHidden = true
        cancelButton.isHidden = true
        let controls = NSStackView(views: [editButton, saveButton, cancelButton, NSView()])
        controls.orientation = .horizontal
        controls.translatesAutoresizingMaskIntoConstraints = false
        yamlScrollView.translatesAutoresizingMaskIntoConstraints = false
        yamlContainerView.addSubview(controls)
        yamlContainerView.addSubview(yamlScrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: yamlContainerView.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: yamlContainerView.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: yamlContainerView.topAnchor, constant: 6),
            yamlScrollView.leadingAnchor.constraint(equalTo: yamlContainerView.leadingAnchor),
            yamlScrollView.trailingAnchor.constraint(equalTo: yamlContainerView.trailingAnchor),
            yamlScrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            yamlScrollView.bottomAnchor.constraint(equalTo: yamlContainerView.bottomAnchor),
        ])
    }

    private func configureDataEditor() {
        dataSplitView.isVertical = true
        dataSplitView.dividerStyle = .thin
        let column = NSTableColumn(identifier: .init("key"))
        column.title = "Key"
        column.width = 240
        keysTable.addTableColumn(column)
        keysTable.delegate = self
        keysTable.dataSource = self
        keysTable.headerView = nil
        keysTable.usesAlternatingRowBackgroundColors = true
        let keyScroll = NSScrollView()
        keyScroll.documentView = keysTable
        keyScroll.hasVerticalScroller = true
        keyScroll.frame = NSRect(x: 0, y: 0, width: 260, height: 500)

        dataValueTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        dataValueTextView.isRichText = false
        dataValueTextView.isEditable = false
        dataValueTextView.isSelectable = true
        dataValueTextView.allowsUndo = true
        dataValueScroll.documentView = dataValueTextView
        dataValueScroll.hasVerticalScroller = true
        revealButton.target = self
        revealButton.action = #selector(toggleSecretReveal)
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveCurrentKey)
        saveKeyButton.isEnabled = false
        let controls = NSStackView(views: [revealButton, saveKeyButton, NSView()])
        controls.orientation = .horizontal
        let editor = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        dataValueScroll.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(controls)
        editor.addSubview(dataValueScroll)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: editor.topAnchor, constant: 7),
            dataValueScroll.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            dataValueScroll.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            dataValueScroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            dataValueScroll.bottomAnchor.constraint(equalTo: editor.bottomAnchor),
        ])
        dataSplitView.addArrangedSubview(keyScroll)
        dataSplitView.addArrangedSubview(editor)
        dataSplitView.setPosition(260, ofDividerAt: 0)
    }

    private func loadObject() {
        guard loadTask == nil else { return }
        statusLabel.stringValue = "Loading…"
        statusLabel.textColor = .secondaryLabelColor
        loadTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            do {
                async let fetchedDetail = provider.getObject(identity: identity)
                if supportsDataEditor {
                    async let fetchedData = provider.getData(identity: identity)
                    let (detail, data) = try await (fetchedDetail, fetchedData)
                    install(detail: detail, data: data)
                } else {
                    install(detail: try await fetchedDetail, data: nil)
                }
            } catch {
                show(error: error)
            }
            loadTask = nil
        }
    }

    private func install(detail: ObjectDetail, data: ObjectData?) {
        self.detail = detail
        objectData = data
        originalYAML = detail.yamlUTF8
        yamlTextView.string = String(decoding: detail.yamlUTF8, as: UTF8.self)
        summaryStack.arrangedSubviews.forEach { view in
            summaryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var lastSection = ""
        for field in detail.summaryFields {
            if field.sectionID != lastSection {
                let heading = NSTextField(labelWithString: field.sectionID.capitalized)
                heading.font = .systemFont(ofSize: 13, weight: .semibold)
                summaryStack.addArrangedSubview(heading)
                lastSection = field.sectionID
            }
            let label = NSTextField(labelWithString: "\(field.label):  \(field.displayText)")
            label.toolTip = field.tooltip
            label.textColor = field.severity == .critical ? .systemRed : .labelColor
            summaryStack.addArrangedSubview(label)
        }
        keysTable.reloadData()
        statusLabel.stringValue = "Resource version \(detail.resourceVersion)"
        statusLabel.textColor = .secondaryLabelColor
        if supportsDataEditor {
            segmented.selectedSegment = 2
            tabChanged()
        }
    }

    @objc private func tabChanged() {
        switch segmented.selectedSegment {
        case 1:
            show(yamlContainerView)
        case 2 where supportsDataEditor:
            show(dataSplitView)
        default:
            show(summaryStack)
        }
    }

    private func show(_ child: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    @objc private func beginYAMLEdit() {
        isEditingYAML = true
        yamlTextView.isEditable = true
        editButton.isHidden = true
        saveButton.isHidden = false
        cancelButton.isHidden = false
        view.window?.makeFirstResponder(yamlTextView)
    }

    @objc private func cancelYAMLEdit() {
        yamlTextView.string = String(decoding: originalYAML, as: UTF8.self)
        finishYAMLEdit()
    }

    @objc private func saveYAML() {
        guard let detail else { return }
        let edited = Data(yamlTextView.string.utf8)
        operationTask?.cancel()
        statusLabel.stringValue = "Validating…"
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            do {
                let prepared = try await provider.prepareYAML(
                    identity: identity,
                    yamlUTF8: edited,
                    expectedResourceVersion: detail.resourceVersion,
                    forceFieldOwnership: false
                )
                guard confirm(diff: prepared.diff) else {
                    statusLabel.stringValue = "Save cancelled"
                    return
                }
                let stream = try await provider.applyYAML(
                    identity: identity,
                    yamlUTF8: prepared.normalizedYAMLUTF8,
                    expectedResourceVersion: detail.resourceVersion,
                    forceFieldOwnership: false
                )
                for try await progress in stream {
                    statusLabel.stringValue = "Saving… \(progress.completedItems)/\(progress.totalItems)"
                    if progress.state.isTerminal {
                        if progress.state == .succeeded {
                            originalYAML = prepared.normalizedYAMLUTF8
                            finishYAMLEdit()
                            loadTask?.cancel()
                            loadTask = nil
                            loadObject()
                        } else {
                            throw progress.issue ?? ClusterManagerIssue(
                                category: .conflict,
                                reason: "YAMLApplyFailed",
                                message: "The YAML edit was not applied. Your local edit is still open.",
                                operation: "apply YAML"
                            )
                        }
                    }
                }
            } catch {
                // Preserve the local editor buffer on conflict or validation error.
                show(error: error)
            }
        }
    }

    private func confirm(diff: [SemanticDiffEntry]) -> Bool {
        guard !diff.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Apply \(diff.count) YAML change\(diff.count == 1 ? "" : "s")?"
        alert.informativeText = diff.prefix(12).map {
            "\($0.path): \($0.beforeSummary) → \($0.afterSummary)"
        }.joined(separator: "\n")
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func finishYAMLEdit() {
        isEditingYAML = false
        yamlTextView.isEditable = false
        editButton.isHidden = false
        saveButton.isHidden = true
        cancelButton.isHidden = true
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditingYAML {
            cancelYAMLEdit()
        } else {
            onBack?()
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if isEditingYAML {
            saveYAML()
        } else if saveKeyButton.isEnabled {
            saveCurrentKey()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { objectData?.entries.count ?? 0 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let entries = objectData?.entries, entries.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let entry = entries[row]
        let label = NSTextField(labelWithString: "\(entry.id)   \(entry.kind.rawValue) · \(entry.byteSize) B")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let data = objectData, data.entries.indices.contains(keysTable.selectedRow) else {
            selectedDataEntry = nil
            dataValueTextView.string = ""
            return
        }
        selectedDataEntry = data.entries[keysTable.selectedRow]
        secretRevealed = !data.secret
        revealButton.isHidden = !data.secret
        revealButton.title = "Reveal"
        displaySelectedData()
    }

    @objc private func toggleSecretReveal() {
        secretRevealed.toggle()
        revealButton.title = secretRevealed ? "Conceal" : "Reveal"
        displaySelectedData()
    }

    private func displaySelectedData() {
        guard let data = objectData, let entry = selectedDataEntry else { return }
        if data.secret && !secretRevealed {
            dataValueTextView.string = "Secret value concealed · \(entry.byteSize) bytes"
            dataValueTextView.isEditable = false
            saveKeyButton.isEnabled = false
            return
        }
        var bytes = Data()
        entry.value.withUnsafeBytes { bytes.append(contentsOf: $0) }
        if entry.kind == .text, let text = String(data: bytes, encoding: .utf8) {
            dataValueTextView.string = text
            dataValueTextView.isEditable = true
            saveKeyButton.isEnabled = true
        } else {
            dataValueTextView.string = "Binary value · \(entry.byteSize) bytes"
            dataValueTextView.isEditable = false
            saveKeyButton.isEnabled = false
        }
        bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
    }

    @objc private func saveCurrentKey() {
        guard let data = objectData, let entry = selectedDataEntry else { return }
        let localValue = Data(dataValueTextView.string.utf8)
        operationTask?.cancel()
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            do {
                let stream = try await provider.updateData(
                    identity: identity,
                    expectedResourceVersion: data.resourceVersion,
                    mutations: [.set(
                        key: entry.id,
                        kind: entry.kind,
                        value: localValue,
                        expectedContentHash: entry.contentHash
                    )]
                )
                for try await progress in stream where progress.state.isTerminal {
                    if progress.state != .succeeded {
                        throw progress.issue ?? ClusterManagerIssue(
                            category: .conflict,
                            reason: "DataUpdateFailed",
                            message: "The key was not saved. Your local value remains in the editor.",
                            operation: "update key/value data"
                        )
                    }
                    statusLabel.stringValue = "Saved \(entry.id)"
                    loadTask?.cancel()
                    loadTask = nil
                    loadObject()
                }
            } catch {
                show(error: error)
            }
        }
    }

    private func show(error: Error) {
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .systemRed
    }

    @objc private func backPressed() { onBack?() }
}
