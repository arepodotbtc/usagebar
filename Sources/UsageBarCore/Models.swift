import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case grok

    public var shortLabel: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .grok: return "Gk"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok Build"
        }
    }
}

public struct UsageWindow: Equatable, Sendable, Codable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ProviderSnapshot: Equatable, Sendable, Codable {
    public var id: ProviderID
    public var plan: String?
    public var windows: [UsageWindow]
    public var error: String?
    public var fetchedAt: Date
    public var transient: Bool

    public init(
        id: ProviderID,
        plan: String? = nil,
        windows: [UsageWindow] = [],
        error: String? = nil,
        fetchedAt: Date = Date(),
        transient: Bool = false
    ) {
        self.id = id
        self.plan = plan
        self.windows = windows
        self.error = error
        self.fetchedAt = fetchedAt
        self.transient = transient
    }

    public static func failed(id: ProviderID, error: Error) -> ProviderSnapshot {
        let fetch = error as? FetchError
        return ProviderSnapshot(
            id: id,
            error: error.localizedDescription,
            fetchedAt: Date(),
            transient: fetch?.isTransient ?? (error is URLError)
        )
    }

    /// Highest used % among windows. Uses last-good numbers even when a transient error is attached.
    public var headlineUsedPercent: Double? {
        guard !windows.isEmpty else { return nil }
        return windows.map(\.usedPercent).max()
    }
}

public struct UsageSnapshot: Equatable, Sendable, Codable {
    public var fetchedAt: Date
    public var providers: [ProviderSnapshot]

    public init(fetchedAt: Date = Date(), providers: [ProviderSnapshot] = []) {
        self.fetchedAt = fetchedAt
        self.providers = providers
    }

    public func provider(_ id: ProviderID) -> ProviderSnapshot? {
        providers.first { $0.id == id }
    }

    /// Keep last-good windows when a provider hits a transient failure (429, timeout, 5xx).
    public func coalesced(with previous: UsageSnapshot?) -> UsageSnapshot {
        guard let previous else { return self }
        let merged = ProviderID.allCases.map { id in
            let next = provider(id) ?? ProviderSnapshot(id: id, error: "Missing")
            return next.coalesced(with: previous.provider(id))
        }
        return UsageSnapshot(fetchedAt: fetchedAt, providers: merged)
    }
}

extension ProviderSnapshot {
    public func coalesced(with previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard windows.isEmpty, isTransientFailure, let previous, !previous.windows.isEmpty else {
            return self
        }
        var kept = previous
        kept.error = Self.staleMessage(error)
        kept.transient = true
        return kept
    }

    public var isTransientFailure: Bool {
        if transient { return true }
        guard let error else { return false }
        return Self.looksTransient(error)
    }

    static func looksTransient(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("rate limited") { return true }
        if lower.contains("timed out") { return true }
        if lower.contains("http 429") { return true }
        return lower.range(of: #"http 5\d\d"#, options: .regularExpression) != nil
    }

    static func staleMessage(_ error: String?) -> String {
        let lower = (error ?? "").lowercased()
        if lower.contains("rate limited") {
            return "Rate limited. Showing last snapshot."
        }
        if lower.contains("timed out") {
            return "Timed out. Showing last snapshot."
        }
        return "Temporarily unavailable. Showing last snapshot."
    }
}

public enum UsageSeverity: Sendable, Equatable {
    case ok
    case warning
    case critical
    case missing

    public static func from(usedPercent: Double?) -> UsageSeverity {
        guard let usedPercent else { return .missing }
        if usedPercent >= 80 { return .critical }
        if usedPercent >= 50 { return .warning }
        return .ok
    }
}
