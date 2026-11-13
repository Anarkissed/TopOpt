// TopologyFocus — his ask 2026-11-13: Topology behaves as Lattice while a group is picked — only that group's shapes (its
// keep-clear / protect / load / anchor volumes) draw; with none picked, every group's do.
import Foundation

enum TopologyFocus {
    /// The items to draw: all of them with no group picked, else only the picked group's (order kept, so a list zipped with
    /// another filtered the same way stays aligned).
    static func only<T>(_ items: [T], active: UUID?, group: (T) -> UUID) -> [T] {
        guard let active else { return items }
        return items.filter { group($0) == active }
    }
}
