import SwiftUI
import UniformTypeIdentifiers

struct FocusView: View {
    @EnvironmentObject private var model: BlockerViewModel
    @EnvironmentObject private var timer: FocusTimerController
    @EnvironmentObject private var appBlocker: AppBlockerController
    @EnvironmentObject private var tabCloser: BrowserTabCloser
    @AppStorage("lockSessions") private var lockSessions = false
    @State private var customMinutes = 30
    @State private var newDomain = ""
    @State private var showingAppPicker = false
    @State private var showingUnlockChallenge = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Focus", subtitle: model.isBlocking
                       ? "Blocking \(model.domains.count) website\(model.domains.count == 1 ? "" : "s")"
                       : "Websites and apps are blocked while a session runs")

            ScrollView {
                VStack(spacing: 16) {
                    timerCard

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
                            .font(.callout)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let hint = tabCloser.permissionHint {
                        Label(hint, systemImage: "hand.raised")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    shieldCard
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
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 8)
                    .animation(.linear(duration: 1), value: timer.progress)

                VStack(spacing: 2) {
                    Text(timer.remainingLabel)
                        .font(Theme.number(44))
                        .monospacedDigit()
                    Text("remaining")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, 4)

            if let taskTitle = timer.currentTaskTitle {
                TagChip(text: taskTitle, color: Theme.accent)
            }

            Text(model.isBlocking
                 ? "Blocking \(model.domains.count) website\(model.domains.count == 1 ? "" : "s") until the timer ends"
                 : "Timer running — websites not blocked")
                .font(.callout)
                .foregroundStyle(.secondary)

            if timer.isLockedSession {
                VStack(spacing: 8) {
                    Label("Locked until \(timer.lockedUntilLabel) — no giving up", systemImage: "lock.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.amberSoft, in: Capsule())

                    Button("Unlock early…") { showingUnlockChallenge = true }
                        .buttonStyle(.plain)
                        .font(.caption)
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

    private var idleTimer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Start a focus session")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Distracting websites and apps are blocked automatically while the timer runs.")
                    .font(.callout)
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
                .background(Theme.surfaceLow, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))

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
                        .font(.callout)
                }
                .toggleStyle(CheckToggleStyle())

                if lockSessions {
                    Text("The helper enforces the lock: quitting the app, editing /etc/hosts, or rebooting won't unblock early. Max 8 hours.")
                        .font(.caption)
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
                .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.callout)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("The blocking helper stopped responding for over 10 minutes, so this locked session's local timer was cleared automatically. Websites may still be blocked until the helper is back — use \u{201C}Update Helper\u{201D} above if it reappears, or check Website Shield below.")
                    .font(.callout)
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
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(model.isBlocking ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceLow))
                            .frame(width: 36, height: 36)
                        Image(systemName: model.isBlocking ? "shield.fill" : "shield")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(model.isBlocking ? .white : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Block distracting websites")
                            .font(.system(size: 15, weight: .semibold))
                        Text(shieldSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(GlowToggleStyle())
            .disabled(!model.canToggle || timer.isRunning)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("Add a website — e.g. youtube.com", text: $newDomain)
                    .textFieldStyle(.plain)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            if model.domains.isEmpty {
                Text("No websites yet — add the ones that distract you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(model.domains, id: \.self) { domain in
                        DomainChip(domain: domain) {
                            if let index = model.domains.firstIndex(of: domain) {
                                model.removeDomains(at: IndexSet(integer: index))
                            }
                        }
                    }
                }
            }
        }
        .card()
    }

    private var shieldSubtitle: String {
        if timer.isRunning { return "Managed by the focus session" }
        if model.domains.isEmpty && !model.isBlocking { return "Add at least one website below to start" }
        return model.isBlocking ? "On — new connections to these sites are refused" : "Off — sites load normally"
    }

    // MARK: - Blocked apps

    private var blockedAppsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Blocked apps")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Quit automatically whenever blocking is on. StudyBlock has to be running to enforce this.")
                        .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            if appBlocker.apps.isEmpty {
                Text("No apps yet — add games, Discord, or whatever eats your study time.")
                    .font(.callout)
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
                                .font(.callout.weight(.medium))
                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                appBlocker.remove(app)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
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
                .background(Theme.surfaceLow.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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

    private func addDomain() {
        model.addDomain(newDomain)
        if model.lastError == nil { newDomain = "" }
    }
}

private struct DomainChip: View {
    let domain: String
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(domain)
                .font(.callout.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Theme.danger : .secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(domain)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering ? Theme.accentSoft : Theme.surfaceLow, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
