// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import MarkdownRender
import XCTest
@testable import DownrightIOS

final class RemoteImageLoaderTests: XCTestCase {
    private let url = URL(string: "https://img.example/a.png")!

    private func response(_ status: Int, mime: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": mime])!
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    func testRasterImagesDecodeAtOnePointPerSourcePixel() throws {
        let decoded = RemoteImageLoader.decode(
            data: png(width: 300, height: 120), response: response(200, mime: "image/png"),
            error: nil, maxPixelDimension: 2048)
        guard case .image(let image) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(image.size.width, 300, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 120, accuracy: 0.5)
    }

    func testLargeImagesAreDownsampledLikeLocalImages() throws {
        let decoded = RemoteImageLoader.decode(
            data: png(width: 1600, height: 400), response: response(200, mime: "image/png"),
            error: nil, maxPixelDimension: 400)
        guard case .image(let image) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertLessThanOrEqual(image.cgImage?.width ?? .max, 400)
        // Scale never drops below 1, as for local images, so the point size
        // is the decoded size and the aspect ratio holds.
        XCTAssertEqual(image.scale, 1)
        XCTAssertEqual(image.size.width / image.size.height, 4, accuracy: 0.05)
    }

    func testErrorsAndRefusalsFail() {
        let data = png(width: 4, height: 4)
        let cases: [(Data?, URLResponse?, Error?)] = [
            (data, response(404, mime: "image/png"), nil),
            (data, response(200, mime: "image/png"), URLError(.timedOut)),
            (Data(), response(200, mime: "image/png"), nil),
            (Data(count: RemoteImageLoader.maximumBytes + 1), response(200, mime: "image/png"), nil),
            (Data("not an image".utf8), response(200, mime: "text/plain"), nil),
        ]
        for (index, (data, response, error)) in cases.enumerated() {
            let decoded = RemoteImageLoader.decode(data: data, response: response, error: error, maxPixelDimension: 64)
            guard case .failed = decoded else { return XCTFail("case \(index): \(decoded)") }
        }
    }

    func testSVGIsRecognisedByTypeOrContent() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="90" height="20"></svg>"#.utf8)
        for mime in ["image/svg+xml", "application/octet-stream"] {
            let decoded = RemoteImageLoader.decode(data: svg, response: response(200, mime: mime),
                                                   error: nil, maxPixelDimension: 64)
            guard case .svg = decoded else { return XCTFail("\(mime): \(decoded)") }
        }
    }

    @MainActor
    func testSVGRendersAtItsOwnSize() {
        let svg = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="90" height="20">
            <rect width="90" height="20" fill="#4c1"/></svg>
            """.utf8)
        let rendered = expectation(description: "rendered")
        var result: UIImage?
        SVGRasterizer.shared.render(svg, maxPixelDimension: 512) { image in
            result = image
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 40)
        let image = try? XCTUnwrap(result)
        XCTAssertEqual(image?.size.width ?? 0, 90, accuracy: 1)
        XCTAssertEqual(image?.size.height ?? 0, 20, accuracy: 1)
        // Painted, not just sized: the middle is the rect's green (#4c1).
        let pixel = image.flatMap(Self.centrePixel)
        XCTAssertEqual(pixel?.green ?? 0, 0xCC, accuracy: 24, "\(String(describing: pixel))")
        XCTAssertEqual(pixel?.red ?? 0xFF, 0x44, accuracy: 24)
        XCTAssertEqual(pixel?.alpha ?? 0, 0xFF, accuracy: 8)
    }

    private static func centrePixel(_ image: UIImage) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let cg = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: -CGFloat(cg.width / 2), y: -CGFloat(cg.height / 2),
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Double(bytes[0]), Double(bytes[1]), Double(bytes[2]), Double(bytes[3]))
    }
}
