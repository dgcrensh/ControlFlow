import Foundation

/// An sRGB color with straight (non-premultiplied) alpha, components in 0...1.
/// Serializes as `#RRGGBBAA`, the file format's color format.
public struct RGBAColor: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    /// The same color with alpha `a`.
    public func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: a) }

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let ink = RGBAColor(r: 0x22 / 255, g: 0x22 / 255, b: 0x22 / 255)

    /// Parses `#RRGGBB` or `#RRGGBBAA` (the leading `#` is optional).
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        let rgba = s.count == 6 ? (value << 8) | 0xFF : value
        self.init(
            r: Double((rgba >> 24) & 0xFF) / 255,
            g: Double((rgba >> 16) & 0xFF) / 255,
            b: Double((rgba >> 8) & 0xFF) / 255,
            a: Double(rgba & 0xFF) / 255
        )
    }

    /// `#RRGGBBAA`, uppercase.
    public var hexString: String {
        func byte(_ v: Double) -> String {
            let hex = String(Int((min(max(v, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }
        return "#" + byte(r) + byte(g) + byte(b) + byte(a)
    }
}

extension RGBAColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBAColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid color \(text)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
