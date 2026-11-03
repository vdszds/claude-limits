import AppKit
import SwiftUI

/// The menu bar item and its dropdown.
///
/// The dropdown window never changes size while it's open. It is a fixed, transparent frame hanging from the menu bar,
/// and only the card inside it grows and shrinks. Resizing the window itself went wrong both ways: SwiftUI's
/// MenuBarExtra resized around its centre and left the old shadow behind, and a resized panel lost keyboard focus
/// after a real click, which closed the dropdown on every collapse.
@MainActor
final class StatusController: NSObject {
    static let width: CGFloat = 320
    private static let screenMargin: CGFloat = 8

    private let store: AccountStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = DropdownPanel()
    private var contentHeight: CGFloat = 0
    private var maxCardHeight: CGFloat = .greatestFiniteMagnitude
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var closedAt = Date.distantPast

    init(store: AccountStore) {
        self.store = store
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }

        let root = PopoverView(store: store)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.contentHeightChanged(height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        panel.setContent(root)
        panel.onCancel = { [weak self] in self?.close() }
        panel.onClickOutsideCard = { [weak self] in self?.close() }
        observeLabel()
    }

    // MARK: Menu bar label

    private func observeLabel() {
        withObservationTracking {
            updateLabel()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    private func updateLabel() {
        guard let button = item.button else { return }
        if store.showsMenuBarBars {
            button.title = ""
            button.image = MenuBarBars.image(levels: store.menuBarLevels())
            button.imagePosition = .imageOnly
        } else if let text = store.menuBarText() {
            button.image = nil
            button.title = text
            button.imagePosition = .noImage
        } else {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Claude Limits")
            image?.isTemplate = true
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        }
    }

    // MARK: Panel

    @objc private func toggle() {
        if panel.isVisible {
            close()
            return
        }
        guard Date.now.timeIntervalSince(closedAt) > 0.25 else { return }
        open()
    }

    private func open() {
        store.refreshIfStale()
        guard let button = item.button, let buttonWindow = button.window else { return }
        let itemRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let inset = DropdownPanel.cardInset

        // From the bottom of the menu bar down to the bottom of the screen, wide enough for the card's shadow.
        let top = min(itemRect.minY, visible.maxY)
        let bottom = visible.minY + Self.screenMargin
        let cardX = max(visible.minX + Self.screenMargin, min(itemRect.minX, visible.maxX - Self.width - Self.screenMargin))
        panel.setFrame(NSRect(x: cardX - inset.left, y: bottom, width: Self.width + inset.left + inset.right, height: top - bottom), display: false)
        maxCardHeight = top - bottom - inset.top - inset.bottom
        panel.setCardHeight(min(max(contentHeight, 1), maxCardHeight))

        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        watchForDismissal()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = .now
        item.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// Closes like a menu: a click in another app, another app coming forward, or one of this app's windows
    /// (the sign-in window) taking focus.
    private func watchForDismissal() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(monitor)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window !== self.panel, window.canBecomeMain else { return }
                self.close()
            }
        })
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 1, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard panel.isVisible else { return }
        panel.setCardHeight(min(height, maxCardHeight))
    }
}

/// A transparent, borderless panel holding the glass card. It can take keyboard focus (for renaming and Escape)
/// without activating the app, like a menu.
final class DropdownPanel: NSPanel {
    /// Room around the card inside the window: a small gap under the menu bar and space for the card's shadow.
    static let cardInset = NSEdgeInsets(top: 5, left: 28, bottom: 44, right: 28)
    private static let cornerRadius: CGFloat = 16

    var onCancel: (() -> Void)?
    var onClickOutsideCard: (() -> Void)?

    private let root = DropdownRootView()
    private let shadowView = NSView()
    private let clipView = NSView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: StatusController.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        root.wantsLayer = true
        root.onClickOutsideCard = { [weak self] in self?.onClickOutsideCard?() }

        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.3
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)

        // The glass draws its own shadow, which would be cut off square at the card's edge, so clip it to the corners.
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Self.cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true

        root.addSubview(shadowView)
        root.addSubview(clipView)
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Puts the SwiftUI content on the system glass, or a popover material before macOS 26.
    func setContent<Content: View>(_ content: Content) {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []

        let background: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = hosting
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            background = effect
        }
        background.frame = clipView.bounds
        background.autoresizingMask = [.width, .height]
        clipView.addSubview(background)
    }

    /// Sizes the card from the top; the window around it stays as it is.
    func setCardHeight(_ height: CGFloat) {
        let inset = Self.cardInset
        let card = NSRect(x: inset.left, y: inset.top, width: StatusController.width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipView.frame = card
        shadowView.frame = card
        shadowView.layer?.shadowPath = CGPath(
            roundedRect: shadowView.bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil
        )
        CATransaction.commit()
        root.cardFrame = card
        root.displayIfNeeded()
    }
}

/// The window's transparent content. A click outside the card closes the panel, like clicking outside a menu.
private final class DropdownRootView: NSView {
    var cardFrame: NSRect = .zero
    var onClickOutsideCard: (() -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return cardFrame.contains(local) ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        onClickOutsideCard?()
    }
}
