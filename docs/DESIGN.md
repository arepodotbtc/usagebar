# UsageBar design

Local macOS menu-bar extra that shows Claude Code, Codex, and Grok Build plan usage. Built with Swift Command Line Tools (`swiftc` / SwiftPM). No Xcode.app, no notch overlay, no cookies, no extra host app.

## Goal

Glanceable used-% in the system menu bar: one ring per provider with the provider logo inside, drawn in white. The ring fills with used percentage and is colored by how much is left. The tooltip carries the text summary.

Click for windows, reset times, plan names, refresh, and open-at-login.

## What the numbers mean

| Provider | Ring value | Windows in the menu |
|---|---|---|
| Claude Code | Max of 5h session and weekly used % | 5h session, Weekly |
| Codex | Max of plan windows | Plan 5h/weekly (per-model `additional_rate_limits` such as Spark are ignored) |
| Grok Build | Weekly SuperGrok credit % (same as `/usage`) | Weekly, product split when it differs |

Colors: green < 50% used, orange 50 to 79, red >= 80, gray if missing.

This is plan quota, not the TUI context counter (`7.0K / 500K`).

## Auth (read existing CLI sessions)

| Provider | Source | Usage endpoint |
|---|---|---|
| Claude | Keychain `Claude Code-credentials` and `Claude Code-credentials-<sha256(config dir)[0:8]>`. Pick newest nonempty `claudeAiOauth.accessToken`. Fallback `~/.claude/.credentials.json` | `GET https://api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` `tokens.access_token` + `account_id` | `GET https://chatgpt.com/backend-api/wham/usage` |
| Grok | `~/.grok/auth.json` OIDC `key` | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` |

Verified 2026-08-28 against the current CLI releases: Claude hashed Keychain item, Codex ChatGPT OAuth, Grok OIDC. The unhashed `Claude Code-credentials` item can have empty tokens; hashed siblings hold the live session.

Token refresh (write back to the same store):

- Claude: `POST https://platform.claude.com/v1/oauth/token`
- Codex: `POST https://auth.openai.com/oauth/token` with client `app_EMoamEEZ73f0CkXaXp7hrann`
- Grok: `POST {oidc_issuer}/oauth2/token`

If refresh fails, the menu says to re-login in that CLI.

## Architecture

```
UsageBar.app (LSUIElement, no Dock icon)
  Status item + NSMenu
  5-minute poll
        |
UsageBarCore
  Claude / Codex / Grok fetchers
  parsers covered by fixture tests
```

Build: `Scripts/build.sh` runs `swift build -c release`, wraps `dist/UsageBar.app`, ad-hoc signs, and runs the built binary with `--self-test`. Fixture tests run with `swift test`.

## Explicitly out of scope (v1)

- Notch / Dynamic Island overlay
- Desktop widgets
- Cursor, OpenRouter, or other providers
- Session context-window tokens
- Browser cookie scraping
- Writing a new login flow (reuse `claude` / `codex login` / `grok login`)

## Failure modes

| Symptom | Cause | What to do |
|---|---|---|
| Claude ring gray | Keychain deny or empty tokens | Allow Always; run `claude` |
| Codex ring gray | Missing or expired `~/.codex/auth.json` | `codex login` |
| Grok ring gray | Expired OIDC session | `grok login` |
| Stale numbers | Provider 429 / outage | Keep last good snapshot; Refresh Now |
| Gatekeeper | Ad-hoc signature | Right-click Open, or `xattr -cr /Applications/UsageBar.app` |

## Privacy

No analytics. Tokens never log. Network only to the three usage/refresh hosts above. Poll interval is 5 minutes on purpose: Anthropic rate-limits `/api/oauth/usage`.
