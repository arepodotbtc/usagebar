import Foundation

public enum ParserSelfTest {
    public static func run() throws {
        let claude = try Claude.parse(Data(claudeJSON.utf8))
        precondition(claude.windows.count == 2)
        precondition(claude.windows[0].usedPercent == 2)
        precondition(claude.windows[1].usedPercent == 16)
        precondition(claude.headlineUsedPercent == 16)

        let codex = try Codex.parse(Data(codexJSON.utf8))
        precondition(codex.plan == "prolite")
        precondition(codex.windows[0].label == "Weekly")
        precondition(codex.windows[0].usedPercent == 8)
        precondition(codex.headlineUsedPercent == 8)
        precondition(codex.windows.count == 1, "per-model additional_rate_limits must be ignored")

        let grok = try Grok.parse(Data(grokJSON.utf8))
        precondition(grok.windows[0].usedPercent == 25)
        precondition(grok.windows.count == 1)

        precondition(UsageSeverity.from(usedPercent: 2) == .ok)
        precondition(UsageSeverity.from(usedPercent: 50) == .warning)
        precondition(UsageSeverity.from(usedPercent: 80) == .critical)

        let rateLimitJSON = "{ \"error\": { \"type\": \"rate_limit_error\", \"message\": \"Rate limited. Please try again later.\" } }"
        let rateLimitText = FetchError.badResponse(429, rateLimitJSON).localizedDescription
        precondition(!rateLimitText.contains("{"), "429 must not dump JSON")
        precondition(!rateLimitText.contains("HTTP 429"), "429 must not dump the status line")
        precondition(rateLimitText.lowercased().contains("rate limited"))

        let serverText = FetchError.badResponse(500, "internal").localizedDescription
        precondition(serverText.contains("500"))
        precondition(serverText.contains("internal"))

        let previous = UsageSnapshot(providers: [
            ProviderSnapshot(
                id: .claude,
                plan: "Max",
                windows: [
                    UsageWindow(id: "five_hour", label: "5h session", usedPercent: 2),
                    UsageWindow(id: "seven_day", label: "Weekly", usedPercent: 16),
                ]
            )
        ])
        let rateLimited = UsageSnapshot(providers: [
            ProviderSnapshot.failed(id: .claude, error: FetchError.rateLimited)
        ])
        let stale = rateLimited.coalesced(with: previous).provider(.claude)!
        precondition(stale.windows.count == 2, "429 must keep last windows")
        precondition(stale.headlineUsedPercent == 16, "stale snapshot must still drive the ring")
        precondition(stale.plan == "Max")
        precondition(stale.error == "Rate limited. Showing last snapshot.")
        precondition(stale.error?.contains("{") != true)

        let authFailed = UsageSnapshot(providers: [
            ProviderSnapshot.failed(id: .claude, error: FetchError.missingAuth("Claude not logged in."))
        ])
        let replaced = authFailed.coalesced(with: previous).provider(.claude)!
        precondition(replaced.windows.isEmpty, "auth errors must not keep stale numbers")
        precondition(replaced.error?.contains("not logged in") == true)

        let timeout = UsageSnapshot(providers: [
            ProviderSnapshot(id: .claude, error: "Timed out", transient: true)
        ])
        let timedOutStale = timeout.coalesced(with: previous).provider(.claude)!
        precondition(timedOutStale.windows.count == 2, "timeouts must keep last windows")

        print("self-test ok")
    }
}

private let claudeJSON = """
{
  "five_hour": { "utilization": 2.0, "resets_at": "2026-08-28T23:29:59.845531+00:00" },
  "seven_day": { "utilization": 16.0, "resets_at": "2026-08-31T15:59:59.845574+00:00" }
}
"""

private let codexJSON = """
{
  "plan_type": "prolite",
  "rate_limit": {
    "primary_window": {
      "used_percent": 8,
      "limit_window_seconds": 604800,
      "reset_at": 1788468681
    },
    "secondary_window": null
  },
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "rate_limit": {
        "primary_window": { "used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1787960857 },
        "secondary_window": { "used_percent": 0, "limit_window_seconds": 604800, "reset_at": 1788547657 }
      }
    }
  ]
}
"""

private let grokJSON = """
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "end": "2026-08-30T04:59:04.166560+00:00"
    },
    "creditUsagePercent": 25.0,
    "productUsage": [{ "product": "GrokBuild", "usagePercent": 25.0 }]
  }
}
"""
