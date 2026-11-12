import Foundation
import Testing
@testable import TerrainCore

private struct GateParity: Decodable {
    struct Sample: Decodable {
        let features: [Double]
        let expectedProbability: Double
        let expectedDecision: Bool
    }
    let featureOrder: [String]
    let samples: [Sample]
}

private func gateModel() throws -> SufficiencyGateV21 {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Demnas3DMap/Models/gate_v21_swift_parameters.json")
    return try SufficiencyGateV21(data: Data(contentsOf: url))
}

@Test func gateV21PythonParity() throws {
    let gate = try gateModel()
    let url = try #require(Bundle.module.url(forResource: "GateV21PythonParity", withExtension: "json"))
    let parity = try JSONDecoder().decode(GateParity.self, from: Data(contentsOf: url))
    #expect(parity.featureOrder == SufficiencyGateV21.featureNames)
    var maximum = 0.0
    for sample in parity.samples {
        let actual = try gate.probability(sample.features)
        maximum = max(maximum, abs(actual - sample.expectedProbability))
        #expect(abs(actual - sample.expectedProbability) < 1e-9)
        #expect(gate.indicatesSufficient(probability: actual, nCPT: Int(sample.features[1])) == sample.expectedDecision)
    }
    print("Gate V2.1 Python parity maximum absolute error: \(maximum) over \(parity.samples.count) samples")
}

@Test func gateV21SummaryMatchesPythonQuantile() throws {
    let summary = try GateV21VoxelSummary(estimatedErrors: [0.05, 0.1, 0.2, 0.3])
    #expect(summary.predictedCoverage == 0.5)
    #expect(abs(summary.estimatedMeanBound - 0.1625) < 1e-12)
    #expect(abs(summary.estimatedP90Bound - 0.27) < 1e-12)
    #expect(throws: Error.self) { try GateV21VoxelSummary(estimatedErrors: []) }
}

@Test func gateV21HistoryUsesPreviousCPTAndResetsOnChangedPrefix() throws {
    let gate = try gateModel()
    var history = GateV21History()
    let first = try GateV21VoxelSummary(estimatedErrors: [0.1, 0.2])
    let second = try GateV21VoxelSummary(estimatedErrors: [0.1, 0.1])
    let a = try history.evaluate(count: 1, stateKey: "A", previousStateKey: nil,
                                 gridSignature: "grid", summary: first, gate: gate)
    #expect(a.deltaPredicted == 0 && a.deltaP90 == 0)
    let b = try history.evaluate(count: 2, stateKey: "B", previousStateKey: "A",
                                 gridSignature: "grid", summary: second, gate: gate)
    #expect(b.deltaPredicted == 0.5)
    #expect(abs(b.deltaP90 - (second.estimatedP90Bound - first.estimatedP90Bound)) < 1e-12)
    let duplicate = try history.evaluate(count: 2, stateKey: "B", previousStateKey: "A",
                                         gridSignature: "grid", summary: second, gate: gate)
    #expect(duplicate.deltaPredicted == b.deltaPredicted)
    #expect(history.entries.count == 2)
    #expect(throws: Error.self) {
        try history.evaluate(count: 2, stateKey: "C", previousStateKey: "changed-A",
                             gridSignature: "grid", summary: second, gate: gate)
    }
    #expect(history.entries.count == 1)
}

@Test func gateV21NeverStopsDQN() throws {
    let gate = try gateModel()
    #expect(!gate.decision.autoStopApproved)
    #expect(!gate.indicatesSufficient(probability: 1, nCPT: 4))
    #expect(gate.indicatesSufficient(probability: 0.995, nCPT: 5))
    #expect(!gate.indicatesSufficient(probability: 1, nCPT: 17))
}
