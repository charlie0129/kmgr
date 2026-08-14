import Foundation

/// Formats the normalized numeric values carried by `ResourceUsageValue`
/// using the same compact units Kubernetes users expect from quantities.
///
/// This is presentation-only: callers retain the original `Double` for
/// geometry and sorting, and retain the exact resource name independently.
public enum KubernetesResourceQuantityFormatter {
    public static func compact(_ value: Double, unit: String) -> String {
        guard value.isFinite else { return "Unavailable" }

        switch unit.lowercased() {
        case "core", "cores":
            return compactCPU(value)
        case "byte", "bytes":
            return compactBytes(value)
        case "", "count":
            return compactDecimal(value, fractionalDigits: 3)
        default:
            return "\(compactDecimal(value, fractionalDigits: 3)) \(unit)"
        }
    }

    private static func compactCPU(_ cores: Double) -> String {
        if cores == 0 { return "0" }
        if abs(cores) < 1 {
            return compactDecimal(cores * 1_000, fractionalDigits: 3) + "m"
        }
        return compactDecimal(cores, fractionalDigits: 3)
    }

    private static func compactBytes(_ bytes: Double) -> String {
        if bytes == 0 { return "0" }
        let units: [(size: Double, suffix: String)] = [
            (pow(2, 60), "Ei"),
            (pow(2, 50), "Pi"),
            (pow(2, 40), "Ti"),
            (pow(2, 30), "Gi"),
            (pow(2, 20), "Mi"),
            (pow(2, 10), "Ki"),
        ]
        for unit in units where abs(bytes) >= unit.size {
            return compactDecimal(bytes / unit.size, fractionalDigits: 2) + unit.suffix
        }
        return compactDecimal(bytes, fractionalDigits: 3)
    }

    private static func compactDecimal(
        _ value: Double,
        fractionalDigits: Int
    ) -> String {
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
