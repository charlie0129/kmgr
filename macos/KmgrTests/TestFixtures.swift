@testable import KmgrCore

func identity(
    _ uid: ResourceUID,
    name: String? = nil,
    namespace: String = "default",
    resource: String = "pods"
) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session-1",
        group: "",
        version: "v1",
        resource: resource,
        namespace: namespace,
        name: name ?? uid.rawValue,
        uid: uid
    )
}

func row(
    _ uid: ResourceUID,
    name: String? = nil,
    namespace: String = "default",
    status: String = "Running"
) -> ResourceRow {
    ResourceRow(
        identity: identity(uid, name: name, namespace: namespace),
        cells: [
            Cell(
                columnID: "name",
                displayText: name ?? uid.rawValue,
                typedValue: .string(name ?? uid.rawValue)
            ),
            Cell(
                columnID: "status",
                displayText: status,
                typedValue: .string(status)
            ),
        ]
    )
}
