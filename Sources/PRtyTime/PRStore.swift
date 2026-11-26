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
    /// Checks and conflicts of your PRs, by PR id. Empty unless `Prefs.showChecks` is on.
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
    @ObservationIgnored private let client = GitHubClient()
    @ObservationIgnored private let stateStore = StateStore()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    /// Feeds `diffStats` and `branches`.
    @ObservationIgnored private var details = DetailsCache()
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.subsystem, category: "poll")

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
        snapshot?.markRead(read)
        persist()
    }

    func markUnread(_ id: String) {
        guard unread.insert(id).inserted else { return }
        snapshot?.markUnread(id, at: Date())
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
        defer { isRefreshing = false }
        let defaults = UserDefaults.standard
        let interval = PollSchedule.interval(minutes: defaults.double(forKey: Prefs.pollMinutes))
        let started = Date()

        do {
            let result = try await client.poll()
            var data = result.data
            // PRs that left every list: look up which were merged.
            if let missing = snapshot?.missing(from: data), !missing.isEmpty {
                do {
                    data.closed = try await client.closedPRs(missing)
                } catch {
                    log.error("checking \(missing.count) closed PRs failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Every poll, not only for updated PRs like line counts: checks
            // finishing needn't change a PR's updatedAt.
            if defaults.bool(forKey: Prefs.showChecks) {
                let mine = data.prs(in: .mine).map(\.id)
                do {
                    data.mergeStatus = try await client.mergeStatus(mine)
                } catch {
                    data.mergeStatus = nil
                    log.error("fetching checks for \(mine.count) PRs failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let settings = Prefs.diffSettings
            let diff = ActivityDiff.run(previous: snapshot, poll: data, settings: settings)
            var next = diff.snapshot
            // Clear dots for PRs read on GitHub.
            var readOnGitHub = 0
            if let since = next.inboxFetchStart(now: Date()) {
                do {
                    let inbox = try await client.inbox(since: since)
                    readOnGitHub = next.syncRead(with: inbox, prs: data.buckets.values.flatMap { $0 })
                } catch {
                    log.error("checking GitHub notifications failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            snapshot = next
            unread = next.unread
            buckets = result.data.buckets
            // On a failed fetch (nil) keep showing the last ones.
            if let fresh = data.mergeStatus, fresh != mergeStatus { mergeStatus = fresh }
            let listed = Set(data.buckets.values.joined().map(\.id))
            let stillSnoozed = Snooze.remaining(snoozed, activity: diff.activity, listed: listed, now: Date())
            if stillSnoozed != snoozed { snoozed = stillSnoozed }
            lastRefresh = Date()
            errorMessage = nil
            let schedule = PollSchedule.afterSuccess(result, interval: interval, now: Date())
            warning = schedule.warning
            failures = 0
            persist()
            diff.notifications.forEach(notifier.post)
            let shown = MenuSections(buckets: data.buckets, staleDays: settings.staleDays, hideBots: settings.ignoreBots)
            let detailsFetched = await refreshDetails(for: shown.toReview.map(\.pr) + shown.reviewed + shown.mine)

            let duration = String(format: "%.1f", Date().timeIntervalSince(started))
            await checkForUpdate()
            log.notice("poll ok: requests=\(result.requests) closed=\(data.closed.count) readOnGitHub=\(readOnGitHub) cost=\(result.cost) remaining=\(result.rateLimit?.remaining ?? -1) details=\(detailsFetched) checks=\(data.mergeStatus?.count ?? -1) duration=\(duration, privacy: .public)s notifications=\(diff.notifications.count)")
            return schedule.delay
        } catch {
            if Task.isCancelled { return interval }
            failures += 1
            errorMessage = error.localizedDescription
            log.error("poll failed (\(self.failures)x): \(error.localizedDescription, privacy: .public)")
            return PollSchedule.retryDelay(failures: failures)
        }
    }

    /// Fetches line counts and branches for PRs that are new or updated since
    /// their last fetch, and drops the ones no longer shown. Fetched with line
    /// counts turned off too, for the menu's Copy branch name. Returns how many
    /// were requested.
    private func refreshDetails(for prs: [PullRequest]) async -> Int {
        let requested = details.outdated(keeping: prs)
        publishDetails()
        guard !requested.isEmpty else { return 0 }
        do {
            details.store(try await client.details(Array(requested.keys)), requested: requested)
            publishDetails()
        } catch {
            log.error("fetching details for \(requested.count) PRs failed: \(error.localizedDescription, privacy: .public)")
        }
        return requested.count
    }

    /// Only assigned on change, to avoid redrawing the panel every poll.
    private func publishDetails() {
        if details.diffStats != diffStats { diffStats = details.diffStats }
        if details.branches != branches { branches = details.branches }
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
