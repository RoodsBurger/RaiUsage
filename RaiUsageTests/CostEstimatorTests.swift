import Testing
import Foundation

@Suite("CostEstimator")
struct CostEstimatorTests {

    /// The shipped default table (fable / opus / sonnet-5 / sonnet-4-x / haiku
    /// / default). Prices are USD per MTok.
    private let pricing = PricingTable.fallback

    private func bd(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreate: Int = 0) -> TokenBreakdown {
        TokenBreakdown(input: input, output: output, cacheRead: cacheRead, cacheCreate: cacheCreate)
    }

    // MARK: - Per-family pricing

    @Test("opus input is priced at $5 / MTok")
    func opusInput() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["claude-opus-4-8": bd(input: 1_000_000)],
            pricing: pricing
        )
        #expect(est.total == 5)
        #expect(est.perModel[.opus48] == 5)
    }

    @Test("opus output is priced at $25 / MTok")
    func opusOutput() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["claude-opus-4-8": bd(output: 1_000_000)],
            pricing: pricing
        )
        #expect(est.total == 25)
    }

    @Test("fable is priced at $10 in / $50 out")
    func fableFamily() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["claude-fable-5": bd(input: 1_000_000, output: 1_000_000)],
            pricing: pricing
        )
        #expect(est.total == 60)
        #expect(est.perModel[.fable5] == 60)
    }

    @Test("haiku is priced at $1 in / $5 out")
    func haikuFamily() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["claude-haiku-4-5": bd(input: 1_000_000, output: 1_000_000)],
            pricing: pricing
        )
        #expect(est.total == 6)
        #expect(est.perModel[.haiku45] == 6)
    }

    /// sonnet-5 and sonnet-4-6 are distinct kinds priced at their own rates ($2 vs $3 input).
    @Test("sonnet-5 and sonnet-4-6 price at distinct rates under distinct kinds")
    func sonnetVersionsPriceDistinctly() {
        let five = CostEstimator.estimate(
            breakdownByRawModel: ["claude-sonnet-5": bd(input: 1_000_000)],
            pricing: pricing
        )
        #expect(five.total == 2)

        let four = CostEstimator.estimate(
            breakdownByRawModel: ["claude-sonnet-4-6": bd(input: 1_000_000)],
            pricing: pricing
        )
        #expect(four.total == 3)

        let both = CostEstimator.estimate(
            breakdownByRawModel: [
                "claude-sonnet-5": bd(input: 1_000_000),
                "claude-sonnet-4-6": bd(input: 1_000_000)
            ],
            pricing: pricing
        )
        #expect(both.perModel[.sonnet5] == 2)
        #expect(both.perModel[.sonnet46] == 3)
        #expect(both.total == 5)
    }

    // MARK: - Fallbacks and edges

    /// Longer ids must win over their prefixes (opus-5-5 vs opus-5, fable-5-1 vs fable-5).
    @Test("current 5.x models price at their own rows")
    func currentModelsPriceDistinctly() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: [
                "claude-opus-5-5": bd(input: 1_000_000, output: 1_000_000),  // $4 + $20
                "claude-opus-5": bd(input: 1_000_000),                        // $5
                "claude-fable-5-1": bd(cacheRead: 1_000_000),                 // $0.25
                "claude-fable-5": bd(cacheRead: 1_000_000)                    // $1
            ],
            pricing: pricing
        )
        #expect(est.perModel[ModelKind(family: .opus, version: "5.5")] == 24)
        #expect(est.perModel[ModelKind(family: .opus, version: "5")] == 5)
        #expect(est.perModel[ModelKind(family: .fable, version: "5.1")] == 0.25)
        #expect(est.perModel[.fable5] == 1)
    }

    @Test("an unknown model falls through to the default row and maps to .other")
    func unknownModelUsesDefault() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["gpt-5-turbo": bd(input: 1_000_000)],
            pricing: pricing
        )
        #expect(est.total == 3)
        #expect(est.perModel[.other] == 3)
    }

    @Test("zero tokens cost $0 with an empty per-model map")
    func zeroTokensIsFree() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["claude-opus-4-8": .zero],
            pricing: pricing
        )
        #expect(est.total == 0)
        #expect(est.perModel.isEmpty)
    }

    @Test("empty breakdown yields the zero estimate")
    func emptyBreakdown() {
        let est = CostEstimator.estimate(breakdownByRawModel: [:], pricing: pricing)
        #expect(est == .zero)
    }

    @Test("a cache-heavy breakdown prices read and write tokens")
    func cacheHeavyCase() {
        // opus: cacheRead 0.5, cacheWrite 6.25.
        let est = CostEstimator.estimate(
            breakdownByRawModel: ["claude-opus-4-8": bd(cacheRead: 2_000_000, cacheCreate: 1_000_000)],
            pricing: pricing
        )
        // 2M * 0.5 + 1M * 6.25 = 1 + 6.25 = 7.25
        #expect(est.total == 7.25)
        #expect(est.perModel[.opus48] == 7.25)
    }

    @Test("costs sum across multiple models into one total")
    func multiModelTotal() {
        let est = CostEstimator.estimate(
            breakdownByRawModel: [
                "claude-opus-4-8": bd(input: 1_000_000),  // $5
                "claude-haiku-4-5": bd(input: 1_000_000)  // $1
            ],
            pricing: pricing
        )
        #expect(est.total == 6)
        #expect(est.perModel[.opus48] == 5)
        #expect(est.perModel[.haiku45] == 1)
    }
}
