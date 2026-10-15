import Foundation

/// One subpath of SVG path data: a start point and cubic segments (lines have their
/// control points on their ends).
struct SVGSubpath: Hashable, Sendable {
    var start: Vec2
    var segments: [CubicBezier] = []
    var closed = false

    /// The subpath as an editable path: one anchor per segment end, with handles from
    /// the control points. A closing point on the start merges into it. Anchors whose
    /// handles line up are smooth (symmetric when the handles are as long). Nil with
    /// fewer than two anchors.
    var bezierPath: BezierPath? {
        var points = [PathPoint(start, in: .zero, out: .zero, mode: .corner)]
        for s in segments {
            // A segment that goes nowhere adds nothing.
            if s.p0.isApproximately(s.p3, tolerance: 1e-9), s.p1.isApproximately(s.p0, tolerance: 1e-9),
               s.p2.isApproximately(s.p3, tolerance: 1e-9) { continue }
            points[points.count - 1].outHandle = s.p1 - s.p0
            points.append(PathPoint(s.p3, in: s.p2 - s.p3, out: .zero, mode: .corner))
        }
        if closed, points.count > 2, let last = points.last,
           last.position.isApproximately(points[0].position, tolerance: 1e-6) {
            points[0].inHandle = last.inHandle
            points.removeLast()
        }
        guard points.count >= 2 else { return nil }
        let isClosed = closed && points.count >= 2
        for i in points.indices {
            let a = points[i].inHandle, b = points[i].outHandle
            let la = a.length, lb = b.length
            guard la > 1e-9, lb > 1e-9 else { continue }
            // Opposite and within about a degree of a straight line.
            if a.dot(b) < 0, abs(a.cross(b)) <= 0.02 * la * lb {
                points[i].mode = abs(la - lb) <= 0.01 * max(la, lb) ? .symmetric : .smooth
            }
        }
        return BezierPath(points: points, closed: isClosed)
    }
}

/// Reads SVG path data (`d`): every command, absolute and relative, with quadratic
/// curves and elliptical arcs turned into cubics. Like a browser, it keeps what it
/// read up to the first error.
enum SVGPathParser {
    static func parse(_ d: String) -> [SVGSubpath] {
        var scanner = NumberScanner(Array(d.utf8))
        var subpaths: [SVGSubpath] = []
        var current: SVGSubpath?
        var point = Vec2.zero
        var start = Vec2.zero
        /// The previous segment's last control point, for the smooth S and T commands.
        var lastCubic: Vec2?
        var lastQuad: Vec2?
        var command: UInt8 = 0

        func finish() {
            if let current { subpaths.append(current) }
            current = nil
        }
        func add(_ segment: CubicBezier) {
            if current == nil { current = SVGSubpath(start: segment.p0) }
            current!.segments.append(segment)
        }
        func line(to p: Vec2) { add(CubicBezier(point, point, p, p)) }

        while true {
            scanner.skipSeparators()
            if let c = scanner.command() {
                command = c
            } else if command == 0 || !scanner.atNumber {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let base = relative ? point : .zero
            func pair() -> Vec2? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return Vec2(x, y) + base
            }
            var cubic: Vec2?
            var quad: Vec2?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = pair() else { return finished(subpaths, current) }
                finish()
                point = p
                start = p
                current = SVGSubpath(start: p)
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = pair() else { return finished(subpaths, current) }
                line(to: p)
                point = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return finished(subpaths, current) }
                let p = Vec2(x + (relative ? point.x : 0), point.y)
                line(to: p)
                point = p
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return finished(subpaths, current) }
                let p = Vec2(point.x, y + (relative ? point.y : 0))
                line(to: p)
                point = p
            case UInt8(ascii: "c"):
                guard let c1 = pair(), let c2 = pair(), let p = pair() else { return finished(subpaths, current) }
                add(CubicBezier(point, c1, c2, p))
                cubic = c2
                point = p
            case UInt8(ascii: "s"):
                guard let c2 = pair(), let p = pair() else { return finished(subpaths, current) }
                let c1 = lastCubic.map { point * 2 - $0 } ?? point
                add(CubicBezier(point, c1, c2, p))
                cubic = c2
                point = p
            case UInt8(ascii: "q"):
                guard let q = pair(), let p = pair() else { return finished(subpaths, current) }
                add(quadratic(point, q, p))
                quad = q
                point = p
            case UInt8(ascii: "t"):
                guard let p = pair() else { return finished(subpaths, current) }
                let q = lastQuad.map { point * 2 - $0 } ?? point
                add(quadratic(point, q, p))
                quad = q
                point = p
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = pair()
                else { return finished(subpaths, current) }
                let pieces = arc(from: point, rx: rx, ry: ry, rotation: angle, largeArc: large, sweep: sweep, to: p)
                if pieces.isEmpty, !point.isApproximately(p, tolerance: 1e-12) { line(to: p) }
                for piece in pieces { add(piece) }
                point = p
            case UInt8(ascii: "z"):
                if current != nil {
                    if !point.isApproximately(start, tolerance: 1e-9) { line(to: start) }
                    current!.closed = true
                    finish()
                }
                point = start
                // A new subpath starts here if more drawing follows without a move.
                command = 0
            default:
                return finished(subpaths, current)
            }
            lastCubic = cubic
            lastQuad = quad
            if command == 0 {
                // After Z only a new command may follow.
                scanner.skipSeparators()
                guard let c = scanner.peekCommand() else { break }
                if c | 0x20 != UInt8(ascii: "m") { current = SVGSubpath(start: start) }
            }
        }
        return finished(subpaths, current)
    }

    private static func finished(_ subpaths: [SVGSubpath], _ current: SVGSubpath?) -> [SVGSubpath] {
        guard let current, !current.segments.isEmpty else { return subpaths.filter { !$0.segments.isEmpty } }
        return (subpaths + [current]).filter { !$0.segments.isEmpty }
    }

    /// The cubic that traces the quadratic with control point `q`.
    static func quadratic(_ p0: Vec2, _ q: Vec2, _ p3: Vec2) -> CubicBezier {
        CubicBezier(p0, p0 + (q - p0) * (2.0 / 3.0), p3 + (q - p3) * (2.0 / 3.0), p3)
    }

    /// An elliptical arc as cubics of at most a quarter turn each, following the SVG
    /// implementation notes (radii too small to reach are scaled up). Empty when the
    /// ends coincide or a radius is zero (the caller draws a line).
    static func arc(from p0: Vec2, rx: Double, ry: Double, rotation degrees: Double, largeArc: Bool,
                    sweep: Bool, to p: Vec2) -> [CubicBezier] {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 1e-12, ry > 1e-12, !p0.isApproximately(p, tolerance: 1e-12) else { return [] }
        let phi = degrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (largeArc != sweep ? 1.0 : -1.0) * (den > 0 ? max(0, num / den).squareRoot() : 0)
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let center = Vec2(cosPhi * cx1 - sinPhi * cy1 + (p0.x + p.x) / 2,
                          sinPhi * cx1 + cosPhi * cy1 + (p0.y + p.y) / 2)
        func angle(_ u: Vec2, _ v: Vec2) -> Double { atan2(u.cross(v), u.dot(v)) }
        let u = Vec2((x1 - cx1) / rx, (y1 - cy1) / ry)
        let v = Vec2((-x1 - cx1) / rx, (-y1 - cy1) / ry)
        let theta = angle(Vec2(1, 0), u)
        var delta = angle(u, v)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        func at(_ t: Double) -> Vec2 {
            Vec2(center.x + rx * cosPhi * cos(t) - ry * sinPhi * sin(t),
                 center.y + rx * sinPhi * cos(t) + ry * cosPhi * sin(t))
        }
        func tangent(_ t: Double) -> Vec2 {
            Vec2(-rx * cosPhi * sin(t) - ry * sinPhi * cos(t), -rx * sinPhi * sin(t) + ry * cosPhi * cos(t))
        }
        let count = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(count)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out: [CubicBezier] = []
        var a = p0
        for i in 0..<count {
            let t1 = theta + step * Double(i), t2 = t1 + step
            let b = i == count - 1 ? p : at(t2)
            out.append(CubicBezier(a, a + tangent(t1) * k, b - tangent(t2) * k, b))
            a = b
        }
        return out
    }
}

/// Numbers, flags and command letters in SVG path data and point lists.
struct NumberScanner {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(_ text: String) {
        self.init(Array(text.utf8))
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    var isAtEnd: Bool { i >= bytes.count }

    mutating func skipSeparators() {
        while i < bytes.count, Self.isSpace(bytes[i]) || bytes[i] == UInt8(ascii: ",") { i += 1 }
    }

    /// True when a number starts here (after separators).
    var atNumber: Bool {
        var j = i
        while j < bytes.count, Self.isSpace(bytes[j]) || bytes[j] == UInt8(ascii: ",") { j += 1 }
        guard j < bytes.count else { return false }
        let c = bytes[j]
        return Self.isDigit(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
    }

    /// The path command letter here, if any, consumed.
    mutating func command() -> UInt8? {
        guard let c = peekCommand() else { return nil }
        i += 1
        return c
    }

    func peekCommand() -> UInt8? {
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        return "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) ? c : nil
    }

    /// A number, with the separators before it. Nil (consuming nothing) when there isn't one.
    mutating func number() -> Double? {
        skipSeparators()
        let start = i
        var j = i
        let negative = j < bytes.count && bytes[j] == UInt8(ascii: "-")
        if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
        let digitsStart = j
        var digits = 0
        while j < bytes.count, Self.isDigit(bytes[j]) { j += 1; digits += 1 }
        if j < bytes.count, bytes[j] == UInt8(ascii: ".") {
            j += 1
            while j < bytes.count, Self.isDigit(bytes[j]) { j += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        var hasExponent = false
        if j < bytes.count, bytes[j] == UInt8(ascii: "e") || bytes[j] == UInt8(ascii: "E") {
            var k = j + 1
            if k < bytes.count, bytes[k] == UInt8(ascii: "-") || bytes[k] == UInt8(ascii: "+") { k += 1 }
            var expDigits = 0
            while k < bytes.count, Self.isDigit(bytes[k]) { k += 1; expDigits += 1 }
            if expDigits > 0 {
                j = k
                hasExponent = true
            }
        }
        // A plain decimal ("12", "-3.25", "+.5", "5.") straight from the bytes; exponents
        // and long mantissas go through Double(text) below.
        if !hasExponent, let value = FastDecimal.value(bytes, from: digitsStart, to: j, negative: negative) {
            i = j
            return value
        }
        var text = String(decoding: bytes[start..<j], as: UTF8.self)
        // "5." and "-.5" are numbers in SVG; give Double a digit on each side of the point.
        text = text.replacingOccurrences(of: ".e", with: ".0e").replacingOccurrences(of: ".E", with: ".0E")
        if text.hasSuffix(".") { text += "0" }
        if let dot = text.firstIndex(of: "."), dot == text.startIndex || !text[text.index(before: dot)].isNumber {
            text.insert("0", at: dot)
        }
        guard let value = Double(text), value.isFinite else { return nil }
        i = j
        return value
    }

    /// An arc flag: a lone 0 or 1, which may run straight into the next number.
    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case UInt8(ascii: "0"): i += 1; return false
        case UInt8(ascii: "1"): i += 1; return true
        default: return nil
        }
    }

    /// Every number in the text, for `points` and `viewBox` lists.
    mutating func numbers() -> [Double] {
        var out: [Double] = []
        while let n = number() { out.append(n) }
        return out
    }
}
