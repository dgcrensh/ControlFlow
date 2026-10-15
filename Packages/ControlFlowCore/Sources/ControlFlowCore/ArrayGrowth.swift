import Foundation

extension Array {
    /// Makes room for `count` more elements, growing geometrically. `reserveCapacity`
    /// on its own allocates exactly what it is asked for, so calling it before each of
    /// many appends to one array copies the whole array every time.
    mutating func reserveAdditional(_ count: Int) {
        let needed = self.count + count
        guard needed > capacity else { return }
        reserveCapacity(Swift.max(needed, capacity * 2))
    }
}
