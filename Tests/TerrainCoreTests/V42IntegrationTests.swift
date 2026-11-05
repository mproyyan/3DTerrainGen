import Testing
import Foundation
import CoreML
import simd
@testable import TerrainCore

func v42Fixture(metres: Double, spacingOverride: Double? = nil, depth: Int = 12) throws -> (TerrainMesh, [GeoPoint], CPTPoint) {
    let origin = GeoPoint(longitude:110,latitude:-7)
    let boundary = [
        CoordinateTransformer.geographic(east:0,north:0,origin:origin),
        CoordinateTransformer.geographic(east:metres,north:0,origin:origin),
        CoordinateTransformer.geographic(east:metres,north:metres,origin:origin),
        CoordinateTransformer.geographic(east:0,north:metres,origin:origin)
    ]
    let positions = boundary.map { geo -> SIMD3<Float> in
        let local = CoordinateTransformer.localMeters(geo,origin:origin)
        return .init(Float(local.x),0,Float(-local.y))
    }
    let metadata = DEMMetadata(width:2,height:2,transform:.init(x0:110,a:0.001,b:0,y0:-7,d:0,e:0.001),
        epsg:4326,noData:nil,verticalReference:"test",provenance:["test"],footprint:boundary)
    let terrain = TerrainMesh(positions:positions,normals:positions.map { _ in .init(0,1,0) },
        indices:[0,1,2,0,2,3],geographicVertices:boundary,elevations:[100,100,100,100],
        origin:origin,elevationOrigin:100,minimum:100,maximum:100,areaSquareMeters:metres*metres,
        metadata:metadata,sourceSampleCount:4,gridSize:"test")
    let extent = try MetricExtent(boundary:boundary,origin:origin)
    let spacing = spacingOverride ?? (metres <= 24 ? 1.0 : 5.0)
    let sideMetres = 24.0 * spacing
    let west = (extent.west+extent.east-sideMetres)/2, south = (extent.south+extent.north-sideMetres)/2
    let site = CoordinateTransformer.geographic(east:west+6.5*spacing,north:south+6.5*spacing,origin:origin)
    var point = CPTPoint(id:UUID(),name:"CPT-1",coordinate:site,surfaceElevation:100)
    let values = (0..<depth).map { z in CPTValue(depth:Double(z)+0.5,qt:10000,totalStress:0,effectiveStress:1000,
        ic:3.5,behavior:.clay,su:nil,phi:nil) }
    point.interpretation = CPTInterpretation(values:values,layers:[],notes:[])
    return (terrain,boundary,point)
}

@Test(arguments: [1.0, 5.0])
func v42SwiftMatchesPythonFeaturesAndCoreMLRecommendation(spacing: Double) async throws {
    let fixtureName = spacing == 1 ? "V42PythonReference1m.json" : "V42PythonReference.json"
    let referenceURL = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent(fixtureName)
    let reference = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:referenceURL)) as? [String:Any])
    let (terrain,boundary,point) = try v42Fixture(metres:spacing == 1 ? 23.8 : 119)
    let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:[point])
    #expect(input.horizontalMeters == spacing)
    #expect(input.validXY.allSatisfy { $0 })
    #expect(input.observed.filter { $0 }.count == 12)
    #expect(input.observed[input.index(6,6,0)])
    #expect(abs(input.features[input.index(6,6,0)] - (3.5-V42Input.mean)/V42Input.std) < 1e-6)
    #expect(abs(input.features[4*input.count] - Float(log1p(spacing))) < 1e-6)
    let project = referenceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let schemaURL = try await MLModel.compileModel(at:project.appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let dqnURL = try await MLModel.compileModel(at:project.appendingPathComponent("Demnas3DMap/Models/DQN_V4_2_SingleCandidate.mlpackage"))
    let schema = try V42SchemaGANService(modelURL:schemaURL)
    let reconstruction = try await schema.reconstruct(input)
    let samples = try #require(reference["reconstruction_samples"] as? [String:Double])
    for (key,expected) in samples {
        let xyz = key.split(separator:",").compactMap { Int($0) }
        #expect(xyz.count == 3)
        #expect(abs(Double(reconstruction[input.index(xyz[0],xyz[1],xyz[2])])-expected) < 0.01)
    }
    #expect(reconstruction[input.index(6,6,0)] == 3.5)
    let state = try V42FeatureAdapter.build(input:input,reconstruction:reconstruction)
    #expect(state.candidates.count == 575)
    let global = try #require(reference["global_context"] as? [Double])
    for i in 0..<11 { #expect(abs(Double(state.global[i])-global[i]) < 0.001) }
    let rows = try #require(reference["candidate_features"] as? [String:[Double]])
    for (key,expected) in rows {
        let xy = key.split(separator:",").compactMap { Int($0) }
        let candidate = try #require(state.candidates.first { $0.x == xy[0] && $0.y == xy[1] })
        for i in 0..<17 { #expect(abs(Double(candidate.local[i])-expected[i]) < 0.001) }
    }
    let scorer = try V42DQNService(modelURL:dqnURL)
    let best = try #require(try await scorer.best(state))
    let bestXY = try #require(reference["best_xy"] as? [Int])
    #expect(best.candidate.x == bestXY[0] && best.candidate.y == bestXY[1])
    #expect(abs(Double(best.score)-(reference["best_q"] as! Double)) < 0.001)
    let integrated = try #require(try await V42RecommendationService.recommend(
        terrain:terrain,boundary:boundary,points:[point],schemaURL:schemaURL,dqnURL:dqnURL))
    #expect(integrated.candidateX == bestXY[0] && integrated.candidateY == bestXY[1])
    let chosen = CoordinateTransformer.localMeters(integrated.coordinate,origin:terrain.origin)
    #expect(hypot(chosen.x-input.east(bestXY[0]),chosen.y-input.north(bestXY[1])) < 0.05)
    var blocked = [Bool](repeating:true,count:24*24)
    blocked[input.xy(best.candidate.x,best.candidate.y)] = false
    let masked = try V42FeatureAdapter.build(input:input,reconstruction:reconstruction,accessMask:blocked)
    #expect(!masked.candidates.contains { $0.x == best.candidate.x && $0.y == best.candidate.y })
}

@Test func v42EligibilityReportsPhysicalGridLimit() throws {
    let origin = GeoPoint(longitude:110,latitude:-7)
    func extent(_ width: Double, _ height: Double) throws -> MetricExtent {
        let boundary = [
            CoordinateTransformer.geographic(east:0,north:0,origin:origin),
            CoordinateTransformer.geographic(east:width,north:0,origin:origin),
            CoordinateTransformer.geographic(east:width,north:height,origin:origin),
            CoordinateTransformer.geographic(east:0,north:height,origin:origin)
        ]
        return try MetricExtent(boundary:boundary,origin:origin)
    }
    let points = [try v42Fixture(metres:20).2]
    #expect(try V42GridPlan.make(extent:extent(20,20),points:points).horizontalMeters == 1)
    #expect(try V42GridPlan.make(extent:extent(80,70),points:points).horizontalMeters == 5)
    #expect(try V42GridPlan.make(extent:extent(200,150),points:points,preferredMeters:2).nx <= 96)
}

@Test(arguments: [(24,12), (32,16), (48,24), (64,32), (96,32)])
func v42FlexibleGridInference(size: (Int,Int)) async throws {
    let (side, depth) = size
    let (terrain,boundary,point) = try v42Fixture(metres:Double(side)-0.2,spacingOverride:1,depth:depth)
    let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:[point],preferredMeters:1)
    #expect(input.nx == side && input.ny == side && input.nz == depth)
    #expect(input.features.count == 7 * side * side * depth)
    let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let schemaURL = try await MLModel.compileModel(at:project.appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let schema = try V42SchemaGANService(modelURL:schemaURL)
    let started = Date()
    let values = try await schema.reconstruct(input)
    let schemaSeconds = Date().timeIntervalSince(started)
    #expect(values.count == side * side * depth)
    #expect(zip(values,input.observed).allSatisfy { !$0.1 || $0.0 == 3.5 })
    let state = try V42FeatureAdapter.build(input:input,reconstruction:values)
    #expect(state.candidates.count == side * side - 1)
    #expect(state.candidates.allSatisfy { $0.local.count == 17 })
    #expect(state.global.count == 11)
    let dqnURL = try await MLModel.compileModel(at:project.appendingPathComponent("Demnas3DMap/Models/DQN_V4_2_SingleCandidate.mlpackage"))
    let scorer = try V42DQNService(modelURL:dqnURL)
    let scoringStarted = Date()
    let best = try #require(try await scorer.best(state))
    #expect((0..<side).contains(best.candidate.x) && (0..<side).contains(best.candidate.y))
    #expect(best.score.isFinite)
    print("V4.2 Flexible \(side)×\(side)×\(depth): SchemaGAN \(String(format:"%.3f",schemaSeconds)) s, DQN \(String(format:"%.3f",Date().timeIntervalSince(scoringStarted))) s for \(state.candidates.count) candidates; input \(input.features.count * MemoryLayout<Float>.size) bytes")
}

@Test func v42LargePhysicalAreaRunsFlexiblePipeline() async throws {
    let (terrain,boundary,point) = try v42Fixture(metres:200,spacingOverride:2,depth:16)
    let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let schemaURL = try await MLModel.compileModel(at:project.appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let dqnURL = try await MLModel.compileModel(at:project.appendingPathComponent("Demnas3DMap/Models/DQN_V4_2_SingleCandidate.mlpackage"))
    let result = try #require(try await V42RecommendationService.recommend(
        terrain:terrain,boundary:boundary,points:[point],preferredMeters:2,schemaURL:schemaURL,dqnURL:dqnURL))
    #expect(result.volume.grid.nx == 96 && result.volume.grid.ny == 96)
    #expect(result.volume.grid.nz == 16)
    #expect(result.volume.grid.spacingMeters > 2)
    #expect(result.qValue.isFinite)
    #expect(terrain.surfacePosition(at:result.coordinate) != nil)
}
