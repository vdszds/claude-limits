import AppKit
import SwiftUI

/// `Limits --snapshot <dir>` renders the dropdown and menu bar bars with sample data to PNGs, for design review.
@MainActor
enum Snapshot {
    static let directory: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()

    static func render(to directory: String) {
        let folder = URL(fileURLWithPath: directory)
        let cases: [(String, AccountStore.Demo, Int?)] = [
            ("accounts", .accounts, nil), ("problem", .problem, nil), ("empty", .empty, nil), ("many", .many, nil),
            ("hover-expanded", .many, 0), ("hover-collapsed", .many, 2),
        ]
        for (name, demo, hovered) in cases {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let root = PopoverView(store: AccountStore(demo: demo), previewHoverIndex: hovered)
                    .background(Color(light: 0xF0F0F2, dark: 0x2A2A2C))
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

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(mode).png"))
            }
        }
        renderMenuBar(to: folder)
    }

    /// Bars for 3, 6 and 10 accounts on a light and a dark menu bar, tinted the way macOS tints template images.
    private static func renderMenuBar(to folder: URL) {
        let rows: [[Double?]] = [
            [42, 93, 12],
            [42, 93, 12, 100, nil, 67],
            [42, 93, 12, 100, 0, 67, 25, 80, 5, 55],
        ]
        for (mode, background, ink) in [("light", 0xE8E8EC, 0x1A1A1A), ("dark", 0x2B2B2E, 0xF2F2F2)] as [(String, UInt32, UInt32)] {
            let scale: CGFloat = 4
            let size = NSSize(width: 120, height: CGFloat(rows.count) * 24 + 8)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            NSColor(hex: background).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, levels) in rows.enumerated() {
                let image = MenuBarBars.image(levels: levels)
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor(hex: ink).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let y = size.height - CGFloat(index + 1) * 24
                tinted.draw(in: NSRect(x: 12, y: y + 4, width: image.size.width, height: image.size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "menubar-\(mode).png"))
        }
    }
}
