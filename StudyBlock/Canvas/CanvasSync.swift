import Foundation
import SwiftUI

/// Owns the Canvas feed URL and runs syncs.
///
/// Fetch, parse and normalize all live in pure functions elsewhere; this
/// holds only the state the UI needs to show — whether a sync is running,
/// when the last one finished, and what went wrong.
@MainActor
final class CanvasSync: ObservableObject {
    /// The feed URL as the user typed it. Held in memory for the settings
    /// field; the durable copy lives in the keychain.
    @Published var feedURL: String
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastSummary: TaskStore.CanvasSyncSummary?
    @Published private(set) var lastError: CanvasFeedError?
    /// Whether course events are imported alongside assignments. Off: a room
    /// booking isn't a task. The whole path underneath is built and tested,
    /// so turning this on is the only change needed to enable it.
    @AppStorage("canvasImportsEvents") var importsEvents = false

    /// The automatic sync runs once per launch, not once per visit to the
    /// Tasks tab — `onAppear` fires every time the tab is selected.
    private var hasAutoSynced = false

    private static let lastSyncedKey = "canvasLastSyncedAt"

    init() {
        feedURL = CanvasCredential.load() ?? ""
        let stored = UserDefaults.standard.double(forKey: Self.lastSyncedKey)
        lastSyncedAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    var isConfigured: Bool {
        !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var lastSyncedLabel: String {
        guard let lastSyncedAt else { return "Never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Synced " + formatter.localizedString(for: lastSyncedAt, relativeTo: .now)
    }

    /// Saves the URL to the keychain. Returns false if the keychain refused,
    /// which the sheet surfaces rather than pretending the save worked.
    @discardableResult
    func saveURL() -> Bool {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        feedURL = trimmed
        lastError = nil
        guard !trimmed.isEmpty else { return CanvasCredential.clear() }
        return CanvasCredential.save(trimmed)
    }

    func forget() {
        CanvasCredential.clear()
        feedURL = ""
        lastError = nil
        lastSummary = nil
        lastSyncedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedKey)
    }

    /// One pull at launch, if a URL is already saved. Silent about failures:
    /// an interrupted network on startup shouldn't greet you with an alert.
    func syncOnLaunch(into store: TaskStore) async {
        guard !hasAutoSynced, isConfigured else { return }
        hasAutoSynced = true
        _ = await sync(into: store)
    }

    /// Fetch, parse, filter, merge. The error path never renders the
    /// underlying `URLError`, because that value carries the feed URL and the
    /// feed URL is a credential — see `CanvasFeedError`.
    @discardableResult
    func sync(into store: TaskStore) async -> Result<TaskStore.CanvasSyncSummary, CanvasFeedError> {
        guard !isSyncing else { return .failure(.transport) }
        isSyncing = true
        defer { isSyncing = false }
        lastError = nil

        let url: URL
        switch CanvasFeed.normalizedURL(feedURL) {
        case .success(let resolved): url = resolved
        case .failure(let error):
            lastError = error
            return .failure(error)
        }

        do {
            let data = try await CanvasFeed.fetch(url: url)
            let events = ICSParser.events(from: data)
            guard !events.isEmpty else {
                lastError = .noEvents
                return .failure(.noEvents)
            }

            let items = CanvasNormalizer.upcoming(CanvasNormalizer.normalize(events))
            let summary = store.mergeCanvas(items, includeEvents: importsEvents)
            registerCategoryColors(in: store)

            lastSummary = summary
            lastSyncedAt = Date()
            UserDefaults.standard.set(lastSyncedAt!.timeIntervalSince1970, forKey: Self.lastSyncedKey)
            return .success(summary)
        } catch let error as CanvasFeedError {
            lastError = error
            return .failure(error)
        } catch {
            // Deliberately not inspected: anything reaching here is unexpected,
            // and rendering it risks printing the URL.
            lastError = .transport
            return .failure(.transport)
        }
    }

    /// Gives the Canvas categories a fixed hue the first time they appear, so
    /// they read as one group instead of taking whatever the name happens to
    /// hash to. A hue the user has since changed is left alone.
    private func registerCategoryColors(in store: TaskStore) {
        if store.courseHues[TaskStore.canvasCategory] == nil {
            store.setHue(28, for: TaskStore.canvasCategory)
        }
        if importsEvents, store.courseHues[TaskStore.canvasEventCategory] == nil {
            store.setHue(268, for: TaskStore.canvasEventCategory)
        }
    }
}
