import Foundation

/// Advisory only. This result never stops the investigation or gates DQN inference.
struct CoverageV1Assessment: Sendable {
    let nCPT: Int
    let predictedCoverage: Double
    let consecutivePositiveCount: Int
    let advisoryHigh: Bool
}

enum CoverageV1RecommendationPolicy {
    /// Advisory status is never an autonomous stopping gate.
    static func next<T>(assessment: CoverageV1Assessment,
                        recommend: () async throws -> T?) async throws -> T? {
        try await recommend()
    }
}

struct CoverageV1History: Sendable {
    private(set) var evaluations: [(count: Int, positive: Bool)] = []

    mutating func reset() { evaluations.removeAll() }

    mutating func record(count: Int, positive: Bool, persistence: Int = 5) -> Int {
        if let last = evaluations.last, count < last.count { reset() }
        if let index = evaluations.firstIndex(where: { $0.count == count }) {
            evaluations.removeSubrange(index..<evaluations.endIndex)
        }
        evaluations.append((count, positive))
        var consecutive = 0, expected = count
        for entry in evaluations.reversed() {
            guard entry.count == expected, entry.positive else { break }
            consecutive += 1; expected -= 1
        }
        return min(consecutive, persistence)
    }
}

struct CoverageV1Service: Sendable {
    static let featureNames = CPTAssessmentPipeline.uncertaintyFeatureNames
    static let coverageThreshold = 0.925
    static let persistence = 5
    let model: HistGradientBoostingJSONModel

    init(model: HistGradientBoostingJSONModel) throws {
        guard model.modelType == .histGradientBoostingBinaryClassifier,
              model.featureNames == Self.featureNames,
              model.treeCount == 180,
              model.coverageThreshold == Self.coverageThreshold,
              model.persistence == Self.persistence else {
            throw MLIntegrationError.invalidContract("Coverage V1 frozen classifier or advisory contract")
        }
        self.model = model
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        try Self(model: .bundled("CoverageV1", bundle: bundle))
    }

    func probability(_ features: [Double]) throws -> Double {
        let raw = try model.rawPrediction(features)
        return raw >= 0 ? 1 / (1 + exp(-raw)) : exp(raw) / (1 + exp(raw))
    }
}

enum CoverageV1Pipeline {
    static func predictedCoverage(probabilities: [Double]) throws -> Double {
        guard !probabilities.isEmpty, probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw MLIntegrationError.invalidInput("Coverage V1 requires finite hidden-voxel probabilities")
        }
        return probabilities.reduce(0, +) / Double(probabilities.count)
    }

    static func assess(volume: ReconstructionVolume, nCPT: Int, service: CoverageV1Service,
                       history: inout CoverageV1History) throws -> CoverageV1Assessment {
        let grid = volume.grid
        guard nCPT > 0, volume.values.count == grid.voxelCount,
              volume.observed.count == grid.voxelCount,
              volume.validXY.count == grid.nx * grid.ny else {
            throw MLIntegrationError.invalidInput("Coverage V1 reconstruction dimensions")
        }
        let sites = (0..<grid.nx).flatMap { x in (0..<grid.ny).compactMap { y -> (Int, Int)? in
            (0..<grid.nz).contains { volume.observed[grid.index(x:x,y:y,z:$0)] } ? (x,y) : nil
        } }
        guard sites.count == nCPT else {
            throw MLIntegrationError.invalidInput("Coverage V1 measured CPT columns do not match CPT count")
        }
        var sum = 0.0, count = 0
        for z in 0..<grid.nz {
            try Task.checkCancellation()
            for y in 0..<grid.ny { for x in 0..<grid.nx {
                guard volume.validXY[grid.xyIndex(x:x,y:y)] else { continue }
                let index = grid.index(x:x,y:y,z:z)
                guard !volume.observed[index] else { continue }
                let features = UncertaintyV2Features.row(volume: volume, x: x, y: y, z: z, sites: sites)
                guard features.count == 10, features.allSatisfy(\.isFinite) else {
                    throw MLIntegrationError.invalidInput("Coverage V1 nonfinite voxel features")
                }
                sum += try service.probability(features)
                count += 1
            } }
        }
        guard count > 0 else { throw MLIntegrationError.invalidInput("Coverage V1 has no hidden valid voxels") }
        let coverage = sum / Double(count)
        let consecutive = history.record(count: nCPT, positive: coverage >= CoverageV1Service.coverageThreshold)
        #if DEBUG
        print("[Coverage V1] CPT=\(nCPT), hidden valid voxels=\(count), predictedCoverage=\(coverage), positive run=\(consecutive)/5, advisoryHigh=\(consecutive >= 5)")
        #endif
        return .init(nCPT: nCPT, predictedCoverage: coverage,
                     consecutivePositiveCount: consecutive, advisoryHigh: consecutive >= 5)
    }
}

/// Keeps the existing risk-map renderer while sourcing its values from Uncertainty V3.
enum UncertaintyV3MapFactory {
    static func makeMap(volume: ReconstructionVolume, service: UncertaintyV3Service) throws -> UncertaintyV2Map {
        let grid = volume.grid
        let sites = (0..<grid.nx).flatMap { x in (0..<grid.ny).compactMap { y -> (Int, Int)? in
            (0..<grid.nz).contains { volume.observed[grid.index(x:x,y:y,z:$0)] } ? (x,y) : nil
        } }
        guard !sites.isEmpty else { throw MLIntegrationError.invalidInput("Uncertainty V3 needs measured CPT") }
        var values = [Float](repeating:.nan,count:grid.voxelCount)
        var featureSeconds = 0.0, treeSeconds = 0.0
        for z in 0..<grid.nz {
            try Task.checkCancellation()
            let featureStart = Date()
            var rows = [(Int,[Double])]()
            for y in 0..<grid.ny { for x in 0..<grid.nx {
                guard volume.validXY[grid.xyIndex(x:x,y:y)] else { continue }
                let index = grid.index(x:x,y:y,z:z)
                guard !volume.observed[index] else { continue }
                let row = UncertaintyV2Features.row(volume:volume,x:x,y:y,z:z,sites:sites)
                guard row.count == 10, row.allSatisfy(\.isFinite) else {
                    throw MLIntegrationError.invalidInput("Uncertainty V3 nonfinite voxel features")
                }
                rows.append((index,row))
            } }
            featureSeconds += Date().timeIntervalSince(featureStart)
            let treeStart = Date()
            for (index,row) in rows { values[index] = Float(try service.predict(row)) }
            treeSeconds += Date().timeIntervalSince(treeStart)
        }
        return .init(grid:grid,estimatedErrorIc:values,featureSeconds:featureSeconds,treeSeconds:treeSeconds)
    }
}
