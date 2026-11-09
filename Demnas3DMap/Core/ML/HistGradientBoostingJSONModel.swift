import Foundation

/// Inference only. The JSON stores already-shrunk leaf contributions.
struct HistGradientBoostingJSONModel: Decodable, Sendable {
    enum ModelType: String, Decodable, Sendable {
        case histGradientBoostingRegressor
        case histGradientBoostingBinaryClassifier
    }

    struct Node: Decodable, Sendable {
        let value: Double
        let featureIndex: Int
        let threshold: Double
        let missingGoToLeft: Bool
        let left: Int
        let right: Int
        let isLeaf: Bool
    }

    let formatVersion: Int
    let modelType: ModelType
    let baseline: Double
    let treeValuesAlreadyShrunk: Bool
    let learningRate: Double
    let featureNames: [String]
    let treeCount: Int
    let trees: [[Node]]
    let calibrationCorrection: Double?
    let probabilityThreshold: Double?
    let coverageThreshold: Double?
    let persistence: Int?

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard formatVersion == 1, treeValuesAlreadyShrunk, baseline.isFinite,
              learningRate.isFinite, !featureNames.isEmpty,
              Set(featureNames).count == featureNames.count,
              treeCount == trees.count, !trees.isEmpty else {
            throw MLIntegrationError.invalidContract("HistGradientBoosting JSON metadata")
        }
        for tree in trees {
            guard !tree.isEmpty else { throw MLIntegrationError.invalidContract("Empty HistGradientBoosting tree") }
            for node in tree {
                guard node.value.isFinite,
                      node.isLeaf || (featureNames.indices.contains(node.featureIndex) &&
                                      node.threshold.isFinite &&
                                      tree.indices.contains(node.left) && tree.indices.contains(node.right)) else {
                    throw MLIntegrationError.invalidContract("Invalid HistGradientBoosting tree node")
                }
            }
        }
    }

    static func bundled(_ name: String, bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MLIntegrationError.missingModel("\(name).json")
        }
        return try Self(data: Data(contentsOf: url))
    }

    func rawPrediction(_ features: [Double]) throws -> Double {
        guard features.count == featureNames.count, features.allSatisfy({ !$0.isInfinite }) else {
            throw MLIntegrationError.invalidInput("Expected \(featureNames.count) features in JSON order; NaN is allowed for missing values.")
        }
        var result = baseline
        for tree in trees {
            var index = 0
            var reachedLeaf = false
            for _ in tree.indices {
                let node = tree[index]
                if node.isLeaf {
                    result += node.value
                    reachedLeaf = true
                    break
                }
                let feature = features[node.featureIndex]
                index = (feature.isNaN ? node.missingGoToLeft : feature <= node.threshold) ? node.left : node.right
            }
            guard reachedLeaf else { throw MLIntegrationError.invalidContract("Tree traversal did not reach a leaf") }
        }
        return result
    }

    /// Named input prevents accidental reordering by callers.
    func rawPrediction(_ features: [String: Double]) throws -> Double {
        guard features.count == featureNames.count else {
            throw MLIntegrationError.invalidInput("Feature names do not match JSON contract")
        }
        return try rawPrediction(featureNames.map { features[$0] ?? .infinity })
    }
}

struct UncertaintyV3Service: Sendable {
    let model: HistGradientBoostingJSONModel

    init(model: HistGradientBoostingJSONModel) throws {
        guard model.modelType == .histGradientBoostingRegressor,
              model.featureNames.count == 10, model.treeCount == 180,
              let correction = model.calibrationCorrection, correction.isFinite else {
            throw MLIntegrationError.invalidContract("Uncertainty V3 model metadata")
        }
        self.model = model
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        try Self(model: .bundled("UncertaintyV3", bundle: bundle))
    }

    func predict(_ features: [Double]) throws -> Double {
        max(0, try model.rawPrediction(features)) + (model.calibrationCorrection ?? 0)
    }

    func predict(_ features: [String: Double]) throws -> Double {
        max(0, try model.rawPrediction(features)) + (model.calibrationCorrection ?? 0)
    }
}

struct SufficiencyV31Service: Sendable {
    let model: HistGradientBoostingJSONModel
    let probabilityThreshold: Double
    let persistence: Int

    init(model: HistGradientBoostingJSONModel) throws {
        guard model.modelType == .histGradientBoostingBinaryClassifier,
              model.featureNames.count == 10, model.treeCount == 250,
              let threshold = model.probabilityThreshold, threshold > 0, threshold < 1,
              let persistence = model.persistence, persistence == 3 else {
            throw MLIntegrationError.invalidContract("Sufficiency V3.1 model metadata")
        }
        self.model = model
        self.probabilityThreshold = threshold
        self.persistence = persistence
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        try Self(model: .bundled("SufficiencyV3_1", bundle: bundle))
    }

    func probability(_ features: [Double]) throws -> Double {
        Self.sigmoid(try model.rawPrediction(features))
    }

    func probability(_ features: [String: Double]) throws -> Double {
        Self.sigmoid(try model.rawPrediction(features))
    }

    private static func sigmoid(_ value: Double) -> Double {
        if value >= 0 { return 1 / (1 + exp(-value)) }
        let exponent = exp(value)
        return exponent / (1 + exponent)
    }
}
