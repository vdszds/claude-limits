import AppKit

/// One vertical bar per account, filled from the bottom by its usage, drawn as a template image so the menu bar tints it.
enum MenuBarBars {
    static func image(levels: [Double?]) -> NSImage {
        let barWidth: CGFloat = levels.count <= 6 ? 4 : 3
        let gap: CGFloat = 2
        let barHeight: CGFloat = 14
        let width = CGFloat(levels.count) * barWidth + CGFloat(max(levels.count - 1, 0)) * gap

        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            for (index, level) in levels.enumerated() {
                let x = CGFloat(index) * (barWidth + gap)
                let track = NSRect(x: x, y: 1, width: barWidth, height: barHeight)
                // A template image only has alpha to work with, so the empty part is a lighter tone of the same colour.
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

                guard let level, level > 0 else { continue }
                let filled = max(2, (barHeight * min(level, 100) / 100).rounded())
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barWidth, height: filled), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
