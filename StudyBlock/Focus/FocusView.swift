import SwiftUI
import UniformTypeIdentifiers

struct FocusView: View {
    @EnvironmentObject private var model: BlockerViewModel
    @EnvironmentObject private var timer: FocusTimerController
    @EnvironmentObject private var appBlocker: AppBlockerController
    @EnvironmentObject private var tabCloser: BrowserTabCloser
    @AppStorage("lockSessions") private var lockSessions = false
    @State private var customMinutes = 30
    /// Per-list text for the "add a website" field, keyed by group.
    @State private var draftDomain: [UUID: String] = [:]
    @State private var expandedGroups: Set<UUID> = []
    @State private var renamingGroup: BlockGroup?
    @State private var groupNameDraft = ""
    @State private var showingNewGroup = false
    @State private var deletingGroup: BlockGroup?
    @State private var showingAppPicker = false
    @State private var showingUnlockChallenge = false

    var body: some View {
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
                    .trim(from: 0, to: timer.progress)
                    .stroke(Theme.accentFill, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: timer.progress)

                VStack(spacing: 2) {
                    Text(timer.isAwaitingConfirmation ? timer.overtimeLabel : timer.remainingLabel)
                        .font(Theme.number(44))
                        .monospacedDigit()
                        .foregroundStyle(timer.isAwaitingConfirmation ? Theme.success : .primary)
                    Text(timer.isAwaitingConfirmation ? "over" : "remaining")
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
            } else {
                Button("Give Up") { timer.giveUp() }
                    .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
            }
        }
        .sheet(isPresented: $showingUnlockChallenge) {
            UnlockChallengeSheet()
        }
    }

    private var timerCaption: String {
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
                Text("Distracting websites and apps are blocked automatically while the timer runs.")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(FocusTimerController.presetMinutes, id: \.self) { minutes in
                    Button("\(minutes) min") { timer.start(minutes: minutes, locked: lockSessions) }
                        .buttonStyle(SoftPillButtonStyle())
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    stepperButton("minus") { customMinutes = max(5, customMinutes - 5) }
                    Text("\(customMinutes) min")
                        .font(Theme.number(15, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 68)
                    stepperButton("plus") { customMinutes = min(180, customMinutes + 5) }
                }
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))

                Button {
                    timer.start(minutes: customMinutes, locked: lockSessions)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(ProminentPillButtonStyle(size: .large))
                .keyboardShortcut(.defaultAction)
            }

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

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.ui(12, .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
            .disabled(!model.canToggle || timer.isRunning)

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
