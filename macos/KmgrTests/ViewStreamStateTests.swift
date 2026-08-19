import Testing
@testable import KmgrCore

@Test func generationSequenceGateIgnoresStaleAndDuplicateMessages() {
    var gate = GenerationSequenceGate()

    #expect(gate.accept(StreamCursor(generation: 4, sequence: 10)) == .acceptedNewGeneration)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 11)) == .acceptedNextSequence)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 11)) == .ignoredStaleOrDuplicateSequence)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 9)) == .ignoredStaleOrDuplicateSequence)
    #expect(gate.accept(StreamCursor(generation: 3, sequence: 999)) == .ignoredStaleGeneration)
    #expect(gate.lastAccepted == StreamCursor(generation: 4, sequence: 11))
}

@Test func newerGenerationSupersedesPriorSequenceSpace() {
    var gate = GenerationSequenceGate(lastAccepted: StreamCursor(generation: 8, sequence: 50_000))

    #expect(gate.accept(StreamCursor(generation: 9, sequence: 0)) == .acceptedNewGeneration)
    #expect(gate.accept(StreamCursor(generation: 8, sequence: 50_001)) == .ignoredStaleGeneration)
    #expect(gate.accept(StreamCursor(generation: 9, sequence: 1)) == .acceptedNextSequence)
    #expect(gate.lastAccepted == StreamCursor(generation: 9, sequence: 1))
}
