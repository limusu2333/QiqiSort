import AppKit
import ImageIO

final class PreviewTicket {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    func cancel() { cancellation?(); cancellation = nil }
}

// All bookkeeping and callbacks run on the main thread; image decoding never does.
final class ReviewPreviewLoader {
    private struct Load {
        let id: UUID
        let operation: BlockOperation
        var callbacks: [UUID: (NSImage?) -> Void]
    }
    let cache = NSCache<NSString, NSImage>()
    private let focused = OperationQueue(), thumbnails = OperationQueue()
    private var loads = [String: Load]()
    init() {
        cache.countLimit = 240; cache.totalCostLimit = 128 * 1024 * 1024
        focused.maxConcurrentOperationCount = 1; focused.qualityOfService = .userInitiated
        thumbnails.maxConcurrentOperationCount = 2; thumbnails.qualityOfService = .userInitiated
    }
    private func key(_ record: ResultRecord, _ pixels: Int) -> String { "\(pixels):\(record.preview)" }
    func cached(_ record: ResultRecord, pixels: Int) -> NSImage? { cache.object(forKey: key(record, pixels) as NSString) }
    @discardableResult func request(_ record: ResultRecord, pixels: Int, focus: Bool = false,
                                   completion: @escaping (NSImage?) -> Void) -> PreviewTicket? {
        let key = key(record, pixels), callbackID = UUID()
        if let image = cache.object(forKey: key as NSString) { completion(image); return nil }
        if loads[key] != nil { loads[key]?.callbacks[callbackID] = completion }
        else {
            let loadID = UUID(), operation = BlockOperation()
            loads[key] = Load(id: loadID, operation: operation, callbacks: [callbackID: completion])
            operation.addExecutionBlock { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                let decoded = autoreleasepool { () -> (NSImage, Int)? in
                    guard let bitmap = Self.decode(URL(fileURLWithPath: record.preview), pixels: pixels) else { return nil }
                    return (NSImage(cgImage: bitmap, size: .zero), bitmap.bytesPerRow * bitmap.height)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, let load = self.loads[key], load.id == loadID else { return }
                    self.loads.removeValue(forKey: key)
                    guard !load.operation.isCancelled else { return }
                    if let decoded { self.cache.setObject(decoded.0, forKey: key as NSString, cost: decoded.1) }
                    for callback in load.callbacks.values { callback(decoded?.0) }
                }
            }
            (focus ? focused : thumbnails).addOperation(operation)
        }
        return PreviewTicket { [weak self] in
            guard let self else { return }
            self.loads[key]?.callbacks.removeValue(forKey: callbackID)
            if let load = self.loads[key], load.callbacks.isEmpty {
                load.operation.cancel(); self.loads.removeValue(forKey: key)
            }
        }
    }
    static func decode(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true]
        let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        // Some cameras only store a tiny preview. Decode a useful preview in the background then.
        if let embedded, max(embedded.width, embedded.height) >= min(pixels, 1000) { return embedded }
        options.removeValue(forKey: kCGImageSourceCreateThumbnailFromImageIfAbsent)
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? embedded
    }
    func cancelAll() { focused.cancelAllOperations(); thumbnails.cancelAllOperations(); loads.removeAll() }
    deinit { focused.cancelAllOperations(); thumbnails.cancelAllOperations() }
}

enum GroupReviewSection: Int, CaseIterable {
    case selected, rejected, skipped, failed, unprocessed, all
    var title: String { ["入选合影", "合影未入选", "非合影／快速跳过", "处理失败", "尚未处理", "全部记录"][rawValue] }
}
extension ReviewWindow {
    func groupSection(for record: ResultRecord) -> GroupReviewSection {
        guard let curated = plan.photos.first(where: { $0.recordID == record.id }) else { return .unprocessed }
        if record.error != nil { return .failed }
        if curated.choice.selected && curated.choice.category == .group { return .selected }
        if curated.choice.category == .group || record.finding?.scene.groupCandidate == true { return .rejected }
        return .skipped
    }
    func showPreview(_ record: ResultRecord) {
        let changed = previewRecordID != record.id
        if changed {
            previewTicket?.cancel(); previewTicket = nil; previewRecordID = record.id; previewLoadedID = nil
            photo.image = previewLoader.cached(record, pixels: 1800) ?? previewLoader.cached(record, pixels: 400)
            photoStage.resetZoom()
        }
        zoomIn.isEnabled = photo.image != nil && !exporting; zoomOut.isEnabled = zoomIn.isEnabled
        emptyPhoto.stringValue = "正在加载预览…"; emptyPhoto.isHidden = photo.image != nil
        guard changed || photo.image == nil else { return }
        previewTicket?.cancel()
        previewTicket = previewLoader.request(record, pixels: 1800, focus: true) { [weak self] image in
            guard let self, self.current?.id == record.id, self.previewRecordID == record.id else { return }
            self.previewLoadedID = record.id; self.photo.image = image; self.emptyPhoto.isHidden = image != nil
            self.emptyPhoto.stringValue = "预览读取失败，请连接原底片磁盘。"
            self.zoomIn.isEnabled = image != nil && !self.exporting; self.zoomOut.isEnabled = self.zoomIn.isEnabled
        }
    }
}
