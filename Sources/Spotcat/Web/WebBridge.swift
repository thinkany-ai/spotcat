import AppKit
import WebKit

/// 扩展页面和内置面板（聊天）共用的 WKWebView 封装：注入 window.spotcat、转发调用、向页面推送事件。
final class WebBridge: NSObject {
    typealias Reply = (Any?, String?) -> Void

    let webView: WKWebView
    /// 处理页面调用，返回 false 表示未知方法。reply 必须在主线程调用
    var handler: ((String, [String: Any], @escaping Reply) -> Bool)?

    private let proxy = MessageProxy()

    /// context 会以 JSON 注入页面：enter（进入参数）、i18n（locale + messages）
    init(context: [String: Any]) {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.addUserScript(WKUserScript(
            source: SpotcatRuntime.script(context: context),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        contentController.addScriptMessageHandler(proxy, contentWorld: .page, name: "spotcat")

        webView = WKWebView(frame: .zero, configuration: config)
        // 透明背景，让面板的毛玻璃透出来
        webView.setValue(false, forKey: "drawsBackground")

        super.init()
        proxy.bridge = self
        webView.navigationDelegate = self
    }

    func load(_ url: URL, readAccess: URL) {
        webView.loadFileURL(url, allowingReadAccessTo: readAccess)
    }

    /// 向页面推送事件（如 AI 流式输出）
    func emit(_ event: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: [event, payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__spotcatEvent && window.__spotcatEvent(...\(json))")
    }

    func teardown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }

    fileprivate func receive(method: String, args: [String: Any], reply: @escaping Reply) {
        if handler?(method, args, reply) != true {
            reply(nil, "Unknown method \(method)")
        }
    }
}

extension WebBridge: WKNavigationDelegate {
    /// 页面内的链接用默认浏览器打开，WebView 只停留在自己的页面
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.navigationType == .linkActivated, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

/// WKUserContentController 会强引用 handler，用弱引用代理避免循环引用
private final class MessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: WebBridge?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return replyHandler(nil, "Invalid message")
        }
        guard let bridge else { return replyHandler(nil, "Page closed") }
        bridge.receive(method: method, args: body["args"] as? [String: Any] ?? [:], reply: replyHandler)
    }
}
