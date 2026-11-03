import AppKit
import SwiftUI

/// `Limits --snapshot <dir>` renders the dropdown and menu bar bars with sample data to PNGs, for design review,
/// and the README's hero image.
@MainActor
enum Snapshot {
    static let directory: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()

    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    private static let cardBackground = (light: UInt32(0xF0F0F2), dark: UInt32(0x2A2A2C))

    static func render(to directory: String) {
        let folder = URL(fileURLWithPath: directory)
        let cases: [(String, AccountStore.Demo, Int?)] = [
            ("accounts", .accounts, nil), ("problem", .problem, nil), ("empty", .empty, nil), ("many", .many, nil),
            ("hover-expanded", .many, 0), ("hover-collapsed", .many, 2),
        ]
        for (name, demo, hovered) in cases {
            for (mode, appearance) in appearances {
                guard let rep = dropdown(AccountStore(demo: demo), hovered: hovered, appearance: appearance) else { continue }
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(mode).png"))
            }
        }
        renderMenuBar(to: folder)
        renderHero(to: folder)
    }

    private static func dropdown(_ store: AccountStore, hovered: Int? = nil, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        let root = PopoverView(store: store, previewHoverIndex: hovered)
            .background(Color(light: cardBackground.light, dark: cardBackground.dark))
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        // The account list measures itself first, then sizes its scroll view, so lay out twice.
        for _ in 0..<2 {
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        view.display()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Bars for 3, 6 and 10 accounts on a light and a dark menu bar, tinted the way macOS tints template images.
    private static func renderMenuBar(to folder: URL) {
        let rows: [[Double?]] = [
            [42, 93, 12],
            [42, 93, 12, 100, nil, 67],
            [42, 93, 12, 100, 0, 67, 25, 80, 5, 55],
        ]
        for (mode, background, ink) in [("light", 0xE8E8EC, 0x1A1A1A), ("dark", 0x2B2B2E, 0xF2F2F2)] as [(String, UInt32, UInt32)] {
            let size = NSSize(width: 120, height: CGFloat(rows.count) * 24 + 8)
            writePNG(size: size, scale: 4, to: folder.appending(path: "menubar-\(mode).png")) {
                NSColor(hex: background).setFill()
                NSRect(origin: .zero, size: size).fill()
                for (index, levels) in rows.enumerated() {
                    let image = tinted(MenuBarBars.image(levels: levels), ink: NSColor(hex: ink))
                    let y = size.height - CGFloat(index + 1) * 24
                    image.draw(in: NSRect(x: 12, y: y + 4, width: image.size.width, height: image.size.height))
                }
            }
        }
    }

    /// The six sample accounts' dropdown hanging from its menu bar item, the way it opens on screen.
    private static func renderHero(to folder: URL) {
        let store = AccountStore(demo: .many)
        let margin: CGFloat = 48
        let menuBarHeight: CGFloat = 24
        for (mode, appearance) in appearances {
            guard let card = dropdown(store, appearance: appearance) else { continue }
            let dark = appearance == .darkAqua
            let ink = NSColor(hex: dark ? 0xF2F2F2 : 0x1A1A1A)
            let size = NSSize(width: card.size.width + margin * 2, height: menuBarHeight + DropdownPanel.cardInset.top + card.size.height + margin)

            writePNG(size: size, scale: 2, to: folder.appending(path: "hero-\(mode).png")) {
                NSGradient(starting: NSColor(hex: dark ? 0x141826 : 0xE9EEF6), ending: NSColor(hex: dark ? 0x2B3550 : 0xC9D6EA))?
                    .draw(in: NSRect(origin: .zero, size: size), angle: 90)
                let bar = NSRect(x: 0, y: size.height - menuBarHeight, width: size.width, height: menuBarHeight)
                NSColor(hex: dark ? 0x1E1E22 : 0xF4F5F8).withAlphaComponent(0.85).setFill()
                bar.fill()

                // The item is highlighted while its dropdown is open, and the card hangs from its left edge.
                let icon = tinted(MenuBarBars.image(levels: store.menuBarLevels()), ink: ink)
                let item = NSRect(x: margin, y: bar.minY + 2, width: icon.size.width + 16, height: menuBarHeight - 4)
                ink.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: item, xRadius: 5, yRadius: 5).fill()
                icon.draw(in: NSRect(x: item.minX + 8, y: bar.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))

                // A clock and a couple of system items on the right, so it reads as a menu bar.
                let clock = NSAttributedString(string: "Tue 9:41", attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: ink])
                var x = size.width - 12 - clock.size().width
                clock.draw(at: NSPoint(x: x, y: bar.midY - clock.size().height / 2))
                for name in ["battery.75percent", "wifi"] {
                    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) else { continue }
                    x -= symbol.size.width + 14
                    tinted(symbol, ink: ink).draw(in: NSRect(x: x, y: bar.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
                }

                let cardRect = NSRect(x: margin, y: bar.minY - DropdownPanel.cardInset.top - card.size.height, width: card.size.width, height: card.size.height)
                let outline = NSBezierPath(roundedRect: cardRect, xRadius: DropdownPanel.cornerRadius, yRadius: DropdownPanel.cornerRadius)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowBlurRadius = 16
                shadow.shadowOffset = NSSize(width: 0, height: -6)
                shadow.set()
                // Filled with the card's own colour, so no dark fringe shows at the rounded corners.
                NSColor(hex: dark ? cardBackground.dark : cardBackground.light).setFill()
                outline.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                card.draw(in: cardRect)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private static func tinted(_ image: NSImage, ink: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func writePNG(size: NSSize, scale: CGFloat, to url: URL, draw: () -> Void) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
