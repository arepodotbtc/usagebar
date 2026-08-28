import Foundation

public enum UsageAggregator {
    public static func fetchAll() async -> UsageSnapshot {
        async let claude = timed(.claude) { await Claude.fetch() }
        async let codex = timed(.codex) { await Codex.fetch() }
        async let grok = timed(.grok) { await Grok.fetch() }
        let providers = await [claude, codex, grok]
        return UsageSnapshot(fetchedAt: Date(), providers: providers)
    }

    static func timed(_ id: ProviderID, _ work: @escaping () async -> ProviderSnapshot) async -> ProviderSnapshot {
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return ProviderSnapshot(id: id, error: "Timed out", fetchedAt: Date(), transient: true)
            }
            if let first = await group.next() {
                group.cancelAll()
                return first
            }
            return ProviderSnapshot(id: id, error: "Timed out", fetchedAt: Date(), transient: true)
        }
    }

    public static func probeJSON(_ snapshot: UsageSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ProbePayload(snapshot: snapshot))
    }
}

private struct ProbePayload: Encodable {
    struct Provider: Encodable {
        var id: String
        var plan: String?
        var headlineUsed: Double?
        var error: String?
        var windows: [Window]
    }

    struct Window: Encodable {
        var id: String
        var label: String
        var usedPercent: Double
        var resetsAt: Date?
    }

    var fetchedAt: Date
    var providers: [Provider]

    init(snapshot: UsageSnapshot) {
        fetchedAt = snapshot.fetchedAt
        providers = snapshot.providers.map { provider in
            Provider(
                id: provider.id.rawValue,
                plan: provider.plan,
                headlineUsed: provider.headlineUsedPercent,
                error: provider.error,
                windows: provider.windows.map {
                    Window(id: $0.id, label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
                }
            )
        }
    }
}
