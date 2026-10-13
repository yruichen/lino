import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct ImageDataChecks {
    static func main() throws {
        // Build a real synthetic 2x2 raster; no GUI, clipboard or personal file.
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let source = NSMutableData(), destination = CGImageDestinationCreateWithData(source, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let png = source as Data
        try ImageData.validate(png, mime: "image/png")
        let converted = try ImageData.png(png)
        try ImageData.validate(converted, mime: "image/png")
        for invalid in [Data(), Data("invalid".utf8), Data(repeating: 0, count: 16 * 1024 * 1024 + 1)] {
            do { try ImageData.validate(invalid, mime: "image/png"); fatalError("Invalid raster accepted") }
            catch ImageDataError.invalid { }
        }
        print("Image data: real raster metadata, PNG conversion and invalid/oversized input checks passed.")
    }
}
