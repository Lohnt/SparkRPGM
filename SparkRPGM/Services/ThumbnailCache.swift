import UIKit
import ImageIO
import CoreGraphics

/// Memory-conscious image loading.
///
/// Game covers can be 4000x4000 PNGs. Loading them at full size on a 3 GB iPad
/// is a fast route to a jetsam. Everything goes through ImageIO thumbnailing and
/// an `NSCache` keyed by path + modification date.
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.faith.sparkrpgm.thumbnails", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 80
        // ~48 MB of decoded bitmaps.
        cache.totalCostLimit = 48 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    func cachedImage(for url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(for: url, maxPixel: maxPixel))
    }

    func image(for url: URL, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let cacheKey = key(for: url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async { [weak self] in
            let image = ThumbnailCache.downsample(url: url, maxPixel: maxPixel)
            if let image = image {
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                self?.cache.setObject(image, forKey: cacheKey, cost: cost)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func imageSynchronously(for url: URL, maxPixel: CGFloat) -> UIImage? {
        let cacheKey = key(for: url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let image = ThumbnailCache.downsample(url: url, maxPixel: maxPixel) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: cacheKey, cost: cost)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }

    private func key(for url: URL, maxPixel: CGFloat) -> NSString {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)|\(Int(maxPixel))" as NSString
    }

    static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
