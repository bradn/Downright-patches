// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
// Platform shim for the shared rendering engine.
//
// The engine, fragments, and theme layer draw with Core Graphics and TextKit 2,
// both of which exist on macOS and iOS.  What differs is the class names of
// colours, fonts, and images.  Shared code names them through these aliases;
// on macOS each alias *is* the AppKit class, so the Mac build is unchanged.
// The view layer (`View/`, `Motion.swift`) stays AppKit-only, except the
// TextKit 2 content storage (`MarkdownContentStorage`,
// `ParagraphSubstitution`), which has no AppKit dependency.
#if os(macOS)
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias PlatformImage = NSImage
/// The appearance dynamic colours are snapshotted against.
public typealias PlatformAppearance = NSAppearance

extension PlatformAppearance {
    static var platformLight: PlatformAppearance? { NSAppearance(named: .aqua) }
    static var platformDark: PlatformAppearance? { NSAppearance(named: .darkAqua) }
}
#else
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias PlatformImage = UIImage
/// UIKit resolves dynamic colours against a trait collection rather than an
/// appearance object.
public typealias PlatformAppearance = UITraitCollection

extension PlatformAppearance {
    static var platformLight: PlatformAppearance? { UITraitCollection(userInterfaceStyle: .light) }
    static var platformDark: PlatformAppearance? { UITraitCollection(userInterfaceStyle: .dark) }

    func performAsCurrentDrawingAppearance(_ block: () -> Void) {
        performAsCurrent(block)
    }
}

// MARK: - AppKit colour API used by the shared engine

/// Mirrors the one `NSColorSpace` the engine converts into.
public enum PlatformColorSpace {
    case sRGB
}

extension UIColor {
    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Resolves a dynamic colour against the current traits and converts it
    /// to sRGB, as `NSColor.usingColorSpace(.sRGB)` does on the Mac.
    func usingColorSpace(_ space: PlatformColorSpace) -> UIColor? {
        let resolved = resolvedColor(with: .current)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = resolved.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)
        else { return nil }
        return UIColor(cgColor: converted)
    }

    private var rgbaComponents: (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    var redComponent: CGFloat { rgbaComponents.0 }
    var greenComponent: CGFloat { rgbaComponents.1 }
    var blueComponent: CGFloat { rgbaComponents.2 }
    var alphaComponent: CGFloat { rgbaComponents.3 }

    var brightnessComponent: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return b
    }

    convenience init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// `NSColor.blended(withFraction:of:)`: a straight sRGB mix.
    func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor? {
        guard let lhs = usingColorSpace(.sRGB), let rhs = color.usingColorSpace(.sRGB) else { return nil }
        let t = min(max(fraction, 0), 1)
        return UIColor(
            red: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * t,
            green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * t,
            blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * t,
            alpha: lhs.alphaComponent + (rhs.alphaComponent - lhs.alphaComponent) * t)
    }
}

extension UIFont {
    var isFixedPitch: Bool { fontDescriptor.symbolicTraits.contains(.traitMonoSpace) }
}

extension UIFontDescriptor.SymbolicTraits {
    static let bold = UIFontDescriptor.SymbolicTraits.traitBold
    static let italic = UIFontDescriptor.SymbolicTraits.traitItalic
}

extension CGRect {
    /// `NSRect.fill(using:)`, drawn into the current UIKit context.
    func fill(using mode: CGBlendMode) {
        UIRectFillUsingBlendMode(self, mode)
    }
}

extension UIImage {
    convenience init?(systemSymbolName name: String, accessibilityDescription: String?) {
        self.init(systemName: name)
        self.accessibilityLabel = accessibilityDescription
    }

    func withSymbolConfiguration(_ configuration: UIImage.SymbolConfiguration) -> UIImage? {
        applyingSymbolConfiguration(configuration)
    }

    /// `NSImage(size:flipped:drawingHandler:)`, rendered once up front.  UIKit
    /// image contexts are always top-left origin, so `flipped` is ignored; the
    /// shared callers only fill whole rects.
    convenience init(size: CGSize, flipped: Bool, drawingHandler: (CGRect) -> Bool) {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = drawingHandler(CGRect(origin: .zero, size: size))
        }
        if let cgImage = rendered.cgImage {
            self.init(cgImage: cgImage, scale: rendered.scale, orientation: .up)
        } else {
            self.init()
        }
    }

    /// `NSImage(cgImage:size:)`: the bitmap shown at `size` points — with
    /// one deliberate difference.  `NSImage` shows any bitmap at any point
    /// size, so on the Mac a downsampled picture still reports its *source*
    /// size.  A UIImage's point size is pixels ÷ scale, and the scale is
    /// never allowed below 1 here (a fractional scale gives blurry, oversized
    /// drawing), so a bitmap smaller than `size` reports its decoded size
    /// instead.  Fragments fit pictures to the column anyway, and the decode
    /// bound is at least the column, so this only shows for pictures wider
    /// than the column — which are scaled down on both platforms.
    convenience init(cgImage: CGImage, size: CGSize) {
        let scale = size.width > 0 ? CGFloat(cgImage.width) / size.width : 1
        self.init(cgImage: cgImage, scale: max(scale, 1), orientation: .up)
    }
}
#endif

// MARK: - Shared helpers with per-platform bodies

/// Pixels per point for rasterised fragments when no view is at hand.
func platformMainDisplayScale() -> CGFloat {
    #if os(macOS)
    NSScreen.main?.backingScaleFactor ?? 2
    #else
    UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2
    #endif
}

/// Whether the image carries an alpha channel worth matting.
func platformImageHasAlpha(_ image: PlatformImage) -> Bool {
    #if os(macOS)
    image.representations.first?.hasAlpha == true
    #else
    guard let alphaInfo = image.cgImage?.alphaInfo else { return false }
    switch alphaInfo {
    case CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast: return false
    default: return true
    }
    #endif
}

/// `PlatformFont(descriptor:size:)`, which is failable only on the Mac.
func platformFont(descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont? {
    PlatformFont(descriptor: descriptor, size: size)
}

/// Runs `body` with `cg` as the current text-drawing context, so
/// `NSAttributedString.draw` and image drawing land in it.
func withPlatformDrawingContext(_ cg: CGContext, flipped: Bool, _ body: () -> Void) {
    #if os(macOS)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: flipped)
    body()
    NSGraphicsContext.current = previous
    #else
    UIGraphicsPushContext(cg)
    body()
    UIGraphicsPopContext()
    #endif
}
