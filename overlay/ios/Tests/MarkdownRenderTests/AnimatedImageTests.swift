// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
// Animated images in the UIKit reader.  iOS only.
#if os(iOS)
import ImageIO
import MarkdownCore
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import MarkdownRender

/// A GIF built in memory: one solid frame per entry, each with its delay.
func makeGIF(delays: [Double], loopCount: Int = 0, size: CGSize = CGSize(width: 40, height: 20)) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, delays.count, nil)!
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
    ] as CFDictionary)
    for (index, delay) in delays.enumerated() {
        let shade = CGFloat(index) / CGFloat(max(1, delays.count - 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let frame = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        CGImageDestinationAddImage(destination, frame.cgImage!, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                            kCGImagePropertyGIFUnclampedDelayTime: delay],
        ] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
@Suite("Animated images")
struct AnimatedImageTests {
    @Test("Frame count, delays and loop count are read from the file")
    func parsesTiming() throws {
        let animation = try #require(AnimatedImageSource(data: makeGIF(delays: [0.05, 0, 0.2], loopCount: 2)))
        #expect(animation.frameCount == 3)
        // A delay of 0 plays as 100 ms, as in browsers.
        #expect(animation.delays.map { ($0 * 1000).rounded() } == [50, 100, 200])
        #expect(animation.loopCount == 2)
        #expect(animation.pixelSize == CGSize(width: 40, height: 20))
    }

    @Test("A single-frame image is not an animation")
    func stillsStayStill() {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        #expect(AnimatedImageSource(data: png) == nil)
        #expect(AnimatedImageSource(data: makeGIF(delays: [0.1])) == nil)
    }

    @Test("Frames advance, loop forever, or stop after a finite loop count")
    func frameSequence() throws {
        let forever = try #require(AnimatedImageSource(data: makeGIF(delays: [0.1, 0.1, 0.1])))
        var loops = 0
        var frames: [Int] = []
        var index = 0
        for _ in 0..<7 {
            index = try #require(AnimatedImageView.nextFrame(after: index, of: forever, loopsCompleted: &loops))
            frames.append(index)
        }
        #expect(frames == [1, 2, 0, 1, 2, 0, 1])

        let twice = try #require(AnimatedImageSource(data: makeGIF(delays: [0.1, 0.1], loopCount: 2)))
        loops = 0
        index = 0
        var played: [Int?] = []
        for _ in 0..<4 {
            let next = AnimatedImageView.nextFrame(after: index, of: twice, loopsCompleted: &loops)
            played.append(next)
            index = next ?? index
        }
        // 0 1 | 0 1 | then rest on the last frame.
        #expect(played == [1, 0, 1, nil])
    }

    @Test("Each frame decodes, composed and within the size bound")
    func decodesFrames() throws {
        let animation = try #require(AnimatedImageSource(data: makeGIF(delays: [0.1, 0.1, 0.1], size: CGSize(width: 200, height: 100))))
        let source = try #require(animation.makeImageSource())
        for index in 0..<3 {
            let frame = try #require(AnimatedImageSource.frame(index, of: source, maxPixelDimension: 50))
            #expect(max(frame.width, frame.height) <= 50)
        }
    }

    // MARK: - In the reader

    private func reader(_ markdown: String, loader: RemoteImageLoading) -> MarkdownReaderView {
        let sheet = StyleSheet(theme: .fallback, appearance: UITraitCollection(userInterfaceStyle: .light))
        let view = MarkdownReaderView(styleSheet: sheet)
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        view.remoteImageLoader = loader
        view.setMarkdown(markdown)
        view.layoutIfNeeded()
        // Fragments draw (block images) when the layer renders.
        _ = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        return view
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func overlays(in view: UIView) -> [AnimatedImageView] {
        view.subviews.compactMap { $0 as? AnimatedImageView }
    }

    @Test("Block and inline GIFs each get one live view")
    func readerPlacesOverlays() async throws {
        let loader = AnimatedStubLoader(data: makeGIF(delays: [0.1, 0.1, 0.1]))
        let view = reader("""
            ![block](https://img.example/a.gif)

            Inline ![dot](https://img.example/b.gif) here.
            """, loader: loader)
        await settle()
        let live = overlays(in: view)
        #expect(live.count == 2)
        #expect(live.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
    }

    @Test("Reduce Motion shows stills: no live views")
    func reduceMotionShowsStills() async throws {
        let saved = AnimatedImageView.reduceMotion
        AnimatedImageView.reduceMotion = { true }
        defer { AnimatedImageView.reduceMotion = saved }
        let loader = AnimatedStubLoader(data: makeGIF(delays: [0.1, 0.1, 0.1]))
        let view = reader("![block](https://img.example/a.gif)\n\nInline ![dot](https://img.example/b.gif) here.",
                          loader: loader)
        await settle()
        #expect(overlays(in: view).isEmpty)
    }
}

/// Serves every URL as the same decoded GIF, still frame plus animation, the
/// way the app's loader does.
private final class AnimatedStubLoader: RemoteImageLoading {
    let image: UIImage
    init(data: Data) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        image = UIImage(cgImage: CGImageSourceCreateImageAtIndex(source, 0, nil)!)
        image.animatedSource = AnimatedImageSource(data: data)
    }
    func cachedImage(for url: URL, maxPixelDimension: Int) -> PlatformImage? { image }
    func hasFailed(_ url: URL) -> Bool { false }
    func loadImage(for url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (PlatformImage?) -> Void) {}
}
#endif
