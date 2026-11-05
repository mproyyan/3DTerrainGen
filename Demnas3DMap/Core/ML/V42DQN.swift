import CoreML
import Foundation

struct V42Candidate: Sendable {
    let x: Int
    let y: Int
    let local: [Float]
}

struct V42State: Sendable {
    let candidates: [V42Candidate]
    let global: [Float]
}

/// dqn3d/v4/features.py, preserving candidate [17] and context [11] order.
enum V42FeatureAdapter {
    static func build(input: V42Input, reconstruction: [Float], accessMask: [Bool]? = nil) throws -> V42State {
        let nx = input.nx, ny = input.ny, depth = input.nz
        guard reconstruction.count == input.count, reconstruction.allSatisfy(\.isFinite),
              accessMask == nil || accessMask?.count == nx*ny else {
            throw MLIntegrationError.invalidInput("V4.2 reconstruction/access mask shape invalid")
        }
        let observedSites = (0..<nx).flatMap { x in (0..<ny).compactMap { y -> (Int,Int)? in
            (0..<depth).contains { input.observed[input.index(x,y,$0)] } ? (x,y) : nil
        } }
        guard !observedSites.isEmpty else { throw MLIntegrationError.invalidInput("V4.2 needs one measured CPT") }
        let validSites = input.validXY.filter { $0 }.count
        let validValues = (0..<nx).flatMap { x in (0..<ny).flatMap { y -> [Double] in
            guard input.validXY[input.xy(x,y)] else { return [] }
            return (0..<depth).map { Double((reconstruction[input.index(x,y,$0)]-V42Input.mean)/V42Input.std) }
        } }
        let observedValid = input.observed.filter { $0 }.count
        let global: [Float] = [
            Float(log1p(Double(observedSites.count))/max(log1p(Double(validSites)),1e-6)),
            Float(Double(nx)*input.horizontalMeters/32),
            Float(Double(ny)*input.northMeters/32),
            Float(Double(depth)*input.depthMeters/16),
            Float(input.horizontalMeters/2), Float(input.northMeters/2),
            Float(input.depthMeters/2), Float(mean(validValues)), Float(std(validValues)),
            Float(Double(validSites)/Double(nx*ny)),
            Float(Double(observedValid)/Double(validSites*depth))
        ]
        let diagonal = hypot(Double(nx)*input.horizontalMeters,Double(ny)*input.northMeters)
        var candidates = [V42Candidate]()
        let radiusX = Int(ceil(4 / input.horizontalMeters))
        let radiusY = Int(ceil(4 / input.northMeters))
        for x in 0..<nx { for y in 0..<ny {
            let xy = input.xy(x,y)
            guard input.validXY[xy], accessMask?[xy] ?? true,
                  !(0..<depth).contains(where: { input.observed[input.index(x,y,$0)] }) else { continue }
            let nearest = observedSites.map { hypot(Double(x-$0.0)*input.horizontalMeters,
                                                     Double(y-$0.1)*input.northMeters) }.min()!
            // Python includes the candidate itself in the 4 m neighborhood. At 5 m/cell it has one site.
            var nearbySites = 0, nearbyObserved = 0, nearbyValid = 0
            var nearbyValues = [Double]()
            for xx in max(0,x-radiusX)..<min(nx,x+radiusX+1) { for yy in max(0,y-radiusY)..<min(ny,y+radiusY+1) {
                guard hypot(Double(x-xx)*input.horizontalMeters,Double(y-yy)*input.northMeters) <= 4+1e-9 else { continue }
                nearbySites += 1
                if (0..<depth).contains(where: { input.observed[input.index(xx,yy,$0)] }) { nearbyObserved += 1 }
                if input.validXY[input.xy(xx,yy)] {
                    nearbyValid += depth
                    for z in 0..<depth { nearbyValues.append(Double((reconstruction[input.index(xx,yy,z)]-V42Input.mean)/V42Input.std)) }
                }
            } }
            let profile = (0..<depth).map { Double((reconstruction[input.index(x,y,$0)]-V42Input.mean)/V42Input.std) }
            let binMeans = (0..<4).map { bin -> Double in
                let start = (bin * depth + 3) / 4, end = min(depth, ((bin + 1) * depth + 3) / 4)
                return mean(Array(profile[start..<end]))
            }
            let local: [Float] = [
                Float(Double(x)/Double(max(nx-1,1))), Float(Double(y)/Double(max(ny-1,1))),
                Float(min(nearest/max(diagonal,1e-6),1)),
                Float(Double(nearbyObserved)/Double(nearbySites)),
                1, Float(mean(profile)), Float(std(profile))
            ] + binMeans.map(Float.init) + [0,0,0,0] + [
                Float(mean(nearbyValues)), Float(Double(nearbyValid)/Double(nearbySites*depth))
            ]
            guard local.count == 17, local.allSatisfy(\.isFinite) else { throw MLIntegrationError.invalidInput("V4.2 candidate features invalid") }
            candidates.append(.init(x:x,y:y,local:local))
        } }
        guard global.count == 11, global.allSatisfy(\.isFinite) else { throw MLIntegrationError.invalidInput("V4.2 global features invalid") }
        return .init(candidates:candidates,global:global)
    }
    private static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0,+)/Double(values.count) }
    private static func std(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let avg = mean(values)
        return sqrt(values.reduce(0) { $0 + ($1-avg)*($1-avg) }/Double(values.count))
    }
}

actor V42DQNService {
    private let model: MLModel
    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource:"DQN_V4_2_SingleCandidate",withExtension:"mlmodelc") else {
            throw MLIntegrationError.missingModel("DQN_V4_2_SingleCandidate")
        }
        model = try MLModel(contentsOf:url)
        guard model.modelDescription.inputDescriptionsByName["candidate_features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,17],
              model.modelDescription.inputDescriptionsByName["global_context"]?.multiArrayConstraint?.shape.map(\.intValue) == [11],
              model.modelDescription.outputDescriptionsByName["var_28"]?.multiArrayConstraint?.shape.map(\.intValue) == [1] else {
            throw MLIntegrationError.invalidContract("DQN V4.2 candidate_features/global_context/var_28")
        }
    }
    func best(_ state: V42State) throws -> (candidate: V42Candidate, score: Float)? {
        guard !state.candidates.isEmpty else { return nil }
        let global = try MLMultiArray(shape:[11],dataType:.float32)
        for i in state.global.indices { global[i] = NSNumber(value:state.global[i]) }
        var best: (candidate:V42Candidate,score:Float)?
        for candidate in state.candidates {
            try Task.checkCancellation()
            let local = try MLMultiArray(shape:[1,17],dataType:.float32)
            for i in candidate.local.indices { local[i] = NSNumber(value:candidate.local[i]) }
            let provider = try MLDictionaryFeatureProvider(dictionary:["candidate_features":local,"global_context":global])
            let prediction = try model.prediction(from:provider)
            guard let q = prediction.featureValue(for:"var_28")?.multiArrayValue,
                  q.count == 1, q.dataType == .float32, q[0].floatValue.isFinite else {
                throw MLIntegrationError.invalidOutput("DQN V4.2 Q-value")
            }
            let score = q[0].floatValue
            // Candidates are x,y lexicographic. Strict comparison preserves Python's tie break.
            if best == nil || score > best!.score { best = (candidate,score) }
        }
        return best
    }
}

struct V42Recommendation: Sendable {
    let coordinate: GeoPoint
    let volume: ReconstructionVolume
    let qValue: Float
    let candidateX: Int
    let candidateY: Int
    var v45Diagnostics: V45RunDiagnostics? = nil
}

enum V42RecommendationService {
    static func recommend(terrain:TerrainMesh,boundary:[GeoPoint],points:[CPTPoint],accessMask:[Bool]? = nil,
                          preferredMeters:Double? = nil,
                          schemaURL:URL? = nil,dqnURL:URL? = nil) async throws -> V42Recommendation? {
        let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:points,preferredMeters:preferredMeters)
        let schema = try V42SchemaGANService(modelURL:schemaURL)
        let reconstruction = try await schema.reconstruct(input)
        try Task.checkCancellation()
        let volume = try input.volume(reconstruction)
        let state = try V42FeatureAdapter.build(input:input,reconstruction:reconstruction,accessMask:accessMask)
        let scorer = try V42DQNService(modelURL:dqnURL)
        guard let best = try await scorer.best(state) else { return nil }
        let east = input.east(best.candidate.x), north = input.north(best.candidate.y)
        let coordinate = CoordinateTransformer.geographic(east:east,north:north,origin:terrain.origin)
        guard terrain.surfacePosition(at:coordinate) != nil else { throw MLIntegrationError.invalidOutput("V4.2 candidate coordinate") }
        return .init(coordinate:coordinate,volume:volume,qValue:best.score,candidateX:best.candidate.x,candidateY:best.candidate.y)
    }
}
