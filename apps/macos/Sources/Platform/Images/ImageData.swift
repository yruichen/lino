import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageDataError: Error { case invalid }
enum ImageData {
    static func validate(_ data: Data, mime: String) throws {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw ImageDataError.invalid }
        if mime == "image/svg+xml" { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 64_000_000 else { throw ImageDataError.invalid }
    }
    static func png(_ data: Data) throws -> Data {
        try validate(data, mime: "image/raster")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageDataError.invalid }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw ImageDataError.invalid }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), result.length <= 16 * 1024 * 1024 else { throw ImageDataError.invalid }
        return result as Data
    }
}
