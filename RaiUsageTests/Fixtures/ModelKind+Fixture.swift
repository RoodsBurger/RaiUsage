import Foundation

/// Named kinds matching the raw model ids the tests feed through the parser.
extension ModelKind {
    static let opus48 = ModelKind(family: .opus, version: "4.8")
    static let opus46 = ModelKind(family: .opus, version: "4.6")
    static let sonnet5 = ModelKind(family: .sonnet, version: "5")
    static let sonnet46 = ModelKind(family: .sonnet, version: "4.6")
    static let haiku45 = ModelKind(family: .haiku, version: "4.5")
    static let fable5 = ModelKind(family: .fable, version: "5")
}
