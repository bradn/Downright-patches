// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import UIKit
import WebKit

/// Draws SVG images, mostly README badges, into bitmaps.  iOS has no public
/// SVG decoder outside WebKit.
///
/// The SVG is loaded as an `<img>` from a `data:` URL in a hidden,
/// non-persistent web view with page JavaScript off, drawn into a canvas and
/// read back as PNG.  An SVG used as an image
/// cannot run scripts or load anything, so the markup can only draw itself.
/// One web view is reused and renders one image at a time.
@MainActor
final class SVGRasterizer: NSObject, WKNavigationDelegate {
    static let shared = SVGRasterizer()

    /// SVG wider or taller than this, in points, is scaled down to fit.
    static let maximumPoints: CGFloat = 1024

    private struct Job {
        let data: Data
        let maxPixelDimension: Int
        let completion: (UIImage?) -> Void
    }

    private var queue: [Job] = []
    private var current: Job?
    private var webView: WKWebView?
    private var timeout: Task<Void, Never>?

    func render(_ data: Data, maxPixelDimension: Int, completion: @escaping (UIImage?) -> Void) {
        queue.append(Job(data: data, maxPixelDimension: maxPixelDimension, completion: completion))
        startNext()
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = self
        // WebKit throttles a web view that has no window, so it sits at the
        // window's origin *behind* the app's own content: never visible,
        // never touched, hidden from accessibility.
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        let view = webView ?? makeWebView()
        webView = view
        if view.window == nil, let window = Self.hostWindow() {
            view.frame.origin = .zero
            window.insertSubview(view, at: 0)
        }
        let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;padding:0;background:transparent}img{display:block}</style>
            </head><body><img id="i" src="data:image/svg+xml;base64,\(job.data.base64EncodedString())"></body></html>
            """
        view.loadHTMLString(html, baseURL: nil)
        // A backstop for a render that never finishes, not a speed limit:
        // WebKit's first launch in a process is slow on a busy device (a
        // full test run measured over 10s), and a timed-out badge is
        // remembered as failed for the session.
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.complete(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await snapshot(webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    /// Only the page we load ourselves; any link or redirect is refused.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    /// Draws the decoded SVG into a canvas and reads it back as PNG.  A
    /// canvas readback does not depend on the web view painting on screen,
    /// which `takeSnapshot` does (an unpainted view snapshots transparent).
    private func snapshot(_ webView: WKWebView) async {
        guard let job = current else { return }
        let screenScale = webView.window?.screen.scale ?? 2
        // App-run script, not page script.
        let result = try? await webView.callAsyncJavaScript(
            """
            const i = document.getElementById('i');
            await i.decode();
            const w = i.naturalWidth, h = i.naturalHeight;
            if (!w || !h) { return null; }
            const fit = Math.min(1, maxPoints / Math.max(w, h));
            const pw = w * fit, ph = h * fit;
            const scale = Math.max(1, Math.min(screenScale, maxPixels / Math.max(pw, ph)));
            const c = document.createElement('canvas');
            c.width = Math.ceil(pw * scale);
            c.height = Math.ceil(ph * scale);
            c.getContext('2d').drawImage(i, 0, 0, c.width, c.height);
            return [scale, c.toDataURL('image/png')];
            """,
            arguments: [
                "maxPoints": Double(Self.maximumPoints),
                "maxPixels": Double(job.maxPixelDimension),
                "screenScale": Double(screenScale),
            ],
            contentWorld: .defaultClient) as? [Any]
        guard let result, result.count == 2,
              let scale = (result[0] as? NSNumber)?.doubleValue,
              let dataURL = result[1] as? String,
              let comma = dataURL.firstIndex(of: ","),
              let png = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: png, scale: CGFloat(scale))
        else { return complete(nil) }
        complete(image)
    }

    private func complete(_ image: UIImage?) {
        timeout?.cancel()
        timeout = nil
        guard let job = current else { return }
        current = nil
        job.completion(image)
        startNext()
    }

    private static func hostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }
}
