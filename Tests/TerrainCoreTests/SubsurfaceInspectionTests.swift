import Foundation
import Testing
import simd
@testable import TerrainCore

private func inspectionVolume(_ grid: ReconstructionGrid, observedX: Int = 2) -> ReconstructionVolume {
    var values = [Float](repeating:2.5,count:grid.voxelCount)
    var observed = [Bool](repeating:false,count:grid.voxelCount)
    for z in 0..<grid.nz {
        values[grid.index(x:2,y:3,z:z)] = z.isMultiple(of:2) ? 1.8 : 3.2
        observed[grid.index(x:observedX,y:3,z:z)] = z < 2
    }
    return .init(terrainOrigin:.init(longitude:110,latitude:-7),westMeters:-10,southMeters:20,
                 grid:grid,values:values,observed:observed,
                 validXY:[Bool](repeating:true,count:grid.nx*grid.ny),
                 observationOrigins:Array(repeating:nil,count:grid.voxelCount),
                 depthResampled:Array(repeating:false,count:grid.voxelCount))
}

@Test func physicalXYSlidersClipNativeAndCoarseBlocks() {
    let grid = ReconstructionGrid(nx:96,ny:96,nz:16,spacingMeters:2.91,
                                  northSpacingMeters:1.75,depthSpacingMeters:0.5)
    let volume = inspectionVolume(grid)
    let bounds = SubsurfaceBounds(volumes:[volume])!
    #expect(abs(bounds.width - 96*2.91) < 1e-8)
    #expect(abs(bounds.height - 96*1.75) < 1e-8)
    let block = AdaptiveGrid.renderBlock(volume:volume,x:2,y:3,z:0,step:4)
    #expect(SubsurfaceSlice().clip(block)?.widthMeters == block.widthMeters)
    let eastLimit = block.centerEast + 0.4
    let northLimit = block.centerNorth + 0.2
    let clipped = SubsurfaceSlice(eastLimit:eastLimit,northLimit:northLimit).clip(block)!
    #expect(abs((clipped.centerEast + clipped.widthMeters/2) - eastLimit) < 1e-8)
    #expect(abs((clipped.centerNorth + clipped.northMeters/2) - northLimit) < 1e-8)
    #expect(SubsurfaceSlice(eastLimit:block.centerEast-block.widthMeters/2,
                           northLimit:nil).clip(block) == nil)
}

@Test func verticalProfileUsesActualDepthIcObservedAndRisk() {
    let grid = ReconstructionGrid(nx:24,ny:24,nz:12,spacingMeters:2,
                                  northSpacingMeters:3,depthSpacingMeters:0.5)
    let volume = inspectionVolume(grid)
    var riskValues = [Float](repeating:0.2,count:grid.voxelCount)
    riskValues[grid.index(x:2,y:3,z:0)] = .nan
    let risk = UncertaintyV2Map(grid:grid,estimatedErrorIc:riskValues,featureSeconds:0,treeSeconds:0)
    let profile = VerticalProfile.inspect(east:volume.east(x:2),north:volume.north(y:3),
                                          volumes:[volume],risk:risk)!
    #expect(profile.points.count == 12)
    #expect(profile.depthAvailable == 6)
    #expect(profile.deepestMeasured == 1)
    #expect(profile.points[0].ic == 1.8)
    #expect(profile.points[0].sbt == "SBT zona 6")
    #expect(profile.points[0].estimatedRiskIc == nil)
    #expect(profile.points[1].estimatedRiskIc == 0.2)
    #expect(profile.points[2].measured == false)
    #expect(VerticalProfile.inspect(east:1000,north:1000,volumes:[volume],risk:risk) == nil)
}

@Test func terrainTapRayUsesRenderedTriangleGeometry() {
    let positions: [SIMD3<Float>] = [[0,1,0],[10,1,0],[0,1,-10]]
    let hit = TerrainRaycast.firstHit(origin:[2,5,-2],direction:[0,-1,0],
                                      positions:positions,indices:[0,1,2])
    #expect(hit != nil)
    #expect(abs(hit!.x-2) < 1e-6 && abs(hit!.z+2) < 1e-6)
    #expect(TerrainRaycast.firstHit(origin:[20,5,-2],direction:[0,-1,0],
                                    positions:positions,indices:[0,1,2]) == nil)
}
