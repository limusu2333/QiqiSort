import Foundation
import CoreGraphics
import Vision

enum NativeFaceLocations {
    static func groupCandidates(_ url: URL, image1600: CGImage? = nil) throws -> [Participant] {
        let image = try image1600 ?? PhotoImage.load(url, maxPixel: 1600)
        let faces = try detected(in: image)
        let humanRequest = VNDetectHumanRectanglesRequest(); humanRequest.upperBodyOnly = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([humanRequest])
        let people = humanRequest.results?.count ?? 0
        if people > faces.count || faces.count >= 8 {
            let tiled = try tiledParticipants(in: PhotoImage.load(url, maxPixel: 2400))
            if tiled.count > faces.count { return clipped(tiled) }
        }
        return faces
    }
    private static func clipped(_ participants: [Participant]) -> [Participant] {
        participants.compactMap { person -> CGRect? in
            let box = CGRect(x: person.box[0], y: person.box[1], width: person.box[2], height: person.box[3])
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return box.isNull || box.width <= 0 || box.height <= 0 ? nil : box
        }.enumerated().map { index, box in
            Participant(id: index + 1, box: [box.minX, box.minY, box.width, box.height])
        }
    }
    static func detected(in image: CGImage) throws -> [Participant] {
        try autoreleasepool {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return clipped((request.results ?? []).sorted { $0.boundingBox.midX < $1.boundingBox.midX }
                .enumerated().map { index, face in
                    let box = face.boundingBox
                    return Participant(id: index + 1, box: [box.minX, 1 - box.maxY, box.width, box.height])
                })
        }
    }
    // Crowd faces can be too small for a whole-frame Vision pass. Overlapping
    // tiles retain image coordinates and merge repeat detections of the same face.
    static func tiledParticipants(in image: CGImage) throws -> [Participant] {
        let width = Double(image.width), height = Double(image.height)
        var boxes = [CGRect]()
        for row in 0..<3 {
            for column in 0..<5 {
                let region = CGRect(x: Double(column) * width * 0.185, y: Double(row) * height * 0.29,
                    width: width * 0.26, height: height * 0.42).integral
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let detected: [CGRect] = try autoreleasepool {
                    guard let tile = image.cropping(to: region) else { return [] }
                    let request = VNDetectFaceRectanglesRequest()
                    try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
                    return (request.results ?? []).map { face in
                        let local = face.boundingBox
                        return CGRect(x: (region.minX + local.minX * region.width) / width,
                            y: (region.minY + (1 - local.maxY) * region.height) / height,
                            width: local.width * region.width / width, height: local.height * region.height / height)
                    }
                }
                for box in detected {
                    let duplicate = boxes.contains { existing in
                        let overlap = existing.intersection(box)
                        return !overlap.isNull && overlap.width * overlap.height
                            > min(existing.width * existing.height, box.width * box.height) * 0.5
                    }
                    if !duplicate { boxes.append(box) }
                }
            }
        }
        return boxes.sorted { $0.midX < $1.midX }.enumerated().map { index, box in
            Participant(id: index + 1, box: [box.minX, box.minY, box.width, box.height])
        }
    }
    static func participants(in image: CGImage, expected: Int) throws -> [Participant]? {
        return try autoreleasepool {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let faces = request.results ?? []
            ModelAudit.shared?.record("native_face_count_check", ["expected": expected,
                "detected": faces.count, "agrees": faces.count == expected])
            // A count mismatch requires independent semantic localization, never truncation.
            guard expected >= 2, faces.count == expected else { return nil }
            return faces.sorted {
                if $0.boundingBox.midX == $1.boundingBox.midX {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.midX < $1.boundingBox.midX
            }.enumerated().map { index, face in
                let box = face.boundingBox
                return Participant(id: index + 1, box: [box.minX, 1 - box.maxY, box.width, box.height])
            }
        }
    }
}
