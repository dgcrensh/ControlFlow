import Foundation

/// Fits a raw Pencil polyline to a smooth cubic Bézier path.
///
/// The polyline is lightly smoothed, split at sharp corners, and each run between
/// corners is fitted with Philip Schneider's least-squares algorithm ("An Algorithm
/// for Automatically Fitting Digitized Curves", Graphics Gems, 1990). A stroke that
/// ends near where it started becomes a closed path.
public enum CurveFitter {
    public struct Options: Hashable, Sendable {
        /// Maximum distance between the fitted curve and the (smoothed) samples.
        public var tolerance: Double
        /// Passes of a [1 2 1] smoothing filter applied before fitting.
        public var smoothingPasses: Int
        /// A stroke whose ends are this close (and that is long enough) is closed.
        public var closeDistance: Double
        /// Turns sharper than this, in degrees, become corner points.
        public var cornerAngle: Double
        /// How far either side of a sample the corner test looks.
        public var cornerRadius: Double

        public init(tolerance: Double = 1.5, smoothingPasses: Int = 1, closeDistance: Double = 16,
                    cornerAngle: Double = 80, cornerRadius: Double? = nil) {
            self.tolerance = tolerance
            self.smoothingPasses = smoothingPasses
            self.closeDistance = closeDistance
            self.cornerAngle = cornerAngle
            self.cornerRadius = cornerRadius ?? max(tolerance * 4, 4)
        }

        /// Options for a stroke drawn at `zoom` with a smoothing amount from 0 (tight) to 1 (smooth).
        /// Distances are given in screen points, so fitting feels the same at any zoom.
        public static func forSmoothing(_ amount: Double, zoom: Double) -> Options {
            let s = min(max(amount, 0), 1)
            let z = max(zoom, 1e-6)
            return Options(
                tolerance: (0.75 + s * 5.25) / z,
                smoothingPasses: Int((s * 4).rounded()),
                closeDistance: 16 / z,
                cornerAngle: 80,
                cornerRadius: (6 + s * 6) / z
            )
        }
    }

    public static func fit(_ input: [Vec2], options: Options = Options()) -> BezierPath {
        var pts = dedupe(input, minSpacing: options.tolerance * 0.1)
        guard pts.count >= 2 else {
            return BezierPath(points: pts.first.map { [PathPoint($0, smooth: false)] } ?? [], closed: false)
        }

        let length = polylineLength(pts)
        let closed = pts.count >= 4 &&
            pts[0].distance(to: pts[pts.count - 1]) <= options.closeDistance &&
            length > options.closeDistance * 4

        if closed {
            // Work on the loop without its duplicated seam.
            while pts.count > 3, pts[pts.count - 1].distance(to: pts[0]) < options.tolerance {
                pts.removeLast()
            }
            pts = smooth(pts, passes: options.smoothingPasses, cyclic: true)
            return fitClosed(pts, options: options)
        } else {
            pts = smooth(pts, passes: options.smoothingPasses, cyclic: false)
            return fitOpen(pts, options: options)
        }
    }

    // MARK: Open and closed runs

    private static func fitOpen(_ pts: [Vec2], options: Options) -> BezierPath {
        let corners = cornerIndices(pts, cyclic: false, options: options)
        let breaks = [0] + corners + [pts.count - 1]
        var curves: [CubicBezier] = []
        var cornerJoins: Set<Int> = []
        for k in 0..<(breaks.count - 1) {
            if k > 0 { cornerJoins.insert(curves.count) }
            let run = Array(pts[breaks[k]...breaks[k + 1]])
            fitRun(run, tan1: nil, tan2: nil, options: options, into: &curves)
        }
        return assemble(curves, closed: false, cornerJoins: cornerJoins)
    }

    private static func fitClosed(_ ring: [Vec2], options: Options) -> BezierPath {
        let n = ring.count
        let corners = cornerIndices(ring, cyclic: true, options: options)
        var curves: [CubicBezier] = []
        var cornerJoins: Set<Int> = []

        if corners.isEmpty {
            // One smooth loop: start and end share the tangent through the seam.
            let loop = ring + [ring[0]]
            let tangent = (ring[1] - ring[n - 1]).normalized
            let t = tangent == .zero ? (ring[1] - ring[0]).normalized : tangent
            fitRun(loop, tan1: t, tan2: -t, options: options, into: &curves)
        } else {
            // Rotate so the loop starts at a corner, then fit corner to corner.
            let start = corners[0]
            let rotated = Array(ring[start...] + ring[..<start])
            let shifted = corners.map { ($0 - start + n) % n }
            let breaks = shifted + [n]
            let loop = rotated + [rotated[0]]
            for k in 0..<(breaks.count - 1) {
                cornerJoins.insert(curves.count)
                let run = Array(loop[breaks[k]...breaks[k + 1]])
                fitRun(run, tan1: nil, tan2: nil, options: options, into: &curves)
            }
        }

        if curves.count == 1 {
            let (a, b) = curves[0].split(at: 0.5)
            curves = [a, b]
        }
        return assemble(curves, closed: true, cornerJoins: cornerJoins)
    }

    /// Fits one run of samples whose ends are fixed. Missing tangents are estimated locally.
    private static func fitRun(_ run: [Vec2], tan1: Vec2?, tan2: Vec2?, options: Options, into out: inout [CubicBezier]) {
        guard run.count >= 2 else { return }
        let reach = options.cornerRadius
        let t1 = tan1 ?? endTangent(run, fromStart: true, reach: reach)
        let t2 = tan2 ?? endTangent(run, fromStart: false, reach: reach)
        fitCubic(run, 0, run.count - 1, t1, t2, options.tolerance, depth: 0, into: &out)
    }

    private static func assemble(_ curves: [CubicBezier], closed: Bool, cornerJoins: Set<Int>) -> BezierPath {
        guard let first = curves.first, let last = curves.last else { return BezierPath() }
        var points: [PathPoint] = []
        let n = curves.count
        if closed {
            for j in 0..<n {
                let p = curves[j].p0
                let prev = curves[(j - 1 + n) % n]
                points.append(PathPoint(p, in: prev.p2 - p, out: curves[j].p1 - p, smooth: !cornerJoins.contains(j)))
            }
        } else {
            points.append(PathPoint(first.p0, in: .zero, out: first.p1 - first.p0, smooth: false))
            for j in 1..<n {
                let p = curves[j].p0
                points.append(PathPoint(p, in: curves[j - 1].p2 - p, out: curves[j].p1 - p, smooth: !cornerJoins.contains(j)))
            }
            points.append(PathPoint(last.p3, in: last.p2 - last.p3, out: .zero, smooth: false))
        }
        return BezierPath(points: points, closed: closed)
    }

    // MARK: Preprocessing

    static func dedupe(_ pts: [Vec2], minSpacing: Double) -> [Vec2] {
        var out: [Vec2] = []
        out.reserveCapacity(pts.count)
        for p in pts {
            if let last = out.last, last.distance(to: p) <= minSpacing { continue }
            out.append(p)
        }
        // Keep the true end of the stroke.
        if let end = pts.last, let last = out.last, last != end, out.count > 1 {
            out[out.count - 1] = end
        }
        return out
    }

    static func polylineLength(_ pts: [Vec2]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i].distance(to: pts[i - 1]) }
        return total
    }

    static func smooth(_ pts: [Vec2], passes: Int, cyclic: Bool) -> [Vec2] {
        let n = pts.count
        guard passes > 0, n >= 3 else { return pts }
        var cur = pts
        for _ in 0..<passes {
            var next = cur
            for i in 0..<n {
                if !cyclic, i == 0 || i == n - 1 { continue }
                let a = cur[(i - 1 + n) % n], b = cur[i], c = cur[(i + 1) % n]
                next[i] = (a + b * 2 + c) / 4
            }
            cur = next
        }
        return cur
    }

    /// Indices of sharp corners, strongest first within each neighbourhood, in ascending order.
    static func cornerIndices(_ pts: [Vec2], cyclic: Bool, options: Options) -> [Int] {
        let n = pts.count
        guard n >= 5 else { return [] }
        let r = options.cornerRadius
        let threshold = options.cornerAngle * .pi / 180

        var angles = [Double](repeating: 0, count: n)
        for i in 0..<n {
            guard let before = walk(pts, from: i, step: -1, distance: r, cyclic: cyclic),
                  let after = walk(pts, from: i, step: 1, distance: r, cyclic: cyclic)
            else { continue }
            let u = (pts[i] - before).normalized
            let v = (after - pts[i]).normalized
            guard u != .zero, v != .zero else { continue }
            angles[i] = acos(min(max(u.dot(v), -1), 1))
        }

        var corners: [Int] = []
        for i in 0..<n where angles[i] > threshold {
            // Keep only the sharpest sample within the corner radius.
            var isPeak = true
            for step in [-1, 1] {
                var j = i
                var dist = 0.0
                while true {
                    let k = j + step
                    let idx = cyclic ? (k % n + n) % n : k
                    if !cyclic, !(0..<n).contains(idx) { break }
                    if idx == i { break }
                    dist += pts[idx].distance(to: pts[j])
                    if dist > r { break }
                    if angles[idx] > angles[i] || (angles[idx] == angles[i] && idx < i) {
                        isPeak = false
                        break
                    }
                    j = idx
                }
                if !isPeak { break }
            }
            if isPeak { corners.append(i) }
        }
        return corners
    }

    /// The first sample at least `distance` along the polyline from `i`, or nil at an open end.
    private static func walk(_ pts: [Vec2], from i: Int, step: Int, distance: Double, cyclic: Bool) -> Vec2? {
        let n = pts.count
        var j = i
        var total = 0.0
        for _ in 0..<n {
            let k = j + step
            let idx = cyclic ? (k % n + n) % n : k
            if !cyclic, !(0..<n).contains(idx) { return nil }
            if idx == i { return nil }
            total += pts[idx].distance(to: pts[j])
            j = idx
            if total >= distance { return pts[j] }
        }
        return nil
    }

    /// A unit tangent at one end of a run, pointing into the run.
    private static func endTangent(_ run: [Vec2], fromStart: Bool, reach: Double) -> Vec2 {
        let n = run.count
        let origin = fromStart ? run[0] : run[n - 1]
        var target = fromStart ? run[n - 1] : run[0]
        let indices: [Int] = fromStart ? Array(1..<n) : Array((0..<(n - 1)).reversed())
        for i in indices where run[i].distance(to: origin) >= reach {
            target = run[i]
            break
        }
        let t = (target - origin).normalized
        return t == .zero ? Vec2(1, 0) : t
    }

    // MARK: Schneider fitting

    private static func fitCubic(_ d: [Vec2], _ first: Int, _ last: Int, _ tHat1: Vec2, _ tHat2: Vec2,
                                 _ error: Double, depth: Int, into out: inout [CubicBezier]) {
        let nPts = last - first + 1
        if nPts == 2 {
            let dist = d[first].distance(to: d[last]) / 3
            out.append(CubicBezier(d[first], d[first] + tHat1 * dist, d[last] + tHat2 * dist, d[last]))
            return
        }

        var u = chordLengthParameterize(d, first, last)
        var bez = generateBezier(d, first, last, u, tHat1, tHat2)
        var (maxError, split) = computeMaxError(d, first, last, bez, u)
        if maxError < error {
            out.append(bez)
            return
        }

        if maxError < error * 4 {
            for _ in 0..<4 {
                let uPrime = reparameterize(d, first, last, u, bez)
                bez = generateBezier(d, first, last, uPrime, tHat1, tHat2)
                (maxError, split) = computeMaxError(d, first, last, bez, uPrime)
                if maxError < error {
                    out.append(bez)
                    return
                }
                u = uPrime
            }
        }

        if depth > 32 {
            out.append(bez)
            return
        }

        var tCenter = (d[split - 1] - d[split + 1]).normalized
        if tCenter == .zero { tCenter = (d[split - 1] - d[split]).normalized }
        if tCenter == .zero { tCenter = tHat2 }
        fitCubic(d, first, split, tHat1, tCenter, error, depth: depth + 1, into: &out)
        fitCubic(d, split, last, -tCenter, tHat2, error, depth: depth + 1, into: &out)
    }

    private static func chordLengthParameterize(_ d: [Vec2], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        u.reserveCapacity(last - first + 1)
        for i in (first + 1)...last {
            u.append(u[u.count - 1] + d[i].distance(to: d[i - 1]))
        }
        let total = u[u.count - 1]
        if total <= 0 {
            let n = Double(u.count - 1)
            return u.indices.map { Double($0) / n }
        }
        return u.map { $0 / total }
    }

    private static func generateBezier(_ d: [Vec2], _ first: Int, _ last: Int, _ u: [Double],
                                       _ tHat1: Vec2, _ tHat2: Vec2) -> CubicBezier {
        let p0 = d[first], p3 = d[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for i in 0..<u.count {
            let t = u[i], mt = 1 - t
            let b0 = mt * mt * mt, b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t, b3 = t * t * t
            let a0 = tHat1 * b1
            let a1 = tHat2 * b2
            c00 += a0.dot(a0)
            c01 += a0.dot(a1)
            c11 += a1.dot(a1)
            let tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += a0.dot(tmp)
            x1 += a1.dot(tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alphaL = abs(det) > 1e-12 ? (x0 * c11 - x1 * c01) / det : 0
        var alphaR = abs(det) > 1e-12 ? (c00 * x1 - c01 * x0) / det : 0

        let segLength = p0.distance(to: p3)
        let epsilon = 1e-6 * segLength
        if alphaL < epsilon || alphaR < epsilon || alphaL > segLength * 3 || alphaR > segLength * 3 {
            // Least squares failed or overshot; fall back to the Wu/Barsky heuristic.
            alphaL = segLength / 3
            alphaR = segLength / 3
        }
        return CubicBezier(p0, p0 + tHat1 * alphaL, p3 + tHat2 * alphaR, p3)
    }

    private static func computeMaxError(_ d: [Vec2], _ first: Int, _ last: Int, _ bez: CubicBezier,
                                        _ u: [Double]) -> (Double, Int) {
        var maxDist = 0.0
        var split = first + (last - first + 1) / 2
        for i in (first + 1)..<last {
            let dist = bez.point(at: u[i - first]).distance(to: d[i])
            if dist >= maxDist {
                maxDist = dist
                split = i
            }
        }
        return (maxDist, split)
    }

    private static func reparameterize(_ d: [Vec2], _ first: Int, _ last: Int, _ u: [Double],
                                       _ bez: CubicBezier) -> [Double] {
        (first...last).map { i in
            let t = u[i - first]
            let q = bez.point(at: t) - d[i]
            let q1 = bez.derivative(at: t)
            let q2 = bez.secondDerivative(at: t)
            let denominator = q1.dot(q1) + q.dot(q2)
            guard abs(denominator) > 1e-12 else { return t }
            return min(max(t - q.dot(q1) / denominator, 0), 1)
        }
    }
}
