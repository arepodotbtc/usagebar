# UsageBar

A tiny macOS menu bar extra that shows how much of your **Claude Code**, **Codex**, and **Grok Build** plan quota you have used.

Three small rings sit in the menu bar, one per provider, each with the provider's logo inside. The ring fills as you use quota and changes color as you get close to the limit. Hover for a text summary. Click for the 5 hour and weekly windows, reset times, and plan names.

No Dock icon, no analytics, no API keys to paste. It reads the same local logins the CLIs already use.

## How it works

Each provider CLI stores an OAuth session on your Mac. UsageBar reads that session, calls the provider's own usage endpoint, and refreshes the session token when it expires, writing it back to the same place the CLI keeps it.

| Provider | Session source | Usage endpoint |
|---|---|---|
| Claude Code | macOS Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| Grok Build | `~/.grok/auth.json` | `cli-chat-proxy.grok.com/v1/billing` |

Each ring shows the highest used percentage across that provider's windows. Rings are green under 50% used, yellow from 50% to 80%, and red above that. A provider you are not signed into shows a dimmed gray ring, and the menu says why.

Polling runs every 5 minutes. Anthropic rate limits its usage endpoint, so keep it there. Rate limited or timed out fetches keep the last good numbers instead of blanking the bar.

Codex reports separate quotas for individual models (for example the Spark model). Those are ignored; only the plan wide limit is shown.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Signed in to the CLIs you want to see: run `claude`, `codex login`, or `grok login` at least once

## Install

```sh
git clone https://github.com/arepodotbtc/usagebar.git
cd usagebar
chmod +x Scripts/*.sh
./Scripts/install.sh
```

That builds a release binary, wraps it as `/Applications/UsageBar.app`, ad-hoc signs it, and launches it.

The first Claude fetch prompts for Keychain access. Choose **Always Allow** so the prompt does not return on every poll.

If Gatekeeper blocks the app, right click it and choose Open, or run:

```sh
xattr -cr /Applications/UsageBar.app
```

**Open at Login** is a toggle in the menu. The app must live in `/Applications` for it to stick.

## Build without installing

```sh
./Scripts/build.sh
open dist/UsageBar.app
```

## Probe from the terminal

Fetches all three providers once and prints the result without touching the menu bar. Handy for checking logins.

```sh
./dist/UsageBar.app/Contents/MacOS/UsageBar --probe
```

Exit code 0 means every provider returned usage windows. Exit code 2 means at least one provider failed, and the output says which and why.

## Tests

Parser tests against saved API fixtures live in `Tests/UsageBarCoreTests`. They use XCTest, which needs a full Xcode install:

```sh
swift test
```

With Command Line Tools only, the same fixtures are checked by the built binary:

```sh
./dist/UsageBar.app/Contents/MacOS/UsageBar --self-test
```

`Scripts/build.sh` runs the self-test automatically.

## Uninstall

```sh
killall UsageBar 2>/dev/null || true
rm -rf /Applications/UsageBar.app
```

Then remove the cloned directory. Nothing else is written outside the app bundle; tokens stay in the CLI stores they came from.

## Privacy

- No analytics or telemetry.
- Tokens are never logged.
- Network traffic goes only to the three usage endpoints above and their token refresh hosts.
- Session tokens are read from, and refreshed into, the same files and Keychain items the CLIs already own.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Claude ring is gray | Keychain access denied, or empty tokens | Choose Always Allow, then run `claude` once |
| Codex ring is gray | Missing or expired `~/.codex/auth.json` | `codex login` |
| Grok ring is gray | Expired Grok session | `grok login` |
| Numbers look stale | Provider returned 429 or is down | Wait, or click Refresh Now |

## Design notes

See [docs/DESIGN.md](docs/DESIGN.md) for the architecture, auth flow, and what is deliberately out of scope.

## Logos

Provider marks are used only for identification. Sources and licenses are listed in `Sources/UsageBar/Logos/SOURCES.txt`.
