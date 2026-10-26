import CoreML
import Foundation

/// Core ML boundary for the SchemaGAN V3 checkpoint paired with DQNScorer. Tensor order is [batch, channel, depth, north, east].
/// The caller must construct sparse and IDW with the model's training preprocessing.
actor DQNReconstructorG16Service {
    static let shape = [1, 1, 16, 16, 16]
    static let voxelCount = 16 * 16 * 16
    static let icMean: Float = 2.314278231778639
    static let icStd: Float = 0.27927494076233944

    private let model: MLModel

    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource: "DQNReconstructorG16", withExtension: "mlmodelc") else {
            throw MLIntegrationError.missingModel("DQNReconstructorG16")
        }
        model = try MLModel(contentsOf: url)
        for name in ["sparse", "mask", "idw"] {
            guard let input = model.modelDescription.inputDescriptionsByName[name],
                  input.type == .multiArray,
                  input.multiArrayConstraint?.dataType == .float32,
                  input.multiArrayConstraint?.shape.map(\.intValue) == Self.shape else {
                throw MLIntegrationError.invalidContract("DQNReconstructor input \(name)")
            }
        }
        guard let output = model.modelDescription.outputDescriptionsByName["reconstruction"],
              output.type == .multiArray,
              output.multiArrayConstraint?.dataType == .float32,
              output.multiArrayConstraint?.shape.map(\.intValue) == Self.shape else {
            throw MLIntegrationError.invalidContract("DQNReconstructor output reconstruction")
        }
    }

    /// Returns physical Ic. Observed cells are restored exactly after inference.
    /// All arrays use flattened [Z,Y,X] order; observedIc is physical Ic at mask=1.
    func reconstruct(sparse: [Float], mask: [Float], idw: [Float], observedIc: [Float]) throws -> [Float] {
        let count = Self.voxelCount
        guard [sparse, mask, idw, observedIc].allSatisfy({ $0.count == count }),
              sparse.allSatisfy(\.isFinite), idw.allSatisfy(\.isFinite),
              mask.allSatisfy({ $0 == 0 || $0 == 1 }),
              mask.contains(1),
              zip(mask, observedIc).allSatisfy({ $0 == 0 || $1.isFinite }),
              zip(sparse, mask).allSatisfy({ $1 == 1 || $0 == 0 }) else {
            throw MLIntegrationError.invalidInput("DQNReconstructor requires finite normalized [16,16,16] tensors and a binary observation mask")
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "sparse": Self.array(sparse), "mask": Self.array(mask), "idw": Self.array(idw)
        ])
        let prediction = try model.prediction(from: features)
        guard let array = prediction.featureValue(for: "reconstruction")?.multiArrayValue,
              array.count == count, array.dataType == .float32 else {
            throw MLIntegrationError.invalidOutput("DQNReconstructor reconstruction")
        }
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let normalized = array[index].floatValue
            let physical = normalized * Self.icStd + Self.icMean
            guard physical.isFinite else { throw MLIntegrationError.invalidOutput("DQNReconstructor returned a nonfinite Ic") }
            values[index] = mask[index] == 1 ? observedIc[index] : physical
        }
        return values
    }

    private static func array(_ values: [Float]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        for (index, value) in values.enumerated() { result[index] = NSNumber(value: value) }
        return result
    }
}
