// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
// Animated images (GIF, animated PNG, animated WebP) for the iOS reader.
// iOS only, like the rest of UIKitView/.
#if os(iOS)
import ImageIO
import ObjectiveC
import UIKit

/// The animation behind a decoded still image: where its bytes are, how many
/// frames it has, and how long each one shows.
///
/// Images are decoded to a single still frame everywhere (ImageIO's frame 0),
/// which is all the Mac and every still-image path ever see.  Decoding all
/// frames up front is not an option: the Downright README's demo GIF is 150
/// frames of 800×450, 216 MB decoded.  So playback streams instead, the way
/// browsers do: `AnimatedImageView` decodes the next frame shortly before it
/// is due and keeps about two in memory.
public final class AnimatedImageSource: @unchecked Sendable {
    /// Browsers show a GIF delay of 10 ms or less as 100 ms; many GIFs rely
    /// on it (a delay of 0 is common), so play them the same.
    static let minimumDelay: TimeInterval = 0.011
    static let substitutedDelay: TimeInterval = 0.1

    public let frameCount: Int
    /// Seconds each frame shows, after the browser substitution above.
    public let delays: [TimeInterval]
    /// 0 plays forever; n plays n times, then rests on the last frame.
    public let loopCount: Int
    public let pixelSize: CGSize

    private let url: URL?
    private let data: Data?

    /// `nil` for a single-frame image: those stay ordinary stills.
    public convenience init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        self.init(source: source, url: url, data: nil)
    }

    public convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        self.init(source: source, url: nil, data: data)
    }

    private init?(source: CGImageSource, url: URL?, data: Data?) {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        frameCount = count
        delays = (0..<count).map { Self.delay(of: source, at: $0) }
        loopCount = Self.loopCount(of: source)
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        pixelSize = CGSize(width: first?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0,
                           height: first?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0)
        self.url = url
        self.data = data
    }

    /// A fresh ImageIO source.  Each player decodes on its own queue with its
    /// own source rather than sharing one across threads.
    func makeImageSource() -> CGImageSource? {
        if let url { return CGImageSourceCreateWithURL(url as CFURL, nil) }
        if let data { return CGImageSourceCreateWithData(data as CFData, nil) }
        return nil
    }

    /// The fully composed frame `index` (ImageIO applies GIF disposal), no
    /// larger than `maxPixelDimension`.
    static func frame(_ index: Int, of source: CGImageSource, maxPixelDimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelDimension),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        var delay: Double?
        for (dictionary, unclamped, clamped) in Self.timingKeys {
            guard let info = properties?[dictionary] as? [CFString: Any] else { continue }
            delay = (info[unclamped] as? Double) ?? (info[clamped] as? Double)
            if delay != nil { break }
        }
        return normalized(delay ?? 0)
    }

    static func normalized(_ delay: TimeInterval) -> TimeInterval {
        delay < minimumDelay ? substitutedDelay : delay
    }

    static func loopCount(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        for (dictionary, key) in Self.loopKeys {
            if let info = properties?[dictionary] as? [CFString: Any], let count = info[key] as? Int {
                return max(0, count)
            }
        }
        return 0
    }

    private static let timingKeys: [(CFString, CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ]

    private static let loopKeys: [(CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
    ]
}

private nonisolated(unsafe) var animatedSourceKey: UInt8 = 0

extension UIImage {
    /// The animation this still frame belongs to, if it has more than one
    /// frame.  Carried on the image itself so every cache and code path that
    /// already handles stills passes animations through untouched.
    public var animatedSource: AnimatedImageSource? {
        get { objc_getAssociatedObject(self, &animatedSourceKey) as? AnimatedImageSource }
        set { objc_setAssociatedObject(self, &animatedSourceKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Plays an `AnimatedImageSource`, decoding each frame shortly before it is
/// due on a background queue and showing it as the layer's contents.
///
/// It runs only while it is worth the battery: in a window, at least partly
/// on screen, with the app active, and with Reduce Motion off.  Otherwise it
/// rests on the frame it has.
public final class AnimatedImageView: UIView {
    /// Overridable so tests can drive either branch.
    public nonisolated(unsafe) static var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    public let animation: AnimatedImageSource
    private var source: CGImageSource?
    private var link: CADisplayLink?
    private let queue = DispatchQueue(label: "downright.animated-image", qos: .userInitiated)
    private(set) var frameIndex = 0
    private var dueTime: CFTimeInterval = 0
    private var decoding = false
    private var loopsCompleted = 0
    private var isFinished = false
    private var observers: [NSObjectProtocol] = []

    public init(animation: AnimatedImageSource, still: CGImage?) {
        self.animation = animation
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.contents = still
        layer.contentsGravity = .resize
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }


    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRunning()
    }

    var isRunning: Bool { link != nil }

    func updateRunning() {
        let shouldRun = window != nil && !isFinished && !Self.reduceMotion()
            && UIApplication.shared.applicationState != .background
        if shouldRun, link == nil {
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            dueTime = 0
        } else if !shouldRun, let link {
            link.invalidate()
            self.link = nil
        }
    }

    /// Off-screen views keep their link but skip decoding, so scrolling back
    /// resumes at once without re-registering.
    private var isOnScreen: Bool {
        guard let window, !isHidden, alpha > 0 else { return false }
        return convert(bounds, to: window).intersects(window.bounds)
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard isOnScreen else {
            dueTime = 0
            return
        }
        let now = link.timestamp
        if dueTime == 0 { dueTime = now + animation.delays[frameIndex] }
        guard now >= dueTime, !decoding else { return }
        guard let next = Self.nextFrame(after: frameIndex, of: animation, loopsCompleted: &loopsCompleted) else {
            isFinished = true
            updateRunning()
            return
        }
        decoding = true
        let animation = animation
        let scale = window?.screen.scale ?? 2
        let pixels = Int(ceil(max(bounds.width, bounds.height) * scale))
        if source == nil { source = animation.makeImageSource() }
        guard let source else { return }
        queue.async { [weak self] in
            let image = AnimatedImageSource.frame(next, of: source, maxPixelDimension: pixels)
            DispatchQueue.main.async {
                guard let self else { return }
                self.decoding = false
                if let image { self.layer.contents = image }
                self.frameIndex = next
                self.dueTime = now + animation.delays[next]
            }
        }
    }

    /// The frame after `index`, or `nil` once a finite loop count is used up
    /// (the view then rests on the last frame, as browsers do).
    static func nextFrame(after index: Int, of animation: AnimatedImageSource, loopsCompleted: inout Int) -> Int? {
        let next = index + 1
        guard next >= animation.frameCount else { return next }
        loopsCompleted += 1
        if animation.loopCount > 0, loopsCompleted >= animation.loopCount { return nil }
        return 0
    }
}

/// `CADisplayLink` retains its target; this keeps the view free to go away.
private final class DisplayLinkTarget {
    weak var view: AnimatedImageView?
    init(_ view: AnimatedImageView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.tick(link)
    }
}

#endif
