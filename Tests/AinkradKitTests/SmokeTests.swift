import Testing

@testable import ainkrad

@Test func rootCommandHasExpectedCommandName() {
    #expect(Ainkrad.configuration.commandName == "ainkrad")
}
