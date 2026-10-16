import Foundation

/// Why a formula didn't typeset, in the typesetter's words ("Missing close brace").
public struct MathError: Error, Hashable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// Typesets LaTeX math to MathJax's SVG: the app's runs MathJax in JavaScriptCore; tests
/// answer from checked-in fixtures. `MathTypesetting.typesetter` is the one in use.
public protocol MathTypesetter: Sendable {
    /// Names the engine and font, such as `mathjax-4.1.3/newcm`, kept with each layout.
    var engine: String { get }
    /// `math.source` typeset in `math.display` style, as MathJax's SVG output, or the
    /// error MathJax gives. `math.size` doesn't matter here (see `MathLayout.parse`).
    func typeset(_ math: MathContent) async throws(MathError) -> String
}

/// The typesetter in use and every layout known, with the engine that made it.
///
/// Drawing never waits for a typesetter: `layout` answers from what is known, and
/// `request` typesets in the background. Layouts read from a file are kept as they are,
/// so a formula looks the same after an app update with a newer MathJax until it is
/// edited or retypeset. Nothing is evicted: a deck has at most hundreds of formulas of
/// a few kilobytes each, and an evicted layout would come back from whatever MathJax
/// the app has.
public enum MathTypesetting {
    struct Entry: Hashable, Sendable {
        var layout: MathLayout
        var engine: String
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var typesetter: (any MathTypesetter)?
        var entries: [MathContent: Entry] = [:]
        var errors: [MathContent: MathError] = [:]
        /// Formulas being typeset, with what to call when each is done.
        var waiting: [MathContent: [@Sendable () -> Void]] = [:]
        /// Bumped whenever a layout or an error is stored or forgotten.
        var generation = 0
    }

    private static let state = State()

    private static func locked<T>(_ body: (State) -> T) -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        return body(state)
    }

    /// The app sets it at launch. Without one, `request` leaves formulas unlaid out.
    public static var typesetter: (any MathTypesetter)? {
        get { locked { $0.typesetter } }
        set { locked { $0.typesetter = newValue } }
    }

    /// Bumped whenever layouts or errors are stored or forgotten, so a renderer that drew
    /// a formula without its layout knows to draw it again (see `ArtBuilder`).
    public static var generation: Int { locked { $0.generation } }

    /// The layout of `math` if it is known; never typesets.
    public static func layout(_ math: MathContent) -> MathLayout? {
        let math = math.unmorphed
        return locked { $0.entries[math]?.layout }
    }

    /// The layout of `math` and the engine that made it, if known.
    static func entry(_ math: MathContent) -> Entry? {
        let math = math.unmorphed
        return locked { $0.entries[math] }
    }

    /// The error from typesetting `math`, if it failed.
    public static func error(_ math: MathContent) -> MathError? {
        let math = math.unmorphed
        return locked { $0.errors[math] }
    }

    /// Typesets `math` unless its layout is known, it failed, or it is being typeset
    /// already; `done` runs (on any thread) once the layout or the error is known, at once
    /// when it is already. Requests for the same formula share one typeset. A blank
    /// formula (one just started with the Math tool) is never typeset, so it keeps its
    /// placeholder box until something is typed.
    public static func request(_ math: MathContent, done: @Sendable @escaping () -> Void = {}) {
        let math = math.unmorphed
        enum Next { case now, later, start(any MathTypesetter) }
        let next: Next = locked { s in
            if math.source.allSatisfy(\.isWhitespace) { return .now }
            // Known, failed, or no typesetter: nothing to wait for.
            if s.entries[math] != nil || s.errors[math] != nil { return .now }
            guard let typesetter = s.typesetter else { return .now }
            if s.waiting[math] != nil {
                s.waiting[math]!.append(done)
                return .later
            }
            s.waiting[math] = [done]
            return .start(typesetter)
        }
        guard case .start(let typesetter) = next else {
            if case .now = next { done() }
            return
        }
        Task.detached {
            let result = await typeset(math, with: typesetter)
            let callbacks: [@Sendable () -> Void] = locked { s in
                switch result {
                case .success(let layout): s.entries[math] = Entry(layout: layout, engine: typesetter.engine)
                case .failure(let error): s.errors[math] = error
                }
                s.generation += 1
                return s.waiting.removeValue(forKey: math) ?? []
            }
            for callback in callbacks { callback() }
        }
    }

    /// Requests each formula in `drawing` that has no layout yet, hasn't failed and isn't
    /// being typeset already, so a renderer can ask on every build without piling up
    /// callbacks; `done` runs as each one arrives. Nothing happens without a typesetter.
    /// Returns how many it requested.
    @discardableResult
    public static func requestMissing(in drawing: Drawing, done: @Sendable @escaping () -> Void) -> Int {
        var maths = Set<MathContent>()
        for layer in drawing.layers {
            for shape in layer.shapes {
                guard let math = shape.math else { continue }
                // A morphing formula needs both ends.
                for end in [math.unmorphed, math.morph?.from].compactMap({ $0 })
                where !end.source.allSatisfy(\.isWhitespace) { maths.insert(end) }
            }
        }
        guard !maths.isEmpty else { return 0 }
        let missing: [MathContent] = locked { s in
            guard s.typesetter != nil else { return [] }
            return maths.filter { s.entries[$0] == nil && s.errors[$0] == nil && s.waiting[$0] == nil }
        }
        for math in missing { request(math, done: done) }
        return missing.count
    }

    /// Typesets `math` and waits for it: the layout, or nil when it failed or there is no
    /// typesetter (see `error`). A known layout is returned at once.
    public static func typeset(_ math: MathContent) async -> MathLayout? {
        if let known = layout(math) { return known }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            request(math) { continuation.resume() }
        }
        return layout(math)
    }

    private static func typeset(_ math: MathContent, with typesetter: any MathTypesetter) async -> Result<MathLayout, MathError> {
        do {
            let svg = try await typesetter.typeset(math)
            return .success(try MathLayout.parse(svg: svg, content: math))
        } catch {
            return .failure(error)
        }
    }

    /// Layouts read from a file, kept as they are (each with the engine that made it).
    /// Replaces what was known of those formulas, errors included.
    public static func insert(_ layouts: [MathContent: MathLayout], engine: String) {
        locked { s in
            for (math, layout) in layouts {
                s.entries[math.unmorphed] = Entry(layout: layout, engine: engine)
                s.errors[math.unmorphed] = nil
            }
            s.generation += 1
        }
    }

    static func insert(_ entries: [MathContent: Entry]) {
        locked { s in
            for (math, entry) in entries {
                s.entries[math.unmorphed] = entry
                s.errors[math.unmorphed] = nil
            }
            s.generation += 1
        }
    }

    /// Forgets the layouts and errors of `maths`, so the next request typesets them
    /// anew (Retypeset All Formulas).
    public static func forget(_ maths: [MathContent]) {
        locked { s in
            for math in maths {
                s.entries[math.unmorphed] = nil
                s.errors[math.unmorphed] = nil
            }
            s.generation += 1
        }
    }

    /// Forgets everything, for tests.
    static func reset() {
        locked { s in
            s.entries = [:]
            s.errors = [:]
            s.generation += 1
        }
    }
}
