import Testing
import Foundation

@Suite("ModelKind")
struct ModelKindTests {

    // MARK: - Version parsing

    @Test func opusVersionsAreParsedFromTheRawId() {
        #expect(ModelKind(rawModel: "claude-opus-5-5") == ModelKind(family: .opus, version: "5.5"))
        #expect(ModelKind(rawModel: "claude-opus-5") == ModelKind(family: .opus, version: "5"))
        #expect(ModelKind(rawModel: "claude-opus-5[1m]") == ModelKind(family: .opus, version: "5"))
        #expect(ModelKind(rawModel: "claude-opus-4-8") == .opus48)
        #expect(ModelKind(rawModel: "claude-opus-4-8[1m]") == .opus48)
        #expect(ModelKind(rawModel: "opus-4.8") == .opus48)
        #expect(ModelKind(rawModel: "claude-opus-4-6") == .opus46)
    }

    /// Opus 5.x must not collapse into an older hardcoded Opus label.
    @Test func opusFiveIsNotLabelledAsFourEight() {
        #expect(ModelKind(rawModel: "claude-opus-5-5").displayName == "Opus 5.5")
        #expect(ModelKind(rawModel: "claude-opus-5").displayName == "Opus 5")
    }

    @Test func fableVersionsAreParsed() {
        #expect(ModelKind(rawModel: "claude-fable-5-1").displayName == "Fable 5.1")
        #expect(ModelKind(rawModel: "claude-fable-5") == .fable5)
        #expect(ModelKind(rawModel: "claude-fable-5[1m]") == .fable5)
        #expect(ModelKind(rawModel: "claude-fable-5-1") != .fable5)
    }

    @Test func dateSuffixIsNotPartOfTheVersion() {
        #expect(ModelKind(rawModel: "claude-haiku-4-5-20251001") == .haiku45)
        #expect(ModelKind(rawModel: "claude-sonnet-5-5").displayName == "Sonnet 5.5")
    }

    /// Bare aliases name no version, so the label shows only the family.
    @Test func bareAliasesCarryNoVersion() {
        #expect(ModelKind(rawModel: "opus") == ModelKind(family: .opus))
        #expect(ModelKind(rawModel: "opus").displayName == "Opus")
        #expect(ModelKind(rawModel: "sonnet").displayName == "Sonnet")
        #expect(ModelKind(rawModel: "fable").family == .fable)
    }

    @Test func unknownModelFallsToOther() {
        #expect(ModelKind(rawModel: "gpt-5") == .other)
        #expect(ModelKind(rawModel: "<synthetic>") == .other)
        #expect(ModelKind(rawModel: "") == .other)
        #expect(ModelKind.other.displayName == "Other")
    }

    // MARK: - Family

    @Test func everyVersionFoldsIntoItsFamily() {
        #expect(ModelKind(rawModel: "claude-opus-5-5").family == .opus)
        #expect(ModelKind.opus48.family == .opus)
        #expect(ModelKind(rawModel: "claude-fable-5-1").family == .fable)
        #expect(ModelFamily.fable.displayName == "Fable")
    }

    // MARK: - Ordering

    @Test func stackOrderGroupsByFamilyThenVersion() {
        let opus55 = ModelKind(family: .opus, version: "5.5")
        let fable51 = ModelKind(family: .fable, version: "5.1")
        let sorted = [ModelKind.other, fable51, opus55, .haiku45, .fable5, .opus48].sorted()
        #expect(sorted == [.haiku45, .opus48, opus55, .fable5, fable51, .other])
    }

    @Test func versionsCompareNumerically() {
        #expect(ModelKind(family: .opus, version: "4.10") > ModelKind(family: .opus, version: "4.9"))
        #expect(ModelKind(family: .opus) < ModelKind(family: .opus, version: "4"))
    }

    // MARK: - Codable

    @Test func roundTripsThroughJSONAsDictionaryKey() throws {
        let original: [ModelKind: Int] = [.opus48: 1, ModelKind(family: .fable, version: "5.1"): 2, .other: 3, ModelKind(family: .sonnet): 4]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([ModelKind: Int].self, from: data) == original)
    }
}
