import SwiftUI
import UniformTypeIdentifiers

struct FocusView: View {
    @EnvironmentObject private var model: BlockerViewModel
    @EnvironmentObject private var timer: FocusTimerController
    @EnvironmentObject private var appBlocker: AppBlockerController
    @EnvironmentObject private var tabCloser: BrowserTabCloser
    @EnvironmentObject private var tasks: TaskStore
    @AppStorage("lockSessions") private var lockSessions = false
    /// Typed rather than stepped. Held as text so a half-finished entry is
    /// the user's business, not something to be rounded into a number.
    @State private var minutesText = "30"
    @AppStorage("focusModeChoice") private var modeChoice = FocusMode.timer.rawValue
    /// Per-list text for the "add a website" field, keyed by group.
    @State private var draftDomain: [UUID: String] = [:]
    @State private var expandedGroups: Set<UUID> = []
    @State private var renamingGroup: BlockGroup?
    @State private var groupNameDraft = ""
    @State private var showingNewGroup = false
    @State private var deletingGroup: BlockGroup?
    @State private var showingAppPicker = false
    @State private var showingUnlockChallenge = false
    @State private var showingTaskPrompt = false

    var body: some View {
        page
            // On the page, not the idle card: starting the session takes that
            // card off screen, and a sheet presented from a view that is
            // being removed is a sheet that can get stuck.
            .sheet(isPresented: $showingTaskPrompt) {
                SessionTaskSheet(tasks: tasks.items,
                                 courseColor: { tasks.color(for: $0) },
                                 onStart: { beginSession(on: $0) },
                                 onCreate: { tasks.addWorkingOn(title: $0) })
            }
    }

    private var page: some View {
        VStack(spacing: 0) {
            PageHeader("Focus", subtitle: model.isBlocking
                       ? "Blocking \(model.domains.count) website\(model.domains.count == 1 ? "" : "s")"
                       : "Websites and apps are blocked while a session runs")

            ScrollView {
                VStack(spacing: 20) {
                    timerCard.sectionDivider()

                    if model.helperState != .ready {
                        helperBanner(icon: "gearshape.2.fill",
                                     tint: Theme.amber,
                                     softTint: Theme.amberSoft,
                                     message: bannerMessage,
                                     buttonTitle: bannerButtonTitle) { model.setUpHelper() }
                    } else if model.helperOutdated || model.helperUnreachable {
                        helperBanner(icon: "arrow.triangle.2.circlepath",
                                     tint: Theme.amber,
                                     softTint: Theme.amberSoft,
                                     message: model.helperUnreachable
                                     ? "The background helper isn't responding — an update changed the app's identity, so it needs one re-approval. Click below, then switch StudyBlock on in System Settings."
                                     : "StudyBlock was updated, but the background helper is still running the old version. Restart it to apply the fix.",
                                     buttonTitle: "Update Helper") { model.updateHelper() }
                    }

                    if timer.helperStuckWarning {
                        helperStuckBanner
                    }

                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    if let hint = tabCloser.permissionHint {
                        Label(hint, systemImage: "hand.raised")
                            .font(Theme.ui(12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    shieldCard.sectionDivider()
                    blockedAppsCard
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Timer hero

    private var timerCard: some View {
        VStack(spacing: 18) {
            if timer.isRunning {
                runningTimer
            } else {
                idleTimer
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 28)
    }

    private var runningTimer: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Theme.accentSoft, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: timer.ringProgress)
                    .stroke(Theme.accentFill, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: timer.ringProgress)

                VStack(spacing: 2) {
                    Text(timer.displayLabel)
                        .font(Theme.number(timer.displayLabel.count > 5 ? 36 : 44))
                        .monospacedDigit()
                        .foregroundStyle(timer.isAwaitingConfirmation ? Theme.success : .primary)
                    Text(ringCaption)
                        .font(Theme.ui(10, .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, 4)

            if let taskTitle = timer.currentTaskTitle {
                TagChip(text: taskTitle, color: Theme.accent)
            }

            Text(timerCaption)
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if timer.isAwaitingConfirmation {
                awaitingControls
            } else if timer.isLockedSession {
                VStack(spacing: 8) {
                    Label("Locked until \(timer.lockedUntilLabel) — no giving up", systemImage: "lock.fill")
                        .font(Theme.ui(12, .medium))
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Button("Unlock early…") { showingUnlockChallenge = true }
                        .buttonStyle(.plain)
                        .font(Theme.ui(10))
                        .foregroundStyle(.tertiary)
                }
            } else if timer.isStopwatch {
                // Stopping a stopwatch is how it is meant to end, so this is
                // the finish button, not an admission of defeat.
                Button {
                    timer.stopStopwatch()
                } label: {
                    Label("Finish Session", systemImage: "flag.checkered")
                }
                .buttonStyle(ProminentPillButtonStyle(size: .large))
                .help("Records \(timer.elapsedMinutes) minutes of focus and releases the block")
            } else {
                Button("Give Up") { timer.giveUp() }
                    .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
            }
        }
        .sheet(isPresented: $showingUnlockChallenge) {
            UnlockChallengeSheet()
        }
    }

    private var ringCaption: String {
        if timer.isAwaitingConfirmation { return "over" }
        return timer.isStopwatch ? "elapsed" : "remaining"
    }

    private var timerCaption: String {
        if timer.isStopwatch {
            return model.isBlocking
                ? "Stopwatch running — blocking \(model.domains.count) website\(model.domains.count == 1 ? "" : "s") until you finish"
                : "Stopwatch running — websites not blocked"
        }
        if timer.isAwaitingConfirmation {
            return model.isBlocking
                ? "Time's up — still blocking until you finish the session"
                : "Time's up — the session stays open until you finish it"
        }
        return model.isBlocking
            ? "Blocking \(model.domains.count) website\(model.domains.count == 1 ? "" : "s") until the timer ends"
            : "Timer running — websites not blocked"
    }

    /// Shown when a task session has run out. It deliberately doesn't end
    /// itself, so this is the only way out — finish it, or buy more time.
    private var awaitingControls: some View {
        VStack(spacing: 12) {
            Label("Time's up on this task", systemImage: "checkmark.circle")
                .font(Theme.ui(12, .medium))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.successSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(spacing: 7) {
                Text("Keep going")
                    .font(Theme.ui(10, .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(FocusTimerController.extendMinutes, id: \.self) { extra in
                        Button("+\(extra)m") { timer.extend(by: extra) }
                            .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
                    }
                }
            }

            Button {
                timer.finishAwaited()
            } label: {
                Label("Finish Session", systemImage: "flag.checkered")
            }
            .buttonStyle(ProminentPillButtonStyle(size: .large))
            .help("Records \(timer.elapsedMinutes) minutes of focus and releases the block")
        }
    }

    private var idleTimer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Start a focus session")
                    .font(Theme.ui(20, .semibold))
                Text(focusMode == .stopwatch
                     ? "Counts up until you stop it. Distracting websites and apps stay blocked the whole time."
                     : "Distracting websites and apps are blocked automatically while the timer runs.")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            modePicker

            if focusMode == .timer {
                HStack(spacing: 10) {
                    ForEach(FocusTimerController.presetMinutes, id: \.self) { minutes in
                        Button("\(minutes) min") { minutesText = String(minutes) }
                            .buttonStyle(SoftPillButtonStyle(
                                tint: typedMinutes == minutes ? Theme.accent : nil))
                    }
                }
            }

            HStack(spacing: 12) {
                if focusMode == .timer { minutesField }

                Button {
                    startSession()
                } label: {
                    Label(focusMode == .stopwatch ? "Start Stopwatch" : "Start",
                          systemImage: "play.fill")
                }
                .buttonStyle(ProminentPillButtonStyle(size: .large))
                .keyboardShortcut(.defaultAction)
                .disabled(focusMode == .timer && typedMinutes == nil)
            }


            // A lock is the helper being told when to let go, so there is
            // nothing to offer a session with no end.
            if focusMode == .timer {
                VStack(spacing: 6) {
                    Toggle(isOn: $lockSessions) {
                        Text("Lock sessions — no giving up until time is up")
                            .font(Theme.ui(12))
                    }
                    .toggleStyle(CheckToggleStyle())

                    if lockSessions {
                        Text("The helper enforces the lock: quitting the app, editing /etc/hosts, or rebooting won't unblock early. Max 8 hours.")
                            .font(Theme.ui(10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                }
            }
        }
    }

    private var focusMode: FocusMode {
        FocusMode(rawValue: modeChoice) ?? .timer
    }

    /// Timer or stopwatch. Two pills rather than a segmented control, so it
    /// matches the preset row directly beneath it.
    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(FocusMode.allCases) { mode in
                Button {
                    modeChoice = mode.rawValue
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
                .buttonStyle(SoftPillButtonStyle(tint: focusMode == mode ? Theme.accent : nil))
            }
        }
    }

    /// What Start will use, or nil while the box holds something unusable —
    /// which disables Start rather than quietly substituting a number the
    /// user didn't ask for.
    private var typedMinutes: Int? {
        let trimmed = minutesText.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), (1...600).contains(value) else { return nil }
        return value
    }

    /// The duration box: typed, not stepped. Keeps the stepper's shell — the
    /// same low surface, hairline and corner radius — so only the innards
    /// changed.
    private var minutesField: some View {
        HStack(spacing: 5) {
            TextField("30", text: $minutesText)
                .textFieldStyle(.plain)
                .font(Theme.number(15, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .onSubmit(startSession)
            Text("min")
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(typedMinutes == nil ? Theme.danger : Theme.stroke, lineWidth: 1))
    }

    /// Start always goes through the question first. A session that knows
    /// what it is for is the one that can credit the right subject and ask
    /// the right thing when it ends; one started blind can do neither, and
    /// the sheet's "Just Focus" is there for when that is genuinely the
    /// answer.
    private func startSession() {
        guard focusMode == .stopwatch || typedMinutes != nil else { return }
        showingTaskPrompt = true
    }

    private func beginSession(on task: TodoItem?) {
        switch focusMode {
        case .stopwatch:
            timer.startStopwatch(task: task)
        case .timer:
            guard let typedMinutes else { return }
            timer.start(minutes: typedMinutes, task: task, locked: lockSessions)
        }
    }

    // MARK: - Helper banners

    private func helperBanner(icon: String, tint: Color, softTint: Color, message: String,
                              buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(softTint).frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(Theme.ui(12))
                    .fixedSize(horizontal: false, vertical: true)
                Button(buttonTitle, action: action)
                    .buttonStyle(SoftPillButtonStyle(tint: tint))
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    /// Shown after the locked-session safety valve trips (helper silent for
    /// 10+ minutes): the app gave up waiting and cleared its own lock state,
    /// but can't guarantee the hosts-file block actually lifted — only the
    /// helper can do that, so this points at reviving it.
    private var helperStuckBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Theme.dangerSoft).frame(width: 38, height: 38)
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.danger)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("The blocking helper stopped responding for over 10 minutes, so this locked session's local timer was cleared automatically. Websites may still be blocked until the helper is back — use \u{201C}Update Helper\u{201D} above if it reappears, or check Website Shield below.")
                    .font(Theme.ui(12))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { timer.acknowledgeHelperStuckWarning() }
                    .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    private var bannerMessage: String {
        switch model.helperState {
        case .requiresApproval:
            return "Approve the StudyBlock helper in System Settings → General → Login Items & Extensions."
        case .notFound:
            return "The helper isn't installed. Make sure StudyBlock is running from /Applications, then set up."
        default:
            return "One-time setup: StudyBlock needs a small background helper to block websites system-wide."
        }
    }

    private var bannerButtonTitle: String {
        model.helperState == .requiresApproval ? "Open System Settings" : "Set Up Helper"
    }

    // MARK: - Website shield

    /// The pending unblock, while it is pending. Deliberately the loudest
    /// thing on the card: it is the one moment the app is asking you to sit
    /// still for half a minute.
    private var cooldownBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unblocking in \(model.unblockCountdownLabel)")
                    .font(Theme.ui(12, .semibold))
                    .monospacedDigit()
                Text("Still time to change your mind.")
                    .font(Theme.ui(10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep Blocking") { model.cancelUnblock() }
                .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var cooldownSetting: some View {
        HStack(spacing: 8) {
            Text("Wait before unblocking")
                .font(Theme.ui(10))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(BlockerViewModel.cooldownChoices, id: \.self) { seconds in
                    Button {
                        model.unblockCooldownSeconds = seconds
                    } label: {
                        if seconds == model.unblockCooldownSeconds {
                            Label(BlockerViewModel.cooldownLabel(seconds), systemImage: "checkmark")
                        } else {
                            Text(BlockerViewModel.cooldownLabel(seconds))
                        }
                    }
                }
            } label: {
                Text(BlockerViewModel.cooldownLabel(model.unblockCooldownSeconds))
                    .font(Theme.ui(10, .medium))
            }
            .menuStyle(.button)
            .buttonStyle(SoftPillButtonStyle())
            .fixedSize()
            Spacer()
        }
    }

    private var shieldCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: Binding(
                get: { model.isBlocking },
                set: { _ in Task { await model.toggleBlocking() } }
            )) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(model.isBlocking ? Theme.accentFill : Theme.surfaceLow)
                            .frame(width: 36, height: 36)
                        Image(systemName: model.isBlocking ? "shield.fill" : "shield")
                            .font(Theme.ui(15, .semibold))
                            .foregroundStyle(model.isBlocking ? .white : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Block distracting websites")
                            .font(Theme.ui(15, .semibold))
                        Text(shieldSubtitle)
                            .font(Theme.ui(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(GlowToggleStyle())
            .disabled(!model.canToggle || timer.isRunning || model.isCoolingDown)

            if model.isCoolingDown {
                cooldownBanner
            } else {
                cooldownSetting
            }

            Divider().overlay(Theme.stroke)

            if model.groups.isEmpty {
                Text("No lists yet — make one and add the sites that distract you.")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider().overlay(Theme.stroke)
                        }
                        groupRow(group)
                    }
                }
            }

            Button {
                groupNameDraft = ""
                showingNewGroup = true
            } label: {
                Label("New List", systemImage: "plus")
            }
            .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
        }
        .card()
        .alert("New block list", isPresented: $showingNewGroup) {
            TextField("Name — e.g. Social, Games, News", text: $groupNameDraft)
            Button("Create") { model.addGroup(named: groupNameDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A list you can switch on and off on its own. Sites in it are blocked whenever it\u{2019}s on and blocking is running.")
        }
        .alert("Rename list", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Name", text: $groupNameDraft)
            Button("Rename") {
                if let group = renamingGroup { model.renameGroup(group.id, to: groupNameDraft) }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
        .confirmationDialog("Delete this list?",
                            isPresented: Binding(get: { deletingGroup != nil },
                                                 set: { if !$0 { deletingGroup = nil } })) {
            Button("Delete \u{201C}\(deletingGroup?.name ?? "")\u{201D}", role: .destructive) {
                if let group = deletingGroup { model.deleteGroup(group.id) }
                deletingGroup = nil
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            Text("\(deletingGroup?.domains.count ?? 0) site\(deletingGroup?.domains.count == 1 ? "" : "s") "
                 + "would stop being blocked. Switching the list off instead keeps it for later.")
        }
    }

    /// One block list: a header that toggles the whole list on or off, and an
    /// expandable body holding its sites.
    @ViewBuilder
    private func groupRow(_ group: BlockGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expandedGroups.remove(group.id) }
                        else { expandedGroups.insert(group.id) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(Theme.ui(9, .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(group.name)
                            .font(Theme.ui(14, .semibold))
                            .foregroundStyle(group.isEnabled ? .primary : .secondary)
                        Text("\(group.domains.count)")
                            .font(Theme.ui(10, .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Menu {
                    Button("Rename\u{2026}") {
                        groupNameDraft = group.name
                        renamingGroup = group
                    }
                    Divider()
                    Button("Delete List", role: .destructive) { deletingGroup = group }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Theme.ui(11, .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Toggle("", isOn: Binding(
                    get: { group.isEnabled },
                    set: { model.setGroup(group.id, enabled: $0) }
                ))
                .toggleStyle(GlowToggleStyle())
                .labelsHidden()
                .help(group.isEnabled
                      ? "On — these sites are part of the block"
                      : "Off — these sites are left out")
            }

            if isExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                    TextField("Add a website — e.g. youtube.com", text: Binding(
                        get: { draftDomain[group.id] ?? "" },
                        set: { draftDomain[group.id] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit { addDomain(to: group) }
                    Button("Add") { addDomain(to: group) }
                        .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
                        .disabled((draftDomain[group.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

                if group.domains.isEmpty {
                    Text("No websites in this list yet.")
                        .font(Theme.ui(12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(group.domains, id: \.self) { domain in
                            DomainChip(domain: domain) {
                                model.removeDomain(domain, from: group.id)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 11)
        .opacity(group.isEnabled ? 1 : 0.55)
    }

    private var shieldSubtitle: String {
        if timer.isRunning { return "Managed by the focus session" }
        if model.domains.isEmpty {
            if model.isBlocking { return "On — but every list is off, so nothing is blocked" }
            return model.groups.contains { !$0.domains.isEmpty }
                ? "Switch on a list below to start"
                : "Add a website to a list below to start"
        }
        let count = model.domains.count
        let sites = "\(count) site\(count == 1 ? "" : "s")"
        let enabled = model.groups.filter { $0.isEnabled && !$0.domains.isEmpty }.count
        let lists = enabled == 1 ? "1 list" : "\(enabled) lists"
        return model.isBlocking
            ? "On — \(sites) across \(lists), new connections refused"
            : "Off — \(sites) across \(lists) ready to block"
    }

    // MARK: - Blocked apps

    private var blockedAppsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Blocked apps")
                        .font(Theme.ui(15, .semibold))
                    Text("Quit automatically whenever blocking is on. StudyBlock has to be running to enforce this.")
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAppPicker = true
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
            }

            if let error = appBlocker.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.danger)
            }

            if appBlocker.apps.isEmpty {
                Text("No apps yet — add games, Discord, or whatever eats your study time.")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(appBlocker.apps) { app in
                        HStack(spacing: 10) {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(Theme.accent)
                            Text(app.name)
                                .font(Theme.ui(12, .medium))
                            Text(app.bundleID)
                                .font(Theme.ui(10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                appBlocker.remove(app)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Theme.ui(10, .semibold))
                            }
                            .buttonStyle(IconButtonStyle())
                            .help("Remove \(app.name)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if app != appBlocker.apps.last {
                            Divider().overlay(Theme.stroke).padding(.leading, 12)
                        }
                    }
                }
                .background(Theme.surfaceLow.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .card()
        .fileImporter(isPresented: $showingAppPicker,
                      allowedContentTypes: [.application],
                      allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                appBlocker.addApp(at: url)
            }
        }
    }

    private func addDomain(to group: BlockGroup) {
        model.addDomain(draftDomain[group.id] ?? "", to: group.id)
        if model.lastError == nil { draftDomain[group.id] = "" }
    }
}

private struct DomainChip: View {
    let domain: String
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(domain)
                .font(Theme.ui(12, .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Theme.ui(8, .semibold))
                    .foregroundStyle(hovering ? Theme.danger : .secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(domain)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering ? Theme.accentSoft : Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
