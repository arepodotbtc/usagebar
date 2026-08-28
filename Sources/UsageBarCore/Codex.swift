import Foundation

public enum Codex {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let refreshSkew: TimeInterval = 300

    public static func fetch() async -> ProviderSnapshot {
        do {
            var session = try loadSession()
            if session.isExpiring(within: refreshSkew) {
                session = try await refresh(session)
            }
            let data: Data
            do {
                data = try await requestUsage(session)
            } catch FetchError.unauthorized {
                session = try await refresh(session)
                data = try await requestUsage(session)
            }
            var snapshot = try parse(data)
            if snapshot.plan == nil { snapshot.plan = session.planHint }
            snapshot.fetchedAt = Date()
            return snapshot
        } catch {
            return ProviderSnapshot.failed(id: .codex, error: error)
        }
    }

    struct Session {
        var accessToken: String
        var refreshToken: String?
        var accountID: String?
        var planHint: String?

        func isExpiring(within skew: TimeInterval) -> Bool {
            guard let exp = JWT.expiresAt(accessToken) else { return false }
            return exp.timeIntervalSinceNow <= skew
        }
    }

    static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func loadSession() throws -> Session {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FetchError.missingAuth("Codex not logged in. Run `codex login`.")
        }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let root else { throw FetchError.missingAuth("Could not parse ~/.codex/auth.json") }
        let tokens = root["tokens"] as? [String: Any]
        let access = tokens?["access_token"] as? String
        guard let access, !access.isEmpty else {
            throw FetchError.missingAuth("Codex auth.json has no access token. Run `codex login`.")
        }
        return Session(
            accessToken: access,
            refreshToken: tokens?["refresh_token"] as? String,
            accountID: tokens?["account_id"] as? String,
            planHint: nil
        )
    }

    static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw FetchError.missingAuth("Codex token expired. Run `codex login`.")
        }
        let data = try await HTTP.postJSON(
            refreshURL,
            headers: ["Accept": "application/json", "User-Agent": "codex-cli"],
            body: [
                "client_id": oauthClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": "openid profile email",
            ]
        )
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String,
            !access.isEmpty
        else {
            throw FetchError.decodeFailed("Codex refresh missing access_token")
        }
        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        var updated = session
        updated.accessToken = access
        updated.refreshToken = newRefresh
        persist(updated)
        return updated
    }

    static func persist(_ session: Session) {
        let url = authFileURL()
        guard
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = session.accessToken
        tokens["refresh_token"] = session.refreshToken ?? ""
        root["tokens"] = tokens
        root["last_refresh"] = ISODates.formatFractional(Date())
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else { return }
        try? FileAtom.write(out, to: url, mode: 0o600)
    }

    static func requestUsage(_ session: Session) async throws -> Data {
        var headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "User-Agent": "Codex/0.150.1",
        ]
        if let accountID = session.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try await HTTP.get(usageURL, headers: headers)
    }

    public static func parse(_ data: Data) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decodeFailed("Codex usage was not JSON")
        }
        var windows: [UsageWindow] = []
        if let rate = root["rate_limit"] as? [String: Any] {
            windows.append(contentsOf: parsedWindows(from: rate))
        }
        // additional_rate_limits carries per-model quotas (for example GPT-5.3-Codex-Spark).
        // They are separate from the plan limit and sit at 0% unless that model is used, so skip them.
        if windows.isEmpty {
            throw FetchError.decodeFailed("Codex usage had no rate-limit windows")
        }
        let plan = root["plan_type"] as? String
        return ProviderSnapshot(id: .codex, plan: plan, windows: windows, fetchedAt: Date())
    }

    static func parsedWindows(from rate: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        if let primary = rate["primary_window"] as? [String: Any],
           let window = window(from: primary, id: "primary", fallbackLabel: "Plan")
        {
            result.append(window)
        }
        if let secondary = rate["secondary_window"] as? [String: Any],
           let window = window(from: secondary, id: "secondary", fallbackLabel: "Weekly")
        {
            result.append(window)
        }
        return result
    }

    static func window(from obj: [String: Any], id: String, fallbackLabel: String) -> UsageWindow? {
        let used = number(obj["used_percent"])
        guard used != nil || obj["reset_at"] != nil else { return nil }
        let seconds = number(obj["limit_window_seconds"]) ?? 0
        let label: String
        if seconds >= 86_400 * 6 {
            label = fallbackLabel.contains("Weekly") ? fallbackLabel : (fallbackLabel == "Plan" ? "Weekly" : "\(fallbackLabel) weekly")
        } else if seconds >= 3_600 * 4 && seconds <= 3_600 * 6 {
            label = fallbackLabel.contains("5h") ? fallbackLabel : (fallbackLabel == "Plan" ? "5h" : "\(fallbackLabel) 5h")
        } else {
            label = fallbackLabel
        }
        let reset: Date?
        if let unix = number(obj["reset_at"]) {
            reset = Date(timeIntervalSince1970: unix)
        } else {
            reset = ISODates.parse(obj["reset_at"] as? String)
        }
        return UsageWindow(id: id, label: label, usedPercent: used ?? 0, resetsAt: reset)
    }

    static func number(_ raw: Any?) -> Double? {
        if let n = raw as? Double { return n }
        if let n = raw as? Int { return Double(n) }
        return nil
    }
}
