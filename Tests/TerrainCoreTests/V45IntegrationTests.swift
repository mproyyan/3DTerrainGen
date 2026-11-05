import Testing
import Foundation
import CoreML
import simd
@testable import TerrainCore

private func v45ProjectURL() -> URL {
    URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Test func v45FeatureOrderAndPythonRows() throws {
    let manifestURL = v45ProjectURL().appendingPathComponent("Tests/TerrainCoreTests/V45FeatureManifest.json")
    let manifest = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
    #expect(manifest["candidate_features"] as? [String] == V45FeatureAdapter.candidateNames)
    #expect(manifest["global_features"] as? [String] == V45FeatureAdapter.globalNames)
    let fixtureURL = v45ProjectURL().appendingPathComponent("Tests/TerrainCoreTests/V45PythonFeatures.json")
    let cases = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL)) as? [[String:Any]])
    for testCase in cases {
        let nx = try #require(testCase["nx"] as? Int), ny = try #require(testCase["ny"] as? Int)
        let nz = try #require(testCase["nz"] as? Int), dx = try #require(testCase["dx"] as? Double)
        let dy = try #require(testCase["dy"] as? Double), dz = try #require(testCase["dz"] as? Double)
        let sites = try #require(testCase["sites"] as? [[Int]])
        let count = nx*ny*nz
        var observed = [Bool](repeating:false,count:count)
        var reconstruction = [Float](repeating:0,count:count)
        for x in 0..<nx { for y in 0..<ny { for z in 0..<nz {
            let i = (z*ny+y)*nx+x
            reconstruction[i] = Float(2.3 + 0.011*Double(x) + 0.017*Double(y) + 0.025*Double(z) + 0.003*Double(x*y)/Double(nx))
        } } }
        for site in sites { for z in 0..<nz { observed[(z*ny+site[1])*nx+site[0]] = true } }
        let input = V42Input(nx:nx,ny:ny,nz:nz,horizontalMeters:dx,northMeters:dy,depthMeters:dz,
                             origin:GeoPoint(longitude:110,latitude:-7),west:0,south:0,
                             observedIc:reconstruction,observed:observed,
                             validXY:[Bool](repeating:true,count:nx*ny),features:[])
        let state = try V45FeatureAdapter.build(input:input,reconstruction:reconstruction)
        #expect(state.candidates.count == nx*ny-sites.count)
        let expectedGlobal = try #require(testCase["global_context"] as? [Double])
        for i in 0..<11 { #expect(abs(Double(state.global[i])-expectedGlobal[i]) < 0.0001) }
        let rows = try #require(testCase["rows"] as? [String:[Double]])
        for (key,expected) in rows {
            let xy = key.split(separator:",").compactMap { Int($0) }
            let candidate = try #require(state.candidates.first { $0.x == xy[0] && $0.y == xy[1] })
            #expect(candidate.local.count == 18)
            for i in 0..<18 { #expect(abs(Double(candidate.local[i])-expected[i]) < 0.0001) }
        }
    }
}

@Test func v45FullCandidateQParity() async throws {
    let fixtureURL = v45ProjectURL().appendingPathComponent("Tests/TerrainCoreTests/V45FullCandidateParity.json")
    let fixture = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL)) as? [String:Any])
    let features = try #require(fixture["features"] as? [[Double]])
    let expected = try #require(fixture["expected_q"] as? [Double])
    let xy = try #require(fixture["candidate_xy"] as? [[Int]])
    let lengths = try #require(fixture["lengths"] as? [Int])
    #expect(features.count == 3068 && expected.count == features.count && xy.count == features.count)
    let modelURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/DQN_V4_5_Extended.mlpackage"))
    let scorer = try V45DQNService(modelURL:modelURL)
    var actual = [Float]()
    for row in features { actual.append(try await scorer.score(row.map(Float.init))) }
    let maxError = zip(actual,expected).map { abs(Double($0.0)-$0.1) }.max() ?? .infinity
    #expect(maxError < 0.00001)
    var start = 0
    for length in lengths {
        let end = start + length
        let expectedBest = (start..<end).max { expected[$0] < expected[$1] }!
        let actualBest = (start..<end).max { actual[$0] < actual[$1] }!
        #expect(xy[actualBest] == xy[expectedBest])
        start = end
    }
    #expect(start == features.count)
    print("DQN V4.5 full candidate parity: \(features.count) Q-values, max error \(maxError)")
}

@Test(arguments: [(24,12,1.0,1), (24,12,1.0,2), (24,12,1.0,3),
                  (32,16,2.0,2), (64,32,3.0,5), (64,32,3.0,40),
                  (96,16,2.0,3)])
func v45EndToEndRecommendation(configuration: (Int,Int,Double,Int)) async throws {
    let (side,depth,spacing,pointCount) = configuration
    let (terrain,boundary,first) = try v42Fixture(metres:Double(side)*spacing-0.2,
                                                 spacingOverride:spacing,depth:depth)
    var points = [first]
    for i in 1..<pointCount {
        let x = 3 + (i-1) % 10, y = 3 + (i-1) / 10
        let coordinate = CoordinateTransformer.geographic(east:(Double(x)+0.5)*spacing,
                                                           north:(Double(y)+0.5)*spacing,origin:terrain.origin)
        var point = CPTPoint(id:UUID(),name:"CPT-\(i+1)",coordinate:coordinate,surfaceElevation:100)
        point.interpretation = first.interpretation
        points.append(point)
    }
    let schemaURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let dqnURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/DQN_V4_5_Extended.mlpackage"))
    let result = try #require(try await V45RecommendationService.recommend(
        terrain:terrain,boundary:boundary,points:points,preferredMeters:spacing,
        schemaURL:schemaURL,dqnURL:dqnURL))
    #expect(result.volume.grid.nx == side && result.volume.grid.ny == side)
    #expect(result.volume.grid.nz == depth)
    #expect(result.qValue.isFinite)
    let diagnostics = try #require(result.v45Diagnostics)
    #expect(diagnostics.scores.legalCount > 0)
    #expect(diagnostics.scores.top.count == 10)
    #expect(diagnostics.scores.top[0].x == result.candidateX)
    #expect(diagnostics.scores.top[0].y == result.candidateY)
    #expect(diagnostics.scores.top[0].qValue == result.qValue)
    #expect(diagnostics.scores.minimumQ <= diagnostics.scores.meanQ)
    #expect(diagnostics.scores.meanQ <= diagnostics.scores.maximumQ)
    #expect(diagnostics.scores.top.allSatisfy { $0.qValue.isFinite })
    #expect(!(0..<depth).contains { result.volume.observed[result.volume.index(x:result.candidateX,y:result.candidateY,z:$0)] })
    let chosen = CoordinateTransformer.localMeters(result.coordinate,origin:terrain.origin)
    #expect(terrain.surfacePosition(at:result.coordinate) != nil)
    #expect(abs(chosen.x-result.volume.east(x:result.candidateX)) < 0.05)
    #expect(abs(chosen.y-result.volume.north(y:result.candidateY)) < 0.05)
}

@Test func v45AnisotropicGridPreservesPhysicalCoordinates() async throws {
    let (terrain,boundary,point) = try v42Fixture(metres:63.8,spacingOverride:2,depth:24)
    let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:[point],
                                     preferredMeters:2,preferredNorthMeters:3,preferredDepthMeters:1.5)
    #expect(input.nx == 32 && input.ny == 22 && input.nz == 16)
    #expect(input.horizontalMeters == 2 && input.northMeters == 3 && input.depthMeters == 1.5)
    #expect(abs(input.features[5*input.count]-Float(log1p(Double(3)))) < 1e-6)
    #expect(abs(input.features[6*input.count]-Float(log1p(Double(1.5)))) < 1e-6)
    let schemaURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let dqnURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/DQN_V4_5_Extended.mlpackage"))
    let result = try #require(try await V45RecommendationService.recommend(
        terrain:terrain,boundary:boundary,points:[point],preferredMeters:2,
        preferredNorthMeters:3,preferredDepthMeters:1.5,
        schemaURL:schemaURL,dqnURL:dqnURL))
    #expect(result.volume.grid.northSpacingMeters == 3)
    #expect(result.volume.grid.depthSpacingMeters == 1.5)
    let local = CoordinateTransformer.localMeters(result.coordinate,origin:terrain.origin)
    #expect(abs(local.x-result.volume.east(x:result.candidateX)) < 0.05)
    #expect(abs(local.y-result.volume.north(y:result.candidateY)) < 0.05)
}

@Test func v45ConcaveBoundaryScoresEveryLegalCandidate() async throws {
    let (terrain, _, point) = try v42Fixture(metres:48,spacingOverride:2,depth:12)
    let vertices: [Point2] = [
        .init(x:0,y:0), .init(x:48,y:0), .init(x:48,y:16),
        .init(x:16,y:16), .init(x:16,y:48), .init(x:0,y:48)
    ]
    let boundary = vertices.map { CoordinateTransformer.geographic(east:$0.x,north:$0.y,origin:terrain.origin) }
    let input = try V42Input.prepare(terrain:terrain,boundary:boundary,points:[point],preferredMeters:2)
    #expect(input.nx == 24 && input.ny == 24)
    #expect(input.validXY.filter { $0 }.count < input.nx * input.ny)
    let schemaURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let dqnURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/DQN_V4_5_Extended.mlpackage"))
    let schema = try V42SchemaGANService(modelURL:schemaURL)
    let reconstruction = try await schema.reconstruct(input)
    var access = [Bool](repeating:true,count:input.nx*input.ny)
    access[input.xy(1,1)] = false
    let state = try V45FeatureAdapter.build(input:input,reconstruction:reconstruction,accessMask:access)
    let observedColumns = (0..<input.nx).flatMap { x in (0..<input.ny).filter { y in
        (0..<input.nz).contains { input.observed[input.index(x,y,$0)] }
    }.map { y in input.xy(x,y) } }
    let expectedCount = (0..<input.nx*input.ny).filter {
        input.validXY[$0] && access[$0] && !observedColumns.contains($0)
    }.count
    #expect(state.candidates.count == expectedCount)
    #expect(!state.candidates.contains { $0.x == 1 && $0.y == 1 })
    #expect(state.candidates.allSatisfy { candidate in
        let p = Point2(x:input.east(candidate.x),y:input.north(candidate.y))
        return input.validXY[input.xy(candidate.x,candidate.y)] && Geometry.contains(p,in:vertices)
    })
    let scorer = try V45DQNService(modelURL:dqnURL)
    let best = try #require(try await scorer.best(state))
    var maximum = -Float.infinity
    var winningXY: (Int,Int)?
    for candidate in state.candidates {
        let q = try await scorer.score(candidate.local + state.global)
        if q > maximum { maximum = q; winningXY = (candidate.x,candidate.y) }
    }
    #expect(best.score == maximum)
    #expect(best.candidate.x == winningXY?.0 && best.candidate.y == winningXY?.1)
    let geo = CoordinateTransformer.geographic(east:input.east(best.candidate.x),
                                               north:input.north(best.candidate.y),origin:terrain.origin)
    let mapped = CoordinateTransformer.localMeters(geo,origin:terrain.origin)
    #expect(hypot(mapped.x-input.east(best.candidate.x),mapped.y-input.north(best.candidate.y)) < 0.05)
    #expect(Geometry.contains(mapped,in:vertices))
    print("V4.5 concave polygon: scored \(state.candidates.count) legal candidates; winner (\(best.candidate.x),\(best.candidate.y)), Q=\(best.score)")
}

@Test func dqnMarkerUsesClippedPolygonMeshFrame() throws {
    let (fixture, _, _) = try v42Fixture(metres:48,spacingOverride:2)
    let polygon: [Point2] = [
        .init(x:0,y:0), .init(x:48,y:0), .init(x:48,y:16),
        .init(x:16,y:16), .init(x:16,y:48), .init(x:0,y:48)
    ]
    let geographic = polygon.map { CoordinateTransformer.geographic(east:$0.x,north:$0.y,origin:fixture.origin) }
    let positions = polygon.map { SIMD3<Float>(Float($0.x),0,Float(-$0.y)) }
    let mesh = TerrainMesh(positions:positions,normals:positions.map { _ in SIMD3<Float>(0,1,0) },
        indices:[0,1,2,0,2,3,0,3,4,0,4,5],geographicVertices:geographic,
        elevations:Array(repeating:100,count:6),origin:fixture.origin,elevationOrigin:100,
        minimum:100,maximum:100,areaSquareMeters:1280,metadata:fixture.metadata,
        sourceSampleCount:6,gridSize:"concave")
    let xy = Point2(x:46,y:8) // Valid DQN cell near the right polygon boundary.
    let geo = CoordinateTransformer.geographic(east:xy.x,north:xy.y,origin:mesh.origin)
    let radius: Float = 1.5
    let marker = try #require(mesh.markerCenter(at:geo,radius:radius))
    let base = marker - SIMD3<Float>(0,radius,0)
    #expect(Geometry.contains(xy,in:polygon))
    #expect(abs(Double(base.x)-xy.x) < 0.01)
    #expect(abs(Double(base.z)+xy.y) < 0.01)
    #expect(abs(base.y) < 0.0001)
    let renderedTriangles = stride(from:0,to:mesh.indices.count,by:3).map { i -> [Point2] in
        (0..<3).map { j in
            let vertex = mesh.positions[Int(mesh.indices[i+j])]
            return Point2(x:Double(vertex.x),y:Double(vertex.z))
        }
    }
    #expect(renderedTriangles.contains { Geometry.contains(.init(x:Double(base.x),y:Double(base.z)),in:$0) })
    let scale: Float = 2/48
    let offset = SIMD3<Float>(-24,0,24)*scale
    let worldBase = base*scale+offset
    #expect(renderedTriangles.contains { triangle in
        let transformed = triangle.map { Point2(x:$0.x*Double(scale)+Double(offset.x),
                                                  y:$0.y*Double(scale)+Double(offset.z)) }
        return Geometry.contains(.init(x:Double(worldBase.x),y:Double(worldBase.z)),in:transformed)
    })
    let outside = CoordinateTransformer.geographic(east:40,north:40,origin:mesh.origin)
    #expect(mesh.markerCenter(at:outside,radius:radius) == nil)
}

@Test func v45MarkerAndRenderedLODMatchRectangular96Grid() async throws {
    let origin = GeoPoint(longitude:110,latitude:-7)
    let width = 110.8, height = 105.4
    let polygon = [Point2(x:0,y:0),Point2(x:width,y:0),
                   Point2(x:width,y:height),Point2(x:0,y:height)]
    let boundary = polygon.map { CoordinateTransformer.geographic(east:$0.x,north:$0.y,origin:origin) }
    let (fixture,_,first) = try v42Fixture(metres:width,spacingOverride:width/95.9,depth:16)
    let positions = polygon.map { SIMD3<Float>(Float($0.x),0,Float(-$0.y)) }
    let terrain = TerrainMesh(positions:positions,normals:positions.map { _ in SIMD3<Float>(0,1,0) },
        indices:[0,1,2,0,2,3],geographicVertices:boundary,
        elevations:Array(repeating:100,count:4),origin:origin,elevationOrigin:100,
        minimum:100,maximum:100,areaSquareMeters:width*height,metadata:fixture.metadata,
        sourceSampleCount:4,gridSize:"96-grid regression")
    func point(_ x: Double, _ y: Double, _ name: String) -> CPTPoint {
        var site = CPTPoint(id:UUID(),name:name,
            coordinate:CoordinateTransformer.geographic(east:x,north:y,origin:origin),surfaceElevation:100)
        site.interpretation = first.interpretation
        return site
    }
    let schemaURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/SchemaGAN_V4_2_Flexible.mlpackage"))
    let dqnURL = try await MLModel.compileModel(at:v45ProjectURL().appendingPathComponent("Demnas3DMap/Models/DQN_V4_5_Extended.mlpackage"))
    let result = try #require(try await V45RecommendationService.recommend(
        terrain:terrain,boundary:boundary,points:[point(15,15,"CPT-1"),point(55,52,"CPT-2")],
        preferredMeters:width/95.9,preferredNorthMeters:height/95.9,
        schemaURL:schemaURL,dqnURL:dqnURL))
    let volume = result.volume, grid = volume.grid
    #expect(grid.nx == 96 && grid.ny == 96 && grid.nz == 16)
    #expect(volume.isValid(x:result.candidateX,y:result.candidateY))
    let sample = try #require(terrain.surfaceSample(at:result.coordinate))
    let local = CoordinateTransformer.localMeters(result.coordinate,origin:origin)
    #expect(abs(Double(sample.position.x)-local.x) < 0.01)
    #expect(abs(Double(sample.position.z)+local.y) < 0.01)
    #expect(sample.triangle == 0 || sample.triangle == 1)
    let step = AdaptiveGrid.renderStep(voxelCount:grid.voxelCount,resolutionMetres:width/95.9)
    let block = AdaptiveGrid.renderBlock(volume:volume,
        x:(result.candidateX/step)*step,y:(result.candidateY/step)*step,z:0,step:step)
    #expect(block.covers(east:local.x,north:local.y))
    let lastBlock = AdaptiveGrid.renderBlock(volume:volume,
        x:((grid.nx-1)/step)*step,y:((grid.ny-1)/step)*step,z:0,step:step)
    #expect(lastBlock.covers(east:volume.east(x:grid.nx-1),north:volume.north(y:grid.ny-1)))
    var partialMask = volume.validXY
    partialMask[grid.xyIndex(x:lastBlock.x,y:lastBlock.y)] = false
    partialMask[grid.xyIndex(x:grid.nx-1,y:grid.ny-1)] = true
    let partialVolume = ReconstructionVolume(terrainOrigin:volume.terrainOrigin,
        westMeters:volume.westMeters,southMeters:volume.southMeters,grid:grid,
        values:volume.values,observed:volume.observed,validXY:partialMask,
        observationOrigins:volume.observationOrigins,depthResampled:volume.depthResampled)
    let edgeBlocks = AdaptiveGrid.renderBlocks(volume:partialVolume,
        x:lastBlock.x,y:lastBlock.y,z:0,step:step)
    #expect(edgeBlocks.contains { $0.covers(east:volume.east(x:grid.nx-1),
                                            north:volume.north(y:grid.ny-1)) })
    #expect(edgeBlocks.allSatisfy { $0.countX == 1 && $0.countY == 1 })
    #expect(!AdaptiveGrid.usesCutaway(displayMode:0)) // Permukaan
    for _ in RiskVisualizationMode.allCases {
        #expect(!AdaptiveGrid.usesCutaway(displayMode:1)) // Lapisan Ic, Risiko, Gabungan
    }
    #expect(AdaptiveGrid.usesCutaway(displayMode:2)) // Potongan only
}
