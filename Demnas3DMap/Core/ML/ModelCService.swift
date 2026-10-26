import CoreML
import Foundation

/// Model C Flexible expects normalized Float32 [B,C,Z,Y,X] tensors.
actor ModelCService {
    static let icMean: Float = 2.305778080072476
    static let icStd: Float = 0.3108808206093057

    private let model: MLModel

    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource: "ModelC_Flexible", withExtension: "mlmodelc") else {
            throw MLIntegrationError.missingModel("ModelC_Flexible")
        }
        model = try MLModel(contentsOf: url)
        for name in ["sparse", "mask", "idw"] {
            guard let input = model.modelDescription.inputDescriptionsByName[name],
                  input.type == .multiArray,
                  input.multiArrayConstraint?.dataType == .float32 else {
                throw MLIntegrationError.invalidContract("ModelC_Flexible input \(name)")
            }
        }
        guard let output = model.modelDescription.outputDescriptionsByName["reconstruction"],
              output.type == .multiArray,
              output.multiArrayConstraint?.dataType == .float32 else {
            throw MLIntegrationError.invalidContract("ModelC_Flexible output reconstruction")
        }
    }

    /// Returns physical Ic, restoring every observed voxel exactly.
    func reconstruct(sparse: [Float], mask: [Float], idw: [Float],
                     observedIc: [Float], grid: ReconstructionGrid) throws -> [Float] {
        let count = grid.voxelCount
        guard [8, 12, 16].contains(grid.nz),
              (16...32).contains(grid.ny), grid.ny.isMultiple(of: 4),
              (16...48).contains(grid.nx), grid.nx.isMultiple(of: 4),
              grid.spacingMeters == 1,
              [sparse, mask, idw, observedIc].allSatisfy({ $0.count == count }),
              sparse.allSatisfy(\.isFinite), idw.allSatisfy(\.isFinite),
              mask.allSatisfy({ $0 == 0 || $0 == 1 }), mask.contains(1),
              zip(mask, observedIc).allSatisfy({ $0 == 0 || $1.isFinite }),
              zip(sparse, mask).allSatisfy({ $1 == 1 || $0 == 0 }) else {
            throw MLIntegrationError.invalidInput("ModelC_Flexible requires finite, equally shaped tensors on a supported 1 m grid")
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "sparse": Self.array(sparse, shape: grid.shape),
            "mask": Self.array(mask, shape: grid.shape),
            "idw": Self.array(idw, shape: grid.shape)
        ])
        let prediction = try model.prediction(from: features)
        guard let array = prediction.featureValue(for: "reconstruction")?.multiArrayValue,
              array.count == count, array.dataType == .float32,
              array.shape.map(\.intValue) == grid.shape else {
            throw MLIntegrationError.invalidOutput("ModelC_Flexible reconstruction shape")
        }
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let physical = array[index].floatValue * Self.icStd + Self.icMean
            guard physical.isFinite else { throw MLIntegrationError.invalidOutput("ModelC_Flexible returned nonfinite Ic") }
            values[index] = mask[index] == 1 ? observedIc[index] : physical
        }
        return values
    }

    private static func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        for (index, value) in values.enumerated() { result[index] = NSNumber(value: value) }
        return result
    }
}

enum MLIntegrationError: LocalizedError, Sendable {
    case missingModel(String)
    case invalidContract(String)
    case invalidInput(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let name): "Core ML model \(name) is unavailable in the app bundle."
        case .invalidContract(let detail): "Unexpected Core ML contract: \(detail)."
        case .invalidInput(let detail): detail
        case .invalidOutput(let detail): "Unexpected Core ML output: \(detail)."
        }
    }
}
