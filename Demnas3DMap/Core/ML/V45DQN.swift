import CoreML
import Foundation

/// dqn3d/v45/features.py: the first 17 candidate features and all 11 global
/// features are shared with V4.2; V4.5 appends lateral_ic_gradient / Ic std.
enum V45FeatureAdapter {
    static let candidateNames = [
        "x_local_fraction", "y_local_fraction", "nearest_cpt_distance_fraction",
        "local_observed_density_4m", "valid_depth_fraction",
        "reconstructed_ic_mean_z", "reconstructed_ic_std_z",
        "depth_bin_0_ic_mean_z", "depth_bin_1_ic_mean_z",
        "depth_bin_2_ic_mean_z", "depth_bin_3_ic_mean_z",
        "depth_bin_0_empty", "depth_bin_1_empty", "depth_bin_2_empty", "depth_bin_3_empty",
        "local_4m_reconstructed_ic_mean_z", "local_4m_valid_fraction", "lateral_ic_gradient"
    ]
    static let globalNames = [
        "log_observed_cpt_fraction", "extent_x_over_32m", "extent_y_over_32m",
        "extent_z_over_16m", "dx_over_2m", "dy_over_2m", "dz_over_2m",
        "global_reconstructed_ic_mean_z", "global_reconstructed_ic_std_z",
        "valid_voxel_fraction", "observed_valid_voxel_fraction"
    ]

    static func build(input: V42Input, reconstruction: [Float], accessMask: [Bool]? = nil) throws -> V42State {
        let base = try V42FeatureAdapter.build(input: input, reconstruction: reconstruction, accessMask: accessMask)
        let nx = input.nx, ny = input.ny, nz = input.nz
        var means = [Double](repeating: 0, count: nx * ny)
        for x in 0..<nx { for y in 0..<ny where input.validXY[input.xy(x,y)] {
            var total = 0.0
            for z in 0..<nz { total += Double(reconstruction[input.index(x,y,z)]) }
            means[input.xy(x,y)] = total / Double(nz)
        } }
        func axisGradient(_ x: Int, _ y: Int, xAxis: Bool) -> Double {
            var total = 0.0, count = 0
            for direction in [-1,1] {
                let xx = xAxis ? x + direction : x
                let yy = xAxis ? y : y + direction
                guard (0..<nx).contains(xx), (0..<ny).contains(yy), input.validXY[input.xy(xx,yy)] else { continue }
                total += abs(means[input.xy(xx,yy)] - means[input.xy(x,y)]) /
                    (xAxis ? input.horizontalMeters : input.northMeters)
                count += 1
            }
            return count == 0 ? 0 : total / Double(count)
        }
        let candidates = base.candidates.map { candidate -> V42Candidate in
            let gx = axisGradient(candidate.x,candidate.y,xAxis:true)
            let gy = axisGradient(candidate.x,candidate.y,xAxis:false)
            let gradient = Float(hypot(gx,gy) / Double(V42Input.std))
            return .init(x:candidate.x,y:candidate.y,local:candidate.local + [gradient])
        }
        guard candidates.allSatisfy({ $0.local.count == 18 && $0.local.allSatisfy(\.isFinite) }) else {
            throw MLIntegrationError.invalidInput("DQN V4.5: 18 fitur kandidat tidak valid.")
        }
        return .init(candidates:candidates,global:base.global)
    }
}

actor V45DQNService {
    private let model: MLModel
    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource:"DQN_V4_5_Extended",withExtension:"mlmodelc") else {
            throw MLIntegrationError.missingModel("DQN_V4_5_Extended")
        }
        model = try MLModel(contentsOf:url)
        guard model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,29],
              model.modelDescription.outputDescriptionsByName["q_value"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,1] else {
            throw MLIntegrationError.invalidContract("DQN V4.5 features [1,29] / q_value [1,1]")
        }
    }
    func score(_ features: [Float]) throws -> Float {
        guard features.count == 29, features.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidInput("DQN V4.5 memerlukan 29 fitur berhingga.")
        }
        let array = try MLMultiArray(shape:[1,29],dataType:.float32)
        for i in features.indices { array[i] = NSNumber(value:features[i]) }
        let result = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["features":array]))
        guard let output = result.featureValue(for:"q_value")?.multiArrayValue,
              output.shape.map(\.intValue) == [1,1], output[0].floatValue.isFinite else {
            throw MLIntegrationError.invalidOutput("DQN V4.5 Q-value")
        }
        return output[0].floatValue
    }
    func evaluate(_ state: V42State) throws -> V45ScoreDiagnostics? {
        guard state.global.count == 11 else { throw MLIntegrationError.invalidInput("DQN V4.5: 11 fitur global diperlukan.") }
        var best: (candidate:V42Candidate,score:Float)?
        var minimum = Float.infinity, maximum = -Float.infinity, total = 0.0
        var top = [V45ScoredCandidate]()
        for candidate in state.candidates {
            try Task.checkCancellation()
            let q = try score(candidate.local + state.global)
            minimum = min(minimum,q); maximum = max(maximum,q); total += Double(q)
            top.append(.init(x:candidate.x,y:candidate.y,qValue:q))
            top.sort { $0.qValue == $1.qValue ? ($0.x == $1.x ? $0.y < $1.y : $0.x < $1.x) : $0.qValue > $1.qValue }
            if top.count > 10 { top.removeLast() }
            // Candidate order is x then y. Strict comparison keeps the first site on a tie.
            if best == nil || q > best!.score { best = (candidate,q) }
        }
        guard let best else { return nil }
        return .init(best:best.candidate,bestQ:best.score,legalCount:state.candidates.count,
                     minimumQ:minimum,meanQ:Float(total/Double(state.candidates.count)),
                     maximumQ:maximum,top:top)
    }
    func best(_ state: V42State) throws -> (candidate: V42Candidate, score: Float)? {
        guard let result = try evaluate(state) else { return nil }
        return (result.best,result.bestQ)
    }
}

struct V45ScoredCandidate: Sendable {
    let x: Int
    let y: Int
    let qValue: Float
}

struct V45ScoreDiagnostics: Sendable {
    let best: V42Candidate
    let bestQ: Float
    let legalCount: Int
    let minimumQ: Float
    let meanQ: Float
    let maximumQ: Float
    let top: [V45ScoredCandidate]
}

struct V45RunDiagnostics: Sendable {
    let scores: V45ScoreDiagnostics
    let schemaSeconds: Double
    let featureSeconds: Double
    let scoringSeconds: Double
}

enum V45RecommendationService {
    static func recommend(terrain:TerrainMesh,boundary:[GeoPoint],points:[CPTPoint],accessMask:[Bool]? = nil,
                          preferredMeters:Double? = nil, preferredNorthMeters:Double? = nil,
                          preferredDepthMeters:Double = 1,
                          schemaURL:URL? = nil,dqnURL:URL? = nil) async throws -> V42Recommendation? {
        let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:points,
                                          preferredMeters:preferredMeters,
                                          preferredNorthMeters:preferredNorthMeters,
                                          preferredDepthMeters:preferredDepthMeters)
        let schema = try V42SchemaGANService(modelURL:schemaURL)
        let schemaStart = Date()
        let reconstruction = try await schema.reconstruct(input)
        let schemaSeconds = Date().timeIntervalSince(schemaStart)
        try Task.checkCancellation()
        let volume = try input.volume(reconstruction)
        let featureStart = Date()
        let state = try V45FeatureAdapter.build(input:input,reconstruction:reconstruction,accessMask:accessMask)
        let featureSeconds = Date().timeIntervalSince(featureStart)
        let scorer = try V45DQNService(modelURL:dqnURL)
        let scoringStart = Date()
        guard let scores = try await scorer.evaluate(state) else { return nil }
        let scoringSeconds = Date().timeIntervalSince(scoringStart)
        let coordinate = CoordinateTransformer.geographic(east:input.east(scores.best.x),
                                                          north:input.north(scores.best.y),origin:terrain.origin)
        guard terrain.surfacePosition(at:coordinate) != nil else {
            throw MLIntegrationError.invalidOutput("DQN V4.5 candidate coordinate")
        }
        return .init(coordinate:coordinate,volume:volume,qValue:scores.bestQ,
                     candidateX:scores.best.x,candidateY:scores.best.y,
                     v45Diagnostics:.init(scores:scores,schemaSeconds:schemaSeconds,
                                          featureSeconds:featureSeconds,scoringSeconds:scoringSeconds))
    }
}
