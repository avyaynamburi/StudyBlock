# StudyBlock

A native macOS study companion:

- **Focus** — website blocker (system-wide, every browser, no extension) + focus timer that blocks automatically while it runs, with the countdown in the menu bar
  - **Locked sessions**: opt-in "no giving up" mode. The root helper enforces the deadline — it refuses early unblock, re-writes `/etc/hosts` within ~3 s if tampered with, and survives app quits and reboots (`RunAtLoad`). Capped at 8 hours. Lock state lives in `/var/db/com.avyay.studyblock.lock.json`.
  - **App blocking**: blocked apps (games, Discord, …) are quit automatically while blocking is on (enforced by the app process, so StudyBlock must be running).
  - **Focus on a task**: a ▶ button on any task starts a session linked to it; focused time accrues to its course.
- **Tasks** — assignment tracker with natural-language quick-add (`essay friday #history !!`), due-date grouping (Overdue/Today/This Week), priorities, and daily/weekly repeats
- **Flashcards** — SM-2 spaced repetition (Again/Hard/Good/Easy with interval previews, due-card badges) plus a no-schedule practice mode
- **Notes** — quick autosaving scratchpads
- **Stats** — focused minutes, day streak, tasks completed, 7-day chart, focus-by-course chart

All data is local JSON in `~/Library/Application Support/StudyBlock/`.

## How the blocking works

```
StudyBlock.app (SwiftUI, runs as you)
 ├─ main window: blocklist editor + on/off toggle
 ├─ menu-bar icon: status + quick toggle
 └─ registers a helper via SMAppService
        │  XPC (com.avyay.studyblock.helper)
        ▼
Root helper daemon (launchd)
 └─ rewrites /etc/hosts: blocked domains → 0.0.0.0, then flushes the DNS cache
```

The helper only ever touches a clearly marked section of `/etc/hosts`, writes atomically with a sanity check, and keeps a pristine backup at `/etc/hosts.studyblock.orig`. Each blocked domain gets both an IPv4 (`0.0.0.0`) and IPv6 (`::`) sinkhole — IPv4-only leaks, because sites with AAAA records still connect over IPv6.

DNS blocking only stops *new* connections, so it can't affect a page that's already loaded (especially offline-capable web apps). While blocking is on, StudyBlock also closes browser tabs pointing at blocked sites — in already-running Safari / Chrome / Brave / Edge / Arc / Vivaldi, via AppleScript. This needs a one-time **Automation** permission grant per browser (System Settings → Privacy & Security → Automation), and only works while StudyBlock itself is running.

## Requirements

- macOS 13+ (built on macOS 15)
- Apple's Command Line Tools (`xcode-select --install`) — full Xcode is **not** required

## Build & install

One-time, so the helper's approval survives rebuilds:

```sh
./scripts/setup-signing.sh
```

This creates a stable self-signed code-signing identity ("StudyBlock Self-Signed") in a dedicated keychain. Without it the build falls back to ad-hoc signing, and macOS resets the helper's approval on every rebuild (because ad-hoc gives each build a different signature). The app's designated requirement pins to this certificate, so rebuilds keep the same identity.

Then, to build:

```sh
./scripts/build-no-xcode.sh
```

This compiles with `swiftc`, hand-assembles the .app bundle, signs it (stable identity if set up, else ad-hoc), installs to /Applications, restarts the helper daemon if it's running, and launches. (There's also an Xcode path — `brew install xcodegen`, then `./scripts/install.sh` — if you ever want Xcode's debugger or SwiftUI previews.)

Then, in the app, click **Set Up Helper** and approve **StudyBlock** in *System Settings → General → Login Items & Extensions* (one-time). After that, blocking is a single toggle — no password prompts.

The Xcode project is generated from `project.yml` — run `xcodegen` after adding/removing files; never edit `StudyBlock.xcodeproj` by hand.

## Verify blocking

```sh
cat /etc/hosts                      # marked studyblock section present when ON
ping -c1 youtube.com                # resolves to 0.0.0.0 when blocked
```

Browsers may cache DNS for a few seconds after toggling; open a new tab. If Chrome still gets through, check that Secure DNS (DNS-over-HTTPS) is off in Chrome settings — a managed-policy mitigation is planned.

## Uninstall / emergency restore

- In the app: turn blocking off, then remove **StudyBlock** in Login Items & Extensions and delete the app.
- If `/etc/hosts` is ever wrong: `sudo cp /etc/hosts.studyblock.orig /etc/hosts`

## Roadmap

Block page (friendly "back to work" page instead of a connection error), block schedules, Pomodoro cycles with breaks, daily focus goals, exam countdowns, Anki/CSV import, subtasks, calendar integration, Network Extension migration for distribution.
