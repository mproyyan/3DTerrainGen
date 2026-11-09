import Foundation
import Testing
@testable import TerrainCore

private func frozenJSON(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("ModelResources/UncertaintyV3_1/\(name).json"))
}

/// Run with `swift test --filter frozenHistGradientBoostingMetadata` for a compact metadata printout.
@Test func frozenHistGradientBoostingMetadata() throws {
    let uncertainty = try UncertaintyV3Service(model: .init(data: frozenJSON("UncertaintyV3")))
    let sufficiency = try SufficiencyV31Service(model: .init(data: frozenJSON("SufficiencyV3_1")))
    print("Uncertainty V3: type=\(uncertainty.model.modelType.rawValue), trees=\(uncertainty.model.treeCount), features=\(uncertainty.model.featureNames.count), calibrationCorrection=\(uncertainty.model.calibrationCorrection!)")
    print("Sufficiency V3.1: type=\(sufficiency.model.modelType.rawValue), trees=\(sufficiency.model.treeCount), features=\(sufficiency.model.featureNames.count), probabilityThreshold=\(sufficiency.probabilityThreshold), persistence=\(sufficiency.persistence)")
    #expect(uncertainty.model.treeCount == 180)
    #expect(uncertainty.model.featureNames.count == 10)
    #expect(sufficiency.model.treeCount == 250)
    #expect(sufficiency.model.featureNames.count == 10)
    #expect(abs(sufficiency.probabilityThreshold - 0.98) < 1e-10)
    #expect(sufficiency.persistence == 3)
    #expect(try uncertainty.predict(Array(repeating: 0, count: 10)).isFinite)
    let probability = try sufficiency.probability(Array(repeating: 0, count: 10))
    #expect(probability >= 0 && probability <= 1)
}

@Test func histGradientBoostingThresholdMissingAndShrunkLeaves() throws {
    let json = """
    {"formatVersion":1,"modelType":"histGradientBoostingRegressor","baseline":2,
     "treeValuesAlreadyShrunk":true,"learningRate":0.01,"featureNames":["a"],"treeCount":2,
     "trees":[
       [{"value":0,"featureIndex":0,"threshold":5,"missingGoToLeft":true,"left":1,"right":2,"isLeaf":false},
        {"value":3,"featureIndex":0,"threshold":0,"missingGoToLeft":false,"left":0,"right":0,"isLeaf":true},
        {"value":7,"featureIndex":0,"threshold":0,"missingGoToLeft":false,"left":0,"right":0,"isLeaf":true}],
       [{"value":-1,"featureIndex":0,"threshold":0,"missingGoToLeft":false,"left":0,"right":0,"isLeaf":true}]]}
    """
    let model = try HistGradientBoostingJSONModel(data: Data(json.utf8))
    #expect(try model.rawPrediction([5]) == 4) // <= takes left; 2 + 3 - 1, no extra learning rate
    #expect(try model.rawPrediction([6]) == 8)
    #expect(try model.rawPrediction([Double.nan]) == 4)
    #expect(try model.rawPrediction(["a": 6]) == 8)
}
