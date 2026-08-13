import Foundation
import Testing
@testable import KmgrCore

@Test func execContainerCatalogUsesFreshSummaryWithoutOfferingDuplicateNames() {
    let fields = [
        ObjectSummaryField(
            sectionID: "containers", fieldID: "ephemeralContainer:debug",
            label: "Ephemeral Container", displayText: "debug"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "container:main",
            label: "Container", displayText: "main"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "initContainer:setup",
            label: "Init Container", displayText: "setup"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "container:debug",
            label: "Container", displayText: "debug"
        ),
        ObjectSummaryField(
            sectionID: "ports", fieldID: "port:TCP:8080:http",
            label: "Port", displayText: "8080/TCP"
        ),
    ]

    #expect(ExecContainerCatalog.candidates(from: fields) == [
        ExecContainerCandidate(name: "debug", kind: .regular),
        ExecContainerCandidate(name: "main", kind: .regular),
        ExecContainerCandidate(name: "setup", kind: .initContainer),
    ])
}

@Test func explicitExecCommandPreservesOneArgumentPerLineWithoutShellParsing() throws {
    let arguments = ExecCommandChoice.arguments(onePerLine: """
        --message
        hello operator
        --selector=app=api
        """)
    let command = try ExecCommandChoice.executable(
        path: " /usr/bin/tool ", arguments: arguments
    ).validatedCommand()

    #expect(command == [
        "/usr/bin/tool", "--message", "hello operator", "--selector=app=api",
    ])
}

@Test func execCommandValidationRejectsLineBreaksAndOversizedCommands() {
    #expect(throws: ExecConfigurationValidationError.invalidArgument) {
        try ExecCommandChoice.executable(
            path: "/bin/echo", arguments: ["unsafe\nargument"]
        ).validatedCommand()
    }
    #expect(throws: ExecConfigurationValidationError.commandTooLarge) {
        try ExecCommandChoice.executable(
            path: "/bin/echo",
            arguments: [String(repeating: "x", count: ExecCommandChoice.maximumUTF8Bytes)]
        ).validatedCommand()
    }
}
