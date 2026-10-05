// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
// AppKit names the shared-engine tests use, mapped to UIKit so the same test
// files run on iOS.  On macOS this file is empty.
#if !os(macOS)
import UIKit
@testable import MarkdownRender

typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSImage = UIImage
typealias NSAppearance = UITraitCollection
typealias NSSize = CGSize
typealias NSRect = CGRect

extension UITraitCollection {
    enum Name { case aqua, darkAqua }

    convenience init?(named name: Name) {
        self.init(userInterfaceStyle: name == .darkAqua ? .dark : .light)
    }

    static func currentDrawing() -> UITraitCollection { .current }

    /// `NSAppearance.name`, for test messages.
    var name: (rawValue: String, Void) {
        (userInterfaceStyle == .dark ? "darkAqua" : "aqua", ())
    }
}

extension UIImage {
    /// `NSImage(size:)`: a blank image of that size.
    convenience init(size: CGSize) {
        self.init(size: size, flipped: false) { _ in true }
    }
}
#endif
