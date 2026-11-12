import Foundation

/// Experimental reconstruction indicator. It never stops CPT collection or DQN.
struct SufficiencyGateV21: Decodable, Sendable {
    struct Scaler: Decodable, Sendable { let mean: [Double]; let scale: [Double] }
    struct Classifier: Decodable, Sendable { let coef: [Double]; let intercept: Double }
    struct Platt: Decodable, Sendable { let coef: Double; let intercept: Double; let input: String }
    struct Decision: Decodable, Sendable {
        let probabilityThreshold: Double
        let minimumCpt: Int
        let maximumEvaluatedCpt: Int
        let autoStopApproved: Bool
        enum CodingKeys: String, CodingKey {
            case probabilityThreshold = "probability_threshold", minimumCpt = "minimum_cpt"
            case maximumEvaluatedCpt = "maximum_evaluated_cpt"
            case autoStopApproved = "auto_stop_approved"
        }
    }
    let modelName: String
    let modelType: String
    let features: [String]
    let scaler: Scaler
    let classifier: Classifier
    let platt: Platt
    let decision: Decision
    enum CodingKeys: String, CodingKey {
        case modelName = "model_name", modelType = "model_type", features, scaler, classifier, platt, decision
    }
    static let featureNames = ["predicted_coverage", "n_cpt", "estimated_mean_bound",
                               "estimated_p90_bound", "delta_predicted", "delta_p90"]

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard modelName == "SufficiencyGate_V2_1", modelType == "StandardScaler_LogisticRegression_Platt",
              features == Self.featureNames, scaler.mean.count == 6, scaler.scale.count == 6,
              classifier.coef.count == 6, scaler.mean.allSatisfy(\.isFinite),
              scaler.scale.allSatisfy({ $0.isFinite && $0 > 0 }),
              classifier.coef.allSatisfy(\.isFinite), classifier.intercept.isFinite,
              platt.coef.isFinite, platt.intercept.isFinite, platt.input == "logit(raw_probability)",
              decision.probabilityThreshold == 0.995, decision.minimumCpt == 5,
              decision.maximumEvaluatedCpt == 16,
              !decision.autoStopApproved else {
            throw MLIntegrationError.invalidContract("Sufficiency Gate V2.1 frozen parameters")
        }
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "gate_v21_swift_parameters", withExtension: "json") else {
            throw MLIntegrationError.missingModel("gate_v21_swift_parameters.json")
        }
        return try Self(data: Data(contentsOf: url))
    }

    func probability(_ values: [Double]) throws -> Double {
        guard values.count == 6, values.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidInput("Sufficiency Gate V2.1 needs six finite features")
        }
        var z = classifier.intercept
        for i in 0..<6 { z += ((values[i] - scaler.mean[i]) / scaler.scale[i]) * classifier.coef[i] }
        let raw = Self.sigmoid(z)
        let clipped = min(max(raw, 1e-6), 1 - 1e-6)
        let logit = log(clipped / (1 - clipped))
        return Self.sigmoid(platt.coef * logit + platt.intercept)
    }

    func indicatesSufficient(probability: Double, nCPT: Int) -> Bool {
        nCPT >= decision.minimumCpt && nCPT <= decision.maximumEvaluatedCpt &&
            probability >= decision.probabilityThreshold
    }

    private static func sigmoid(_ x: Double) -> Double {
        if x >= 0 { return 1 / (1 + exp(-x)) }
        let e = exp(x); return e / (1 + e)
    }
}

struct GateV21VoxelSummary: Codable, Sendable {
    let predictedCoverage: Double
    let estimatedMeanBound: Double
    let estimatedP90Bound: Double
    let count: Int

    /// Python: mean(error <= 0.15), mean(error), np.quantile(error, 0.90).
    init(estimatedErrors: [Double]) throws {
        guard !estimatedErrors.isEmpty, estimatedErrors.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw MLIntegrationError.invalidInput("Gate V2.1 requires finite estimated errors for hidden valid voxels")
        }
        count = estimatedErrors.count
        predictedCoverage = Double(estimatedErrors.filter { $0 <= 0.15 }.count) / Double(count)
        estimatedMeanBound = estimatedErrors.reduce(0, +) / Double(count)
        let sorted = estimatedErrors.sorted()
        let position = 0.9 * Double(count - 1)
        let lower = Int(floor(position)), upper = Int(ceil(position))
        estimatedP90Bound = sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

struct GateV21Assessment: Sendable {
    let nCPT: Int
    let summary: GateV21VoxelSummary
    let deltaPredicted: Double
    let deltaP90: Double
    let probability: Double
    let indicatesSufficient: Bool
}

struct GateV21History: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let count: Int
        let stateKey: String
        let gridSignature: String
        let summary: GateV21VoxelSummary
    }
    private(set) var entries: [Entry] = []
    mutating func reset() { entries.removeAll() }

    /// A changed prefix invalidates subsequent deltas. Duplicate evaluations replace the same count.
    mutating func evaluate(count: Int, stateKey: String, previousStateKey: String?, gridSignature: String,
                           summary: GateV21VoxelSummary, gate: SufficiencyGateV21) throws -> GateV21Assessment {
        guard count > 0 else { throw MLIntegrationError.invalidInput("Gate V2.1 CPT count") }
        guard count <= gate.decision.maximumEvaluatedCpt else {
            reset()
            throw MLIntegrationError.invalidInput("Gate V2.1 has only been evaluated through 16 CPT")
        }
        if let index = entries.firstIndex(where: { $0.count >= count }) { entries.removeSubrange(index...) }
        if entries.last?.count != count - 1 || entries.last?.stateKey != previousStateKey ||
            entries.last?.gridSignature != gridSignature { reset() }
        let previous = entries.last?.summary
        entries.append(.init(count: count, stateKey: stateKey, gridSignature: gridSignature, summary: summary))
        guard count == 1 || previous != nil else {
            throw MLIntegrationError.invalidInput("Gate V2.1 needs the preceding CPT-count state for delta features")
        }
        let deltaPredicted = summary.predictedCoverage - (previous?.predictedCoverage ?? summary.predictedCoverage)
        let deltaP90 = summary.estimatedP90Bound - (previous?.estimatedP90Bound ?? summary.estimatedP90Bound)
        let values = [summary.predictedCoverage, Double(count), summary.estimatedMeanBound,
                      summary.estimatedP90Bound, deltaPredicted, deltaP90]
        let probability = try gate.probability(values)
        return .init(nCPT: count, summary: summary, deltaPredicted: deltaPredicted,
                     deltaP90: deltaP90, probability: probability,
                     indicatesSufficient: gate.indicatesSufficient(probability: probability, nCPT: count))
    }
}
