import os

/// Intervals for Instruments. They show in the Points of Interest track of the Time
/// Profiler and Metal System Trace templates, and cost next to nothing when no trace
/// is recording. See "Measuring performance" in `docs/plans/performance-audit.md`.
enum Signposts {
    static let canvas = OSSignposter(subsystem: "com.dgcrensh.ControlFlow", category: .pointsOfInterest)
}
