import AppKit
import Dispatch
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Object Data editor drafts", .serialized)
struct ObjectDetailDataDraftTests {
    @Test("Data text search bounds queries and returns context around full-value matches")
    func boundedDataTextSearch() throws {
        let oversized = String(repeating: "界", count: 2_000)
        let query = ObjectDataTextSearch.normalizedQuery(oversized)
        #expect(query.count == ObjectDataTextSearch.maximumQueryCharacters)
        #expect(query.utf8.count <= ObjectDataTextSearch.maximumQueryUTF8Bytes)

        let text = String(repeating: "before ", count: 80)
            + "deep-marker\nnext line"
            + String(repeating: " after", count: 80)
        let match = try #require(ObjectDataTextSearch.match(
            in: Data(text.utf8),
            query: "DEEP-MARKER"
        ))
        #expect(match.snippet.contains("deep-marker"))
        #expect(match.snippet.contains("next line"))
        #expect(match.snippet.hasPrefix("…"))
        #expect(match.snippet.hasSuffix("…"))
        #expect(match.snippet.count <= DataValuePreviewPresentation.maximumTextCharacterCount)
        #expect(ObjectDataTextSearch.match(
            in: Data([0xff, 0x00, 0x41]),
            query: "A"
        ) == nil)
    }

    @Test("draft store keeps independent text and binary values in memory")
    func independentTextAndBinaryDrafts() throws {
        let store = DataEditorDraftStore()
        let binary = Data([0x00, 0xff, 0x10, 0x80])
        let originalBinary = Data([0x01, 0x02])
        let binaryHash = Data(repeating: 7, count: 32)
        store.update(
            key: "archive",
            kind: .binary,
            value: binary,
            storedKind: .binary,
            valueMatchesStored: false,
            storedContentHash: binaryHash
        )
        store.update(
            key: "config",
            kind: .binary,
            value: Data("plain text bytes".utf8),
            storedKind: .text,
            valueMatchesStored: true,
            storedContentHash: Data(repeating: 3, count: 32)
        )

        var binaryDraft = try #require(store.snapshot(for: "archive"))
        defer {
            binaryDraft.value.resetBytes(
                in: binaryDraft.value.startIndex..<binaryDraft.value.endIndex
            )
        }
        #expect(binaryDraft.kind == .binary)
        #expect(binaryDraft.value == binary)
        #expect(binaryDraft.expectedContentHash == binaryHash)
        #expect(store.metadata(for: "archive")?.kind == .binary)
        #expect(store.metadata(for: "archive")?.byteCount == 4)

        let kindOnlyDraft = try #require(store.snapshot(for: "config"))
        #expect(kindOnlyDraft.kind == .binary)
        #expect(kindOnlyDraft.value == Data("plain text bytes".utf8))

        store.update(
            key: "archive",
            kind: .binary,
            value: originalBinary,
            storedKind: .binary,
            valueMatchesStored: true,
            storedContentHash: binaryHash
        )
        #expect(store.snapshot(for: "archive") == nil)
        #expect(store.snapshot(for: "config") != nil)
        store.removeAll()
        #expect(store.isEmpty)
    }

    @Test("ConfigMap Value column previews stored and unsaved decoded text")
    func configMapValueColumnUsesCurrentDraft() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        try await waitForDataRows(table, count: 2)

        #expect(table.selectedRow == 0)
        #expect(editor.string == "server-alpha")
        #expect(try valueText(in: table, row: 0) == "server-alpha")
        #expect(try valueAccessibility(in: table, row: 0) == "Text value: server-alpha")
        select(row: 0, in: table, controller: controller)
        editor.string = "draft\nalpha"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(try valueText(in: table, row: 0) == "draft alpha")
        #expect(try valueAccessibility(in: table, row: 0) == "Text value: draft alpha")

        select(row: 1, in: table, controller: controller)
        #expect(try valueText(in: table, row: 0) == "draft alpha")
    }

    @Test("Value column safely labels binary bytes and truncates long text")
    func binaryAndTruncatedValueColumnPreviews() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let longText = String(
            repeating: "v",
            count: DataValuePreviewPresentation.maximumTextCharacterCount + 40
        )
        let binaryBytes = Data("must-not-render-as-text".utf8)
        let data = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-1",
            entries: [
                ObjectDataEntry(
                    key: "long",
                    kind: .text,
                    value: Data(longText.utf8),
                    byteSize: UInt64(longText.utf8.count),
                    contentHash: Data(repeating: 3, count: 32)
                ),
                ObjectDataEntry(
                    key: "archive",
                    kind: .binary,
                    value: binaryBytes,
                    byteSize: UInt64(binaryBytes.count),
                    contentHash: Data(repeating: 4, count: 32)
                ),
            ],
            secret: false
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: data),
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        try await waitForDataRows(table, count: 2)

        let truncated = try valueText(in: table, row: 0)
        #expect(truncated.count == DataValuePreviewPresentation.maximumTextCharacterCount)
        #expect(truncated.hasSuffix("…"))
        #expect(truncated != longText)
        #expect(try valueAccessibility(in: table, row: 0).contains("truncated preview"))

        let binary = try valueText(in: table, row: 1)
        #expect(binary.hasPrefix("6D 75 73 74"))
        #expect(binary.contains("|must-not-render-…|"))
        #expect(binary.hasSuffix("· \(binaryBytes.count) bytes"))
        #expect(try valueAccessibility(in: table, row: 1) == "Binary value: \(binary)")
    }

    @Test("Data master-detail keeps every key visible and its divider adjustable")
    func multiKeyMasterDetailLayout() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.viewDidAppear()
        defer {
            controller.stop()
            window.contentViewController = nil
            window.close()
        }

        let table = try dataKeysTable(in: controller.view)
        try await waitForDataRows(table, count: 2)
        controller.view.layoutSubtreeIfNeeded()
        let split = try #require(draftDescendants(of: controller.view)
            .compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "object-data-split" })
        #expect(split.arrangedSubviews.count == 2)
        #expect(split.arrangedSubviews[0].frame.width > 100)
        #expect(split.arrangedSubviews[1].frame.width > 100)
        #expect(try row(forKey: "alpha", in: table) >= 0)
        #expect(try row(forKey: "beta", in: table) >= 0)

        let available = split.bounds.width - split.dividerThickness
        split.setPosition(available * 0.40, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let narrowerTableWidth = split.arrangedSubviews[0].frame.width
        split.setPosition(available * 0.55, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(split.arrangedSubviews[0].frame.width > narrowerTableWidth + 20)

        split.setPosition(1, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(split.arrangedSubviews[0].frame.width > 100)
        #expect(split.arrangedSubviews[1].frame.width > 100)

        let selectedKey = try #require(draftDescendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Selected data key" })
        #expect(selectedKey.stringValue == "alpha")
    }

    @Test("ConfigMap search matches complete keys, values, and current drafts")
    func configMapKeyValueSearch() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let longValue = String(repeating: "prefix-", count: 40)
            + "deep-marker\nsecond line"
        let data = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-1",
            entries: [
                dataEntry(key: "alpha", value: longValue, hashByte: 1),
                dataEntry(key: "beta", value: "ordinary", hashByte: 2),
                dataEntry(key: "marker-key", value: "other", hashByte: 3),
            ],
            secret: false
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: data)
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let search = try dataSearchField(in: controller.view)
        try await waitForDataRows(table, count: 3)

        applyDataSearch("DEEP-MARKER", field: search)
        try await waitForDataRows(table, count: 1)
        #expect(try row(forKey: "alpha", in: table) == 0)
        #expect(try valueText(in: table, row: 0).contains("deep-marker"))
        #expect(try valueAccessibility(in: table, row: 0).hasPrefix("Value match:"))
        #expect(editor.string == longValue)
        editor.string = "edited while filtered"
        controller.textDidChange(Notification(
            name: NSText.didChangeNotification,
            object: editor
        ))
        #expect(table.numberOfRows == 1)
        #expect(editor.string == "edited while filtered")

        applyDataSearch("marker-key", field: search)
        try await waitForDataRows(table, count: 1)
        #expect(try row(forKey: "marker-key", in: table) == 0)

        applyDataSearch("", field: search)
        try await waitForDataRows(table, count: 3)
        select(row: try row(forKey: "alpha", in: table), in: table, controller: controller)
        editor.string = "draft-only-marker"
        controller.textDidChange(Notification(
            name: NSText.didChangeNotification,
            object: editor
        ))
        applyDataSearch("draft-only", field: search)
        try await waitForDataRows(table, count: 1)
        #expect(try row(forKey: "alpha", in: table) == 0)
        #expect(try valueText(in: table, row: 0) == "draft-only-marker")
    }

    @Test("Secret search requires reveal authority and never presents base64")
    func secretValueSearchRevealBoundary() async throws {
        let fixture = detailFixture(resource: "secrets", secret: true)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data)
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let search = try dataSearchField(in: controller.view)
        let reveal = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Show decoded values" })
        try await waitForDataRows(table, count: 2)

        applyDataSearch("server-alpha", field: search)
        try await waitForDataRows(table, count: 0)
        reveal.performClick(nil)
        try await waitForDataRows(table, count: 1)
        let revealed = try valueText(in: table, row: 0)
        #expect(revealed.contains("server-alpha"))
        #expect(!revealed.contains(Data("server-alpha".utf8).base64EncodedString()))

        reveal.performClick(nil)
        try await waitForDataRows(table, count: 2)
        #expect(search.stringValue.isEmpty)
        #expect(try valueText(in: table, row: 0).hasPrefix("Secret concealed"))

        applyDataSearch("beta", field: search)
        try await waitForDataRows(table, count: 1)
        #expect(try row(forKey: "beta", in: table) == 0)
        #expect(try valueText(in: table, row: 0).hasPrefix("Secret concealed"))
    }

    @Test("slash and Command-F focus Data search from the key table")
    func dataSearchKeyboardFocus() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data)
        )
        let window = NSWindow(contentViewController: controller)
        controller.viewDidAppear()
        defer {
            controller.stop()
            window.contentViewController = nil
            window.close()
        }

        let table = try dataKeysTable(in: controller.view)
        let search = try dataSearchField(in: controller.view)
        try await waitForDataRows(table, count: 2)
        #expect(window.makeFirstResponder(table))

        table.keyDown(with: try dataKeyEvent("/"))
        #expect(search.currentEditor() != nil)

        #expect(window.makeFirstResponder(table))
        table.keyDown(with: try dataKeyEvent("f", modifiers: .command))
        #expect(search.currentEditor() != nil)
    }

    @Test("ConfigMap text drafts survive key switches")
    func configMapDraftSurvivesKeySwitch() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let rename = try #require(dataButtons(in: controller.view).first { $0.title == "Rename" })
        try await waitForDataRows(table, count: 2)

        select(row: 0, in: table, controller: controller)
        #expect(editor.string == "server-alpha")
        editor.string = "draft-alpha"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(!rename.isEnabled)

        select(row: 1, in: table, controller: controller)
        #expect(editor.string == "server-beta")
        #expect(try stateText(in: table, row: 0) == "Unsaved")

        editor.string = "draft-beta"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        select(row: 0, in: table, controller: controller)
        #expect(editor.string == "draft-alpha")
        #expect(try stateText(in: table, row: 1) == "Unsaved")
        #expect(!rename.isEnabled)
    }

    @Test("Secret drafts survive conceal, reveal, and key switches without previews")
    func secretDraftSurvivesConcealAndKeySwitch() async throws {
        let fixture = detailFixture(resource: "secrets", secret: true)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let reveal = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Show decoded values" })
        let save = try #require(dataButtons(in: controller.view).first { $0.title == "Save Key" })
        try await waitForDataRows(table, count: 2)

        select(row: 0, in: table, controller: controller)
        #expect(!editor.string.contains("server-alpha"))
        #expect(!editor.isEditable)
        #expect(try valueText(in: table, row: 0) == "Secret concealed · 12 bytes")
        #expect(!(try valueAccessibility(in: table, row: 0)).contains("server-alpha"))

        reveal.performClick(nil)
        #expect(reveal.state == .on)
        #expect(editor.string == "server-alpha")
        #expect(try valueText(in: table, row: 0) == "server-alpha")
        editor.string = "draft-secret-alpha"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(save.isEnabled)
        try await waitForCondition {
            (try? valueText(in: table, row: 0)) == "draft-secret-alpha"
        }

        reveal.performClick(nil)
        #expect(reveal.state == .off)
        #expect(!editor.string.contains("draft-secret-alpha"))
        #expect(!editor.isEditable)
        #expect(!save.isEnabled)
        #expect(try stateText(in: table, row: 0) == "Unsaved")
        #expect(!(try valueText(in: table, row: 0)).contains("draft-secret-alpha"))
        #expect(!(try valueAccessibility(in: table, row: 0)).contains("draft-secret-alpha"))

        reveal.performClick(nil)
        #expect(editor.string == "draft-secret-alpha")
        select(row: 1, in: table, controller: controller)
        #expect(reveal.state == .on)
        #expect(editor.string == "server-beta")
        #expect(!editor.string.contains("draft-secret-alpha"))
        select(row: 0, in: table, controller: controller)
        #expect(editor.string == "draft-secret-alpha")
        #expect(try valueText(in: table, row: 0) == "draft-secret-alpha")
    }

    @Test("binary Secret drafts survive conceal and key switches")
    func binarySecretDraftSurvivesConcealAndKeySwitch() async throws {
        let fixture = detailFixture(resource: "secrets", secret: true)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let reveal = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Show decoded values" })
        try await waitForDataRows(table, count: 2)

        select(row: 0, in: table, controller: controller)
        reveal.performClick(nil)
        controller.replaceSelectedDataWithImportedBytes(Data([0x00, 0xff, 0x10, 0x80]))
        #expect(editor.string.contains("00000000"))
        #expect(editor.string.contains("00 FF 10 80"))
        #expect(editor.string.contains("|....|"))
        #expect(!editor.isEditable)
        #expect(try stateText(in: table, row: 0) == "Unsaved")

        reveal.performClick(nil)
        #expect(editor.string == "Secret value concealed · 4 bytes")
        reveal.performClick(nil)
        #expect(editor.string.contains("00 FF 10 80"))

        select(row: 1, in: table, controller: controller)
        select(row: 0, in: table, controller: controller)
        #expect(reveal.state == .on)
        #expect(editor.string.contains("00 FF 10 80"))
    }

    @Test("plain D toggles Secret reveal from the key table but edits inside the value editor")
    func secretRevealKeyboardScope() async throws {
        let fixture = detailFixture(resource: "secrets", secret: true)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data)
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let reveal = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Show decoded values" })
        try await waitForDataRows(table, count: 2)

        table.keyDown(with: try dataKeyEvent("d"))
        #expect(reveal.state == .on)
        #expect(editor.string == "server-alpha")

        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("d", replacementRange: editor.selectedRange())
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(reveal.state == .on)
        #expect(editor.string == "server-alphad")
        #expect(try stateText(in: table, row: 0) == "Unsaved")
    }

    @Test("initial Data errors are structured and retry the same UID-pinned request")
    func initialDataErrorCanRetry() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let provider = SequencedDataObjectDetailProvider(responses: [
            .failure(ClusterManagerIssue(
                category: .unavailable,
                reason: "DataUnavailable",
                message: "The Data request failed.",
                operation: "load key/value data"
            )),
            .data(fixture.data),
        ])
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: provider
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let retry = try #require(dataButtons(in: controller.view).first { $0.title == "Retry" })
        try await waitForCondition { !retry.isHidden }
        #expect(controller.workspaceStatus.text.contains("Data request failed"))
        #expect(controller.workspaceStatus.toolTip?.contains("DataUnavailable") == true)
        #expect(table.numberOfRows == 0)

        retry.performClick(nil)
        try await waitForDataRows(table, count: 2)
        #expect(retry.isHidden)
        #expect(table.selectedRow == 0)
        #expect(await provider.dataCallCount() == 2)
        #expect(await provider.objectCallCount() == 0)
        #expect(await provider.requestedUIDs() == [fixture.identity.uid, fixture.identity.uid])
    }

    @Test("helper recovery preserves drafts and revokes transient Secret reveal")
    func successfulRecoveryPreservesDraftsAndConcealsSecret() async throws {
        let fixture = detailFixture(resource: "secrets", secret: true)
        let provider = SequencedDataObjectDetailProvider(responses: [
            .data(fixture.data),
            .data(fixture.data),
        ])
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: provider
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let reveal = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Show decoded values" })
        try await waitForDataRows(table, count: 2)
        reveal.performClick(nil)
        editor.string = "draft-survives-recovery"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        controller.engineDidDisconnect()
        #expect(reveal.state == .off)
        #expect(!reveal.isEnabled)
        #expect(editor.string.contains("draft-survives-recovery") == false)
        #expect((try valueText(in: table, row: 0))
            .contains("draft-survives-recovery") == false)
        table.keyDown(with: try dataKeyEvent("d"))
        #expect(reveal.state == .off)
        #expect(editor.string.contains("draft-survives-recovery") == false)
        var recoveryResult: Result<Void, Error>?
        controller.recover(session: OpenedClusterSession(
            sessionID: "recovered-session",
            contextName: "context",
            clusterName: "cluster",
            serverHostname: "example.invalid",
            defaultNamespace: "default"
        )) { recoveryResult = $0 }
        try await waitForCondition { recoveryResult != nil }

        guard case .success? = recoveryResult else {
            Issue.record("Expected Data recovery to succeed")
            return
        }
        #expect(reveal.state == .off)
        #expect(editor.string.contains("draft-survives-recovery") == false)
        #expect(try stateText(in: table, row: 0) == "Unsaved")
        #expect(controller.identity.clusterSessionID == "recovered-session")
        #expect(await provider.requestedSessionIDs()
            == [fixture.identity.clusterSessionID, "recovered-session"])

        try await waitForCondition { reveal.isEnabled }
        reveal.performClick(nil)
        #expect(editor.string == "draft-survives-recovery")
    }

    @Test("retry after failed helper recovery stays on the recovered session")
    func recoveryRetryUsesCurrentSession() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let provider = SequencedDataObjectDetailProvider(responses: [
            .data(fixture.data),
            .failure(ClusterManagerIssue(
                category: .unavailable,
                reason: "TemporaryRecoveryFailure",
                message: "The recovered helper was temporarily unavailable.",
                operation: "recover key/value data"
            )),
            .data(fixture.data),
        ])
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: provider
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let retry = try #require(dataButtons(in: controller.view).first { $0.title == "Retry" })
        try await waitForDataRows(table, count: 2)
        controller.engineDidDisconnect()

        var recoveryResult: Result<Void, Error>?
        controller.recover(session: OpenedClusterSession(
            sessionID: "recovered-session",
            contextName: "context",
            clusterName: "cluster",
            serverHostname: "example.invalid",
            defaultNamespace: "default"
        )) { recoveryResult = $0 }
        try await waitForCondition { recoveryResult != nil && !retry.isHidden }
        guard case .failure? = recoveryResult else {
            Issue.record("Expected the first Data recovery request to fail")
            return
        }
        #expect(controller.identity.clusterSessionID == "recovered-session")

        retry.performClick(nil)
        try await waitForSequencedDataFetches(provider, count: 3)
        try await waitForCondition { retry.isHidden && table.numberOfRows == 2 }
        #expect(await provider.requestedSessionIDs() == [
            fixture.identity.clusterSessionID,
            "recovered-session",
            "recovered-session",
        ])
    }

    @Test("identical binary import remains saved")
    func identicalBinaryImportIsNotMarkedUnsaved() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let bytes = Data([0x00, 0xff, 0x10, 0x80])
        let data = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-1",
            entries: [ObjectDataEntry(
                key: "archive",
                kind: .binary,
                value: bytes,
                byteSize: UInt64(bytes.count),
                contentHash: Data(repeating: 8, count: 32)
            )],
            secret: false
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: data),
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let save = try #require(dataButtons(in: controller.view).first { $0.title == "Save Key" })
        let rename = try #require(dataButtons(in: controller.view).first { $0.title == "Rename" })
        try await waitForDataRows(table, count: 1)

        select(row: 0, in: table, controller: controller)
        controller.replaceSelectedDataWithImportedBytes(bytes)

        #expect(try stateText(in: table, row: 0) == "Saved")
        #expect(!editor.string.contains("unsaved"))
        #expect(!save.isEnabled)
        #expect(rename.isEnabled)
    }

    @Test("file replacement preserves existing ConfigMap text membership")
    func fileReplacementPreservesConfigMapTextKind() async throws {
        try await assertImportedReplacement(
            resource: "configmaps",
            secret: false,
            storedKind: .text,
            originalBytes: Data("server text".utf8),
            importedBytes: Data("replacement text".utf8),
            expectedKind: .text
        )
    }

    @Test("file replacement preserves existing ConfigMap binary membership")
    func fileReplacementPreservesConfigMapBinaryKind() async throws {
        try await assertImportedReplacement(
            resource: "configmaps",
            secret: false,
            storedKind: .binary,
            originalBytes: Data([0x00, 0x01, 0x02]),
            importedBytes: Data([0xff, 0x80, 0x10]),
            expectedKind: .binary
        )
    }

    @Test("file replacement keeps Secret imports as raw binary bytes")
    func fileReplacementKeepsSecretBinaryImport() async throws {
        try await assertImportedReplacement(
            resource: "secrets",
            secret: true,
            storedKind: .text,
            originalBytes: Data("server secret".utf8),
            importedBytes: Data([0x00, 0xff, 0x10, 0x80]),
            expectedKind: .binary
        )
    }

    @Test("data value file I/O runs off main and keeps its captured key")
    func dataValueFileIORunsOffMainAndKeepsTargetKey() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let probe = DataValueFileOperationProbe(
            importedBytes: Data([0x00, 0xff, 0x10, 0x80])
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
            dataFileReader: { try probe.read($0) },
            dataFileWriter: { try probe.write($0, to: $1) }
        )
        controller.loadView()
        controller.viewDidAppear()
        defer {
            probe.releaseAll()
            controller.stop()
        }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let importButton = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Replace from File…" })
        let exportButton = try #require(dataButtons(in: controller.view)
            .first { $0.title == "Export…" })
        try await waitForDataRows(table, count: 2)

        let alphaRow = try row(forKey: "alpha", in: table)
        let betaRow = try row(forKey: "beta", in: table)
        select(row: alphaRow, in: table, controller: controller)
        controller.importDataFile(
            from: URL(fileURLWithPath: "/tmp/kmgr-import-probe.bin"),
            forKey: "alpha"
        )
        try await waitForCondition { probe.readStarted }
        #expect(probe.readRanOnMainThread == false)
        #expect(!importButton.isEnabled)
        #expect(!exportButton.isEnabled)

        // A table selection can change while the utility task is reading. The
        // completion must still update the key captured before the read.
        select(row: betaRow, in: table, controller: controller)
        probe.releaseRead()
        try await waitForCondition {
            (try? stateText(in: table, row: alphaRow)) == "Unsaved"
        }
        #expect(try stateText(in: table, row: betaRow) == "Saved")
        #expect(editor.string == "server-beta")

        select(row: alphaRow, in: table, controller: controller)
        controller.exportDataFile(
            probe.importedBytes,
            key: "alpha",
            to: URL(fileURLWithPath: "/tmp/kmgr-export-probe.bin")
        )
        try await waitForCondition { probe.writeStarted }
        #expect(probe.writeRanOnMainThread == false)
        #expect(!importButton.isEnabled)
        #expect(!exportButton.isEnabled)
        probe.releaseWrite()
        try await waitForCondition { probe.writeFinished }
        #expect(probe.writtenBytes == probe.importedBytes)
    }

    @Test("stopping the Data screen ignores a late file-read completion")
    func stoppingDetailInvalidatesDataFileCallback() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let probe = DataValueFileOperationProbe(
            importedBytes: Data([0xde, 0xad, 0xbe, 0xef])
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
            dataFileReader: { try probe.read($0) }
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { probe.releaseAll() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        try await waitForDataRows(table, count: 2)
        let alphaRow = try row(forKey: "alpha", in: table)
        select(row: alphaRow, in: table, controller: controller)
        #expect(editor.string == "server-alpha")

        controller.importDataFile(
            from: URL(fileURLWithPath: "/tmp/kmgr-late-import-probe.bin"),
            forKey: "alpha"
        )
        try await waitForCondition { probe.readStarted }
        controller.stop()
        probe.releaseRead()
        try await waitForCondition { probe.readFinished }
        try await Task.sleep(for: .milliseconds(30))

        #expect(probe.readObservedCancellation == true)
        #expect(editor.string == "server-alpha")
    }

    @Test("save locks editing and a missing sibling draft remains recoverable")
    func saveLocksAndPreservesMissingDraft() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let provider = DraftMutationObjectDetailProvider(
            detail: fixture.detail,
            data: fixture.data
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: provider,
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let save = try #require(dataButtons(in: controller.view).first { $0.title == "Save Key" })
        let rename = try #require(dataButtons(in: controller.view).first { $0.title == "Rename" })
        try await waitForDataRows(table, count: 2)

        select(row: 1, in: table, controller: controller)
        editor.string = "draft-beta"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        select(row: 0, in: table, controller: controller)
        editor.string = "saved-alpha"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        save.performClick(nil)

        try await waitForPendingUpdate(provider)
        #expect(!editor.isEditable)
        #expect(!rename.isEnabled)

        let refreshed = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-2",
            entries: [dataEntry(key: "alpha", value: "saved-alpha", hashByte: 9)],
            secret: false
        )
        await provider.blockNextDataFetch()
        await provider.succeed(with: refreshed)
        try await waitForBlockedDataFetch(provider)
        #expect(!editor.isEditable)
        await provider.resumeDataFetch()
        try await waitForDataFetches(provider, count: 2)
        try await waitForCondition {
            guard let beta = try? row(forKey: "beta", in: table) else { return false }
            return (try? stateText(in: table, row: beta)) == "Conflict"
        }

        let betaRow = try row(forKey: "beta", in: table)
        #expect(try stateText(in: table, row: betaRow) == "Conflict")
        select(row: betaRow, in: table, controller: controller)
        #expect(editor.string == "draft-beta")
        #expect(save.isEnabled)
        #expect(!rename.isEnabled)

        save.performClick(nil)
        try await waitForUpdateCalls(provider, count: 2)
        let latestMutation = await provider.latestMutation()
        let recreation = try #require(latestMutation)
        guard case .set(let key, let kind, let value, let expectedHash) = recreation else {
            Issue.record("Expected a create-only set mutation for the tombstone draft")
            return
        }
        #expect(key == "beta")
        #expect(kind == .text)
        #expect(value == Data("draft-beta".utf8))
        #expect(expectedHash.isEmpty)
    }

    @Test("conflict sheet and retry keep the submitted editor locked")
    func conflictRetryKeepsEditorLocked() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let provider = DraftMutationObjectDetailProvider(
            detail: fixture.detail,
            data: fixture.data
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: provider,
        )
        controller.loadView()
        let window = NSWindow(contentViewController: controller)
        controller.viewDidAppear()
        defer {
            controller.stop()
            window.close()
        }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        let save = try #require(dataButtons(in: controller.view).first { $0.title == "Save Key" })
        try await waitForDataRows(table, count: 2)

        select(row: 0, in: table, controller: controller)
        editor.string = "local-alpha"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        save.performClick(nil)
        try await waitForPendingUpdate(provider)

        let current = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-2",
            entries: [
                dataEntry(key: "alpha", value: "server-alpha-2", hashByte: 7),
                dataEntry(key: "beta", value: "server-beta", hashByte: 2),
            ],
            secret: false
        )
        await provider.failConflict(with: current)
        try await waitForCondition { window.attachedSheet != nil }
        #expect(!editor.isEditable)

        let sheet = try #require(window.attachedSheet)
        let retry = try #require(draftDescendants(of: sheet.contentView ?? NSView())
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Retry with Current Version" })
        #expect(retry.isEnabled)
        retry.performClick(nil)
        try await waitForUpdateCalls(provider, count: 2)
        #expect(!editor.isEditable)

        let saved = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-3",
            entries: [
                dataEntry(key: "alpha", value: "local-alpha", hashByte: 9),
                dataEntry(key: "beta", value: "server-beta", hashByte: 2),
            ],
            secret: false
        )
        await provider.succeed(with: saved)
        try await waitForDataFetches(provider, count: 3)
    }

    private func detailFixture(
        resource: String,
        secret: Bool
    ) -> (identity: ResourceIdentity, detail: ObjectDetail, data: ObjectData) {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: resource,
            namespace: "dev",
            name: "settings",
            uid: ResourceUID("uid")
        )
        let entries = [
            dataEntry(key: "alpha", value: "server-alpha", hashByte: 1),
            dataEntry(key: "beta", value: "server-beta", hashByte: 2),
        ]
        return (
            identity,
            ObjectDetail(identity: identity, resourceVersion: "rv-1"),
            ObjectData(
                identity: identity,
                resourceVersion: "rv-1",
                entries: entries,
                secret: secret
            )
        )
    }

    private func assertImportedReplacement(
        resource: String,
        secret: Bool,
        storedKind: DataValueKind,
        originalBytes: Data,
        importedBytes: Data,
        expectedKind: DataValueKind
    ) async throws {
        let fixture = detailFixture(resource: resource, secret: secret)
        let expectedHash = Data(repeating: 6, count: 32)
        let data = ObjectData(
            identity: fixture.identity,
            resourceVersion: "rv-1",
            entries: [ObjectDataEntry(
                key: "payload",
                kind: storedKind,
                value: originalBytes,
                byteSize: UInt64(originalBytes.count),
                contentHash: expectedHash
            )],
            secret: secret
        )
        let provider = DraftMutationObjectDetailProvider(
            detail: fixture.detail,
            data: data
        )
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: provider,
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try dataKeysTable(in: controller.view)
        let buttons = dataButtons(in: controller.view)
        let save = try #require(buttons.first { $0.title == "Save Key" })
        try await waitForDataRows(table, count: 1)
        select(row: 0, in: table, controller: controller)
        if secret {
            let reveal = try #require(buttons.first { $0.title == "Show decoded values" })
            reveal.performClick(nil)
        }

        controller.replaceSelectedDataWithImportedBytes(importedBytes)
        #expect(try stateText(in: table, row: 0) == "Unsaved")
        #expect(save.isEnabled)
        save.performClick(nil)
        try await waitForPendingUpdate(provider)

        let mutation = try #require(await provider.latestMutation())
        guard case .set(let key, let kind, let value, let expectedContentHash) = mutation else {
            Issue.record("Expected imported bytes to submit a set mutation")
            return
        }
        #expect(key == "payload")
        #expect(kind == expectedKind)
        #expect(value == importedBytes)
        #expect(expectedContentHash == expectedHash)
    }

    @Test("Escape leaves Data value editing before navigating Back")
    func escapeLeavesDataEditorBeforeBack() async throws {
        let fixture = detailFixture(resource: "configmaps", secret: false)
        let controller = ObjectDataViewController(
            identity: fixture.identity,
            provider: DraftObjectDetailProvider(detail: fixture.detail, data: fixture.data),
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        var backCount = 0
        controller.onBack = { backCount += 1 }
        controller.loadView()
        window.contentView = controller.view
        controller.viewDidAppear()
        defer {
            window.makeFirstResponder(nil)
            controller.stop()
            window.contentView = NSView()
            window.close()
        }

        let table = try dataKeysTable(in: controller.view)
        let editor = try dataValueEditor(in: controller.view)
        try await waitForDataRows(table, count: 2)
        select(row: 0, in: table, controller: controller)
        editor.string = "draft-kept-after-escape"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(window.makeFirstResponder(editor))
        #expect(window.firstResponder === editor)

        controller.cancelOperation(nil)

        #expect(backCount == 0)
        #expect(window.firstResponder === table)
        #expect(editor.string == "draft-kept-after-escape")
        #expect(try stateText(in: table, row: 0) == "Unsaved")

        controller.cancelOperation(nil)
        #expect(backCount == 1)
    }

    private func dataEntry(key: String, value: String, hashByte: UInt8) -> ObjectDataEntry {
        ObjectDataEntry(
            key: key,
            kind: .text,
            value: Data(value.utf8),
            byteSize: UInt64(value.utf8.count),
            contentHash: Data(repeating: hashByte, count: 32)
        )
    }

    private func select(
        row: Int,
        in table: NSTableView,
        controller: ObjectDataViewController
    ) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: table
        ))
    }

    private func stateText(in table: NSTableView, row: Int) throws -> String {
        let column = try #require(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "state"
        })
        let cell = try #require(table.view(
            atColumn: column,
            row: row,
            makeIfNecessary: true
        ) as? NSTableCellView)
        return cell.textField?.stringValue ?? ""
    }

    private func valueCell(in table: NSTableView, row: Int) throws -> NSTableCellView {
        let column = try #require(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "value"
        })
        return try #require(table.view(
            atColumn: column,
            row: row,
            makeIfNecessary: true
        ) as? NSTableCellView)
    }

    private func valueText(in table: NSTableView, row: Int) throws -> String {
        try valueCell(in: table, row: row).textField?.stringValue ?? ""
    }

    private func valueAccessibility(in table: NSTableView, row: Int) throws -> String {
        try valueCell(in: table, row: row).accessibilityValue() as? String ?? ""
    }

    private func row(forKey key: String, in table: NSTableView) throws -> Int {
        let column = try #require(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "key"
        })
        for row in 0..<table.numberOfRows {
            let cell = table.view(
                atColumn: column,
                row: row,
                makeIfNecessary: true
            ) as? NSTableCellView
            if cell?.textField?.stringValue == key { return row }
        }
        throw CancellationError()
    }
}
}

private final class DataValueFileOperationProbe: @unchecked Sendable {
    let importedBytes: Data
    private let lock = NSLock()
    private let readGate = DispatchSemaphore(value: 0)
    private let writeGate = DispatchSemaphore(value: 0)
    private var storedReadStarted = false
    private var storedReadFinished = false
    private var storedReadRanOnMainThread: Bool?
    private var storedReadObservedCancellation: Bool?
    private var storedWriteStarted = false
    private var storedWriteFinished = false
    private var storedWriteRanOnMainThread: Bool?
    private var storedWrittenBytes: Data?

    init(importedBytes: Data) {
        self.importedBytes = importedBytes
    }

    var readStarted: Bool { lock.withLock { storedReadStarted } }
    var readFinished: Bool { lock.withLock { storedReadFinished } }
    var readRanOnMainThread: Bool? { lock.withLock { storedReadRanOnMainThread } }
    var readObservedCancellation: Bool? {
        lock.withLock { storedReadObservedCancellation }
    }
    var writeStarted: Bool { lock.withLock { storedWriteStarted } }
    var writeFinished: Bool { lock.withLock { storedWriteFinished } }
    var writeRanOnMainThread: Bool? { lock.withLock { storedWriteRanOnMainThread } }
    var writtenBytes: Data? { lock.withLock { storedWrittenBytes } }

    func read(_ url: URL) throws -> Data {
        lock.withLock {
            storedReadStarted = true
            storedReadRanOnMainThread = Thread.isMainThread
        }
        readGate.wait()
        lock.withLock {
            storedReadObservedCancellation = Task.isCancelled
            storedReadFinished = true
        }
        return importedBytes
    }

    func write(_ bytes: Data, to url: URL) throws {
        lock.withLock {
            storedWriteStarted = true
            storedWriteRanOnMainThread = Thread.isMainThread
        }
        writeGate.wait()
        lock.withLock {
            storedWrittenBytes = bytes
            storedWriteFinished = true
        }
    }

    func releaseRead() { readGate.signal() }
    func releaseWrite() { writeGate.signal() }

    func releaseAll() {
        readGate.signal()
        writeGate.signal()
    }
}

private actor SequencedDataObjectDetailProvider: ObjectDetailProviding {
    enum Response: Sendable {
        case data(ObjectData)
        case failure(ClusterManagerIssue)
    }

    private var responses: [Response]
    private var dataCalls = 0
    private var objectCalls = 0
    private var requestedIdentities: [ResourceIdentity] = []

    init(responses: [Response]) { self.responses = responses }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        objectCalls += 1
        throw CancellationError()
    }

    nonisolated func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    nonisolated func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        dataCalls += 1
        requestedIdentities.append(identity)
        guard !responses.isEmpty else { throw CancellationError() }
        switch responses.removeFirst() {
        case .failure(let issue):
            throw issue
        case .data(var data):
            guard data.identity.uid == identity.uid else { throw CancellationError() }
            data.identity.clusterSessionID = identity.clusterSessionID
            return data
        }
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit { throw CancellationError() }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func dataCallCount() -> Int { dataCalls }
    func objectCallCount() -> Int { objectCalls }
    func requestedUIDs() -> [ResourceUID] { requestedIdentities.map(\.uid) }
    func requestedSessionIDs() -> [String] { requestedIdentities.map(\.clusterSessionID) }
}

private actor DraftMutationObjectDetailProvider: ObjectDetailProviding {
    private var detail: ObjectDetail
    private var data: ObjectData
    private var pendingUpdate: AsyncThrowingStream<OperationProgress, Error>.Continuation?
    private var dataFetchCount = 0
    private var updateCallCount = 0
    private var latestMutations: [DataMutationKind] = []
    private var shouldBlockNextDataFetch = false
    private var blockedDataFetch: CheckedContinuation<Void, Never>?

    init(detail: ObjectDetail, data: ObjectData) {
        self.detail = detail
        self.data = data
    }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }

    nonisolated func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    nonisolated func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        dataFetchCount += 1
        if shouldBlockNextDataFetch {
            shouldBlockNextDataFetch = false
            await withCheckedContinuation { blockedDataFetch = $0 }
        }
        return data
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let pair = AsyncThrowingStream<OperationProgress, Error>.makeStream()
        pendingUpdate = pair.continuation
        updateCallCount += 1
        latestMutations = mutations
        return pair.stream
    }

    func hasPendingUpdate() -> Bool { pendingUpdate != nil }

    func fetchCount() -> Int { dataFetchCount }

    func numberOfUpdateCalls() -> Int { updateCallCount }

    func latestMutation() -> DataMutationKind? { latestMutations.last }

    func blockNextDataFetch() { shouldBlockNextDataFetch = true }

    func hasBlockedDataFetch() -> Bool { blockedDataFetch != nil }

    func resumeDataFetch() {
        blockedDataFetch?.resume()
        blockedDataFetch = nil
    }

    func succeed(with updatedData: ObjectData) {
        data = updatedData
        detail.resourceVersion = updatedData.resourceVersion
        pendingUpdate?.yield(OperationProgress(
            cursor: StreamCursor(generation: 1, sequence: 1),
            operationID: "save-key",
            state: .succeeded,
            completedItems: 1,
            totalItems: 1,
            itemResults: []
        ))
        pendingUpdate?.finish()
        pendingUpdate = nil
    }

    func failConflict(with currentData: ObjectData) {
        data = currentData
        detail.resourceVersion = currentData.resourceVersion
        pendingUpdate?.yield(OperationProgress(
            cursor: StreamCursor(generation: 1, sequence: 1),
            operationID: "save-key",
            state: .failed,
            completedItems: 0,
            totalItems: 1,
            itemResults: [],
            issue: ClusterManagerIssue(
                category: .conflict,
                reason: "Conflict",
                message: "The key changed on the server.",
                operation: "save key"
            )
        ))
        pendingUpdate?.finish()
        pendingUpdate = nil
    }
}

private struct DraftObjectDetailProvider: ObjectDetailProviding {
    var detail: ObjectDetail
    var data: ObjectData

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

    func getData(identity: ResourceIdentity) async throws -> ObjectData { data }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}

@MainActor
private func draftDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(draftDescendants(of:))
}

@MainActor
private func dataKeysTable(in root: NSView) throws -> NSTableView {
    try #require(draftDescendants(of: root).compactMap { $0 as? NSTableView }
        .first { $0.accessibilityLabel() == "ConfigMap or Secret data keys and values" })
}

@MainActor
private func dataValueEditor(in root: NSView) throws -> NSTextView {
    let scroll = try #require(draftDescendants(of: root).compactMap { $0 as? NSScrollView }
        .first { $0.accessibilityLabel() == "Selected decoded data value editor" })
    return try #require(scroll.documentView as? NSTextView)
}

@MainActor
private func dataSearchField(in root: NSView) throws -> NSSearchField {
    try #require(draftDescendants(of: root).compactMap { $0 as? NSSearchField }
        .first {
            $0.accessibilityLabel()
                == "Search ConfigMap or Secret data keys and values"
        })
}

@MainActor
private func applyDataSearch(_ query: String, field: NSSearchField) {
    field.stringValue = query
    _ = field.sendAction(field.action, to: field.target)
}

@MainActor
private func dataButtons(in root: NSView) -> [NSButton] {
    draftDescendants(of: root).compactMap { $0 as? NSButton }
}

@MainActor
private func dataKeyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 2
    ))
}

@MainActor
private func waitForDataRows(
    _ table: NSTableView,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while table.numberOfRows != count {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForPendingUpdate(
    _ provider: DraftMutationObjectDetailProvider,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await provider.hasPendingUpdate()) {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForDataFetches(
    _ provider: DraftMutationObjectDetailProvider,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await provider.fetchCount() < count {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForSequencedDataFetches(
    _ provider: SequencedDataObjectDetailProvider,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await provider.dataCallCount() < count {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForBlockedDataFetch(
    _ provider: DraftMutationObjectDetailProvider,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await provider.hasBlockedDataFetch()) {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForUpdateCalls(
    _ provider: DraftMutationObjectDetailProvider,
    count: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await provider.numberOfUpdateCalls() < count {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
