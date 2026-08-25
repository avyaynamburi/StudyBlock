import AppKit
import Combine
import Foundation

struct BlockedApp: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bundleID: String
}

/// Quits blocked apps while website blocking is active (manual or session).
/// Runs in the app process — if StudyBlock isn't running, apps aren't
/// enforced (websites still are, via the helper).
@MainActor
final class AppBlockerController: ObservableObject {
    @Published var apps: [BlockedApp] = [] {
        didSet { JSONStore.save(apps, to: "blocked-apps.json") }
    }
    @Published var lastError: String?

    /// Never terminate these, no matter what gets into the list.
    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systempreferences", Bundle.main.bundleIdentifier ?? "com.avyay.StudyBlock",
    ]

    private let blocker: BlockerViewModel
    private var launchObserver: NSObjectProtocol?
    private var blockingWatcher: AnyCancellable?

    init(blocker: BlockerViewModel) {
        self.blocker = blocker
        apps = JSONStore.load([BlockedApp].self, from: "blocked-apps.json") ?? []

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self.enforce(on: app) }
        }

        // Sweep already-running apps whenever blocking turns on (including
        // at launch, if a block or locked session is already active).
        blockingWatcher = blocker.$isBlocking
            .removeDuplicates()
            .sink { [weak self] isBlocking in
                guard isBlocking else { return }
                Task { @MainActor in self?.sweepRunningApps() }
            }
    }

    func addApp(at url: URL) {
        lastError = nil
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            lastError = "That doesn't look like an app."
            return
        }
        guard !Self.protectedBundleIDs.contains(bundleID) else {
            lastError = "That app can't be blocked."
            return
        }
        guard !apps.contains(where: { $0.bundleID == bundleID }) else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        apps.append(BlockedApp(name: name, bundleID: bundleID))
        if blocker.isBlocking { sweepRunningApps() }
    }

    func remove(_ app: BlockedApp) {
        apps.removeAll { $0.id == app.id }
    }

    func sweepRunningApps() {
        for running in NSWorkspace.shared.runningApplications {
            enforce(on: running)
        }
    }

    private func enforce(on app: NSRunningApplication) {
        guard blocker.isBlocking,
              let bundleID = app.bundleIdentifier,
              !Self.protectedBundleIDs.contains(bundleID),
              apps.contains(where: { $0.bundleID == bundleID }) else { return }

        app.terminate()
        // Apps with unsaved-state prompts can ignore the polite ask.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !app.isTerminated {
                app.forceTerminate()
            }
        }
    }
}
