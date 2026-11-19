import Foundation
import CryptoKit

enum WeddingReviewPolicy {
    static var method: String { "hierarchical-v\(WeddingClassification.version)-activity-v\(WeddingActivityReview.version)" }
    static var promptSHA256: String {
        let text = method + "\n" + WeddingActivityReview.prompt + "\n" + WeddingActivityReview.confirmationPrompt + "\n" + WeddingWardrobeReview.prompt
            + "\n" + WeddingWardrobeReview.confirmationPrompt
            + "\nwardrobe-change-requires-independent-garment-agreement-and-visible-bodice-v3"
            + "\npickup-ceremony-and-couple-portrait-context-review-v2"
            + "\nconfirmation-full1008-left55-right55-from1344-and-wardrobe-upper65-from1344-v1"
            + "\n" + WeddingWardrobeReview.confirmationPrompt(observation: "ACTIVITY_EVIDENCE")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func enabled(_ resources: ProjectResources) throws -> Bool {
        // Adapter receipts retain the historical model validation. The current executable
        // versions its review prompts separately and binds them to the task cache.
        try resources.reviewManifest() != nil
    }
}
