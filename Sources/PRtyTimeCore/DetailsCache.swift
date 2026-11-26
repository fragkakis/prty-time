import Foundation

/// Line counts and head branches of the PRs on show. A PR's details are fetched
/// again only when its `updatedAt` changes.
public struct DetailsCache: Sendable, Equatable {
    public private(set) var diffStats: [String: DiffStat] = [:]
    public private(set) var branches: [String: String] = [:]
    /// The `updatedAt` each PR's details were fetched at.
    private var fetchedAt: [String: Date] = [:]

    public init() {}

    /// Forgets the PRs not in `prs`, and returns those whose details are missing
    /// or older than the PR, by id with the `updatedAt` to pass to `store`.
    public mutating func outdated(keeping prs: [PullRequest]) -> [String: Date] {
        let updatedAt = Dictionary(prs.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        fetchedAt = fetchedAt.filter { updatedAt[$0.key] != nil }
        diffStats = diffStats.filter { updatedAt[$0.key] != nil }
        branches = branches.filter { updatedAt[$0.key] != nil }
        return updatedAt.filter { fetchedAt[$0.key] != $0.value }
    }

    /// Stores the details fetched for `requested` (from `outdated`). A requested
    /// PR GitHub returned nothing for isn't asked for again until it changes.
    public mutating func store(_ fetched: [String: PRDetails], requested: [String: Date]) {
        diffStats.merge(fetched.mapValues(\.diff)) { $1 }
        branches.merge(fetched.mapValues(\.branch)) { $1 }
        fetchedAt.merge(requested) { $1 }
    }
}
