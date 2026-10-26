import Testing
import Foundation
import simd
@testable import TerrainCore

@Test func syntheticCPTFilesImportAndReachDQNDepth() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SampleData")
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "csv" }
    #expect(files.count == 5)
    for file in files {
        let csv = try String(contentsOf: file, encoding: .utf8)
        let samples = try CPTProcessor.parse(csv)
        let interpreted = try CPTProcessor.interpret(csv: csv, assumptions: CPTAssumptions())
        #expect(samples.count == 32)
        #expect(samples.last?.depth == 16)
        #expect(interpreted.values.allSatisfy { $0.ic.isFinite })
    }
}

private func testTerrain(concave: Bool = false) throws -> (TerrainMesh, [GeoPoint]) {
    let coords: [Point2] = concave ? [.init(x:0,y:0),.init(x:0.002,y:0),.init(x:0.002,y:0.0007),.init(x:0.0007,y:0.0007),.init(x:0.0007,y:0.002),.init(x:0,y:0.002)] : [.init(x:0,y:0),.init(x:0.002,y:0),.init(x:0.002,y:0.002),.init(x:0,y:0.002)]
    let geos = coords.map { GeoPoint(longitude:110+$0.x, latitude:-7+$0.y) }
    let origin = geos[0]
    let positions = geos.map { p -> SIMD3<Float> in
        let l = CoordinateTransformer.localMeters(p, origin: origin)
        return .init(Float(l.x),0,Float(-l.y))
    }
    let triangles = try Geometry.triangulate(coords)
    let indices = triangles.flatMap { $0.map { UInt32(coords.firstIndex(of:$0)!) } }
    let metadata = DEMMetadata(width: 2, height: 2, transform: .init(x0:110,a:0.002,b:0,y0:-7,d:0,e:0.002), epsg:4326, noData: .nan, verticalReference:"Test datum", provenance:["Test"], footprint:geos)
    let local = positions.map { Point2(x:Double($0.x),y:Double($0.z)) }
    return (.init(positions:positions,normals:positions.map { _ in .init(0,1,0) },indices:indices,geographicVertices:geos,elevations:geos.map { _ in 100 },origin:origin,elevationOrigin:100,minimum:100,maximum:100,areaSquareMeters:abs(Geometry.area(local)),metadata:metadata,sourceSampleCount:4,gridSize:"test"), geos)
}

private func testPoint(_ n: Int, complete: Bool = true, depth: Double = 10) throws -> CPTPoint {
    var point = CPTPoint(id:UUID(),name:"CPT-\(n)",coordinate:.init(longitude:110.0002+Double(n)*0.0003,latitude:-6.9998),surfaceElevation:100)
    if complete {
        point.csv = "\(CPTProcessor.header)\n0.5,0.6,40,\n\(depth),0.8,50,"
        point.interpretation = try CPTProcessor.interpret(csv:point.csv,assumptions:point.assumptions)
        point.updatedAt = Date()
    }
    return point
}

@Test func cptCSVRejectsInvalidAndUnorderedValues() throws {
    let invalid = ["0,1,10,\n1,2,20,", "1,1,10,\n1,2,20,", "2,1,10,\n1,2,20,", "1,nan,10,\n2,2,20,", "1,1,0,\n2,2,20,", "1,1,10,hello\n2,2,20,", "1,1,10\n2,2,20", "1,1,10,inf\n2,2,20,"]
    for rows in invalid { #expect(throws: TerrainError.self) { try CPTProcessor.parse(CPTProcessor.header+"\n"+rows) } }
    let rows = try CPTProcessor.parse("\u{feff}"+CPTProcessor.header+"\r\n1,1,10,-20\r\n2,2,20,\r\n")
    #expect(rows.count == 2)
    #expect(rows[0].u2KPa == -20)
    #expect(rows[1].u2KPa == nil)
}

@Test func cptNormalizationUsesConsistentUnitsAndPorePressure() throws {
    let csv = CPTProcessor.header+"\n1,0.5,35,100\n2,0.5,35,100"
    let result = try CPTProcessor.interpret(csv:csv,assumptions:.init(coneAreaRatio:0.8,unitWeight:18,waterTableDepth:0,nkt:15))
    let v = result.values[0]
    #expect(abs(v.qt-520) < 1e-9)
    #expect(abs(v.totalStress-18) < 1e-9)
    #expect(abs(v.effectiveStress-8.19) < 1e-9)
    let expectedIc = hypot(3.47-log10(502/8.19),1.22+log10(3500/502))
    #expect(abs(v.ic-expectedIc) < 1e-9)
    #expect(v.behavior == .clay)
    #expect(abs(try #require(v.su)-502/15) < 1e-9)
    #expect(v.phi == nil)
    #expect(throws: TerrainError.self) { try CPTProcessor.interpret(csv: CPTProcessor.header+"\n1,0.001,10,\n2,0.001,10,", assumptions:.init()) }
    #expect(throws: TerrainError.self) { try CPTProcessor.interpret(csv:csv,assumptions:.init(nkt:0)) }
}

@Test func cptExampleRespondsToDataAndKeepsUnmeasuredDepthUnknown() throws {
    let sand = try CPTProcessor.interpret(csv:CPTProcessor.example(variable:false,iteration:0),assumptions:.init())
    let mixed = try CPTProcessor.interpret(csv:CPTProcessor.example(variable:true,iteration:0),assumptions:.init())
    #expect(sand.layers.count == 1)
    #expect(sand.layers[0].behavior == .sand)
    #expect(sand.layers[0].su == nil)
    #expect(sand.layers[0].phi != nil)
    #expect(mixed.layers.count > 1)
    #expect(mixed.layers.contains { $0.behavior == .clay })
    #expect(mixed.layers.first?.top == 0.5)
    #expect(mixed.layers.last?.bottom == 20)
    #expect(mixed.notes.contains { $0.contains("qt ≈ qc") })
    for layer in mixed.layers where layer.behavior == .transitional {
        #expect(layer.su == nil && layer.phi == nil)
    }
    for pair in zip(mixed.layers,mixed.layers.dropFirst()) { #expect(pair.0.bottom == pair.1.top) }
}

@Test func isolatedClassificationSpikeDoesNotCreateLayer() throws {
    var rows = [CPTProcessor.header]
    for n in 1...20 { rows.append("\(Double(n)*0.5),\(n == 10 ? 0.6 : 10),\(n == 10 ? 40 : 24),") }
    let result = try CPTProcessor.interpret(csv:rows.joined(separator:"\n"),assumptions:.init())
    #expect(result.values.contains { $0.behavior == .clay })
    #expect(result.layers.count == 1)
    #expect(result.layers[0].behavior == .sand)
    #expect(result.layers[0].su == nil)
}

@Test func sequentialSimulationRequiresSubmittedProfilesAndCanReopen() throws {
    let points = try (0..<3).map { try testPoint($0) }
    #expect(!InvestigationSimulator.status(points:[],scenario:.homogeneous).finished)
    #expect(InvestigationSimulator.status(points:[points[0]],scenario:.homogeneous).finished)
    #expect(!InvestigationSimulator.status(points:[points[0]],scenario:.variable).finished)
    #expect(InvestigationSimulator.status(points:points,scenario:.variable).finished)
    #expect(!InvestigationSimulator.status(points:Array(points.dropLast()),scenario:.variable).finished)
    let pending = try testPoint(4,complete:false)
    #expect(!InvestigationSimulator.status(points:points+[pending],scenario:.variable).finished)
}

@Test func candidateStaysInConcaveTerrainAndStopsWhileWaiting() throws {
    let (terrain,boundary) = try testTerrain(concave:true)
    let point = try testPoint(0)
    let candidate = try #require(InvestigationSimulator.recommendation(points:[point],scenario:.variable,terrain:terrain))
    #expect(Geometry.contains(candidate.point,in:boundary.map(\.point)))
    #expect(terrain.surfacePosition(at:candidate) != nil)
    #expect(CoordinateTransformer.localMeters(candidate,origin:point.coordinate).length >= 2)
    #expect(InvestigationSimulator.recommendation(points:[point],scenario:.homogeneous,terrain:terrain) == nil)
    #expect(InvestigationSimulator.recommendation(points:[point,try testPoint(1,complete:false)],scenario:.variable,terrain:terrain) == nil)
    #expect(terrain.surfacePosition(at:.init(longitude:110.0018,latitude:-6.9982)) == nil)
}

@Test func subsurfaceCoverageAndDepthRemainDistinct() throws {
    let (terrain,boundary) = try testTerrain()
    let point = try testPoint(0,depth:5)
    let variable = try SubsurfaceModel.columns(terrain:terrain,boundary:boundary,points:[point],scenario:.variable)
    let homogeneous = try SubsurfaceModel.columns(terrain:terrain,boundary:boundary,points:[point],scenario:.homogeneous)
    #expect(variable.contains { $0.behavior == nil && $0.bottom == 5 && !$0.observed })
    #expect(homogeneous.contains { $0.behavior != nil && !$0.observed })
    #expect(!homogeneous.contains { $0.behavior == nil && $0.bottom == 5 })
    #expect(homogeneous.contains { $0.behavior == nil && $0.top == 0 && $0.bottom == 0.5 })
    #expect(homogeneous.allSatisfy { $0.bottom <= 5 })
    #expect(homogeneous.contains { $0.observed && $0.behavior == .clay })
    let deep = try testPoint(3,depth:10)
    let mixedDepth = try SubsurfaceModel.columns(terrain:terrain,boundary:boundary,points:[point,deep],scenario:.homogeneous)
    #expect(mixedDepth.contains { $0.behavior == nil && $0.top == 5 && $0.bottom == 10 })
    #expect(try SubsurfaceModel.columns(terrain:terrain,boundary:boundary,points:[],scenario:.variable).isEmpty)
}

@Test func projectRoundTripPreservesTerrainAndPendingDataIncludingNaNNoData() throws {
    let (terrain,boundary) = try testTerrain()
    var points = [try testPoint(0),try testPoint(1,complete:false)]
    points[1].draft = .init(csv: "unfinished CSV", assumptions: .init(), origin: .entered)
    var original = InvestigationProject(boundary:boundary,terrain:terrain,points:points,scenario:.variable)
    original.spatialResolutionMeters = 2.5
    let restored = try InvestigationProject.decode(original.encoded())
    #expect(restored.boundary == boundary)
    #expect(restored.spatialResolutionMeters == 2.5)
    #expect(restored.terrain.positions == terrain.positions)
    #expect(restored.terrain.metadata.noData?.isNaN == true)
    #expect(restored.points[0].interpretation?.layers.count == points[0].interpretation?.layers.count)
    #expect(restored.points[0].csv == points[0].csv)
    #expect(restored.points[1].interpretation == nil)
    #expect(restored.points[1].draft?.csv == "unfinished CSV")
    #expect(restored.points[0].id == points[0].id)
    var legacy = try JSONSerialization.jsonObject(with: original.encoded()) as! [String: Any]
    legacy.removeValue(forKey: "spatialResolutionMeters")
    let legacyProject = try InvestigationProject.decode(JSONSerialization.data(withJSONObject: legacy))
    #expect(legacyProject.spatialResolutionMeters == nil)
    var unsupported = original; unsupported.version = 2
    #expect(throws: TerrainError.self) { try InvestigationProject.decode(unsupported.encoded()) }
}
