import Foundation
import Testing
@testable import TerrainCore

private func assessmentVolume() -> ReconstructionVolume {
    let grid = ReconstructionGrid(nx: 3, ny: 4, nz: 2,
                                  spacingMeters: 10, northSpacingMeters: 20, depthSpacingMeters: 2)
    var observed = [Bool](repeating: false, count: grid.voxelCount)
    for z in 0..<grid.nz { observed[grid.index(x: 0, y: 0, z: z)] = true }
    return ReconstructionVolume(terrainOrigin: .init(longitude: 110, latitude: -7),
                                westMeters: 0, southMeters: 0, grid: grid,
                                values: [Float](repeating: 2.5, count: grid.voxelCount),
                                observed: observed,
                                validXY: [Bool](repeating: true, count: grid.nx * grid.ny),
                                observationOrigins: Array(repeating: nil, count: grid.voxelCount),
                                depthResampled: [Bool](repeating: false, count: grid.voxelCount))
}

@Test func sufficiencyPersistenceAndDuplicateCount() {
    var history = SufficiencyHistory()
    #expect(history.record(count: 4, positive: true, persistence: 3).sufficient == false)
    #expect(history.record(count: 4, positive: true, persistence: 3).consecutive == 1)
    #expect(history.record(count: 5, positive: true, persistence: 3).sufficient == false)
    #expect(history.record(count: 6, positive: true, persistence: 3).sufficient == true)
    #expect(history.record(count: 6, positive: true, persistence: 3).consecutive == 3)
    #expect(history.record(count: 5, positive: false, persistence: 3).consecutive == 0)
    #expect(history.record(count: 6, positive: true, persistence: 3).consecutive == 1)
    history.reset()
    #expect(history.record(count: 1, positive: true, persistence: 3).consecutive == 1)
}

@Test func sufficiencyPositiveNegativePositiveDoesNotStop() {
    var history = SufficiencyHistory()
    _ = history.record(count: 4, positive: true, persistence: 3)
    _ = history.record(count: 5, positive: false, persistence: 3)
    let result = history.record(count: 6, positive: true, persistence: 3)
    #expect(result.consecutive == 1 && !result.sufficient)
    #expect(history.record(count: 2, positive: true, persistence: 3).consecutive == 1)
}

@Test func predictedCoverageUsesOnlyEstimatedErrorThreshold() throws {
    #expect(try CPTAssessmentPipeline.predictedCoverage(errors: [0.1, 0.15, 0.1500001, 0.3]) == 0.5)
}

@Test func scaleAwareFeaturesUsePhysicalXYDistances() throws {
    let volume = assessmentVolume()
    let row = try CPTAssessmentPipeline.scaleAwareFeatures(volume: volume, nCPT: 1,
                                                            predictedCoverage: 0.5, sites: [(0, 0)])
    #expect(row.count == 10)
    #expect(row[0] == 0.5 && row[2] == 1)
    #expect(row[3] == 20 && row[4] == 60 && row[6] == 1200)
    #expect(abs(row[5] - hypot(20, 60)) < 1e-12)
    #expect(abs(row[8] - hypot(20, 60)) < 1e-12)
    #expect(abs(row[1] - 1) < 1e-12)
    #expect(abs(row[7] - sqrt(1200)) < 1e-12)
    #expect(row[9] == 3)
}

@Test func dqnBoundaryRunsOnlyWhenInsufficientAndIgnoresQValue() async throws {
    var calls = 0
    func assessment(_ sufficient: Bool) -> CPTInvestigationAssessment {
        .init(nCPT: 3, predictedCoverage: 0.1, maxNearestDistanceMeters: 10,
              maxDistanceFraction: 0.2, sufficiencyProbability: sufficient ? 0.99 : 0.5,
              positiveGate: sufficient, consecutivePositiveCount: sufficient ? 3 : 0,
              isSufficient: sufficient)
    }
    let stopped: Int? = try await CPTRecommendationGate.nextIfInsufficient(assessment: assessment(true)) {
        calls += 1
        return 42
    }
    #expect(stopped == nil && calls == 0)
    let next: Int? = try await CPTRecommendationGate.nextIfInsufficient(assessment: assessment(false)) {
        calls += 1
        return -999 // A Q-value-like number has no role in the stopping decision.
    }
    #expect(next == -999 && calls == 1)
}

@Test func assessmentUsesReconstructionAndEstimatedRiskWithoutGroundTruth() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let folder = root.appendingPathComponent("ModelResources/UncertaintyV3_1")
    let uncertainty = try UncertaintyV3Service(model: .init(data: Data(contentsOf: folder.appendingPathComponent("UncertaintyV3.json"))))
    let sufficiency = try SufficiencyV31Service(model: .init(data: Data(contentsOf: folder.appendingPathComponent("SufficiencyV3_1.json"))))
    var history = SufficiencyHistory()
    let result = try CPTAssessmentPipeline.assess(volume: assessmentVolume(), nCPT: 1,
                                                  uncertainty: uncertainty, sufficiency: sufficiency,
                                                  history: &history)
    #expect(result.nCPT == 1)
    #expect((0...1).contains(result.predictedCoverage))
    #expect(result.maxNearestDistanceMeters > 0)
    #expect((0...1).contains(result.sufficiencyProbability))
    #expect(history.gates.count == 1)
}
