import Foundation

/// Reads short decimals straight from bytes, without building a `String` for
/// `Double(text)`. Used by the JSON parser and the SVG number scanner.
///
/// A decimal with at most 15 significant digits and at most 22 digits after the point is
/// `mantissa / 10^decimals` with both operands exact in a `Double` (10^15 < 2^53, and every
/// power of ten up to 10^22 is exact), so one IEEE division rounds the true decimal value
/// correctly: the same `Double` that `Double(text)` gives. Anything else (more digits, an
/// exponent) returns nil and the caller falls back to `Double(text)`.
enum FastDecimal {
    /// 10^0 through 10^22, each exact.
    static let powersOfTen: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    /// The most significant digits the fast path takes.
    static let maxSignificantDigits = 15

    /// The value of `bytes[from..<to]`, which the caller has checked holds only ASCII digits
    /// and at most one `.` (with at least one digit), negated when `negative`. Nil when it
    /// can't be computed exactly.
    static func value(_ bytes: [UInt8], from: Int, to: Int, negative: Bool) -> Double? {
        var mantissa: UInt64 = 0
        var significant = 0
        var decimals = 0
        var afterPoint = false
        var k = from
        while k < to {
            let b = bytes[k]
            k += 1
            if b == UInt8(ascii: ".") {
                afterPoint = true
                continue
            }
            if afterPoint { decimals += 1 }
            // Leading zeros are not significant.
            if significant == 0, b == UInt8(ascii: "0") { continue }
            significant += 1
            if significant > maxSignificantDigits { return nil }
            mantissa = mantissa &* 10 &+ UInt64(b &- UInt8(ascii: "0"))
        }
        guard decimals < powersOfTen.count else { return nil }
        let magnitude = Double(mantissa) / powersOfTen[decimals]
        return negative ? -magnitude : magnitude
    }
}
