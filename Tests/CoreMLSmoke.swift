// Standalone macOS smoke test for the flexible Model C and DQN scorer.
// Usage: swift Tests/CoreMLSmoke.swift /path/ModelC_Flexible.mlmodelc /path/DQNScorer.mlmodelc
import CoreML
import Foundation

func makeArray(_ shape: [Int]) throws -> MLMultiArray {
    try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
}

guard CommandLine.arguments.count == 3 else {
    fatalError("Pass paths to compiled ModelC_Flexible.mlmodelc and DQNScorer.mlmodelc")
}
let modelC = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
for (nx, ny, nz) in [(16, 16, 8), (24, 24, 12), (32, 24, 16), (32, 32, 16), (48, 32, 12), (48, 32, 16)] {
    let shape = [1, 1, nz, ny, nx]
    let sparse = try makeArray(shape)
    let mask = try makeArray(shape)
    let idw = try makeArray(shape)
    for z in 0..<nz { mask[(z * ny + ny / 2) * nx + nx / 2] = 1 }
    let input = try MLDictionaryFeatureProvider(dictionary: ["sparse": sparse, "mask": mask, "idw": idw])
    let output = try modelC.prediction(from: input)
    guard let reconstruction = output.featureValue(for: "reconstruction")?.multiArrayValue,
          reconstruction.shape.map(\.intValue) == shape,
          reconstruction.count == nx * ny * nz,
          (0..<reconstruction.count).allSatisfy({ reconstruction[$0].floatValue.isFinite }) else {
        fatalError("Model C Flexible output invalid for \(nx)×\(ny)×\(nz)")
    }
    print("Model C Flexible \(nx)×\(ny)×\(nz): PASS")
}

let dqn = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let features = try makeArray([2, 28])
let dFeatures = try MLDictionaryFeatureProvider(dictionary: ["candidate_features": features])
let dOutput = try dqn.prediction(from: dFeatures)
guard let scores = dOutput.featureValue(for: "q_scores")?.multiArrayValue,
      scores.count == 2,
      (0..<scores.count).allSatisfy({ scores[$0].floatValue.isFinite }) else {
    fatalError("DQN output shape/values invalid")
}
print("DQN load and shape smoke: PASS")
