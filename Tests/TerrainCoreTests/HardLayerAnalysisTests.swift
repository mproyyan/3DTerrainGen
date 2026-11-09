import Foundation
import Testing
@testable import TerrainCore

private func sample(_ depth: Double, _ qc: Double) -> CPTSample {
    .init(depth:depth,qcMPa:qc,fsKPa:100,u2KPa:nil)
}

@Test func isolatedQcSpikeDoesNotQualify() {
    #expect(HardLayerAnalysisService.indication(samples:[
        sample(1.0,10),sample(1.1,22),sample(1.2,24),sample(1.3,10)
    ]) == nil)
}

@Test func persistentQcReturnsFirstStartAndIntervalStatistics() throws {
    let indication = try #require(HardLayerAnalysisService.indication(samples:[
        sample(1.0,10),sample(1.1,21),sample(1.2,22),sample(1.3,23),
        sample(1.4,22),sample(1.5,24),sample(1.6,25)
    ]))
    #expect(indication.depth == 1.1)
    #expect(indication.confirmedUntilDepth == 1.6)
    #expect(indication.startQcMPa == 21)
    #expect(abs(indication.meanQcMPa - (21+22+23+22+24+25)/6.0) < 1e-12)
}

@Test func qcDropResetsRunAndFirstQualifyingIntervalWins() throws {
    let indication = try #require(HardLayerAnalysisService.indication(samples:[
        sample(1.0,21),sample(1.2,22),sample(1.3,10),
        sample(2.0,23),sample(2.3,24),sample(2.5,25),
        sample(3.0,10),sample(4.0,25),sample(4.5,26)
    ]))
    #expect(indication.depth == 2.0)
    #expect(indication.confirmedUntilDepth == 2.5)
}

@Test func actualCPTWithoutQualifyingIntervalReturnsNil() {
    #expect(HardLayerAnalysisService.indication(samples:[sample(1.0,10),sample(2.0,15)]) == nil)
}

@Test func onlyMeasuredCPTCellCanExposeQc() throws {
    let origin = GeoPoint(longitude:110,latitude:-7)
    let grid = ReconstructionGrid(nx:3,ny:3,nz:2,spacingMeters:2,northSpacingMeters:2,depthSpacingMeters:1)
    var observed = [Bool](repeating:false,count:grid.voxelCount)
    for z in 0..<2 { observed[grid.index(x:1,y:1,z:z)] = true }
    let volume = ReconstructionVolume(terrainOrigin:origin,westMeters:0,southMeters:0,grid:grid,
        values:[Float](repeating:2.5,count:grid.voxelCount),observed:observed,
        validXY:[Bool](repeating:true,count:9),
        observationOrigins:Array(repeating:nil,count:grid.voxelCount),
        depthResampled:[Bool](repeating:false,count:grid.voxelCount))
    let coordinate = CoordinateTransformer.geographic(east:volume.east(x:1),north:volume.north(y:1),origin:origin)
    var point = CPTPoint(id:UUID(),name:"CPT-1",coordinate:coordinate,surfaceElevation:100)
    point.csv = "depth_m,qc_mpa,fs_kpa,u2_kpa\n1.0,21,100,\n1.5,22,100,"
    point.interpretation = CPTInterpretation(values:[],layers:[],notes:[])
    let boundary = [(0.0,0.0),(6.0,0.0),(6.0,6.0),(0.0,6.0)].map {
        CoordinateTransformer.geographic(east:$0.0,north:$0.1,origin:origin)
    }
    let matched = HardLayerAnalysisService.measuredPoint(gridX:1,gridY:1,volume:volume,
        points:[point],boundary:boundary)
    #expect(matched?.id == point.id)
    #expect(HardLayerAnalysisService.indication(for:point)?.depth == 1.0)
    #expect(HardLayerAnalysisService.measuredPoint(gridX:2,gridY:1,volume:volume,
        points:[point],boundary:boundary) == nil)
    point.dataOrigin = .example
    #expect(HardLayerAnalysisService.indication(for:point) == nil)
    #expect(HardLayerAnalysisService.measuredPoint(gridX:1,gridY:1,volume:volume,
        points:[point],boundary:boundary) == nil)
}
