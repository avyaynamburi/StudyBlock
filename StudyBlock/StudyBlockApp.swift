import SwiftUI

@main
struct StudyBlockApp: App {
    @StateObject private var blocker: BlockerViewModel
    @StateObject private var timer: FocusTimerController
    @StateObject private var stats: StatsStore
    @StateObject private var appBlocker: AppBlockerController
    @StateObject private var tabCloser: BrowserTabCloser
    @StateObject private var tasks = TaskStore()
    @StateObject private var decks = DeckStore()
    @StateObject private var notes = NotesStore()
    @Environment(\.openWindow) private var openWindow

    init() {
        let blocker = BlockerViewModel()
        let stats = StatsStore()
        _blocker = StateObject(wrappedValue: blocker)
        _stats = StateObject(wrappedValue: stats)
        _timer = StateObject(wrappedValue: FocusTimerController(blocker: blocker, stats: stats))
        _appBlocker = StateObject(wrappedValue: AppBlockerController(blocker: blocker))
        _tabCloser = StateObject(wrappedValue: BrowserTabCloser(blocker: blocker))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(blocker)
                .environmentObject(timer)
                .environmentObject(stats)
                .environmentObject(appBlocker)
                .environmentObject(tabCloser)
                .environmentObject(tasks)
                .environmentObject(decks)
                .environmentObject(notes)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            if timer.isRunning {
                Text("Focus session — \(timer.remainingLabel) left")
                if timer.isLockedSession {
                    Text("Locked until \(timer.lockedUntilLabel)")
                } else {
                    Button("Give Up Session") { timer.giveUp() }
                }
            } else {
                Text(blocker.isBlocking
                     ? "Blocking \(blocker.domains.count) website\(blocker.domains.count == 1 ? "" : "s")"
                     : "Not blocking")
                Button("Start 25 min Session") { timer.start(minutes: 25) }
                Button(blocker.isBlocking ? "Stop Blocking" : "Start Blocking") {
                    Task { await blocker.toggleBlocking() }
                }
                .disabled(!blocker.canToggle)
            }
            Divider()
            Button("Open StudyBlock") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit StudyBlock") { NSApplication.shared.terminate(nil) }
        } label: {
            if timer.isRunning {
                Text(timer.remainingLabel).monospacedDigit()
            }
            Image(systemName: blocker.isBlocking ? "shield.fill" : "shield")
        }
    }
}
