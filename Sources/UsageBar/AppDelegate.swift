import AppKit
import ServiceManagement
import UsageBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var snapshot = UsageSnapshot()
    private var timer: Timer?
    private var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "UsageBar"
        }
        renderPlaceholder()
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let next = await UsageAggregator.fetchAll()
            await MainActor.run {
                self.snapshot = next.coalesced(with: self.snapshot)
                self.refreshing = false
                self.renderBar()
                self.rebuildMenu()
            }
        }
    }

    func renderPlaceholder() {
        applyStrip(UsageSnapshot())
    }

    func renderBar() {
        applyStrip(snapshot)
    }

    func applyStrip(_ snapshot: UsageSnapshot) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        let strip = RingStrip.image(for: snapshot)
        strip.isTemplate = false
        button.image = strip
        button.image?.isTemplate = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        statusItem.length = RingStrip.stripWidth + 8
        button.toolTip = tooltip()
    }

    func tooltip() -> String {
        snapshot.providers.map { provider in
            let used = provider.headlineUsedPercent.map { "\(Int($0.rounded()))% used" }
            let plan = provider.plan.map { " \($0)" } ?? ""
            if let error = provider.error {
                if let used {
                    return "\(provider.id.displayName)\(plan): \(used) (\(error))"
                }
                return "\(provider.id.displayName): \(error)"
            }
            return "\(provider.id.displayName)\(plan): \(used ?? "--")"
        }.joined(separator: "\n")
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for id in ProviderID.allCases {
            let provider = snapshot.provider(id) ?? ProviderSnapshot(id: id, error: "Waiting…")
            let header = NSMenuItem()
            let plan = provider.plan.map { "  ·  \($0)" } ?? ""
            header.title = "\(provider.id.displayName)\(plan)"
            let icon = RingStrip.single(id: id, used: provider.headlineUsedPercent)
            icon.isTemplate = false
            header.image = icon
            header.image?.isTemplate = false
            header.isEnabled = false
            menu.addItem(header)

            if provider.windows.isEmpty {
                let message = provider.error ?? "No windows"
                let item = NSMenuItem(title: "  \(message)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for window in provider.windows {
                    let reset = window.resetsAt.map { "   \(relative($0))" } ?? ""
                    let padded = window.label.padding(toLength: 14, withPad: " ", startingAt: 0)
                    let title = "  \(padded) \(Int(window.usedPercent.rounded()))% used\(reset)"
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
                if let error = provider.error {
                    let item = NSMenuItem(title: "  \(error)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
        }

        let age = snapshot.fetchedAt == Date.distantPast
            ? "Never refreshed"
            : "Updated \(relative(snapshot.fetchedAt))"
        let ageItem = NSMenuItem(title: age, action: nil, keyEquivalent: "")
        ageItem.isEnabled = false
        menu.addItem(ageItem)

        let refreshItem = NSMenuItem(title: refreshing ? "Refreshing…" : "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !refreshing
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func relative(_ date: Date) -> String {
        if date.timeIntervalSinceNow > 0 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "resets \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc func refreshClicked() {
        refresh()
    }

    @objc func toggleLogin() {
        LaunchAtLogin.isEnabled.toggle()
        rebuildMenu()
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("UsageBar launch-at-login failed: \(error.localizedDescription)")
            }
        }
    }
}
