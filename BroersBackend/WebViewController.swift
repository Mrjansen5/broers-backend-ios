// Shows the existing web app and hands the Radio tab's buttons to the native RadioEngine.
// The bridge script (RadioBridge.js, injected into the page) catches taps on Join / Leave / the big mute button
// before the web Radio sees them and posts them here as { cmd: ... } messages. The engine pushes its state back
// into the page with window.__broersNative.update(state), so the Radio tab looks the same as on Android and the web.
import UIKit
import WebKit
import AVFoundation

final class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://broersbackend.snjco.ca/cal/")!
    private var web: WKWebView!

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default() // keeps the sign-in (localStorage 'bcal_token') between launches
        if #available(iOS 14.0, *) { cfg.limitsNavigationsToAppBoundDomains = true } // lets the page's service worker run
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(self), name: "broersRadio")
        if let url = Bundle.main.url(forResource: "RadioBridge", withExtension: "js"),
           let src = try? String(contentsOf: url) {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        // Tell the page it is inside the iPhone app before any of its own scripts run.
        // navigator.standalone = true: the page treats the app as "installed" and stops showing its Add-to-Home-Screen banner.
        let early = "window.BROERS_IOS_APP = '1.0.0'; try { Object.defineProperty(navigator, 'standalone', { get: () => true }) } catch (e) {}"
        ucc.addUserScript(WKUserScript(source: early, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        cfg.applicationNameForUserAgent = "BroersBackendiOS/1.0.0"

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 15 / 255, green: 13 / 255, blue: 12 / 255, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        RadioEngine.shared.onState = { [weak self] json in
            self?.web.evaluateJavaScript("window.__broersNative && window.__broersNative.update(\(json))", completionHandler: nil)
        }
        web.load(URLRequest(url: Self.home))
    }

    @objc private func reload(_ sender: UIRefreshControl) {
        web.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sender.endRefreshing() }
    }

    // MARK: page -> native
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else { return }
        let radio = RadioEngine.shared
        switch cmd {
        case "join":
            let token = m["token"] as? String ?? ""
            radio.join(token: token, myName: m["name"] as? String ?? "You")
        case "leave": radio.leave(reason: "left")
        case "toggle": radio.toggle(source: "screen")
        case "mode":
            if let callkit = m["callkit"] as? Bool { radio.setUseCallKit(callkit) }
        case "hello": radio.pushState()
        default: break
        }
    }

    // MARK: navigation — our own pages stay inside the app; everything else opens in Safari
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let ours = url.host == Self.home.host || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data"
        if ours { return decisionHandler(.allow) }
        if ["http", "https", "tel", "mailto", "sms", "maps"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.host == Self.home.host { webView.load(URLRequest(url: url)) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // The page's own camera/mic uses (receipt photos etc.) — the person already allowed it for the app.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Self.home.host ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
}

// WKUserContentController holds its handlers strongly; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
