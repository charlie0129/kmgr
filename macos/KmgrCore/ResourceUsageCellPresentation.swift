import Foundation

/// A framework-independent description of a compact native resource-usage
/// cell. Ratios deliberately remain unbounded so callers can show over-request
/// and over-limit values instead of silently clamping them to 100 percent.
public struct ResourceUsageCellPresentation: Hashable, Sendable {
    public enum Pressure: String, Hashable, Sendable {
        case normal
        case warning
        case critical
    }

    public enum Component: String, Hashable, Sendable {
        case usage
        case request
        case limit
        case capacity
    }

    public struct Marker: Hashable, Sendable {
        public var component: Component
        public var ratio: Double

        public init(component: Component, ratio: Double) {
            self.component = component
            self.ratio = ratio
        }

        public var isOverflow: Bool { ratio > 1 }
    }

    public var text: String
    public var primaryComponent: Component?
    public var fillRatio: Double?
    public var markers: [Marker]
    public var pressure: Pressure
    public var effectiveSeverity: CellSeverity
    public var accessibilityLabel: String
    public var accessibilityValue: String

    public init?(cell: Cell) {
        guard case .usage(let value)? = cell.typedValue else { return nil }
        self.init(
            displayText: cell.displayText,
            value: value,
            cellSeverity: cell.severity
        )
    }

    public init(
        displayText: String,
        value: ResourceUsageValue,
        cellSeverity: CellSeverity = .normal
    ) {
        text = displayText.isEmpty ? "—" : displayText
        primaryComponent = Self.primaryComponent(value)
        pressure = Self.pressure(value)
        effectiveSeverity = Self.effectiveSeverity(
            cellSeverity: cellSeverity,
            pressure: pressure
        )

        let components = Self.components(value)
        if let denominator = Self.denominator(value) {
            fillRatio = primaryComponent.flatMap { component in
                Self.geometryValue(components[component]).map { $0 / denominator }
            }
            markers = [.request, .limit, .capacity].compactMap { component in
                Self.geometryValue(components[component]).map {
                    Marker(component: component, ratio: $0 / denominator)
                }
            }
        } else if !components.isEmpty {
            // Explicit zero is a real value. Give it zero-position geometry
            // even though there is no positive quantity from which to scale.
            fillRatio = primaryComponent.flatMap { component in
                Self.geometryValue(components[component]).map { _ in 0 }
            }
            markers = [.request, .limit, .capacity].compactMap { component in
                Self.geometryValue(components[component]).map { _ in
                    Marker(component: component, ratio: 0)
                }
            }
        } else {
            fillRatio = nil
            markers = []
        }

        let title = Self.resourceTitle(value.resourceName)
        accessibilityLabel = value.usage == nil
            ? "\(title) resource allocation"
            : "\(title) resource usage"
        let quantityDescription = Self.accessibilityValue(
            title: title,
            displayText: text,
            value: value
        )
        accessibilityValue = switch effectiveSeverity {
        case .warning: "Warning, \(quantityDescription)"
        case .critical: "Critical, \(quantityDescription)"
        default: quantityDescription
        }
    }

    public var hasOverflow: Bool {
        (fillRatio.map { $0 > 1 } ?? false) || markers.contains(where: \.isOverflow)
    }

    private static func components(
        _ value: ResourceUsageValue
    ) -> [Component: Double] {
        var result: [Component: Double] = [:]
        if let usage = value.usage { result[.usage] = usage }
        if let request = value.request { result[.request] = request }
        if let limit = value.limit { result[.limit] = limit }
        if let capacity = value.capacity { result[.capacity] = capacity }
        return result
    }

    private static func primaryComponent(_ value: ResourceUsageValue) -> Component? {
        if value.usage != nil { return .usage }
        if value.request != nil { return .request }
        if value.limit != nil { return .limit }
        if value.capacity != nil { return .capacity }
        return nil
    }

    private static func denominator(_ value: ResourceUsageValue) -> Double? {
        // Allocation columns are scaled to allocatable capacity. Usage columns
        // without capacity use the largest request/limit reference so both
        // markers fit when the object is within its declared bounds; actual
        // usage can still extend beyond the track.
        if let capacity = geometryValue(value.capacity), capacity > 0 {
            return capacity
        }
        let declared = [value.request, value.limit]
            .compactMap(geometryValue)
            .filter { $0 > 0 }
        if let declaredMaximum = declared.max() {
            return declaredMaximum
        }
        if let usage = geometryValue(value.usage), usage > 0 {
            return usage
        }
        return nil
    }

    private static func geometryValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func pressure(_ value: ResourceUsageValue) -> Pressure {
        guard let usage = positiveFinite(value.usage) else { return .normal }

        // A capacity component identifies Node-style usage. The protocol's
        // capacity value is the allocatable denominator used for display;
        // scheduler request/limit aggregates have different semantics and
        // must never be substituted for missing actual usage.
        if value.capacity != nil {
            guard let capacity = positiveFinite(value.capacity) else { return .normal }
            if usage >= capacity * 0.9 { return .critical }
            if usage >= capacity * 0.8 { return .warning }
            return .normal
        }

        // Pod-style usage becomes critical only near a positive limit. A
        // request is a scheduling baseline, so crossing it is useful warning
        // pressure but is not itself a critical condition.
        let limit = positiveFinite(value.limit)
        if let limit, usage >= limit * 0.9 { return .critical }
        let warningReferences = [
            positiveFinite(value.request),
            limit,
        ].compactMap { $0 }
        return warningReferences.contains { usage >= $0 * 0.8 }
            ? .warning
            : .normal
    }

    private static func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func effectiveSeverity(
        cellSeverity: CellSeverity,
        pressure: Pressure
    ) -> CellSeverity {
        if cellSeverity == .critical || pressure == .critical { return .critical }
        if cellSeverity == .warning || pressure == .warning { return .warning }
        return cellSeverity
    }

    private static func accessibilityValue(
        title: String,
        displayText: String,
        value: ResourceUsageValue
    ) -> String {
        var parts = [title]
        if let usage = value.usage {
            parts.append("usage \(spokenQuantity(usage, value: value))")
        }
        if let request = value.request {
            parts.append("request \(spokenQuantity(request, value: value))")
        }
        if let limit = value.limit {
            parts.append("limit \(spokenQuantity(limit, value: value))")
        }
        if let capacity = value.capacity {
            parts.append("capacity \(spokenQuantity(capacity, value: value))")
        }
        if parts.count == 1 {
            let status = displayText == "—" ? "values unavailable" : displayText
            parts.append(status)
        }
        return parts.joined(separator: ", ")
    }

    private static func spokenQuantity(
        _ number: Double,
        value: ResourceUsageValue
    ) -> String {
        guard number.isFinite else { return "unavailable" }
        switch value.unit.lowercased() {
        case "cores", "core":
            if number != 0, abs(number) < 1 {
                let millicores = number * 1_000
                return "\(compact(millicores, fractionalDigits: 3)) "
                    + (isOne(millicores) ? "millicore" : "millicores")
            }
            return "\(compact(number, fractionalDigits: 3)) "
                + (isOne(number) ? "core" : "cores")
        case "bytes", "byte":
            return spokenBytes(number)
        case "count":
            if value.resourceName == "pods" {
                return "\(compact(number, fractionalDigits: 3)) "
                    + (isOne(number) ? "pod" : "pods")
            }
            return "\(compact(number, fractionalDigits: 3)) "
                + (isOne(number) ? "unit" : "units")
        case "":
            return compact(number, fractionalDigits: 3)
        default:
            return "\(compact(number, fractionalDigits: 3)) \(value.unit)"
        }
    }

    private static func spokenBytes(_ bytes: Double) -> String {
        let units: [(size: Double, singular: String, plural: String)] = [
            (pow(2, 60), "exbibyte", "exbibytes"),
            (pow(2, 50), "pebibyte", "pebibytes"),
            (pow(2, 40), "tebibyte", "tebibytes"),
            (pow(2, 30), "gibibyte", "gibibytes"),
            (pow(2, 20), "mebibyte", "mebibytes"),
            (pow(2, 10), "kibibyte", "kibibytes"),
        ]
        for unit in units where abs(bytes) >= unit.size {
            let scaled = bytes / unit.size
            let name = isOne(scaled) ? unit.singular : unit.plural
            return "\(compact(scaled, fractionalDigits: 2)) \(name)"
        }
        return "\(compact(bytes, fractionalDigits: 3)) "
            + (isOne(bytes) ? "byte" : "bytes")
    }

    private static func resourceTitle(_ resourceName: String) -> String {
        switch resourceName {
        case "cpu": return "CPU"
        case "memory": return "Memory"
        case "ephemeral-storage": return "Ephemeral storage"
        case "pods": return "Pods"
        case "": return "Resource"
        default:
            if resourceName.hasPrefix("hugepages-") {
                return "Huge pages \(resourceName.dropFirst("hugepages-".count))"
            }
            return resourceName
        }
    }

    private static func isOne(_ value: Double) -> Bool {
        abs(abs(value) - 1) < 0.000_000_1
    }

    private static func compact(_ value: Double, fractionalDigits: Int) -> String {
        guard value.isFinite else { return "unavailable" }
        var text = String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            fractionalDigits,
            value
        )
        if text.contains(".") {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
