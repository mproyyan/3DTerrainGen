import Foundation
import Testing
@testable import TerrainCore

@Test func qcfsFlexibleManifestAcceptsProjectGridWithoutResizing() throws {
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Demnas3DMap/Models/QCFS_V3_D_Flexible_manifest.json")
    let manifest = try JSONDecoder().decode(QCFSFlexibleManifest.self, from: Data(contentsOf:url))
    try manifest.validate(.init(nx:24,ny:24,nz:24,spacingMeters:1))
    try manifest.validate(.init(nx:84,ny:96,nz:16,spacingMeters:2.5834637167069228,
                                northSpacingMeters:4.2788617807958405,depthSpacingMeters:1))
    #expect(throws: Error.self) {
        try manifest.validate(.init(nx:129,ny:96,nz:16,spacingMeters:1))
    }
    #expect(throws: Error.self) {
        try manifest.validate(.init(nx:84,ny:96,nz:33,spacingMeters:1))
    }
}

@Test func bearingV1UsesContinuousPhysicalDepthAndValidMask() throws {
    let grid = ReconstructionGrid(nx:24,ny:24,nz:24,spacingMeters:2,
                                  northSpacingMeters:3,depthSpacingMeters:0.5)
    var qc = [Float](repeating:5,count:grid.voxelCount)
    var ic = [Float](repeating:2.8,count:grid.voxelCount)
    var valid = [Bool](repeating:false,count:24*24)
    valid[grid.xyIndex(x:4,y:6)] = true
    for z in 8...9 {
        let i = grid.index(x:4,y:6,z:z)
        qc[i] = 12; ic[i] = 2.0
    }
    let depths = try FlexibleBearingV1.depths(qc:qc,ic:ic,validXY:valid,grid:grid)
    #expect(depths[grid.xyIndex(x:4,y:6)] == 4.0)
    #expect(depths[grid.xyIndex(x:5,y:6)] == nil)
    qc[grid.index(x:4,y:6,z:9)] = 5
    let broken = try FlexibleBearingV1.depths(qc:qc,ic:ic,validXY:valid,grid:grid)
    #expect(broken[grid.xyIndex(x:4,y:6)] == nil)
}

@Test func bearingCandidateDetailsKeepMeasuredAndPredictedEvidenceSeparate() throws {
    let grid = ReconstructionGrid(nx:2,ny:2,nz:2,spacingMeters:2,
                                  northSpacingMeters:3,depthSpacingMeters:1)
    var qc = [Float](repeating:0,count:grid.voxelCount)
    var ic = [Float](repeating:0,count:grid.voxelCount)
    var observed = [Bool](repeating:false,count:grid.voxelCount)
    let measuredIndex = grid.index(x:0,y:0,z:1)
    let predictedIndex = grid.index(x:1,y:1,z:1)
    qc[measuredIndex] = 12; ic[measuredIndex] = 2.0; observed[measuredIndex] = true
    qc[predictedIndex] = 10.1; ic[predictedIndex] = 2.18
    var depths = [Double?](repeating:nil,count:4)
    depths[grid.xyIndex(x:0,y:0)] = 1
    depths[grid.xyIndex(x:1,y:1)] = 1
    let details = try BearingCandidateDetails.make(depths:depths,qc:qc,ic:ic,
        observed:observed,grid:grid,cptXYMeters:[Point2(x:1,y:1.5)])
    let measured = try #require(details[grid.xyIndex(x:0,y:0)])
    let predicted = try #require(details[grid.xyIndex(x:1,y:1)])
    #expect(measured.measuredAtCPT)
    #expect(!measured.nearThreshold)
    #expect(!predicted.measuredAtCPT)
    #expect(predicted.nearThreshold)
    #expect(abs(predicted.nearestCPTMeters - hypot(2,3)) < 1e-9)
    #expect(details[grid.xyIndex(x:1,y:0)] == nil)
}

@Test func bearingReliabilityUsesFrozenLookupAndRejectsUnsupportedCPTCount() throws {
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Demnas3DMap/Models/bearing_reliability_lookup.json")
    let lookup = try JSONDecoder().decode(BearingReliabilityLookup.self,from:Data(contentsOf:url))
    let grid = ReconstructionGrid(nx:24,ny:24,nz:24,spacingMeters:1)
    let valid = [Bool](repeating:true,count:576)
    var depth = [Double?](repeating:nil,count:576)
    depth[grid.xyIndex(x:12,y:12)] = 3
    let site = BearingLayerResult.Site(name:"CPT-1",x:12,y:12)
    let supported = lookup.summarize(depths:depth,validXY:valid,sites:[site],grid:grid,
        qcMinimum:10,icMaximum:2.2,thickness:1)
    #expect(supported != nil)
    #expect(supported?.conditionalDepthP90Meters != nil)
    #expect(lookup.summarize(depths:depth,validXY:valid,
        sites:(0..<2).map { .init(name:"CPT-\($0)",x:$0,y:$0) },grid:grid,
        qcMinimum:10,icMaximum:2.2,thickness:1) == nil)
    #expect(lookup.summarize(depths:depth,validXY:valid,sites:[site],grid:grid,
        qcMinimum:15,icMaximum:2.2,thickness:1) == nil)
}
