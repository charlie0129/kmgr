import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Object Details metadata editing", .serialized)
struct ObjectDetailMetadataEditingTests {
    @Test("Summary exposes separate section actions and Return edits the selected kind")
    func sectionActionsAndReturn() async throws {
        let identity = detailMetadataIdentity()
        let controller = ObjectSummaryViewController(
            identity: identity,
            provider: DetailMetadataProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                labels: ["team": "platform"],
                annotations: ["team": "Platform Team"]
            ))
        )
        var requests: [(ResourceMetadataKind, String?)] = []
        controller.onEditMetadata = { _, kind, key in requests.append((kind, key)) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.stop()
            window.orderOut(nil)
        }

        let table = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "object-detail-summary-table" })
        try await detailMetadataWaitUntil { table.numberOfRows >= 4 }
        for row in 0..<table.numberOfRows {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        let labelsButton = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "object-detail-edit-labels" })
        let annotationsButton = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "object-detail-edit-annotations" })
        #expect(labelsButton.title == "Edit Labels…")
        #expect(annotationsButton.title == "Edit Annotations…")

        let sectionView = try #require(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let sectionDescendants = detailMetadataDescendants(of: sectionView)
        let sectionBackground = try #require(sectionDescendants
            .compactMap { $0 as? NSVisualEffectView }
            .first { $0.identifier?.rawValue == "object-detail-summary-section-background" })
        #expect(sectionBackground.material == .headerView)
        #expect(sectionDescendants.contains {
            $0.identifier?.rawValue == "object-detail-summary-section-accent"
        })
        #expect(sectionDescendants.contains {
            $0.identifier?.rawValue == "object-detail-summary-section-separator"
        })
        let heading = try #require(sectionDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Labels" })
        #expect(heading.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(controller.tableView(table, heightOfRow: 0) == 36)
        #expect(abs(table.rect(ofRow: 0).height - 36) <= 1)

        annotationsButton.performClick(nil)
        #expect(requests.count == 1)
        #expect(requests[0].0 == .annotations)
        #expect(requests[0].1 == nil)

        let labelRow = try detailMetadataRow(
            key: "team",
            value: "platform",
            in: table
        )
        table.selectRowIndexes(IndexSet(integer: labelRow), byExtendingSelection: false)
        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        table.keyDown(with: returnEvent)
        #expect(requests.count == 2)
        #expect(requests[1].0 == .labels)
        #expect(requests[1].1 == "team")

        #expect(controller.contextualShortcutSnapshot.items.contains {
            $0.id == "details.edit-metadata"
        })
    }

    @Test("empty metadata still exposes both kind-specific edit actions")
    func emptySectionsRemainEditable() async throws {
        let identity = detailMetadataIdentity()
        let controller = ObjectSummaryViewController(
            identity: identity,
            provider: DetailMetadataProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-empty"
            ))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.stop()
            window.orderOut(nil)
        }
        let table = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "object-detail-summary-table" })
        try await detailMetadataWaitUntil { table.numberOfRows == 2 }
        for row in 0..<table.numberOfRows {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        let buttonIDs = Set(detailMetadataDescendants(of: controller.view)
            .compactMap { ($0 as? NSButton)?.identifier?.rawValue })
        #expect(buttonIDs.contains("object-detail-edit-labels"))
        #expect(buttonIDs.contains("object-detail-edit-annotations"))
    }

    @Test("Summary rows and user-sized columns fill the viewport across resize")
    func summaryRowsAndColumnsFillViewportAcrossResize() async throws {
        let identity = detailMetadataIdentity()
        let suite = "kmgr-detail-metadata-layout-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let tableLayoutStore = TableLayoutStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let labels = Dictionary(uniqueKeysWithValues: (0..<64).map {
            (String(format: "label-%02d", $0), "value-\($0)")
        })
        let controller = ObjectSummaryViewController(
            identity: identity,
            provider: DetailMetadataProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-wide",
                summaryFields: [ObjectSummaryField(
                    sectionID: "identity",
                    fieldID: "name",
                    label: "Name",
                    displayText: "api"
                )],
                labels: labels,
                annotations: ["example.test/note": "owned"]
            )),
            tableLayoutStore: tableLayoutStore
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let host = WorkspaceRightPaneViewController(
            connectionActivityView: ClusterConnectionActivityView()
        )
        let placeholder = NSViewController()
        placeholder.view = NSView()
        host.setContent(placeholder, initialStatus: WorkspaceStatus("Ready"))
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 800))
        window.makeKeyAndOrderFront(nil)
        host.setContent(controller, initialStatus: controller.workspaceStatus)
        defer {
            controller.stop()
            window.orderOut(nil)
        }

        let table = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "object-detail-summary-table" })
        let scrollView = try #require(table.enclosingScrollView)
        try await detailMetadataWaitUntil { table.numberOfRows >= 69 }
        let section = try #require(
            table.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        window.contentView?.layoutSubtreeIfNeeded()

        let button = try #require(detailMetadataDescendants(of: section)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "object-detail-edit-labels" })
        #expect(table.effectiveStyle == .plain)
        assertSummarySectionFillsTable(
            section: section,
            button: button,
            table: table
        )

        table.tableColumns[0].width = 400
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: table
        )
        window.setContentSize(NSSize(width: 1_500, height: 800))
        window.layoutIfNeeded()
        try await detailMetadataWaitUntil {
            let width = table.tableColumns.reduce(0) { $0 + $1.width }
                + table.intercellSpacing.width
                    * CGFloat(max(0, table.tableColumns.count - 1))
            return abs(width - scrollView.contentSize.width) <= 1
        }

        #expect(abs(table.frame.width - scrollView.contentSize.width) <= 1)
        let columnWidth = table.tableColumns.reduce(0) { $0 + $1.width }
            + table.intercellSpacing.width
                * CGFloat(max(0, table.tableColumns.count - 1))
        #expect(abs(columnWidth - scrollView.contentSize.width) <= 1)
        assertSummarySectionFillsTable(
            section: section,
            button: button,
            table: table
        )
    }
}
}

@MainActor
private func assertSummarySectionFillsTable(
    section: NSView,
    button: NSButton,
    table: NSTableView
) {
    let sectionFrame = section.convert(section.bounds, to: table)
    #expect(abs(sectionFrame.minX - table.bounds.minX) <= 1)
    #expect(abs(sectionFrame.maxX - table.bounds.maxX) <= 1)

    let buttonFrame = button.convert(button.bounds, to: table)
    #expect(abs(table.bounds.maxX - buttonFrame.maxX - 8) <= 1)
}

private struct DetailMetadataProvider: ObjectDetailProviding {
    var detail: ObjectDetail

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }
    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
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
        throw CancellationError()
    }
}

private func detailMetadataIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "team-a",
        name: "api",
        uid: "deployment-uid"
    )
}

@MainActor
private func detailMetadataDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(detailMetadataDescendants(of:))
}

@MainActor
private func detailMetadataRow(
    key: String,
    value: String,
    in table: NSTableView
) throws -> Int {
    try #require((0..<table.numberOfRows).first { row in
        let keyText = (table.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? NSTableCellView)?.textField?.stringValue
        let valueText = (table.view(atColumn: 1, row: row, makeIfNecessary: true)
            as? NSTableCellView)?.textField?.stringValue
        return keyText == key && valueText == value
    })
}

private func detailMetadataWaitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DetailMetadataTestError.timedOut
}

private enum DetailMetadataTestError: Error {
    case timedOut
}
