import ControlFlowCore
import Foundation
import JavaScriptCore

/// Typesets formulas with MathJax (TeX in, SVG out), run in JavaScriptCore from the
/// bundled `cf-mathjax.js` (built by `MathJax/build.sh`). Every typesetter forwards to
/// one shared engine, so the bundle is loaded once, on the first formula.
struct MathJaxTypesetter: MathTypesetter {
    let engine = "mathjax-4.1.3/newcm"

    func typeset(_ math: MathContent) async throws(MathError) -> String {
        try await MathJaxEngine.shared.typeset(math.source, display: math.display)
    }
}

/// Owns the one `JSContext`, which isn't `Sendable` and so never leaves the actor. It
/// runs on a thread of its own with a big stack, since JavaScriptCore's interpreter
/// recurses on the thread's stack and MathJax recurses deeply on nested formulas (a
/// cooperative pool thread has 512 KB); that also keeps the bundle's load from holding
/// one of the pool's few threads.
actor MathJaxEngine {
    static let shared = MathJaxEngine()

    private nonisolated let thread = MathJaxThread()
    nonisolated var unownedExecutor: UnownedSerialExecutor { thread.asUnownedSerialExecutor() }

    private var context: JSContext?
    private var typesetFunction: JSValue?
    /// Why the bundle didn't load, so every later formula fails the same way at once.
    private var loadError: MathError?

    /// How long loading the bundle took, in seconds, once it has loaded.
    private(set) var loadSeconds: Double?

    /// MathJax's SVG for `source`, or its error ("Missing close brace").
    func typeset(_ source: String, display: Bool) throws(MathError) -> String {
        let function = try loaded()
        let interval = Signposts.canvas.beginInterval("MathJax typeset")
        defer { Signposts.canvas.endInterval("MathJax typeset", interval) }
        context?.exception = nil
        let result = function.call(withArguments: [source, display])
        if let exception = context?.exception {
            context?.exception = nil
            throw MathError(message: Self.message(exception))
        }
        guard let result, result.isString, let svg = result.toString() else {
            throw MathError(message: "MathJax returned no SVG")
        }
        return svg
    }

    /// `cfTypeset`, evaluating the bundle the first time.
    private func loaded() throws(MathError) -> JSValue {
        if let typesetFunction { return typesetFunction }
        if let loadError { throw loadError }
        let interval = Signposts.canvas.beginInterval("MathJax load")
        defer { Signposts.canvas.endInterval("MathJax load", interval) }
        let start = Date()
        guard let url = Bundle.main.url(forResource: "cf-mathjax", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw failed("MathJax isn't in the app")
        }
        guard let context = JSContext() else {
            throw failed("JavaScript isn't available")
        }
        context.name = "MathJax"
        _ = context.evaluateScript(script, withSourceURL: url)
        if let exception = context.exception {
            throw failed("MathJax didn't load: " + Self.message(exception))
        }
        guard let function = context.objectForKeyedSubscript("cfTypeset"), function.isObject else {
            throw failed("MathJax didn't load: no cfTypeset")
        }
        self.context = context
        typesetFunction = function
        loadSeconds = Date().timeIntervalSince(start)
        return function
    }

    /// Remembers why the bundle didn't load.
    private func failed(_ message: String) -> MathError {
        let error = MathError(message: message)
        loadError = error
        return error
    }

    /// The text of a JavaScript exception: an Error's `message`, or the value itself.
    private static func message(_ exception: JSValue) -> String {
        if let message = exception.objectForKeyedSubscript("message"), message.isString,
           let text = message.toString(), !text.isEmpty {
            return text
        }
        return exception.toString() ?? "MathJax failed"
    }

    #if DEBUG
    /// The checkpoint before the Math tool: loads the bundle if it isn't yet, then
    /// typesets the prototype's 200-formula benchmark. Returns the load time (nil if it
    /// had already loaded), the first formula's time and the average of the rest, in
    /// milliseconds.
    func benchmark() throws(MathError) -> (load: Double?, first: Double, average: Double) {
        let wasLoaded = typesetFunction != nil
        _ = try loaded()
        let formula = { (i: Int) in
            "\\sum_{k=0}^{\(i)} \\binom{n}{k} x^k = \\int_0^{\(i)} e^{-t^2}\\,dt + \\frac{\\pi}{\(i + 1)}"
        }
        var start = Date()
        _ = try typeset(formula(0), display: true)
        let first = Date().timeIntervalSince(start) * 1000
        start = Date()
        for i in 1...200 { _ = try typeset(formula(i), display: true) }
        let average = Date().timeIntervalSince(start) * 1000 / 200
        return (wasLoaded ? nil : (loadSeconds ?? 0) * 1000, first, average)
    }
    #endif
}

/// Runs `MathJaxEngine`'s jobs one at a time on one thread with an 8 MB stack.
final class MathJaxThread: SerialExecutor, @unchecked Sendable {
    private final class Queue: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [UnownedJob] = []
    }

    private let queue = Queue()

    init() {
        let queue = queue
        let thread = Thread { [unowned self] in
            while true {
                queue.condition.lock()
                while queue.jobs.isEmpty { queue.condition.wait() }
                let job = queue.jobs.removeFirst()
                queue.condition.unlock()
                job.runSynchronously(on: self.asUnownedSerialExecutor())
            }
        }
        thread.name = "MathJax"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.condition.lock()
        queue.jobs.append(job)
        queue.condition.signal()
        queue.condition.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
