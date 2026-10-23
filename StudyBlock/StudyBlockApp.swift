import SwiftUI

@main
struct StudyBlockApp: App {
    @StateObject private var blocker: BlockerViewModel
    @StateObject private var timer: FocusTimerController
    @StateObject private var stats: StatsStore
    @StateObject private var appBlocker: AppBlockerController
    @StateObject private var tabCloser: BrowserTabCloser
    @StateObject private var scheduler: BlockScheduleController
    @StateObject private var tasks = TaskStore()
    @StateObject private var decks = DeckStore()
    @StateObject private var notes = NotesStore()
    @StateObject private var events = EventStore()
    @StateObject private var canvas = CanvasSync()
    @Environment(\.openWindow) private var openWindow

    init() {
        let blocker = BlockerViewModel()
        let stats = StatsStore()
        _blocker = StateObject(wrappedValue: blocker)
        _stats = StateObject(wrappedValue: stats)
        _timer = StateObject(wrappedValue: FocusTimerController(blocker: blocker, stats: stats))
        _appBlocker = StateObject(wrappedValue: AppBlockerController(blocker: blocker))
        _tabCloser = StateObject(wrappedValue: BrowserTabCloser(blocker: blocker))
        _scheduler = StateObject(wrappedValue: BlockScheduleController(blocker: blocker))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(blocker)
                .environmentObject(timer)
                .environmentObject(stats)
                .environmentObject(appBlocker)
                .environmentObject(tabCloser)
                .environmentObject(scheduler)
                .environmentObject(tasks)
                .environmentObject(decks)
                .environmentObject(notes)
                .environmentObject(events)
                .environmentObject(canvas)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            if timer.isAwaitingConfirmation {
                // The session is over but still open, and the window may not
                // be. Finishing and extending have to be reachable from here.
                Text("Time's up — \(timer.overtimeLabel) over")
                Button("Finish Session") { timer.finishAwaited() }
                Menu("Keep Going") {
                    ForEach(FocusTimerController.extendMinutes, id: \.self) { extra in
                        Button("\(extra) more minutes") { timer.extend(by: extra) }
                    }
                }
            } else if timer.isPending {
                // A session set up for later still has to be visible and
                // cancellable from outside the window.
                Text("Starting in \(timer.pendingLabel)")
                Button("Start Now") { timer.startPendingNow() }
                Button("Cancel") { timer.cancelPendingStart() }
            } else if timer.isRunning {
                Text(timer.isStopwatch
                     ? "Stopwatch — \(timer.elapsedLabel) so far"
                     : "Focus session — \(timer.remainingLabel) left")
                if timer.isStopwatch {
                    // Stopping a stopwatch is its normal ending, so it banks
                    // the time rather than counting as giving up.
                    Button("Finish Session") { timer.stopStopwatch() }
                } else if timer.isLockedSession {
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
            if timer.isAwaitingConfirmation {
                Text("done").monospacedDigit()
            } else if timer.isRunning {
                Text(timer.displayLabel).monospacedDigit()
            }
            Image(systemName: blocker.isBlocking ? "shield.fill" : "shield")
        }
    }
}
