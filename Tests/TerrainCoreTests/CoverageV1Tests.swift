import Foundation
import Testing
@testable import TerrainCore

private func coverageModel() throws -> CoverageV1Service {
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf:root.appendingPathComponent("Demnas3DMap/Models/CoverageV1.json"))
    return try CoverageV1Service(model:.init(data:data))
}

private struct CoverageParity: Decodable {
    struct Sample: Decodable { let features: [Double]; let expectedRaw: Double; let expectedProbability: Double }
    let featureNames: [String]
    let samples: [Sample]
}

@Test func coverageV1PythonParityAndFeatureOrder() throws {
    let service = try coverageModel()
    let reference = try JSONDecoder().decode(CoverageParity.self,
        from:Data(contentsOf:Bundle.module.url(forResource:"CoverageV1Parity",withExtension:"json")!))
    #expect(service.model.featureNames == reference.featureNames)
    var maxRaw = 0.0, maxProbability = 0.0
    for sample in reference.samples {
        maxRaw = max(maxRaw, abs(try service.model.rawPrediction(sample.features) - sample.expectedRaw))
        maxProbability = max(maxProbability, abs(try service.probability(sample.features) - sample.expectedProbability))
    }
    print("Coverage V1 Python parity: raw max=\(maxRaw), probability max=\(maxProbability)")
    #expect(maxRaw < 1e-9)
    #expect(maxProbability < 1e-9)
}

@Test func coverageV1AveragesProbabilitiesInsteadOfThresholdingErrors() throws {
    #expect(try CoverageV1Pipeline.predictedCoverage(probabilities:[0.1,0.7,0.9]) == (0.1+0.7+0.9)/3)
    #expect(throws: Error.self) { try CoverageV1Pipeline.predictedCoverage(probabilities:[]) }
}

@Test func coverageV1FiveConsecutiveEvaluationsAreAdvisoryOnly() {
    var history = CoverageV1History()
    for n in 1...4 { #expect(history.record(count:n,positive:true) == n) }
    #expect(history.record(count:4,positive:true) == 4) // UI refresh does not advance count.
    #expect(history.record(count:5,positive:true) == 5)
    let assessment = CoverageV1Assessment(nCPT:5,predictedCoverage:0.925,
        consecutivePositiveCount:5,advisoryHigh:true)
    #expect(assessment.advisoryHigh)
    #expect(history.record(count:6,positive:false) == 0)
    #expect(history.record(count:7,positive:true) == 1)
    history.reset()
    #expect(history.record(count:1,positive:true) == 1)
}

@Test func advisoryHighNeverStopsDQNAndQDoesNotSetSufficiency() async throws {
    var calls = 0
    for high in [false,true] {
        let assessment = CoverageV1Assessment(nCPT:5,predictedCoverage:high ? 0.99 : 0.4,
            consecutivePositiveCount:high ? 5 : 0,advisoryHigh:high)
        let selected: Double? = try await CoverageV1RecommendationPolicy.next(assessment:assessment) {
            calls += 1
            return -999 // Q is only a ranking result; its magnitude cannot change the advisory.
        }
        #expect(selected == -999)
        #expect(assessment.advisoryHigh == high)
    }
    #expect(calls == 2)
}

@Test func verticalProfileKeepsSimpleStatusAndTechnicalDetails() throws {
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf:root.appendingPathComponent("Demnas3DMap/Views/Terrain3DView.swift"),
                            encoding:.utf8)
    #expect(source.contains("Indikasi Lapisan Keras"))
    #expect(source.contains("Belum teridentifikasi"))
    #expect(source.contains("Belum tersedia di lokasi ini"))
    #expect(source.contains("Belum cukup data untuk menghitung kapasitas"))
    #expect(source.contains("DisclosureGroup(\"Details\""))
    #expect(source.contains("Text(\"Masih dibutuhkan\")"))
}

@Test func dqnSpacingUsesPhysicalGridDiagonalAndExcludesNearbyCandidate() throws {
    let grid = ReconstructionGrid(nx:3,ny:4,nz:2,spacingMeters:10,
        northSpacingMeters:20,depthSpacingMeters:2)
    let spacing = V46FeatureAdapter.recommendationSpacing(grid:grid)
    #expect(abs(spacing - 0.1 * hypot(20,60)) < 1e-12)
    var observed = [Bool](repeating:false,count:grid.voxelCount)
    for z in 0..<2 { observed[grid.index(x:0,y:0,z:z)] = true }
    let volume = ReconstructionVolume(terrainOrigin:.init(longitude:110,latitude:-7),
        westMeters:0,southMeters:0,grid:grid,
        values:[Float](repeating:2.5,count:grid.voxelCount),observed:observed,
        validXY:[Bool](repeating:true,count:12),
        observationOrigins:Array(repeating:nil,count:grid.voxelCount),
        depthResampled:[Bool](repeating:false,count:grid.voxelCount))
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let contract = try V46Contract(data:Data(contentsOf:root.appendingPathComponent("Demnas3DMap/Models/DQN_V4_6_A_contract.json")))
    let origin = Point2(x:volume.east(x:0),y:volume.north(y:0))
    let eligible = try V46FeatureAdapter.build(volume:volume,contract:contract,
        minimumSpacingMeters:spacing,occupiedMeters:[origin])
    #expect(!eligible.candidates.contains { $0.x == 0 && $0.y == 0 })
    #expect(!eligible.candidates.contains { hypot(volume.east(x:$0.x)-origin.x,
                                                    volume.north(y:$0.y)-origin.y) < spacing })
    #expect(eligible.candidates.contains { $0.x == 2 && $0.y == 3 })
}

@Test func coverageV1PipelineUsesHiddenValidVoxelsAndV3MapPreservesObservedMask() throws {
    let grid = ReconstructionGrid(nx:3,ny:3,nz:2,spacingMeters:4,
        northSpacingMeters:7,depthSpacingMeters:2)
    var observed = [Bool](repeating:false,count:grid.voxelCount)
    for z in 0..<2 { observed[grid.index(x:0,y:0,z:z)] = true }
    var valid = [Bool](repeating:true,count:9)
    valid[grid.xyIndex(x:2,y:2)] = false
    let volume = ReconstructionVolume(terrainOrigin:.init(longitude:110,latitude:-7),
        westMeters:0,southMeters:0,grid:grid,
        values:[Float](repeating:2.5,count:grid.voxelCount),observed:observed,
        validXY:valid,observationOrigins:Array(repeating:nil,count:grid.voxelCount),
        depthResampled:[Bool](repeating:false,count:grid.voxelCount))
    let service = try coverageModel()
    var history = CoverageV1History()
    let result = try CoverageV1Pipeline.assess(volume:volume,nCPT:1,service:service,history:&history)
    var probabilities = [Double]()
    for z in 0..<2 { for y in 0..<3 { for x in 0..<3 {
        guard valid[grid.xyIndex(x:x,y:y)], !observed[grid.index(x:x,y:y,z:z)] else { continue }
        let row = UncertaintyV2Features.row(volume:volume,x:x,y:y,z:z,sites:[(0,0)])
        probabilities.append(try service.probability(row))
    } } }
    #expect(probabilities.count == 14)
    #expect(abs(result.predictedCoverage - (try CoverageV1Pipeline.predictedCoverage(probabilities:probabilities))) < 1e-12)
    #expect(history.evaluations.count == 1)
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let v3 = try UncertaintyV3Service(model:.init(data:Data(contentsOf:
        root.appendingPathComponent("Demnas3DMap/Models/UncertaintyV3.json"))))
    let risk = try UncertaintyV3MapFactory.makeMap(volume:volume,service:v3)
    #expect(risk.value(x:0,y:0,z:0) == nil)
    #expect(risk.value(x:2,y:2,z:1) == nil)
    #expect(risk.value(x:1,y:1,z:0) != nil)
}
