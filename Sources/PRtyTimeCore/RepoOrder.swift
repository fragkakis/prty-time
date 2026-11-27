import Foundation

/// The repo order arranged by dragging, one for every list in the panel.
///
/// The saved order is a list of "owner/name", top first, that only grows, so a
/// repo keeps its place while it has no PRs. A list shows its repos in that
/// order, then the repos without a place, newest activity first
/// (`groupedByRepo(order:)`). Each list shows only some repos, a different set
/// each time, so a move changes the saved order as little as it can: only the
/// moved repo changes place, and only as far as it must to sit between its new
/// neighbours. What was arranged before, also among repos not shown now, stays
/// unless the move contradicts it.
public enum RepoOrder {
    /// The saved `order` after moving `repo` to `index` of a list showing
    /// `shown`, top to bottom. Every repo the list shows gets a place, so it
    /// stays as it was left.
    public static func moving(_ repo: String, to index: Int, shown: [String], in order: [String]) -> [String] {
        guard let from = shown.firstIndex(of: repo) else { return order }
        var after = shown
        after.remove(at: from)
        after.insert(repo, at: min(max(index, 0), after.count))
        guard after != shown else { return order }

        // Repos without a place were shown below all placed ones, so that's where they go.
        let placed = Set(order)
        var order = order + after.filter { $0 != repo && !placed.contains($0) }

        // Between its new neighbours, as near as possible to where it was. A repo
        // without a place comes up from the bottom.
        let was = order.firstIndex(of: repo) ?? order.count
        order.removeAll { $0 == repo }
        let at = after.firstIndex(of: repo)!
        let low = at > 0 ? (order.firstIndex(of: after[at - 1]) ?? -1) + 1 : 0
        let high = at + 1 < after.count ? order.firstIndex(of: after[at + 1]) ?? order.count : order.count
        order.insert(repo, at: min(max(was, low), high))
        return order
    }
}
