import AppKit
import WebKit
import PelicanCore

@MainActor
final class ThumbnailRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    func render(_ svg: String) async throws -> Data {
        try SVGValidator.validate(svg)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 480), configuration: config)
            view.navigationDelegate = self
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view; window.setFrameOrigin(NSPoint(x: -2000, y: -2000)); window.orderBack(nil)
            self.window = window; self.webView = view
            view.loadHTMLString("""
            <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:white}body>svg{display:block;width:100%;height:100%}</style></head><body>\(svg)</body></html>
            """, baseURL: nil)
            timeout = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { finish(.failure(NSError(domain: "Thumbnail", code: 1))) } }
            if Task.isCancelled { finish(.failure(CancellationError())) }
          }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration(); config.rect = webView.bounds; config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { [weak self] image, error in
            Task { @MainActor in
                if let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) { self?.finish(.success(png)) }
                else { self?.finish(.failure(error ?? NSError(domain: "Thumbnail", code: 2))) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil; webView?.stopLoading(); webView = nil; window?.close(); window = nil
        continuation.resume(with: result)
    }
}
