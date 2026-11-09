import Foundation

struct CPTInvestigationAssessment: Sendable {
    let nCPT: Int
    let predictedCoverage: Double
    let maxNearestDistanceMeters: Double
    let maxDistanceFraction: Double
    let sufficiencyProbability: Double
    let positiveGate: Bool
    let consecutivePositiveCount: Int
    let isSufficient: Bool
}

/// One entry per CPT count. Re-evaluating a count replaces its entry, never advances persistence.
struct SufficiencyHistory: Sendable {
    private(set) var gates: [(count: Int, positive: Bool)] = []

    mutating func reset() { gates.removeAll() }

    mutating func record(count: Int, positive: Bool, persistence: Int) -> (consecutive: Int, sufficient: Bool) {
        if let last = gates.last, count < last.count { reset() }
        if let index = gates.firstIndex(where: { $0.count == count }) {
            gates.removeSubrange(index..<gates.endIndex)
        }
        gates.append((count, positive))
        var consecutive = 0
        var expected = count
        for entry in gates.reversed() {
            guard entry.count == expected, entry.positive else { break }
            consecutive += 1
            expected -= 1
        }
        return (consecutive, consecutive >= persistence)
    }
}

/// V4.6-A is called only through this boundary, after the frozen sufficiency gate.
enum CPTRecommendationGate {
    static func nextIfInsufficient<T>(assessment: CPTInvestigationAssessment,
                                      recommend: () async throws -> T?) async throws -> T? {
        guard !assessment.isSufficient else { return nil }
        return try await recommend()
    }
}

enum CPTAssessmentPipeline {
    static let coverageErrorThresholdIc = 0.15
    static let uncertaintyFeatureNames = [
        "distance_to_cpt_m", "depth_m", "predicted_ic", "lateral_gradient",
        "vertical_gradient", "nearby_cpt_fraction_25m", "n_cpt", "dx_m", "dy_m", "dz_m"
    ]
    static let sufficiencyFeatureNames = [
        "predicted_coverage", "max_distance_fraction", "n_cpt", "site_width_m",
        "site_height_m", "site_diagonal_m", "site_area_m2", "mean_cpt_spacing_m",
        "max_nearest_distance_m", "aspect_ratio"
    ]

    static func predictedCoverage(errors: [Double], threshold: Double = coverageErrorThresholdIc) throws -> Double {
        guard !errors.isEmpty, errors.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidInput("Uncertainty V3 requires valid unobserved voxels")
        }
        return Double(errors.filter { $0 <= threshold }.count) / Double(errors.count)
    }

    static func scaleAwareFeatures(volume: ReconstructionVolume, nCPT: Int,
                                   predictedCoverage: Double, sites: [(Int, Int)]) throws -> [Double] {
        let grid = volume.grid
        let dx = grid.spacingMeters, dy = grid.northSpacingMeters
        let width = Double(grid.nx - 1) * dx
        let height = Double(grid.ny - 1) * dy
        let diagonal = hypot(width, height)
        guard nCPT > 0, sites.count == nCPT, width > 0, height > 0,
              predictedCoverage.isFinite, (0...1).contains(predictedCoverage) else {
            throw MLIntegrationError.invalidInput("Invalid V3.1 scale-aware geometry or CPT count")
        }
        var maxNearest = 0.0
        for y in 0..<grid.ny { for x in 0..<grid.nx where volume.validXY[grid.xyIndex(x:x,y:y)] {
            let nearest = sites.map { hypot(Double(x - $0.0) * dx, Double(y - $0.1) * dy) }.min()!
            maxNearest = max(maxNearest, nearest)
        } }
        let area = width * height
        return [predictedCoverage, maxNearest / diagonal, Double(nCPT), width, height,
                diagonal, area, sqrt(area / Double(nCPT)), maxNearest,
                max(width, height) / min(width, height)]
    }

    static func assess(volume: ReconstructionVolume, nCPT: Int,
                       uncertainty: UncertaintyV3Service, sufficiency: SufficiencyV31Service,
                       history: inout SufficiencyHistory) throws -> CPTInvestigationAssessment {
        let grid = volume.grid
        #if DEBUG
        print("[V3/V3.1] assessment grid=\(grid.nx)×\(grid.ny)×\(grid.nz), spacing=\(grid.spacingMeters)×\(grid.northSpacingMeters)×\(grid.depthSpacingMeters) m; CPT count=\(nCPT)")
        print("[V3/V3.1] V3 feature order matches frozen JSON: \(uncertainty.model.featureNames == uncertaintyFeatureNames); V3.1 feature order matches frozen JSON: \(sufficiency.model.featureNames == sufficiencyFeatureNames)")
        #endif
        guard uncertainty.model.featureNames == uncertaintyFeatureNames,
              sufficiency.model.featureNames == sufficiencyFeatureNames,
              grid.nx >= 2, grid.ny >= 2, grid.nz >= 2,
              [grid.spacingMeters, grid.northSpacingMeters, grid.depthSpacingMeters].allSatisfy({ $0.isFinite && $0 > 0 }),
              volume.values.count == grid.voxelCount,
              volume.observed.count == grid.voxelCount,
              volume.validXY.count == grid.nx * grid.ny else {
            throw MLIntegrationError.invalidContract("V3/V3.1 feature or volume contract")
        }
        let sites = (0..<grid.nx).flatMap { x in (0..<grid.ny).compactMap { y -> (Int, Int)? in
            (0..<grid.nz).contains { volume.observed[grid.index(x:x,y:y,z:$0)] } ? (x,y) : nil
        } }
        #if DEBUG
        print("[V3/V3.1] observed grid sites=\(sites.count), complete CPT count=\(nCPT)")
        #endif
        guard sites.count == nCPT else {
            throw MLIntegrationError.invalidInput("Measured CPT columns (\(sites.count)) do not match complete CPT count (\(nCPT)); check sampled depth coverage")
        }
        var covered = 0, total = 0
        #if DEBUG
        var minimumError = Double.infinity, maximumError = -Double.infinity, sumError = 0.0
        var allFeaturesFinite = true
        #endif
        for z in 0..<grid.nz {
            try Task.checkCancellation()
            for y in 0..<grid.ny { for x in 0..<grid.nx {
                let index = grid.index(x:x,y:y,z:z)
                guard volume.validXY[grid.xyIndex(x:x,y:y)], !volume.observed[index] else { continue }
                // The V3 training features match the existing physical-grid V2 extractor.
                let row = UncertaintyV2Features.row(volume: volume, x: x, y: y, z: z, sites: sites)
                #if DEBUG
                allFeaturesFinite = allFeaturesFinite && row.count == 10 && row.allSatisfy(\.isFinite)
                #endif
                guard row.count == 10, row.allSatisfy(\.isFinite) else {
                    throw MLIntegrationError.invalidInput("V3 voxel (\(x),\(y),\(z)) has \(row.count) features or a nonfinite value")
                }
                let estimatedError = try uncertainty.predict(row)
                guard estimatedError.isFinite else { throw MLIntegrationError.invalidOutput("Nonfinite Uncertainty V3 estimated error") }
                if estimatedError <= coverageErrorThresholdIc { covered += 1 }
                #if DEBUG
                minimumError = min(minimumError, estimatedError)
                maximumError = max(maximumError, estimatedError)
                sumError += estimatedError
                #endif
                total += 1
            } }
        }
        guard total > 0 else { throw MLIntegrationError.invalidInput("No valid unobserved voxels for V3 coverage; valid XY=\(volume.validXY.filter { $0 }.count), measured CPT columns=\(sites.count)") }
        let coverage = Double(covered) / Double(total)
        #if DEBUG
        print("[V3/V3.1] V3 voxels evaluated=\(total); all 10 features finite=\(allFeaturesFinite); estimated error min/mean/max=\(minimumError)/\(sumError / Double(total))/\(maximumError) Ic")
        print("[V3/V3.1] predictedCoverage=\(coverage) = \(covered)/\(total) valid unobserved voxels with estimated error <= \(coverageErrorThresholdIc) Ic")
        #endif
        let row = try scaleAwareFeatures(volume: volume, nCPT: nCPT, predictedCoverage: coverage, sites: sites)
        #if DEBUG
        print("[V3/V3.1] V3.1 features: \(zip(sufficiencyFeatureNames, row).map { "\($0.0)=\($0.1)" }.joined(separator: ", "))")
        #endif
        let probability = try sufficiency.probability(row)
        let positive = probability >= sufficiency.probabilityThreshold
        let persistence = history.record(count: nCPT, positive: positive, persistence: sufficiency.persistence)
        #if DEBUG
        print("[V3/V3.1] probability=\(probability); positive gate=\(positive); persistence count=\(persistence.consecutive); sufficient=\(persistence.sufficient)")
        #endif
        return .init(nCPT: nCPT, predictedCoverage: coverage,
                     maxNearestDistanceMeters: row[8], maxDistanceFraction: row[1],
                     sufficiencyProbability: probability, positiveGate: positive,
                     consecutivePositiveCount: persistence.consecutive, isSufficient: persistence.sufficient)
    }
}
