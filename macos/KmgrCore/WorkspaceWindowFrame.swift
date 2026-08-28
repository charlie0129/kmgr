import Foundation

/// A workspace window's global AppKit frame, kept independently of AppKit's
/// named-frame preferences. Coordinates are intentionally signed: a display
/// to the left or below the primary display has a negative global origin.
public struct WorkspaceWindowFrame: Codable, Hashable, Sendable {
    public static let maximumCoordinateMagnitude = 1_000_000_000.0
    public static let maximumDimension = 65_536.0

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite
            && x >= -Self.maximumCoordinateMagnitude
            && x <= Self.maximumCoordinateMagnitude
            && y >= -Self.maximumCoordinateMagnitude
            && y <= Self.maximumCoordinateMagnitude
            && width.isFinite && height.isFinite
            && width > 0 && width <= Self.maximumDimension
            && height > 0 && height <= Self.maximumDimension
    }
}
