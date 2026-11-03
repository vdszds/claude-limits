import AppKit
import SwiftUI
import WebKit

/// A small claude.ai browser window bound to one account's cookie jar.
@MainActor
final class SignInController: NSObject {
    enum Purpose {
        case add
        case signInAgain(Account)
        /// Shows claude.ai's own usage page. Also how a Cloudflare check gets passed.
        case usagePage(Account)
    }

    private static var current: SignInController?

    static func present(_ purpose: Purpose, store: AccountStore) {
        current?.window.close()
        let controller = SignInController(purpose: purpose, store: store)
        current = controller
        controller.show()
    }

    private let purpose: Purpose
    private let store: AccountStore
    private let storeID: UUID
    private let dataStore: WKWebsiteDataStore
    private let webView: WKWebView
    private let window: NSWindow
    private let browser = BrowserState()
    private var popup: NSWindow?
    private var poll: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var checking = false
    private var succeeded = false
    private var pollsWithoutCookie = 0
    private var reloads = 0

    private init(purpose: Purpose, store: AccountStore) {
        self.purpose = purpose
        self.store = store
        switch purpose {
        case .add: storeID = UUID()
        case .signInAgain(let account), .usagePage(let account): storeID = account.storeID
        }
        dataStore = ClaudeWeb.dataStore(storeID)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = ClaudeWeb.userAgent

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        switch purpose {
        case .add: window.title = "Add a Claude account"
        case .signInAgain(let account): window.title = "Sign in to \(account.label)"
        case .usagePage(let account): window.title = account.label
        }
        let host = NSHostingView(rootView: BrowserView(state: browser, webView: webView))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 500, height: 720))
        window.contentMinSize = NSSize(width: 380, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.browser.address = webView.url?.absoluteString ?? "" }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.browser.canGoBack = webView.canGoBack }
            },
        ]
    }

    private var waitsForSignIn: Bool {
        if case .usagePage = purpose { return false }
        return true
    }

    private func show() {
        Task {
            if case .signInAgain = purpose { await ClaudeWeb.clearSession(in: dataStore) }
            webView.load(URLRequest(url: waitsForSignIn ? ClaudeWeb.loginPage : ClaudeWeb.usagePage))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        guard waitsForSignIn else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSignedIn() }
        }
    }

    private func checkSignedIn() {
        guard !checking, !succeeded,
              let url = webView.url, url.host()?.hasSuffix("claude.ai") == true,
              !url.path().hasPrefix("/login"), !url.path().hasPrefix("/magic-link")
        else {
            pollsWithoutCookie = 0
            return
        }

        checking = true
        Task {
            defer { checking = false }
            guard await ClaudeWeb.cookies(in: dataStore).contains(where: { $0.name == "sessionKey" }) else {
                // WebKit sometimes only exposes a fresh cookie after another navigation.
                pollsWithoutCookie += 1
                if pollsWithoutCookie >= 3, reloads < 3 {
                    pollsWithoutCookie = 0
                    reloads += 1
                    webView.reload()
                }
                return
            }
            guard let organization = try? await ClaudeWeb.primaryOrganization(store: dataStore), !succeeded else { return }
            finish(with: organization)
        }
    }

    private func finish(with organization: Organization) {
        succeeded = true
        switch purpose {
        case .add: store.add(storeID: storeID, organization: organization)
        case .signInAgain(let account), .usagePage(let account): store.reconnected(account.id, organization: organization)
        }
        window.close()
    }
}

extension SignInController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        popup?.close()
        webView.stopLoading()
        observations.removeAll()

        switch purpose {
        case .add where !succeeded:
            let id = storeID
            Task { await ClaudeWeb.removeDataStore(id) }
        case .signInAgain(let account) where !succeeded, .usagePage(let account):
            Task { await store.refresh(account.id) }
        default:
            break
        }
        if Self.current === self { Self.current = nil }
    }
}

extension SignInController: WKNavigationDelegate, WKUIDelegate {
    /// Google and Apple sign-in open a popup that has to share the opener's session.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        child.customUserAgent = ClaudeWeb.userAgent
        child.uiDelegate = self
        child.navigationDelegate = self

        let panel = NSWindow(contentRect: child.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = navigationAction.request.url?.host() ?? window.title
        panel.contentView = child
        let origin = window.frame.origin
        panel.setFrameOrigin(NSPoint(x: origin.x + 40, y: origin.y + 40))
        popup?.close()
        popup = panel
        panel.makeKeyAndOrderFront(nil)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView !== self.webView else { return }
        popup?.close()
        popup = nil
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor @Observable
final class BrowserState {
    var address = ""
    var canGoBack = false
}

/// A back button and an address field, so a sign-in link from email can be pasted in.
struct BrowserView: View {
    @Bindable var state: BrowserState
    let webView: WKWebView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { webView.goBack() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(Palette.icon).frame(width: 24, height: 22)
                }
                .disabled(!state.canGoBack)
                Button { webView.reload() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Palette.icon).frame(width: 24, height: 22)
                }
                TextField("Address", text: $state.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(open)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            WebViewHost(webView: webView)
        }
    }

    private func open() {
        var text = state.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme == "https" else { return }
        webView.load(URLRequest(url: url))
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
