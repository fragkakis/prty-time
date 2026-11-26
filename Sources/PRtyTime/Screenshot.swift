import AppKit
import ImageIO
import PRtyTimeCore
import SwiftUI
import UniformTypeIdentifiers

#if DEMO
// Renders the README's docs/demo-{light,dark}.gif (the keyboard flow) and
// docs/social-preview.png (upload it in the repo's Settings → Social preview) from
// demo data. Only in DEMO builds: `make screenshots`.
@MainActor
enum Screenshot {
    static func run(to dir: String) {
        let now = Date()
        func avatarURL(_ login: String) -> URL { URL(string: "https://example.invalid/\(login).png")! }
        func pr(_ id: String, _ repo: String, _ number: Int, _ title: String, by author: String, _ minutes: Double,
                teams: [String] = [], draft: Bool = false, decision: ReviewDecision? = nil) -> PullRequest {
            PullRequest(
                id: id, number: number, title: title, url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                isDraft: draft, updatedAt: now.addingTimeInterval(-minutes * 60),
                author: Actor(login: author, avatarURL: avatarURL(author)), repo: repo,
                requestedTeams: teams, hasDetails: true, reviewDecision: decision
            )
        }
        let buckets: [Bucket: [PullRequest]] = [
            .direct: [
                pr("d1", "acme/api", 482, "Add rate limiting to the public API", by: "alice", 12),
                pr("d2", "acme/web", 1290, "Fix flaky checkout test", by: "bob", 190),
            ],
            .team: [
                pr("t1", "acme/api", 479, "Bump Postgres driver to 3.2", by: "carol", 40, teams: ["backend"]),
                pr("t2", "acme/web", 1287, "New onboarding flow", by: "dan", 26 * 60, teams: ["frontend"]),
                pr("t3", "acme/infra", 77, "Move workers to arm64", by: "erin", 50 * 60, teams: ["platform"]),
                pr("t4", "acme/mobile", 311, "Dark mode for the settings screen", by: "frank", 5 * 1440, teams: ["mobile"]),
            ],
            .reviewed: [
                pr("r1", "acme/api", 470, "Cache feature flags in memory", by: "grace", 2 * 1440, decision: .approved),
            ],
            .mine: [
                pr("m1", "acme/api", 485, "Retry webhooks with exponential backoff", by: "you", 25, decision: .approved),
                pr("m2", "acme/web", 1292, "Speed up search suggestions", by: "you", 4 * 60, decision: .reviewRequired),
                pr("m3", "acme/api", 480, "Remove legacy v1 endpoints", by: "you", 1440, decision: .changesRequested),
                pr("m4", "acme/infra", 79, "Add staging smoke tests", by: "you", 3 * 1440, draft: true, decision: .reviewRequired),
            ],
        ]
        let counts: [String: (Int, Int)] = [
            "d1": (148, 12), "d2": (6, 9), "t1": (2, 2), "t2": (1_240, 310), "t3": (87, 45), "t4": (214, 36),
            "r1": (64, 8), "m1": (96, 14), "m2": (41, 17), "m3": (12, 1_870), "m4": (230, 0),
        ]
        PRStore.shared.showDemo(
            buckets: buckets, unread: ["d1", "t2", "m1"],
            diffStats: counts.mapValues { DiffStat(additions: $0.0, deletions: $0.1) },
            // A daytime clock in the footer, whenever this runs. Ages use `updatedAt`, not this.
            lastRefresh: Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: now)
        )
        for login in ["alice", "bob", "carol", "dan", "erin", "frank", "grace"] {
            AvatarStore.shared.preload(identicon(login), for: avatarURL(login))
        }

        Task {
            await demo(.aqua, to: URL(fileURLWithPath: dir).appendingPathComponent("demo-light.gif"))
            await demo(.darkAqua, to: URL(fileURLWithPath: dir).appendingPathComponent("demo-dark.gif"))
            await socialPreview(to: dir)
            NSApp.terminate(nil)
        }
    }

    /// A GitHub-style identicon: a mirrored 5x5 grid in a color derived from the login.
    static func identicon(_ login: String) -> NSImage {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in login.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let color = NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.5, brightness: 0.78, alpha: 1)
        let bits = hash >> 12
        let px = 140
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        color.setFill()
        let cell: CGFloat = 24, inset: CGFloat = 10
        for col in 0..<3 {
            for row in 0..<5 where (bits >> UInt64(col * 5 + row)) & 1 == 1 {
                for c in Set([col, 4 - col]) {
                    NSRect(x: inset + CGFloat(c) * cell, y: inset + CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 70, height: 70))
        image.addRepresentation(rep)
        return image
    }

    static func render(_ appearance: NSAppearance.Name) async -> NSImage {
        let view = NSHostingView(rootView: MenuContent(store: PRStore.shared).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 460, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))
        let size = view.fittingSize
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The keyboard flow, a frame per step with the keys as its caption.
    static func demo(_ appearance: NSAppearance.Name, to url: URL) async {
        let panel = PanelState.shared
        panel.tab = .review
        let steps: [(caption: String, seconds: Double, set: () -> Void)] = [
            ("⌃⌥P opens the panel from any app", 2.0, { panel.query = "" }),
            ("Type to filter", 0.3, { panel.query = "p" }),
            ("Type to filter", 0.3, { panel.query = "po" }),
            ("Type to filter", 0.3, { panel.query = "pos" }),
            ("Type to filter", 0.6, { panel.query = "post" }),
            ("↩ opens the first match", 1.8, {}),
            ("Esc clears the filter", 1.2, { panel.query = "" }),
            ("↓ and ↑ pick a PR", 0.6, { panel.highlightedID = "d1" }),
            ("↓ and ↑ pick a PR", 0.6, { panel.highlightedID = "t1" }),
            ("↓ and ↑ pick a PR", 1.2, { panel.highlightedID = "d2" }),
            ("⌘2 switches tabs", 2.2, { panel.highlightedID = nil; panel.tab = .mine }),
        ]
        var frames: [(CGImage, Double)] = []
        for step in steps {
            step.set()
            frames.append((frame(await render(appearance), caption: step.caption, dark: appearance == .darkAqua), step.seconds))
        }
        panel.tab = .review
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, seconds) in frames {
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds]] as CFDictionary)
        }
        CGImageDestinationFinalize(gif)
    }

    /// The panel on a plain background with a caption under it, at 2x. Opaque
    /// and without a shadow: GIFs have 256 colors and no partial transparency.
    static func frame(_ panel: NSImage, caption: String, dark: Bool) -> CGImage {
        let pad: CGFloat = 20, captionHeight: CGFloat = 48, radius: CGFloat = 12
        let size = NSSize(width: panel.size.width + 2 * pad, height: panel.size.height + pad + captionHeight)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: dark ? 0.1 : 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let rect = NSRect(x: pad, y: captionHeight, width: panel.size.width, height: panel.size.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        panel.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.15)).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor(white: dark ? 0.85 : 0.2, alpha: 1),
            .paragraphStyle: style,
        ])
        text.draw(in: NSRect(x: 0, y: (captionHeight - 22) / 2, width: size.width, height: 22))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    /// 1280x640, GitHub's size for a repo's social preview.
    static func socialPreview(to dir: String) async {
        let panel = PanelState.shared
        panel.tab = .review
        panel.query = ""
        let shot = await render(.aqua)
        let size = NSSize(width: 1280, height: 640)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1), ending: NSColor(srgbRed: 0.86, green: 0.89, blue: 0.94, alpha: 1))!
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // The panel on the right, cut off at the bottom edge like a menu bar's drop-down.
        let scale: CGFloat = 1.1
        let panelSize = NSSize(width: shot.size.width * scale, height: shot.size.height * scale)
        let rect = NSRect(x: size.width - 64 - panelSize.width, y: size.height - 56 - panelSize.height, width: panelSize.width, height: panelSize.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        shot.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        let left: CGFloat = 80, width = rect.minX - left - 56
        NSApp.applicationIconImage.draw(in: NSRect(x: left - 12, y: 400, width: 160, height: 160))
        func text(_ string: String, _ font: NSFont, _ color: NSColor, in frame: NSRect) {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(in: frame)
        }
        text("PRty Time", .systemFont(ofSize: 68, weight: .bold), NSColor(white: 0.1, alpha: 1), in: NSRect(x: left, y: 300, width: width, height: 84))
        text("The GitHub pull requests waiting on you, in your Mac's menu bar.", .systemFont(ofSize: 30, weight: .regular),
             NSColor(white: 0.3, alpha: 1), in: NSRect(x: left, y: 170, width: width, height: 120))
        text("Free and open source for macOS", .systemFont(ofSize: 22, weight: .medium), NSColor(white: 0.45, alpha: 1),
             in: NSRect(x: left, y: 140, width: width, height: 30))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("social-preview.png"))
    }
}
#endif
