import CoreML
import Foundation
import Testing
@testable import TerrainCore

private func v46Root() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func v46Contract() throws -> V46Contract {
    try V46Contract(data: Data(contentsOf: v46Root().appendingPathComponent("ModelResources/DQNV46A/DQN_V4_6_A_contract.json")))
}

private func v46FixtureVolume(_ fixture: [String: Any]) throws -> ReconstructionVolume {
    let nx = try #require(fixture["nx"] as? Int), ny = try #require(fixture["ny"] as? Int)
    let nz = try #require(fixture["nz"] as? Int)
    let dx = try #require(fixture["dx"] as? Double), dy = try #require(fixture["dy"] as? Double)
    let dz = try #require(fixture["dz"] as? Double)
    let sites = try #require(fixture["sites"] as? [[Int]])
    let invalid = try #require(fixture["invalid"] as? [[Int]])
    let grid = ReconstructionGrid(nx: nx, ny: ny, nz: nz,
                                  spacingMeters: dx, northSpacingMeters: dy, depthSpacingMeters: dz)
    var valid = [Bool](repeating: true, count: nx * ny)
    var observed = [Bool](repeating: false, count: grid.voxelCount)
    var values = [Float](repeating: 0, count: grid.voxelCount)
    for cell in invalid { valid[grid.xyIndex(x: cell[0], y: cell[1])] = false }
    for x in 0..<nx { for y in 0..<ny { for z in 0..<nz {
        values[grid.index(x:x,y:y,z:z)] = Float(2.3 + 0.011 * Double(x) + 0.017 * Double(y)
                                                 + 0.025 * Double(z) + 0.003 * Double(x * y) / Double(nx))
    } } }
    for site in sites { for z in 0..<nz { observed[grid.index(x:site[0],y:site[1],z:z)] = true } }
    return .init(terrainOrigin: .init(longitude:110,latitude:-7), westMeters:0, southMeters:0,
                 grid:grid, values:values, observed:observed, validXY:valid,
                 observationOrigins:Array(repeating:nil,count:grid.voxelCount),
                 depthResampled:Array(repeating:false,count:grid.voxelCount))
}

@Test func v46FeatureOrderAndPythonRows() throws {
    let contract = try v46Contract()
    #expect(contract.input.combinedOrder == V46FeatureAdapter.candidateNames + V46FeatureAdapter.globalNames)
    #expect(contract.input.combinedOrder.count == 29)
    let url = try #require(Bundle.module.url(forResource:"V46PythonFeatures",withExtension:"json"))
    let cases = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [[String:Any]])
    for fixture in cases {
        let volume = try v46FixtureVolume(fixture)
        let state = try V46FeatureAdapter.build(volume:volume,contract:contract)
        let candidateCount = try #require(fixture["candidate_count"] as? Int)
        #expect(state.candidates.count == candidateCount)
        let expectedGlobal = try #require(fixture["global_context"] as? [Double])
        for i in 0..<11 { #expect(abs(Double(state.global[i]) - expectedGlobal[i]) < 1e-5) }
        let rows = try #require(fixture["rows"] as? [String:[Double]])
        for (key,expected) in rows {
            let xy = key.split(separator:",").compactMap { Int($0) }
            let candidate = try #require(state.candidates.first { $0.x == xy[0] && $0.y == xy[1] })
            #expect(candidate.local.count == 18)
            #expect(candidate.local.count + state.global.count == 29)
            for i in 0..<18 { #expect(abs(Double(candidate.local[i]) - expected[i]) < 1e-5) }
        }
    }
}

@Test func v46LegalCandidatesExcludeMeasuredAndInaccessible() throws {
    let url = try #require(Bundle.module.url(forResource:"V46PythonFeatures",withExtension:"json"))
    let fixtures = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [[String:Any]])
    let volume = try v46FixtureVolume(fixtures[0])
    var access = [Bool](repeating:true,count:volume.grid.nx*volume.grid.ny)
    access[volume.grid.xyIndex(x:1,y:1)] = false
    let state = try V46FeatureAdapter.build(volume:volume,contract:v46Contract(),accessMask:access)
    #expect(!state.candidates.contains { $0.x == 0 && $0.y == 0 })
    #expect(!state.candidates.contains { $0.x == 1 && $0.y == 1 })
    #expect(!state.candidates.contains { $0.x == 4 && $0.y == 5 })
    #expect(state.candidates.allSatisfy { access[volume.grid.xyIndex(x:$0.x,y:$0.y)] })
    let spaced = try V46FeatureAdapter.build(volume:volume,contract:v46Contract(),minimumSpacingMeters:5)
    #expect(spaced.candidates.allSatisfy { hypot(volume.east(x:$0.x)-volume.east(x:0),
                                            volume.north(y:$0.y)-volume.north(y:0)) >= 5 })
}

@Test func v46MinimumDistanceFiltersOriginalCPTPositionsWithoutChangingFeatures() throws {
    let url = try #require(Bundle.module.url(forResource:"V46PythonFeatures",withExtension:"json"))
    let fixtures = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [[String:Any]])
    let volume = try v46FixtureVolume(fixtures[0])
    let contract = try v46Contract()
    let baseline = try V46FeatureAdapter.build(volume:volume,contract:contract)
    // Original surveyed position can differ from the CPT's snapped model cell center.
    let surveyed = Point2(x:volume.east(x:0) + 0.7, y:volume.north(y:0) + 0.4)
    let filtered = try V46FeatureAdapter.build(volume:volume,contract:contract,
                                                minimumSpacingMeters:5,occupiedMeters:[surveyed])
    #expect(filtered.global == baseline.global)
    #expect(filtered.candidates.count < baseline.candidates.count)
    for candidate in filtered.candidates {
        let distance = hypot(volume.east(x:candidate.x) - surveyed.x,
                             volume.north(y:candidate.y) - surveyed.y)
        #expect(distance >= 5)
        let original = try #require(baseline.candidates.first { $0.x == candidate.x && $0.y == candidate.y })
        #expect(candidate.local == original.local)
    }
}

@Test func v46CoreMLPythonParity() async throws {
    let url = try #require(Bundle.module.url(forResource:"DQN_V4_6_A_parity",withExtension:"json"))
    let fixture = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    let order = try #require(fixture["featureOrder"] as? [String])
    let contract = try v46Contract()
    #expect(order == contract.input.combinedOrder)
    let samples = try #require(fixture["samples"] as? [[String:Any]])
    let compiled = try await MLModel.compileModel(at:v46Root().appendingPathComponent("ModelResources/DQNV46A/DQN_V4_6_A.mlpackage"))
    let scorer = try V46DQNService(modelURL:compiled)
    var maximum = 0.0
    for sample in samples {
        let features = try #require(sample["features"] as? [Double])
        let expected = try #require(sample["expectedQ"] as? Double)
        #expect(features.count == 29)
        let actual = try await scorer.score(features.map(Float.init))
        let error = abs(Double(actual)-expected)
        maximum = max(maximum,error)
        #expect(error <= 1e-5)
    }
    print("DQN V4.6-A Core ML parity: \(samples.count) samples, max absolute Q error \(maximum)")
}

@Test func v46RecommendationIsArgmaxAmongLegalCandidates() async throws {
    let (terrain,boundary,point) = try v42Fixture(metres:23.8,spacingOverride:1,depth:12)
    let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:[point],preferredMeters:1)
    let volume = try input.volume([Float](repeating:2.5,count:input.count))
    let contract = try v46Contract()
    let state = try V46FeatureAdapter.build(volume:volume,contract:contract)
    let compiled = try await MLModel.compileModel(at:v46Root().appendingPathComponent("ModelResources/DQNV46A/DQN_V4_6_A.mlpackage"))
    let scorer = try V46DQNService(modelURL:compiled)
    let best = try #require(try await scorer.best(state, volume: volume,
                                                measuredCPT: [point.coordinate]))
    var independentMaximum = -Float.infinity
    var independentXY: (Int, Int)?
    for candidate in state.candidates {
        let q = try await scorer.score(candidate.local + state.global)
        if q > independentMaximum {
            independentMaximum = q
            independentXY = (candidate.x, candidate.y)
        }
    }
    #expect(best.score == independentMaximum)
    #expect(best.candidate.x == independentXY?.0 && best.candidate.y == independentXY?.1)
    let result = try #require(try await V46RecommendationService.recommend(
        volume:volume,terrain:terrain,measuredCPT:[point.coordinate],modelURL:compiled,
        contractURL:v46Root().appendingPathComponent("ModelResources/DQNV46A/DQN_V4_6_A_contract.json")))
    #expect(result.legalCount == state.candidates.count)
    #expect(result.candidateX == best.candidate.x && result.candidateY == best.candidate.y)
    #expect(result.qValue == best.score)
    let spacing = V46FeatureAdapter.recommendationSpacing(grid:volume.grid)
    let original = CoordinateTransformer.localMeters(point.coordinate,origin:terrain.origin)
    let filtered = try V46FeatureAdapter.build(volume:volume,contract:contract,
        minimumSpacingMeters:spacing,occupiedMeters:[original])
    let filteredBest = try #require(try await scorer.best(filtered))
    var filteredMaximum = -Float.infinity
    for candidate in filtered.candidates {
        filteredMaximum = max(filteredMaximum,try await scorer.score(candidate.local + filtered.global))
    }
    #expect(filteredBest.score == filteredMaximum)
    #expect(filtered.candidates.allSatisfy {
        hypot(volume.east(x:$0.x)-original.x,volume.north(y:$0.y)-original.y) >= spacing
    })
    #expect(!volume.observed[volume.index(x:result.candidateX,y:result.candidateY,z:0)])
    let mapped = CoordinateTransformer.localMeters(result.coordinate,origin:terrain.origin)
    #expect(hypot(mapped.x-volume.east(x:result.candidateX),mapped.y-volume.north(y:result.candidateY)) < 0.05)
    let west = CoordinateTransformer.geographic(east:volume.east(x:0),north:volume.north(y:0),origin:terrain.origin)
    let east = CoordinateTransformer.geographic(east:volume.east(x:volume.grid.nx-1),north:volume.north(y:0),origin:terrain.origin)
    let north = CoordinateTransformer.geographic(east:volume.east(x:0),north:volume.north(y:volume.grid.ny-1),origin:terrain.origin)
    #expect(west.longitude < east.longitude)
    #expect(west.latitude < north.latitude)
}

@Test func noV45FallbackFromSession() throws {
    let source = try String(contentsOf:v46Root().appendingPathComponent("Demnas3DMap/TerrainSession.swift"),encoding:.utf8)
    #expect(source.contains("V46RecommendationService.recommend"))
    #expect(!source.contains("V45RecommendationService.recommend"))
    #expect(!source.contains("AdaptiveDQNRecommendationService.recommend"))
}

@Test func v46GateUsesOnlyDQNWhenInsufficient() async throws {
    let insufficient = CPTInvestigationAssessment(nCPT: 1, predictedCoverage: 0.2,
        maxNearestDistanceMeters: 10, maxDistanceFraction: 0.3,
        sufficiencyProbability: 0.2, positiveGate: false,
        consecutivePositiveCount: 0, isSufficient: false)
    let sufficient = CPTInvestigationAssessment(nCPT: 3, predictedCoverage: 0.9,
        maxNearestDistanceMeters: 2, maxDistanceFraction: 0.1,
        sufficiencyProbability: 0.99, positiveGate: true,
        consecutivePositiveCount: 3, isSufficient: true)
    let selected = try await CPTRecommendationGate.nextIfInsufficient(assessment: insufficient) { "DQN V4.6-A" }
    #expect(selected == "DQN V4.6-A")
    let unavailable = try await CPTRecommendationGate.nextIfInsufficient(assessment: insufficient) { Optional<String>.none }
    #expect(unavailable == nil)
    let skipped = try await CPTRecommendationGate.nextIfInsufficient(assessment: sufficient) { () -> String? in
        Issue.record("DQN must not run after sufficient assessment")
        return "unexpected"
    }
    #expect(skipped == nil)
}

@Test func v46ActiveFlowAndUILabelsExcludeGeometricFallback() throws {
    let root = v46Root()
    let source = try String(contentsOf:root.appendingPathComponent("Demnas3DMap/TerrainSession.swift"),encoding:.utf8)
    #expect(source.contains("V46RecommendationService.recommend"))
    #expect(!source.contains("explorationHeuristic"))
    #expect(!source.contains("explorationRecommendation"))
    for file in ["TerrainMapView.swift", "Terrain3DView.swift", "CPTWorkspaceView.swift"] {
        let ui = try String(contentsOf:root.appendingPathComponent("Demnas3DMap/Views/" + file),encoding:.utf8)
        #expect(!ui.localizedCaseInsensitiveContains("heuristic"))
    }
}
