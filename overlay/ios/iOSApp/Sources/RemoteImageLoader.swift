// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import ImageIO
import MarkdownRender
import UIKit

/// Fetches `https:` images for documents when Settings > Apps > Downright >
/// Load Remote Images is on.
///
/// Loading a web image tells its server your IP address and when you opened
/// the document, which is why the Mac app never does it and why this one has
/// a switch.  Requests carry no cookies or credentials, and responses go
/// through a small cache of their own.
@MainActor
final class RemoteImageLoader: RemoteImageLoading {
    static let shared = RemoteImageLoader()

    /// Larger responses are refused rather than decoded.
    nonisolated static let maximumBytes = 20 * 1024 * 1024

    private let session: URLSession
    private let images = NSCache<NSString, UIImage>()
    private var failed: Set<URL> = []
    private var waiting: [URL: [@MainActor (PlatformImage?) -> Void]] = [:]

    init(session: URLSession = RemoteImageLoader.makeSession()) {
        self.session = session
        images.totalCostLimit = 64 * 1024 * 1024
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            directory: caches?.appendingPathComponent("RemoteImages", isDirectory: true))
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }

    nonisolated func cachedImage(for url: URL, maxPixelDimension: Int) -> PlatformImage? {
        MainActor.assumeIsolated { images.object(forKey: Self.key(url, maxPixelDimension)) }
    }

    nonisolated func hasFailed(_ url: URL) -> Bool {
        MainActor.assumeIsolated { failed.contains(url) }
    }

    nonisolated func loadImage(
        for url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (PlatformImage?) -> Void
    ) {
        MainActor.assumeIsolated {
            start(url, maxPixelDimension: maxPixelDimension, completion: completion)
        }
    }

    /// Forgets failures, so a document reopened after the network comes back
    /// tries again.
    func forgetFailures() {
        failed.removeAll()
    }

    private func start(_ url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (PlatformImage?) -> Void) {
        guard waiting[url] == nil else {
            waiting[url]?.append(completion)
            return
        }
        waiting[url] = [completion]
        let request = URLRequest(url: url)
        session.dataTask(with: request) { [weak self] data, response, error in
            let decoded = Self.decode(data: data, response: response, error: error,
                                      maxPixelDimension: maxPixelDimension)
            Task { @MainActor in
                self?.finish(url, maxPixelDimension: maxPixelDimension, result: decoded)
            }
        }.resume()
    }

    private func finish(_ url: URL, maxPixelDimension: Int, result: Decoded) {
        let image: UIImage?
        switch result {
        case .image(let decoded):
            image = decoded
        case .svg(let data):
            // SVG needs WebKit, which lives on the main thread.
            SVGRasterizer.shared.render(data, maxPixelDimension: maxPixelDimension) { [weak self] rendered in
                self?.deliver(url, maxPixelDimension: maxPixelDimension, image: rendered)
            }
            return
        case .failed:
            image = nil
        }
        deliver(url, maxPixelDimension: maxPixelDimension, image: image)
    }

    private func deliver(_ url: URL, maxPixelDimension: Int, image: UIImage?) {
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            images.setObject(image, forKey: Self.key(url, maxPixelDimension), cost: cost)
        } else {
            failed.insert(url)
        }
        let completions = waiting.removeValue(forKey: url) ?? []
        completions.forEach { $0(image) }
    }

    private nonisolated static func key(_ url: URL, _ dimension: Int) -> NSString {
        "\(dimension)|\(url.absoluteString)" as NSString
    }

    enum Decoded {
        case image(UIImage)
        case svg(Data)
        case failed
    }

    /// Runs on the session's queue: checks the response and decodes raster
    /// formats, downsampled the way local images are.
    nonisolated static func decode(data: Data?, response: URLResponse?, error: Error?,
                                   maxPixelDimension: Int) -> Decoded {
        guard error == nil, let data, !data.isEmpty, data.count <= maximumBytes else { return .failed }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return .failed }
        let mime = (response?.mimeType ?? "").lowercased()
        if mime.contains("svg") || looksLikeSVG(data) { return .svg(data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .failed }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed
        }
        // Sized exactly as local images are (`PlatformImage(cgImage:size:)`):
        // one point per source pixel, except that a downsampled picture never
        // gets a scale below 1, so it reports its decoded size instead.  The
        // decode bound is always at least the column, which the fragment fits
        // pictures to anyway.
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? CGFloat(cgImage.width)
        let scale = sourceWidth > 0 ? max(1, CGFloat(cgImage.width) / sourceWidth) : 1
        return .image(UIImage(cgImage: cgImage, scale: scale, orientation: .up))
    }

    nonisolated static func looksLikeSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }
}
