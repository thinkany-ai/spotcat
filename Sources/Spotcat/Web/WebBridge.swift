import AppKit
import WebKit

/// 扩展页面和内置面板（聊天）共用的 WKWebView 封装：注入 window.spotcat、转发调用、向页面推送事件。
final class WebBridge: NSObject {
    typealias Reply = (Any?, String?) -> Void

    let webView: WKWebView
    /// 处理页面调用，返回 false 表示未知方法。reply 必须在主线程调用
    var handler: ((String, [String: Any], @escaping Reply) -> Bool)?

    private let proxy = MessageProxy()
    private var devReloadObserver: NSObjectProtocol?

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

        webView = DraggableWebView(frame: .zero, configuration: config)
        // 透明背景，让面板的毛玻璃透出来
        webView.setValue(false, forKey: "drawsBackground")

        super.init()
        proxy.bridge = self
        webView.navigationDelegate = self
        observeDevReload()
    }

    deinit {
        if let devReloadObserver { NotificationCenter.default.removeObserver(devReloadObserver) }
    }

    /// make dev：源码里的页面文件改动后刷新。只改了 CSS 时就地替换样式表，页面状态（如对话内容）保留
    private func observeDevReload() {
        guard DevReload.start() else { return }
        devReloadObserver = NotificationCenter.default.addObserver(forName: DevReload.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let page = self.webView.url, page.isFileURL else { return }
            let paths = note.userInfo?[DevReload.pathsKey] as? [String] ?? []
            let pageDirectory = page.deletingLastPathComponent().path + "/"
            let related = paths.filter { $0.hasPrefix(pageDirectory) }
            guard !related.isEmpty else { return }
            if related.allSatisfy({ $0.hasSuffix(".css") }) {
                self.webView.evaluateJavaScript("""
                    document.querySelectorAll('link[rel="stylesheet"]').forEach(l => {
                      l.href = l.href.split('?')[0] + '?' + Date.now()
                    })
                    """)
            } else {
                self.webView.reload()
            }
        }
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
        if method == "window.drag" {
            (webView as? DraggableWebView)?.dragWindow()
            return reply(true, nil)
        }
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

/// 网页会吞掉鼠标事件，窗口没法按背景拖动。页面在可拖动区域按下鼠标时调用 "window.drag"，
/// 这里用记下的那次按下事件让窗口跟着鼠标走（与 Tauri 的 drag region 同一做法）
final class DraggableWebView: WKWebView {
    private var lastMouseDown: NSEvent?

    override func mouseDown(with event: NSEvent) {
        lastMouseDown = event
        super.mouseDown(with: event)
    }

    func dragWindow() {
        // 消息是异步到达的，鼠标已经松开就不拖了
        guard let event = lastMouseDown, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        window?.performDrag(with: event)
    }
}
