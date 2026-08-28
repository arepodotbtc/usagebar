import CryptoKit
import Foundation

public enum Claude {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let servicePrefix = "Claude Code-credentials"
    static let refreshSkew: TimeInterval = 300

    public static func fetch() async -> ProviderSnapshot {
        do {
            var creds = try loadCredentials()
            if creds.isExpiring(within: refreshSkew) {
                creds = try await refresh(creds)
            }
            let data: Data
            do {
                data = try await requestUsage(token: creds.accessToken)
            } catch FetchError.unauthorized {
                creds = try await refresh(creds)
                data = try await requestUsage(token: creds.accessToken)
            }
            var snapshot = try parse(data)
            snapshot.plan = creds.planLabel
            snapshot.fetchedAt = Date()
            return snapshot
        } catch {
            return ProviderSnapshot.failed(id: .claude, error: error)
        }
    }

    // MARK: - Auth

    struct Credentials {
        var service: String
        var account: String
        var raw: [String: Any]
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?

        var planLabel: String {
            let sub = (subscriptionType ?? "").trimmingCharacters(in: .whitespaces)
            let tier = (rateLimitTier ?? "")
                .replacingOccurrences(of: "default_claude_", with: "")
                .replacingOccurrences(of: "_", with: " ")
            let raw = !tier.isEmpty ? tier : sub
            guard !raw.isEmpty else { return "Claude" }
            return raw.split(separator: " ").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }

        func isExpiring(within skew: TimeInterval) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow <= skew
        }
    }

    static func loadCredentials() throws -> Credentials {
        let account = NSUserName()
        let services = keychainServices(account: account)
        var best: Credentials?
        for service in services {
            guard let creds = readCredentials(service: service, account: account) else { continue }
            if best == nil || (creds.expiresAt ?? .distantPast) > (best!.expiresAt ?? .distantPast) {
                best = creds
            }
        }
        if let file = try? readCredentialsFile() {
            if best == nil || (file.expiresAt ?? .distantPast) > (best!.expiresAt ?? .distantPast) {
                best = file
            }
        }
        guard let best, !best.accessToken.isEmpty else {
            throw FetchError.missingAuth("Claude not logged in. Run `claude` once, then Allow Keychain access.")
        }
        return best
    }

    static func keychainServices(account: String) -> [String] {
        var names = [servicePrefix]
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        for path in [configured, home].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            names.append("\(servicePrefix)-\(sha256Prefix(path))")
        }
        return Array(Set(names))
    }

    static func sha256Prefix(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    static func readCredentials(service: String, account: String) -> Credentials? {
        guard let secret = security(["find-generic-password", "-s", service, "-a", account, "-w"]) else {
            return nil
        }
        return parseCredentialsJSON(Data(secret.utf8), service: service, account: account)
    }

    static func security(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readCredentialsFile() throws -> Credentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let dir = (configured?.isEmpty == false)
            ? URL(fileURLWithPath: configured!, isDirectory: true)
            : home.appendingPathComponent(".claude")
        let url = dir.appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return parseCredentialsJSON(data, service: "file", account: NSUserName())
    }

    static func parseCredentialsJSON(_ data: Data, service: String, account: String) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String) ?? ""
        guard !token.isEmpty else { return nil }
        let refresh = (oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String)
        let expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            expires = nil
        }
        return Credentials(
            service: service,
            account: account,
            raw: root,
            accessToken: token,
            refreshToken: refresh,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    static func refresh(_ creds: Credentials) async throws -> Credentials {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw FetchError.missingAuth("Claude token expired. Run `claude` to refresh.")
        }
        let data = try await HTTP.postJSON(
            refreshURL,
            headers: ["Accept": "application/json", "User-Agent": "claude-code/2.1.251"],
            body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": oauthClientID,
                "scope": "user:profile user:inference user:sessions:claude_code",
            ]
        )
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String,
            !access.isEmpty
        else {
            throw FetchError.decodeFailed("Claude refresh missing access_token")
        }
        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        var updated = creds
        updated.accessToken = access
        updated.refreshToken = newRefresh
        updated.expiresAt = expiresAt
        persistRefreshed(updated)
        return updated
    }

    static func persistRefreshed(_ creds: Credentials) {
        guard creds.service != "file" else { return }
        var root = creds.raw
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken ?? ""
        if let expiresAt = creds.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        root["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: []),
              let json = String(data: data, encoding: .utf8)
        else { return }
        _ = security([
            "add-generic-password", "-U",
            "-s", creds.service,
            "-a", creds.account,
            "-w", json,
        ])
    }

    static func requestUsage(token: String) async throws -> Data {
        try await HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
            "User-Agent": "claude-code/2.1.251",
            "x-app": "cli",
            "Accept": "application/json",
        ])
    }

    // MARK: - Parse

    public static func parse(_ data: Data) throws -> ProviderSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decodeFailed("Claude usage was not JSON")
        }
        var windows: [UsageWindow] = []
        if let window = window(from: root["five_hour"], id: "five_hour", label: "5h session") {
            windows.append(window)
        }
        if let window = window(from: root["seven_day"], id: "seven_day", label: "Weekly") {
            windows.append(window)
        }
        if windows.isEmpty {
            throw FetchError.decodeFailed("Claude usage had no 5h/weekly windows")
        }
        return ProviderSnapshot(id: .claude, windows: windows, fetchedAt: Date())
    }

    static func window(from raw: Any?, id: String, label: String) -> UsageWindow? {
        guard let obj = raw as? [String: Any] else { return nil }
        let used = number(obj["utilization"])
        guard used != nil || obj["resets_at"] != nil else { return nil }
        return UsageWindow(
            id: id,
            label: label,
            usedPercent: used ?? 0,
            resetsAt: ISODates.parse(obj["resets_at"] as? String)
        )
    }

    static func number(_ raw: Any?) -> Double? {
        if let n = raw as? Double { return n }
        if let n = raw as? Int { return Double(n) }
        return nil
    }
}
