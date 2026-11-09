import Foundation
import Testing
@testable import TerrainCore

private struct FrozenParitySamples: Decodable {
    struct Uncertainty: Decodable {
        struct Sample: Decodable {
            let features: [String: Double]
            let expectedRawPrediction: Double
            let expectedEstimatedError: Double
        }
        let featureOrder: [String]
        let samples: [Sample]
    }
    struct Sufficiency: Decodable {
        struct Sample: Decodable {
            let features: [String: Double]
            let expectedProbability: Double
            let expectedDecision: Bool
        }
        let featureOrder: [String]
        let samples: [Sample]
    }
    let formatVersion: Int
    let uncertaintyV3: Uncertainty
    let sufficiencyV3_1: Sufficiency
}

private func loadParitySamples() throws -> FrozenParitySamples {
    let url = try #require(Bundle.module.url(forResource: "ParitySamples", withExtension: "json"))
    return try JSONDecoder().decode(FrozenParitySamples.self, from: Data(contentsOf: url))
}

private func frozenModelJSON(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("ModelResources/UncertaintyV3_1/\(name).json"))
}

private func orderedFeatures(_ values: [String: Double], names: [String]) throws -> [Double] {
    #expect(Set(values.keys) == Set(names))
    return try names.map { try #require(values[$0]) }
}

@Test func uncertaintyV3PythonParity() throws {
    let samples = try loadParitySamples()
    let service = try UncertaintyV3Service(model: .init(data: frozenModelJSON("UncertaintyV3")))
    #expect(samples.formatVersion == 1)
    #expect(samples.uncertaintyV3.featureOrder == service.model.featureNames)
    #expect(!samples.uncertaintyV3.samples.isEmpty)

    var maxAbsoluteError = 0.0
    for sample in samples.uncertaintyV3.samples {
        let features = try orderedFeatures(sample.features, names: service.model.featureNames)
        let raw = try service.model.rawPrediction(features)
        let estimatedError = try service.predict(features)
        let rawError = abs(raw - sample.expectedRawPrediction)
        let finalError = abs(estimatedError - sample.expectedEstimatedError)
        maxAbsoluteError = max(maxAbsoluteError, rawError, finalError)
        #expect(rawError <= 1e-9)
        #expect(finalError <= 1e-9)
    }
    print("Uncertainty V3 maximum absolute parity error: \(maxAbsoluteError) across \(samples.uncertaintyV3.samples.count) samples")
}

@Test func sufficiencyV31PythonParity() throws {
    let samples = try loadParitySamples()
    let service = try SufficiencyV31Service(model: .init(data: frozenModelJSON("SufficiencyV3_1")))
    #expect(samples.formatVersion == 1)
    #expect(samples.sufficiencyV3_1.featureOrder == service.model.featureNames)
    #expect(!samples.sufficiencyV3_1.samples.isEmpty)

    var maxAbsoluteError = 0.0
    for sample in samples.sufficiencyV3_1.samples {
        let features = try orderedFeatures(sample.features, names: service.model.featureNames)
        let probability = try service.probability(features)
        let error = abs(probability - sample.expectedProbability)
        maxAbsoluteError = max(maxAbsoluteError, error)
        #expect(error <= 1e-9)
        #expect((probability >= service.probabilityThreshold) == sample.expectedDecision)
    }
    print("Sufficiency V3.1 maximum absolute parity error: \(maxAbsoluteError) across \(samples.sufficiencyV3_1.samples.count) samples")
}
