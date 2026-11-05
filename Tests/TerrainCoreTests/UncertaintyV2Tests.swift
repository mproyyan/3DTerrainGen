import Foundation
import Testing
import Darwin
@testable import TerrainCore

private func uncertaintyProjectURL() -> URL {
    URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Test func uncertaintyV2InputKeyTracksCoordinatesAndResolution() async throws {
    let origin = GeoPoint(longitude:110,latitude:-7)
    let boundary = [origin, GeoPoint(longitude:110.001,latitude:-7),
                    GeoPoint(longitude:110.001,latitude:-6.999)]
    let first = CPTPoint(id:UUID(),name:"CPT-1",coordinate:origin,surfaceElevation:100)
    let moved = CPTPoint(id:first.id,name:first.name,
                         coordinate:GeoPoint(longitude:110.0001,latitude:-7),surfaceElevation:100)
    let a = UncertaintyV2Features.inputKey(points:[first],resolutionMeters:2,boundary:boundary)
    let b = UncertaintyV2Features.inputKey(points:[moved],resolutionMeters:2,boundary:boundary)
    let c = UncertaintyV2Features.inputKey(points:[first],resolutionMeters:3,boundary:boundary)
    let d = UncertaintyV2Features.inputKey(points:[first],resolutionMeters:2,boundary:Array(boundary.reversed()))
    #expect(a != b && a != c && a != d)
}

@Test func uncertaintyV2RiskChangesWithCPTPositionAndKeepsMeasuredVoxelsSolid() throws {
    let grid = ReconstructionGrid(nx:9,ny:7,nz:5,spacingMeters:4,northSpacingMeters:3,depthSpacingMeters:2)
    var values = [Float](repeating:2.7,count:grid.voxelCount)
    for z in 0..<grid.nz { for y in 0..<grid.ny { for x in 0..<grid.nx {
        values[grid.index(x:x,y:y,z:z)] += Float(Double(x)*0.02 + Double(y)*0.01 + Double(z)*0.03)
    } } }
    let valid = [Bool](repeating:true,count:grid.nx*grid.ny)
    let model = try UncertaintyV2Model(data:Data(contentsOf:uncertaintyProjectURL().appendingPathComponent("Demnas3DMap/Models/uncertainty_v2_trees.json")))
    func volume(sites: [(Int,Int)]) -> ReconstructionVolume {
        var observed = [Bool](repeating:false,count:grid.voxelCount)
        for (x,y) in sites { for z in 0..<grid.nz { observed[grid.index(x:x,y:y,z:z)] = true } }
        return ReconstructionVolume(terrainOrigin:.init(longitude:110,latitude:-7),westMeters:0,southMeters:0,
                                    grid:grid,values:values,observed:observed,validXY:valid,
                                    observationOrigins:Array(repeating:nil,count:grid.voxelCount),
                                    depthResampled:Array(repeating:false,count:grid.voxelCount))
    }
    let first = volume(sites:[(0,0)])
    let added = volume(sites:[(0,0),(8,6)])
    let moved = volume(sites:[(8,6)])
    let a = try UncertaintyV2Features.makeMap(volume:first,model:model)
    let b = try UncertaintyV2Features.makeMap(volume:added,model:model)
    let c = try UncertaintyV2Features.makeMap(volume:moved,model:model)
    #expect(a.value(x:8,y:6,z:2) != nil)
    #expect(b.value(x:8,y:6,z:2) == nil)
    #expect(c.value(x:0,y:0,z:2) != nil)
    let rowA = UncertaintyV2Features.row(volume:first,x:4,y:3,z:2,sites:[(0,0)])
    let rowB = UncertaintyV2Features.row(volume:added,x:4,y:3,z:2,sites:[(0,0),(8,6)])
    #expect(rowA[6] == 1 && rowB[6] == 2)
    #expect(rowA[0] == rowB[0])
    #expect(a.value(x:7,y:5,z:2) != b.value(x:7,y:5,z:2))
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:b.value(x:0,y:0,z:2),observed:true) == 1)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:b.value(x:8,y:6,z:2),observed:true) == 1)
    #expect(a.value(x:8,y:6,z:2) != b.value(x:8,y:6,z:2))
    #expect(a.value(x:0,y:0,z:2) != c.value(x:0,y:0,z:2))
}

@Test func uncertaintyV2ProfileFlexibleGrids() throws {
    let model = try UncertaintyV2Model(data:Data(contentsOf:uncertaintyProjectURL().appendingPathComponent("Demnas3DMap/Models/uncertainty_v2_trees.json")))
    for (nx,ny,nz,dx,dy,dz,siteCount) in [(24,24,12,1.0,1.0,1.0,1),
                                           (48,32,16,2.0,3.0,1.5,4),
                                           (96,96,16,1.78,2.68,1.5,3),
                                           (96,96,32,4.0,5.0,2.0,8)] {
        let grid = ReconstructionGrid(nx:nx,ny:ny,nz:nz,spacingMeters:dx,northSpacingMeters:dy,depthSpacingMeters:dz)
        var values = [Float](repeating:0,count:grid.voxelCount)
        for z in 0..<nz { for y in 0..<ny { for x in 0..<nx {
            values[grid.index(x:x,y:y,z:z)] = Float(2.5 + 0.01*Double(x) + 0.015*Double(y) + 0.02*Double(z))
        } } }
        var observed = [Bool](repeating:false,count:grid.voxelCount)
        var sites = [(Int,Int)]()
        for i in 0..<siteCount {
            let x = 2 + i * (nx-4) / max(siteCount,1)
            let y = 2 + i * (ny-4) / max(siteCount,1)
            sites.append((x,y))
            for z in 0..<nz { observed[grid.index(x:x,y:y,z:z)] = true }
        }
        let volume = ReconstructionVolume(terrainOrigin:.init(longitude:110,latitude:-7),westMeters:0,southMeters:0,
                                          grid:grid,values:values,observed:observed,
                                          validXY:Array(repeating:true,count:nx*ny),
                                          observationOrigins:Array(repeating:nil,count:grid.voxelCount),
                                          depthResampled:Array(repeating:false,count:grid.voxelCount))
        let featureStart = Date()
        let rows = (0..<nz).flatMap { z in (0..<ny).flatMap { y in (0..<nx).map { x in
            UncertaintyV2Features.row(volume:volume,x:x,y:y,z:z,sites:sites)
        } } }
        let featureSeconds = Date().timeIntervalSince(featureStart)
        let inferenceStart = Date()
        let predictions = try rows.map { try model.predict($0) }
        let inferenceSeconds = Date().timeIntervalSince(inferenceStart)
        let mapStart = Date()
        let map = try UncertaintyV2Features.makeMap(volume:volume,model:model)
        let mapSeconds = Date().timeIntervalSince(mapStart)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        #expect(map.estimatedErrorIc.count == grid.voxelCount)
        #expect(predictions.count == grid.voxelCount)
        print(String(format:"Uncertainty V2 profile %d×%d×%d @ %.1f/%.1f/%.1f m, CPT=%d: features %.3f s, trees %.3f s, full map %.3f s, peak RSS %.1f MiB, map %.1f MiB",nx,ny,nz,dx,dy,dz,siteCount,featureSeconds,inferenceSeconds,mapSeconds,Double(usage.ru_maxrss)/1048576,Double(grid.voxelCount*MemoryLayout<Float>.size)/1048576))
    }
}

@Test(arguments: [1,2,3,5])
func uncertaintyV2AdditionalCPTRefreshesActualRiskMap(siteCount: Int) throws {
    let grid = ReconstructionGrid(nx:24,ny:24,nz:12,spacingMeters:2,northSpacingMeters:3,depthSpacingMeters:1.5)
    let model = try UncertaintyV2Model(data:Data(contentsOf:uncertaintyProjectURL().appendingPathComponent("Demnas3DMap/Models/uncertainty_v2_trees.json")))
    func makeVolume(_ count: Int) -> ReconstructionVolume {
        var observed = [Bool](repeating:false,count:grid.voxelCount)
        let sites = [(2,2),(18,3),(4,17),(18,18),(11,11)]
        for (x,y) in sites.prefix(count) { for z in 0..<grid.nz { observed[grid.index(x:x,y:y,z:z)] = true } }
        let values = (0..<grid.voxelCount).map { Float(2.4 + Double($0 % grid.nx) * 0.02) }
        return ReconstructionVolume(terrainOrigin:.init(longitude:110,latitude:-7),westMeters:0,southMeters:0,
                                    grid:grid,values:values,observed:observed,
                                    validXY:Array(repeating:true,count:grid.nx*grid.ny),
                                    observationOrigins:Array(repeating:nil,count:grid.voxelCount),
                                    depthResampled:Array(repeating:false,count:grid.voxelCount))
    }
    let volume = makeVolume(siteCount)
    let map = try UncertaintyV2Features.makeMap(volume:volume,model:model)
    #expect(map.statistics?.count == grid.voxelCount-siteCount*grid.nz)
    #expect(map.featureSeconds >= 0 && map.treeSeconds >= 0)
    #expect(map.value(x:2,y:2,z:4) == nil)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:nil,observed:true,mode:.combined) == 1)
    let next = try UncertaintyV2Features.makeMap(volume:makeVolume(min(siteCount+1,5)),model:model)
    if siteCount < 5 {
        let sites = [(2,2),(18,3),(4,17),(18,18),(11,11)]
        let (newX,newY) = sites[siteCount]
        #expect(map.value(x:newX,y:newY,z:4) != nil)
        #expect(next.value(x:newX,y:newY,z:4) == nil)
        #expect(next.statistics?.count == grid.voxelCount-(siteCount+1)*grid.nz)
    }
}

@Test func uncertaintyV2PythonParity() throws {
    let root = uncertaintyProjectURL()
    let model = try UncertaintyV2Model(data: Data(contentsOf:root.appendingPathComponent("Demnas3DMap/Models/uncertainty_v2_trees.json")))
    let fixture = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("Tests/TerrainCoreTests/UncertaintyV2PythonParity.json"))) as? [String:Any])
    #expect(model.features == fixture["features"] as? [String])
    let rows = try #require(fixture["rows"] as? [[Double]])
    let expected = try #require(fixture["expected"] as? [Double])
    #expect(rows.count == expected.count && rows.count == 48)
    var maximum = 0.0
    for (row, reference) in zip(rows,expected) {
        maximum = max(maximum, abs(try model.predict(row)-reference))
    }
    #expect(maximum < 1e-9)
    print("Uncertainty V2 Swift/Python JSON parity: 48 evaluation rows, maximum error \(maximum)")
}

@Test func uncertaintyV2TreeThresholdMissingAndCorrection() throws {
    let leaf: [String:Any] = ["value":0.25,"feature":0,"threshold":0,"missing_left":false,"left":0,"right":0,"leaf":true]
    let split: [String:Any] = ["value":0,"feature":0,"threshold":5,"missing_left":true,"left":1,"right":2,"leaf":false]
    var right = leaf; right["value"] = 0.75
    let payload: [String:Any] = ["format_version":1,"features":UncertaintyV2Model.featureNames,
                                "baseline":0.1,"calibration_correction":0.05,
                                "trees":[[split,leaf,right]] + Array(repeating:[leaf],count:83)]
    let model = try UncertaintyV2Model(data:JSONSerialization.data(withJSONObject:payload))
    func row(_ first: Double) -> [Double] { [first] + Array(repeating:0,count:9) }
    #expect(abs(try model.predict(row(5)) - 21.15) < 1e-8)
    #expect(abs(try model.predict(row(5.01)) - 21.65) < 1e-8)
    #expect(abs(try model.predict(row(.nan)) - 21.15) < 1e-8)
}

@Test func uncertaintyV2FeaturesMasksAndPhysicalSpacing() throws {
    let grid = ReconstructionGrid(nx:3,ny:3,nz:3,spacingMeters:2,northSpacingMeters:3,depthSpacingMeters:4)
    var values = [Float](repeating:0,count:grid.voxelCount)
    for z in 0..<3 { for y in 0..<3 { for x in 0..<3 {
        values[grid.index(x:x,y:y,z:z)] = Float(2 + 0.2*Double(x) + 0.3*Double(y) + 0.4*Double(z))
    } } }
    var observed = [Bool](repeating:false,count:grid.voxelCount)
    for z in 0..<3 { observed[grid.index(x:0,y:0,z:z)] = true }
    var valid = [Bool](repeating:true,count:9)
    valid[grid.xyIndex(x:2,y:2)] = false
    let volume = ReconstructionVolume(terrainOrigin:.init(longitude:110,latitude:-7),westMeters:0,southMeters:0,
                                      grid:grid,values:values,observed:observed,validXY:valid,
                                      observationOrigins:Array(repeating:nil,count:27),depthResampled:Array(repeating:false,count:27))
    let row = UncertaintyV2Features.row(volume:volume,x:1,y:1,z:1,sites:[(0,0)])
    #expect(abs(row[0]-sqrt(13)) < 1e-9)
    #expect(row[1] == 4)
    #expect(abs(row[2]-2.9) < 1e-5)
    #expect(abs(row[3]-sqrt(0.02)) < 1e-6)
    #expect(abs(row[4]-0.1) < 1e-6)
    #expect(row[5] == 1 && row[6] == 1)
    #expect(row[7] == 2 && row[8] == 3 && row[9] == 4)
    let model = try UncertaintyV2Model(data:Data(contentsOf:uncertaintyProjectURL().appendingPathComponent("Demnas3DMap/Models/uncertainty_v2_trees.json")))
    let map = try UncertaintyV2Features.makeMap(volume:volume,model:model)
    #expect(map.value(x:0,y:0,z:1) == nil)
    #expect(map.value(x:2,y:2,z:1) == nil)
    #expect(map.value(x:1,y:1,z:1)?.isFinite == true)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:0,observed:false,mode:.combined) == 0.95)
    #expect(abs(UncertaintyV2Visual.opacity(estimatedErrorIc:1,observed:false,mode:.combined)-0.15) < 1e-6)
    #expect(abs(UncertaintyV2Visual.opacity(estimatedErrorIc:10,observed:false,mode:.combined)-0.15) < 1e-6)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:map.value(x:1,y:1,z:1),observed:false,mode:.ic) == 1)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:map.value(x:1,y:1,z:1),observed:false,mode:.risk) == 1)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:map.value(x:1,y:1,z:1),observed:false,mode:.combined) < 1)
    #expect(UncertaintyV2Visual.opacity(estimatedErrorIc:10,observed:true) == 1)
}
