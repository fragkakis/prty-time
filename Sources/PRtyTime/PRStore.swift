import AppKit
import Observation
import os
import PRtyTimeCore

@MainActor @Observable
final class PRStore {
    static let shared = PRStore()

    private(set) var buckets: [Bucket: [PullRequest]] = [:]
    private(set) var unread: Set<String> = []
    private(set) var lastRefresh: Date?
    private(set) var errorMessage: String?
    private(set) var warning: String?
    private(set) var isRefreshing = false
    /// Line counts of the PRs on show, by PR id.
    private(set) var diffStats: [String: DiffStat] = [:]
    /// Head branches of the PRs on show, by PR id.
    private(set) var branches: [String: String] = [:]
    /// Checks and conflicts of the PRs on show, by PR id. Empty unless `Prefs.showChecks` is on.
    private(set) var mergeStatus: [String: MergeStatus] = [:]
    /// Snoozed PRs by id, with when they come back on their own (see `Snooze`).
    /// Not in the snapshot, which a poll replaces after awaiting GitHub: a snooze
    /// made meanwhile would be lost.
    private(set) var snoozed = UserDefaults.standard.dictionary(forKey: PRStore.snoozedKey) as? [String: Date] ?? [:] {
        didSet { UserDefaults.standard.set(snoozed, forKey: Self.snoozedKey) }
    }
    private static let snoozedKey = "snoozed"
    /// A release newer than this app, kept until the app is updated.
    private(set) var update: Release? {
        didSet { UserDefaults.standard.set(update.map { ["version": $0.version, "url": $0.url.absoluteString] }, forKey: Self.updateKey) }
    }
    private static let updateKey = "availableUpdate"
    private static let updateCheckedKey = "updateCheckedAt"
    /// The release last notified about, so each one is notified once.
    private static let notifiedUpdateKey = "notifiedUpdate"

    @ObservationIgnored private var snapshot: Snapshot?
    /// Dots cleared or put by hand while a poll runs. The poll diffs the snapshot
    /// from before them, so they're replayed onto its result.
    @ObservationIgnored private var dotChanges: [(inout Snapshot) -> Void] = []
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let poller: Poller
    @ObservationIgnored private let stateStore = StateStore()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.subsystem, category: "poll")

    private init() {
        // One client for both, so `gh auth token` runs once.
        client = GitHubClient()
        poller = Poller(github: client)
    }

    #if DEMO
    /// Shows demo data as if polled, for `Screenshot`.
    func showDemo(buckets: [Bucket: [PullRequest]], unread: Set<String>, diffStats: [String: DiffStat], mergeStatus: [String: MergeStatus], lastRefresh: Date?) {
        self.buckets = buckets
        self.unread = unread
        self.diffStats = diffStats
        self.mergeStatus = mergeStatus
        self.lastRefresh = lastRefresh
    }
    #endif

    func start() {
        snapshot = stateStore.load()
        unread = snapshot?.unread ?? []
        // Drops a saved release that's no longer newer: the app was updated.
        update = UserDefaults.standard.bool(forKey: Prefs.checkUpdates) ? Self.savedUpdate() : nil
        notifier.onOpen = { [weak self] id in self?.markRead(id) }
        notifier.activate()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Give the network a moment to come back.
                try? await Task.sleep(for: .seconds(5))
                PRStore.shared.refreshNow()
            }
        }
        restartLoop()
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        restartLoop()
    }

    func open(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
        markRead(pr.id)
    }

    /// Hides the PR until `until` or new activity, and clears its dot.
    func snooze(_ pr: PullRequest, until: Date) {
        snoozed[pr.id] = until
        markRead(pr.id)
    }

    func unsnooze(_ id: String) {
        snoozed[id] = nil
    }

    /// After the Settings toggle: turned on, checks now; turned off, forgets the release found.
    func updateChecksChanged(_ on: Bool) {
        guard on else {
            update = nil
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.updateCheckedKey)
        Task { await checkForUpdate() }
    }

    func markRead(_ id: String) {
        markRead([id])
    }

    func markRead(_ ids: some Sequence<String>) {
        let read = unread.intersection(ids)
        guard !read.isEmpty else { return }
        unread.subtract(read)
        change { $0.markRead(read) }
    }

    func markUnread(_ id: String) {
        guard unread.insert(id).inserted else { return }
        let now = Date()
        change { $0.markUnread(id, at: now) }
    }

    /// Applies a dot change to the snapshot, and keeps it for the poll running, if any.
    private func change(_ edit: @escaping (inout Snapshot) -> Void) {
        if snapshot != nil { edit(&snapshot!) }
        if isRefreshing { dotChanges.append(edit) }
        persist()
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                let delay = await poll()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Runs one poll and returns the number of seconds until the next one.
    private func poll() async -> TimeInterval {
        isRefreshing = true
        dotChanges = []
        defer {
            isRefreshing = false
            dotChanges = []
        }
        let started = Date()

        switch await poller.run(previous: snapshot, settings: Prefs.pollSettings) {
        case .cancelled(let delay):
            return delay
        case .failed(let message, let failures, let delay):
            errorMessage = message
            log.error("poll failed (\(failures)x): \(message, privacy: .public)")
            return delay
        case .updated(let poll):
            for error in poll.errors { log.error("\(error, privacy: .public)") }
            var next = poll.snapshot
            for edit in dotChanges { edit(&next) }
            dotChanges = []
            snapshot = next
            unread = next.unread
            buckets = poll.buckets
            // On a failed fetch (nil) keep showing the last ones.
            if let fresh = poll.mergeStatus, fresh != mergeStatus { mergeStatus = fresh }
            let listed = Set(poll.buckets.values.joined().map(\.id))
            let stillSnoozed = Snooze.remaining(snoozed, activity: poll.activity, listed: listed, now: Date())
            if stillSnoozed != snoozed { snoozed = stillSnoozed }
            lastRefresh = Date()
            errorMessage = nil
            warning = poll.warning
            persist()
            poll.notifications.forEach(notifier.post)
            let detailsFetched = await refreshDetails(for: poll.shown)

            let duration = String(format: "%.1f", Date().timeIntervalSince(started))
            await checkForUpdate()
            log.notice("poll ok: \(poll.summary, privacy: .public) details=\(detailsFetched) duration=\(duration, privacy: .public)s")
            return poll.delay
        }
    }

    /// Updates line counts and branches of the PRs on show. Fetched with line
    /// counts turned off too, for the menu's Copy branch name. Returns how many
    /// were requested.
    private func refreshDetails(for prs: [PullRequest]) async -> Int {
        let (details, requested, error) = await poller.refreshDetails(for: prs)
        if let error { log.error("\(error, privacy: .public)") }
        // Only assigned on change, to avoid redrawing the panel every poll.
        if details.diffStats != diffStats { diffStats = details.diffStats }
        if details.branches != branches { branches = details.branches }
        return requested
    }

    /// Looks for a newer release once a day (after a poll, when the network is
    /// up) and notifies about each new one once.
    private func checkForUpdate() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.checkUpdates),
              UpdateCheck.isDue(lastChecked: defaults.object(forKey: Self.updateCheckedKey) as? Date)
        else { return }
        // Also when it fails, so a failing check is retried tomorrow, not every poll.
        defaults.set(Date(), forKey: Self.updateCheckedKey)
        do {
            let latest = try await client.latestRelease()
            update = UpdateCheck.isNewer(latest.version, than: AppInfo.version) ? latest : nil
            if let update, defaults.string(forKey: Self.notifiedUpdateKey) != update.version {
                notifier.postUpdate(update)
                defaults.set(update.version, forKey: Self.notifiedUpdateKey)
            }
            log.notice("update check: latest=\(latest.version, privacy: .public) running=\(AppInfo.version, privacy: .public)")
        } catch {
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func savedUpdate() -> Release? {
        guard let saved = UserDefaults.standard.dictionary(forKey: updateKey),
              let version = saved["version"] as? String,
              let url = (saved["url"] as? String).flatMap(URL.init(string:)),
              UpdateCheck.isNewer(version, than: AppInfo.version)
        else { return nil }
        return Release(version: version, url: url)
    }

    private func persist() {
        guard let snapshot else { return }
        do {
            try stateStore.save(snapshot)
        } catch {
            log.error("saving state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
