import Darwin
import Foundation

@main
struct ForkVocabularyTests {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() async throws {
        let vocabulary = RecordingVocabulary(savedTerms: ["VoiceInk", "Andrey"])
        require(
            vocabulary.enhancementSection == "Important Vocabulary: VoiceInk, Andrey",
            "Saved vocabulary keeps the existing enhancement prompt format"
        )
        require(
            RecordingVocabulary.screenNames(in: "Tim Cook works at Apple in Cupertino.", language: "en").isEmpty,
            "Screen-derived names do not enter dictation vocabulary"
        )
        let text = "I use voice ink; keep $1 and \\literal exactly."
        let corrected = try await vocabulary.correctTranscription(text)
        require(corrected == text, "Dictation is not automatically phonetically rewritten")
        require(RecordingVocabulary().enhancementSection.isEmpty, "Empty vocabulary stays empty")
        print("VoiceInk maintained vocabulary checks passed")
    }
}
