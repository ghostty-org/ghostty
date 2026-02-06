import Testing
@testable import Ghostty

struct KeyTextAccumulatorTests {
    @Test func testFiltersControlOnlyText() {
        let result = Ghostty.SurfaceView.nonControlText(from: ["\u{11}", "\u{08}"])
        #expect(result.isEmpty)
    }

    @Test func testKeepsPrintableText() {
        let result = Ghostty.SurfaceView.nonControlText(from: ["q", "\u{11}", "m"])
        #expect(result == ["q", "m"])
    }

    @Test func testCtrlQUsesFallbackText() {
        let decision = Ghostty.SurfaceView.resolvedAccumulatedText(
            from: ["\u{11}"],
            fallback: "q"
        )
        #expect(decision == .fallback("q"))
    }

    @Test func testCtrlJUsesFallbackText() {
        let decision = Ghostty.SurfaceView.resolvedAccumulatedText(
            from: ["\u{0A}"],
            fallback: "j"
        )
        #expect(decision == .fallback("j"))
    }
}
