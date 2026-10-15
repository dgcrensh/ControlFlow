import Foundation
import XCTest
@testable import ControlFlowCore

/// The byte-level number readers (`FastDecimal`, the JSON parser, the SVG `NumberScanner`)
/// give exactly the `Double` that `Double(text)` gives, bit for bit, and reject what JSON's
/// grammar rejects.
final class NumberParsingTests: XCTestCase {
    /// Valid JSON numbers. The plain decimals take the fast path; the rest fall back.
    static let jsonNumbers = [
        "0", "-0", "0.0", "-0.0", "1", "-1", "7", "10", "0.5", "-0.5", "0.0001", "-0.0001", "0.1", "0.2", "0.3",
        "1.5", "12.3456", "-12.3456", "123.4", "1000", "1024.0001", "3.1416", "-3.1416", "0.0625", "99.9999",
        "180", "-180", "359.9999", "0.0003", "1234.5678", "65535", "0.30000000000000004",
        // The largest 15-digit values, and around them.
        "999999999999999", "-999999999999999", "99999999999999.9", "9999999999.99999", "0.999999999999999",
        "0.000000000000001", "123456789012345", "1234567890.12345", "9007199254740991", "9007199254740993",
        "1234567890123456", "12345678901234567890", "0.1234567890123456789",
        // Long runs of zeros.
        "100000000000000000000000", "0.0000000000000000000001", "0.00000000000000000000001", "1.000000000000000000000000",
        // Exponents (always the fallback).
        "1e0", "1E5", "-2.5e-3", "1e+10", "1e-10", "6.02214076e23", "1e308", "1.7976931348623157e308", "5e-324",
        "1e-400", "0e0", "-0e0",
    ]

    /// Forms that JSON's grammar rejects (the old `isValidNumber` rejected all of these).
    static let invalidJSONNumbers = [
        "-", "+1", "01", "-01", "00", ".5", "-.5", "5.", "1.", "1.e5", "1e", "1e+", "1e-", "1E", "--1", "1-2", "1+2",
        "1.2.3", "1e5.5", "1ee5", "+", ".", "e5", "-e5", "1.5e", "Infinity", "NaN", "-Infinity", "1e5e5",
    ]

    func testFastDecimalMatchesDoubleOfText() throws {
        var fast = 0
        for text in Self.jsonNumbers where !text.contains("e") && !text.contains("E") {
            let bytes = Array(text.utf8)
            let negative = bytes.first == UInt8(ascii: "-")
            guard let value = FastDecimal.value(bytes, from: negative ? 1 : 0, to: bytes.count, negative: negative) else {
                continue
            }
            fast += 1
            let expected = try XCTUnwrap(Double(text))
            XCTAssertEqual(value.bitPattern, expected.bitPattern, text)
        }
        // Most of the table goes through the fast path, so the comparison above means something.
        XCTAssertGreaterThanOrEqual(fast, 40)
        // -0 keeps its sign.
        XCTAssertEqual(FastDecimal.value(Array("0".utf8), from: 0, to: 1, negative: true)?.sign, .minus)
        // Past 15 significant digits or 22 decimals it declines rather than rounding twice.
        XCTAssertNil(FastDecimal.value(Array("1234567890123456".utf8), from: 0, to: 16, negative: false))
        XCTAssertNil(FastDecimal.value(Array("0.00000000000000000000001".utf8), from: 0, to: 25, negative: false))
        XCTAssertNotNil(FastDecimal.value(Array("999999999999999".utf8), from: 0, to: 15, negative: false))
    }

    /// Random decimals of every length the fast path takes, as the format writes them.
    func testRandomDecimalsMatchDoubleOfText() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let digits = Int.random(in: 1...15, using: &generator)
            var text = String((0..<digits).map { _ in Character(String(Int.random(in: 0...9, using: &generator))) })
            let point = Int.random(in: 0...digits, using: &generator)
            if point < digits {
                text.insert(".", at: text.index(text.startIndex, offsetBy: point == 0 ? 0 : point))
                if point == 0 { text = "0" + text }
            }
            // JSON allows no leading zeros.
            while text.count > 1, text.hasPrefix("0"), !text.hasPrefix("0.") { text.removeFirst() }
            if Bool.random(using: &generator) { text = "-" + text }
            let expected = try XCTUnwrap(Double(text), text)
            guard case .number(let value) = try JSONValue(parsing: text) else { return XCTFail(text) }
            XCTAssertEqual(value.bitPattern, expected.bitPattern, text)
            var scanner = NumberScanner(text)
            XCTAssertEqual(scanner.number()?.bitPattern, expected.bitPattern, text)
        }
    }

    func testJSONNumbersMatchDoubleOfText() throws {
        for text in Self.jsonNumbers {
            let expected = try XCTUnwrap(Double(text), text)
            for document in [text, " \(text) ", "[\(text)]", "{\"a\":\(text)}", "[\n\t\(text)\r\n,1]"] {
                let value = try JSONValue(parsing: document)
                let number: Double?
                switch value {
                case .number(let n): number = n
                case .array(let items): if case .number(let n) = items[0] { number = n } else { number = nil }
                case .object(let members): if case .number(let n) = members[0].value { number = n } else { number = nil }
                default: number = nil
                }
                XCTAssertEqual(number?.bitPattern, expected.bitPattern, document)
            }
        }
    }

    func testInvalidJSONNumbersAreRejected() {
        for text in Self.invalidJSONNumbers {
            XCTAssertThrowsError(try JSONValue(parsing: text), text) { error in
                XCTAssertEqual((error as? JSONParseError)?.message, "Invalid value", text)
            }
            XCTAssertThrowsError(try JSONValue(parsing: "[1, \(text)]"), text) { error in
                // The error points at the start of the number, as before.
                XCTAssertEqual((error as? JSONParseError)?.offset, 4, text)
            }
        }
    }

    /// SVG numbers allow a leading `+` or `.`, a trailing `.`, and exponents; each must read
    /// as `Double` reads the same number written out in full.
    func testSVGNumbersMatchDoubleOfText() throws {
        let cases: [(String, String)] = [
            ("0", "0"), ("-0", "-0"), ("+0", "0"), ("12", "12"), ("-3.25", "-3.25"), ("+7.5", "7.5"), (".5", "0.5"),
            ("-.5", "-0.5"), ("+.5", "0.5"), ("5.", "5.0"), ("-5.", "-5.0"), ("0.0001", "0.0001"),
            ("999999999999999", "999999999999999"), ("1234567890123456789", "1234567890123456789"),
            ("1e3", "1e3"), ("1.5E-2", "1.5E-2"), (".5e1", "0.5e1"), ("5.e1", "5.0e1"), ("-2.5e+3", "-2.5e+3"),
            ("0.30000000000000004", "0.30000000000000004"),
        ]
        for (svg, full) in cases {
            var scanner = NumberScanner(svg)
            let value = try XCTUnwrap(scanner.number(), svg)
            XCTAssertTrue(scanner.isAtEnd, svg)
            XCTAssertEqual(value.bitPattern, try XCTUnwrap(Double(full)).bitPattern, svg)
        }
        // Numbers run into each other the way path data writes them.
        var scanner = NumberScanner("M10-5.5.5,1e2-.25+3")
        _ = scanner.command()
        XCTAssertEqual(scanner.numbers(), [10, -5.5, 0.5, 100, -0.25, 3])
        // An exponent without digits isn't part of the number.
        scanner = NumberScanner("2e")
        XCTAssertEqual(scanner.number(), 2)
        XCTAssertFalse(scanner.isAtEnd)
        for bad in ["", ".", "-", "+", "e5", "-e5", "+-1"] {
            var scanner = NumberScanner(bad)
            XCTAssertNil(scanner.number(), bad)
        }
    }
}
