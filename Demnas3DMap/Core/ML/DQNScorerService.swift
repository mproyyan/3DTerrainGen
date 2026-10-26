import CoreML
import Foundation

/// Scores already validated candidate feature rows. This service does not invent
/// the 17 local and 11 global training features or generate candidate positions.
actor DQNScorerService {
    private let model: MLModel

    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource: "DQNScorer", withExtension: "mlmodelc") else {
            throw MLIntegrationError.missingModel("DQNScorer")
        }
        model = try MLModel(contentsOf: url)
        guard let input = model.modelDescription.inputDescriptionsByName["candidate_features"],
              input.type == .multiArray,
              input.multiArrayConstraint?.dataType == .float32,
              let output = model.modelDescription.outputDescriptionsByName["q_scores"],
              output.type == .multiArray,
              output.multiArrayConstraint?.dataType == .float32 else {
            throw MLIntegrationError.invalidContract("DQNScorer candidate_features/q_scores")
        }
    }

    /// Row order is preserved. Q-values are scores, not probabilities or confidence.
    func score(candidateFeatures rows: [[Float]]) throws -> [Float] {
        guard (1...1000).contains(rows.count), rows.allSatisfy({ $0.count == 28 && $0.allSatisfy(\.isFinite) }) else {
            throw MLIntegrationError.invalidInput("DQN requires 1–1000 finite rows of 28 training features")
        }
        let array = try MLMultiArray(shape: [NSNumber(value: rows.count), 28], dataType: .float32)
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { array[row * 28 + column] = NSNumber(value: value) }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["candidate_features": array])
        let prediction = try model.prediction(from: features)
        guard let output = prediction.featureValue(for: "q_scores")?.multiArrayValue,
              output.count == rows.count, output.dataType == .float32 else {
            throw MLIntegrationError.invalidOutput("DQN q_scores shape")
        }
        let scores = (0..<rows.count).map { output[$0].floatValue }
        guard scores.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidOutput("DQN returned nonfinite Q-values")
        }
        return scores
    }
}
