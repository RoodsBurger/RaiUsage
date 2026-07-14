import Testing
import Foundation

@Suite("UpdateVersion")
struct UpdateVersionTests {

    // MARK: - components

    @Test("plain dotted version parses numerically")
    func plainComponents() {
        #expect(UpdateVersion.components("5.8.0") == [5, 8, 0])
    }

    @Test("leading v is stripped")
    func vPrefix() {
        #expect(UpdateVersion.components("v5.9.1") == [5, 9, 1])
        #expect(UpdateVersion.components("V2.0") == [2, 0])
    }

    @Test("suffixed components read their leading digits")
    func suffixedComponents() {
        #expect(UpdateVersion.components("5.9.0-rc1") == [5, 9, 0])
        #expect(UpdateVersion.components("5.9.1beta") == [5, 9, 1])
    }

    @Test("non-numeric components parse as zero")
    func garbageComponents() {
        #expect(UpdateVersion.components("abc.def") == [0, 0])
        #expect(UpdateVersion.components("") == [0])
    }

    @Test("surrounding whitespace is ignored")
    func whitespace() {
        #expect(UpdateVersion.components("  v5.8.0\n") == [5, 8, 0])
    }

    // MARK: - isNewer

    @Test("equal versions are not newer")
    func equalNotNewer() {
        #expect(!UpdateVersion.isNewer("5.8.0", than: "5.8.0"))
        #expect(!UpdateVersion.isNewer("v5.8.0", than: "5.8.0"))
    }

    @Test("patch bump is newer")
    func patchBump() {
        #expect(UpdateVersion.isNewer("5.8.1", than: "5.8.0"))
        #expect(!UpdateVersion.isNewer("5.8.0", than: "5.8.1"))
    }

    @Test("minor bump is newer")
    func minorBump() {
        #expect(UpdateVersion.isNewer("5.9.0", than: "5.8.9"))
        #expect(!UpdateVersion.isNewer("5.8.9", than: "5.9.0"))
    }

    @Test("major bump is newer")
    func majorBump() {
        #expect(UpdateVersion.isNewer("6.0.0", than: "5.99.99"))
        #expect(!UpdateVersion.isNewer("5.99.99", than: "6.0.0"))
    }

    @Test("comparison is numeric per component, not lexicographic")
    func numericNotLexicographic() {
        #expect(UpdateVersion.isNewer("5.10.0", than: "5.9.9"))
        #expect(UpdateVersion.isNewer("5.8.10", than: "5.8.9"))
        #expect(!UpdateVersion.isNewer("5.9.9", than: "5.10.0"))
    }

    @Test("missing components count as zero")
    func componentCountMismatch() {
        #expect(!UpdateVersion.isNewer("5.8", than: "5.8.0"))
        #expect(!UpdateVersion.isNewer("5.8.0", than: "5.8"))
        #expect(UpdateVersion.isNewer("5.8.1", than: "5.8"))
        #expect(UpdateVersion.isNewer("5.9", than: "5.8.7"))
    }

    @Test("v prefix on either side does not affect ordering")
    func mixedPrefixes() {
        #expect(UpdateVersion.isNewer("v5.9.0", than: "5.8.0"))
        #expect(UpdateVersion.isNewer("5.9.0", than: "v5.8.0"))
        #expect(!UpdateVersion.isNewer("v5.8.0", than: "v5.8.0"))
    }

    @Test("empty and garbage versions never beat a real one")
    func degenerateInputs() {
        #expect(!UpdateVersion.isNewer("", than: "5.8.0"))
        #expect(!UpdateVersion.isNewer("abc", than: "5.8.0"))
        #expect(UpdateVersion.isNewer("5.8.0", than: ""))
        #expect(UpdateVersion.isNewer("0.0.1", than: "garbage"))
    }

    // MARK: - normalized

    @Test("normalized strips one leading v and whitespace only")
    func normalized() {
        #expect(UpdateVersion.normalized("v5.9.0") == "5.9.0")
        #expect(UpdateVersion.normalized(" V5.9.0 ") == "5.9.0")
        #expect(UpdateVersion.normalized("5.9.0") == "5.9.0")
        #expect(UpdateVersion.normalized("vv5.9.0") == "v5.9.0")
    }
}
