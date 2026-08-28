import AppKit
import UsageBarCore

enum RingStrip {
    static var barHeight: CGFloat { NSStatusBar.system.thickness }
    static var ringSize: CGFloat { max(22, barHeight - 1) }
    static let gap: CGFloat = 7
    static var height: CGFloat { barHeight }
    static let lineWidth: CGFloat = 3.2

    static var stripWidth: CGFloat {
        let count = CGFloat(ProviderID.allCases.count)
        return count * ringSize + (count - 1) * gap
    }

    static func image(for snapshot: UsageSnapshot) -> NSImage {
        let size = NSSize(width: stripWidth, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            drawStrip(in: rect, snapshot: snapshot)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func single(id: ProviderID, used: Double?) -> NSImage {
        let size = NSSize(width: ringSize, height: ringSize)
        let image = NSImage(size: size, flipped: false) { rect in
            drawRing(in: rect, id: id, used: used)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func drawStrip(in rect: NSRect, snapshot: UsageSnapshot) {
        var x = rect.minX
        let y = rect.minY + (rect.height - ringSize) / 2
        for id in ProviderID.allCases {
            let ring = NSRect(x: x, y: y, width: ringSize, height: ringSize)
            drawRing(in: ring, id: id, used: snapshot.provider(id)?.headlineUsedPercent)
            x += ringSize + gap
        }
    }

    static func drawRing(in rect: NSRect, id: ProviderID, used: Double?) {
        let missing = used == nil
        let remaining = used.map { max(0, min(100, 100 - $0)) }
        let fill = fillColor(remaining: remaining)
        let track = NSColor(white: 0.55, alpha: missing ? 0.35 : 0.55)
        let logoColor = logoTint(id: id, missing: missing)

        let inset = lineWidth / 2
        let ringRect = rect.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: ringRect.midX, y: ringRect.midY)
        let radius = min(ringRect.width, ringRect.height) / 2

        let trackPath = NSBezierPath(ovalIn: ringRect)
        trackPath.lineWidth = lineWidth
        track.setStroke()
        trackPath.stroke()

        if let remaining, remaining < 99.6, let used {
            let percent = max(0, min(100, used))
            if percent > 0.4 {
                let arc = NSBezierPath()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                let start: CGFloat = 90
                let end = start - 360 * CGFloat(percent / 100)
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: start,
                    endAngle: end,
                    clockwise: true
                )
                fill.setStroke()
                arc.stroke()
            }
        }

        let logoSide = rect.width * 0.56
        let logoRect = NSRect(
            x: center.x - logoSide / 2,
            y: center.y - logoSide / 2,
            width: logoSide,
            height: logoSide
        )
        drawLogo(id, in: logoRect, tint: logoColor)
    }

    /// Green = lots left, yellow = not much, red = almost none.
    static func fillColor(remaining: Double?) -> NSColor {
        guard let remaining else {
            return NSColor(white: 0.55, alpha: 1)
        }
        if remaining > 50 { return NSColor.systemGreen }
        if remaining > 20 { return NSColor.systemYellow }
        return NSColor.systemRed
    }

    static func logoTint(id: ProviderID, missing: Bool) -> NSColor {
        // All provider logos are drawn in plain white, regardless of brand color or appearance.
        let color = NSColor.white
        return missing ? color.withAlphaComponent(0.45) : color
    }

    static func drawLogo(_ id: ProviderID, in rect: NSRect, tint: NSColor) {
        guard let source = logoImage(id) else { return }
        let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
            source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            tint.setFill()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    static func logoImage(_ id: ProviderID) -> NSImage? {
        let name: String
        switch id {
        case .claude: name = "claude"
        case .codex: name = "codex"
        case .grok: name = "grok"
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Logos") {
            return NSImage(contentsOf: url)
        }
        return Bundle.module.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}
