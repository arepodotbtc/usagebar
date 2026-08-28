import Foundation

public enum Grok {
    static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let defaultIssuer = "https://auth.x.ai"
    static let refreshSkew: TimeInterval = 300

    public static func fetch() async -> ProviderSnapshot {
        do {
            var session = try loadSession()
            if session.isExpiring(within: refreshSkew) {
                session = try await refresh(session)
            }
            let data: Data
            do {
                data = try await requestCredits(session)
            } catch FetchError.unauthorized {
                session = try await refresh(session)
                data = try await requestCredits(session)
            }
            var snapshot = try parse(data)
            if snapshot.plan == nil { snapshot.plan = session.planHint }
            snapshot.fetchedAt = Date()
            return snapshot
        } catch {
            return ProviderSnapshot.failed(id: .grok, error: error)
        }
    }

    struct Session {
        var entryKey: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var userID: String?
        var oidcIssuer: String?
        var oidcClientId: String?

        func isExpiring(within skew: TimeInterval) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow <= skew
        }

        var planHint: String? {
            guard let payload = JWT.payload(accessToken) else { return nil }
            if let tier = payload["tier"] as? Int {
                return tier >= 5 ? "SuperGrok Heavy" : "SuperGrok"
            }
            return nil
        }
    }

    static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    static func loadSession() throws -> Session {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FetchError.missingAuth("Grok not logged in. Run `grok login`.")
        }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let root else { throw FetchError.missingAuth("Could not parse ~/.grok/auth.json") }
        for (key, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            guard let token = entry["key"] as? String, !token.isEmpty else { continue }
            return Session(
                entryKey: key,
                accessToken: token,
                refreshToken: entry["refresh_token"] as? String,
                expiresAt: ISODates.parse(entry["expires_at"] as? String),
                userID: (entry["user_id"] as? String) ?? (entry["principal_id"] as? String),
                oidcIssuer: entry["oidc_issuer"] as? String,
                oidcClientId: entry["oidc_client_id"] as? String
            )
        }
        throw FetchError.missingAuth("auth.json has no Grok session. Run `grok login`.")
    }

    static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw FetchError.missingAuth("Grok session expired. Run `grok login`.")
        }
        guard let clientId = session.oidcClientId, !clientId.isEmpty else {
            throw FetchError.missingAuth("Grok session has no OIDC client id. Run `grok login`.")
        }
        let issuer = (session.oidcIssuer?.isEmpty == false) ? session.oidcIssuer! : defaultIssuer
        guard let tokenURL = URL(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth2/token") else {
            throw FetchError.decodeFailed("Invalid Grok OIDC issuer")
        }
        let data = try await HTTP.postForm(
            tokenURL,
            headers: ["Accept": "application/json", "User-Agent": "xai-grok-cli"],
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientId,
            ]
        )
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String,
            !access.isEmpty
        else {
            throw FetchError.decodeFailed("Grok refresh missing access_token")
        }
        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 21_600
        var updated = session
        updated.accessToken = access
        updated.refreshToken = newRefresh
        updated.expiresAt = Date().addingTimeInterval(expiresIn)
        persist(updated)
        return updated
    }

    static func persist(_ session: Session) {
        let url = authFileURL()
        guard
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entry = root[session.entryKey] as? [String: Any]
        else { return }
        entry["key"] = session.accessToken
        entry["refresh_token"] = session.refreshToken ?? ""
        if let expiresAt = session.expiresAt {
            entry["expires_at"] = ISODates.formatFractional(expiresAt)
        }
        root[session.entryKey] = entry
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileAtom.write(out, to: url, mode: 0o600)
    }

    static func requestCredits(_ session: Session) async throws -> Data {
        var headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "User-Agent": "xai-grok-cli",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "x-grok-client-version": grokClientVersion(),
            "x-grok-client-mode": "interactive",
        ]
        if let userID = session.userID, !userID.isEmpty {
            headers["x-userid"] = userID
        }
        return try await HTTP.get(creditsURL, headers: headers)
    }

    static func grokClientVersion() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/.metadata_version")
        if let raw = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return "1.0.5"
    }

    public static func parse(_ data: Data) throws -> ProviderSnapshot {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = root["config"] as? [String: Any]
        else {
            throw FetchError.decodeFailed("Grok billing was not JSON")
        }
        let percent = number(config["creditUsagePercent"]) ?? 0
        let period = config["currentPeriod"] as? [String: Any]
        let resets = ISODates.parse(period?["end"] as? String)
            ?? ISODates.parse(config["billingPeriodEnd"] as? String)
        var windows = [
            UsageWindow(id: "weekly", label: "Weekly", usedPercent: percent, resetsAt: resets),
        ]
        if let products = config["productUsage"] as? [[String: Any]] {
            for product in products {
                let name = prettyProduct(product["product"] as? String ?? "Product")
                let used = number(product["usagePercent"]) ?? 0
                if name == "Build" && abs(used - percent) < 0.5 { continue }
                windows.append(UsageWindow(id: "product-\(name)", label: name, usedPercent: used, resetsAt: resets))
            }
        }
        let plan = (config["subscriptionTierDisplay"] as? String)
            ?? (config["subscriptionTier"] as? String)
        return ProviderSnapshot(id: .grok, plan: plan, windows: windows, fetchedAt: Date())
    }

    static func prettyProduct(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "PRODUCT_", with: "")
            .replacingOccurrences(of: "Grok", with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: " ")
    }

    static func number(_ raw: Any?) -> Double? {
        if let n = raw as? Double { return n }
        if let n = raw as? Int { return Double(n) }
        return nil
    }
}
