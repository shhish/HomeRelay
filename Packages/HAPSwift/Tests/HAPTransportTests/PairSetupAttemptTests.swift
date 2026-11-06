import Testing
@testable import HAPTransport

@Suite struct PairSetupAttemptTests {
    @Test func refusesAfterTheSpecLimit() async {
        let attempts = PairSetupAttempts()
        for _ in 0..<(PairSetupAttempts.limit - 1) { await attempts.failed() }
        #expect(await attempts.allowed)
        await attempts.failed()
        #expect(await !attempts.allowed)
        await attempts.reset()
        #expect(await attempts.allowed)
    }
}
