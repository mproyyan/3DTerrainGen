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

@Test func twoRenderedVoxelTapsSelectDifferentExactGridLocations() {
    let grid = ReconstructionGrid(nx:24,ny:24,nz:12,spacingMeters:2,
                                  northSpacingMeters:3,depthSpacingMeters:1)
    let volume = inspectionVolume(grid)
    let north = volume.north(y:3)
    let boxes = [2,4].map { x in
        TerrainRaycast.Box(center:[Float(volume.east(x:x)),0,Float(-north)],size:[2,2,3])
    }
    func select(_ east: Double) -> VerticalProfile? {
        guard let hit = TerrainRaycast.firstBoxHit(
            origin:[Float(east),5,Float(-north)],direction:[0,-1,0],boxes:boxes) else { return nil }
        return VerticalProfile.inspect(east:Double(hit.x),north:Double(-hit.z),volumes:[volume],risk:nil)
    }
    let first = select(volume.east(x:2))!
    let second = select(volume.east(x:4))!
    #expect(first.x == 2 && second.x == 4)
    #expect(first.east == volume.east(x:2) && second.east == volume.east(x:4))
    #expect(first.points[0].ic != second.points[0].ic)
    #expect(select(1000) == nil)
}

@Test func sceneRulerUsesPhysicalNonUniformGridAndSharedLocalAxes() {
    let grid = ReconstructionGrid(nx:96,ny:32,nz:16,spacingMeters:1.04,
                                  northSpacingMeters:1.9375,depthSpacingMeters:1)
    let volume = inspectionVolume(grid)
    let ruler = SceneRulerLayout(volumes:[volume],surfaceY:7,depthScale:5)!
    #expect(abs(ruler.bounds.width-99.84) < 1e-8)
    #expect(abs(ruler.bounds.height-62) < 1e-8)
    #expect(ruler.depthMeters == 16)
    let origin = ruler.point(east:ruler.bounds.west,north:ruler.bounds.south,depth:0)
    let xEnd = ruler.point(east:ruler.bounds.east,north:ruler.bounds.south,depth:0)
    let yEnd = ruler.point(east:ruler.bounds.west,north:ruler.bounds.north,depth:0)
    let down = ruler.point(east:ruler.bounds.west,north:ruler.bounds.south,depth:16)
    #expect(abs(Double(xEnd.x-origin.x)-99.84) < 1e-4)
    #expect(abs(Double(yEnd.z-origin.z)+62) < 1e-5)
    #expect(abs(Double(down.y-origin.y)+80) < 1e-5)
    #expect(SceneRulerLayout.tickValues(length:ruler.bounds.width).last == ruler.bounds.width)
    #expect(SceneRulerLayout.tickValues(length:16) == [0,5,10,16])
    #expect(SceneRulerLayout.tickValues(length:62).count <= 7)
    let nextProject = inspectionVolume(.init(nx:24,ny:24,nz:12,spacingMeters:2,
                                             northSpacingMeters:3,depthSpacingMeters:0.5))
    let nextRuler = SceneRulerLayout(volumes:[nextProject],surfaceY:7,depthScale:1)!
    #expect(nextRuler.bounds.width == 48)
    #expect(nextRuler.bounds.height == 72)
    #expect(nextRuler.depthMeters == 6)
}
