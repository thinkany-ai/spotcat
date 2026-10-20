import AppKit
import WebKit

final class Runner: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var window: NSWindow!
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    func start() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "testResult")
        let width = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 1200 : 1200
        let height = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 466 : 466
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        if CommandLine.arguments.contains("--dark") { webView.appearance = NSAppearance(named: .darkAqua) }
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fputs("FAIL: WebKit test timeout\n", stderr); exit(1) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let script = try String(contentsOf: root.appendingPathComponent("tests.js"), encoding: .utf8)
            webView.evaluateJavaScript(script + "\n;void 0;") { _, error in
                if let error { print("FAIL: \(error)"); exit(1) }
            }
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let result = message.body as? [String: Any] else { exit(1) }
        if let progress = result["progress"] as? String { print("PASS: \(progress)"); fflush(stdout); return }
        for line in result["results"] as? [String] ?? [] where line.hasPrefix("INFO:") { print(line) }
        if let error = result["error"] { print("FAIL: \(error)") }
        exit(result["ok"] as? Bool == true ? 0 : 1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let runner = Runner()
runner.start()
app.run()
