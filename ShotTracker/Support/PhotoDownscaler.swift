import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks a picked photo to an avatar-sized JPEG before it's stored. A medication photo
/// is only ever drawn at ≤ 180 pt, but the full camera image (several MB of HEIC) was
/// stored and decoded on every render of every row that showed it.
nonisolated enum PhotoDownscaler {
    static let maxPixelSize = 600

    static func thumbnailData(from data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
