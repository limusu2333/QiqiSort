import Foundation
import ImageIO

struct DecodedPhoto {
    let url: URL
    let images: [Int: CGImage]
    var groupFaces: [Participant]? = nil
}

enum PhotoPreparation {
    @TaskLocal static var current: DecodedPhoto?
    static let workers = 4

    static func image(_ url: URL, maxPixel: Int) throws -> CGImage {
        if let current, current.url == url, let image = current.images[maxPixel] { return image }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw GatherError.message("无法读取图片：\(url.lastPathComponent)") }
            return image
        }
    }

    static func resized(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, longest > 0 else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

struct PreparedPhotoInput {
    let index: Int
    let id: String
    let pair: [URL]
    let hashes: [String: String]
    let errors: [String]
    let decoded: DecodedPhoto?
    let seconds: Double

    static func prepare(index: Int, key: String, files: [URL], cache: URL, rulesHash: String,
                        context: String, retained: ResultRecord?, mode: TaskMode = .organize,
                        cancellation: Cancellation) -> PreparedPhotoInput {
        let started = Date()
        let pair = files.sorted {
            let a = ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
            let b = ["jpg", "jpeg"].contains($1.pathExtension.lowercased())
            return a != b ? a : $0.path < $1.path
        }
        var hashes = [String: String](), errors = [String](), decoded: DecodedPhoto?
        for file in pair {
            if cancellation.isCancelled || Task.isCancelled { break }
            do { hashes[file.path] = try fileHash(file, cancellation: cancellation) }
            catch is CancellationError { break }
            catch { errors.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        let reusable = retained?.error == nil && retained?.finding?.requiresReassessment == false
            && retained?.sourceHashes == hashes && hashes.count == pair.count
        if !reusable {
            for file in pair {
                if cancellation.isCancelled || Task.isCancelled { break }
                guard let digest = hashes[file.path] else { continue }
                let saved = cache.appendingPathComponent(sha256(Data((digest + rulesHash + context).utf8)) + ".json")
                // Cache hits need no image decoding; corrupt cache files are handled by the consumer.
                if let cached = try? CurationFiles.read(Finding.self, saved), !cached.requiresReassessment { break }
                if mode == .groups {
                    if let prepared = try? autoreleasepool(invoking: { () -> DecodedPhoto in
                        let screen = try PhotoPreparation.image(file, maxPixel: 1600)
                        let faces = try NativeFaceLocations.groupCandidates(file, image1600: screen)
                        guard faces.count >= 2 else {
                            return DecodedPhoto(url: file, images: [:], groupFaces: faces)
                        }
                        let image1008 = try PhotoPreparation.resized(screen, maxPixel: 1008) ?? PhotoPreparation.image(file, maxPixel: 1008)
                        let image672 = try PhotoPreparation.resized(image1008, maxPixel: 672) ?? PhotoPreparation.image(file, maxPixel: 672)
                        return DecodedPhoto(url: file, images: [672: image672, 1008: image1008], groupFaces: faces)
                    }) {
                        decoded = prepared; break
                    }
                } else if let images = try? autoreleasepool(invoking: { () -> [Int: CGImage] in
                    let image1008 = try PhotoPreparation.image(file, maxPixel: 1008)
                    let image672 = try PhotoPreparation.resized(image1008, maxPixel: 672) ?? PhotoPreparation.image(file, maxPixel: 672)
                    return [672: image672, 1008: image1008]
                }) {
                    decoded = DecodedPhoto(url: file, images: images); break
                }
            }
        }
        return PreparedPhotoInput(index: index, id: sha256(Data(key.utf8)), pair: pair,
            hashes: hashes, errors: errors, decoded: decoded, seconds: Date().timeIntervalSince(started))
    }
}
