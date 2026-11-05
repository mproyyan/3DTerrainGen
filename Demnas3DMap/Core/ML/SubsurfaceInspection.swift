import Foundation
import simd

struct SubsurfaceSlice: Sendable, Equatable {
    var eastLimit: Double? = nil
    var northLimit: Double? = nil
    var isActive: Bool { eastLimit != nil || northLimit != nil }

    func clip(_ block: RenderVoxelBlock) -> SlicedVoxelBlock? {
        let west = block.centerEast - block.widthMeters/2
        let south = block.centerNorth - block.northMeters/2
        let east = min(block.centerEast + block.widthMeters/2, eastLimit ?? .infinity)
        let north = min(block.centerNorth + block.northMeters/2, northLimit ?? .infinity)
        guard east-west > 1e-6, north-south > 1e-6 else { return nil }
        return .init(centerEast:(west+east)/2,centerNorth:(south+north)/2,
                     widthMeters:east-west,northMeters:north-south)
    }
}

struct SlicedVoxelBlock: Sendable {
    let centerEast: Double
    let centerNorth: Double
    let widthMeters: Double
    let northMeters: Double
}

struct SubsurfaceBounds: Sendable {
    let west: Double, south: Double, east: Double, north: Double
    var width: Double { east-west }
    var height: Double { north-south }
    init?(volumes: [ReconstructionVolume]) {
        guard let first = volumes.first else { return nil }
        west = volumes.map(\.westMeters).min() ?? first.westMeters
        south = volumes.map(\.southMeters).min() ?? first.southMeters
        east = volumes.map { $0.westMeters + Double($0.grid.nx)*$0.grid.spacingMeters }.max() ?? west
        north = volumes.map { $0.southMeters + Double($0.grid.ny)*$0.grid.northSpacingMeters }.max() ?? south
    }
}

enum IcSBTClassifier {
    static func zone(_ ic: Float) -> Int {
        if ic < 1 || ic > 4 { return 0 }
        if ic < 1.31 { return 7 }
        if ic < 2.05 { return 6 }
        if ic < 2.6 { return 5 }
        if ic < 2.95 { return 4 }
        if ic < 3.6 { return 3 }
        return 2
    }
    static func label(_ ic: Float) -> String {
        let value = zone(ic)
        return value == 0 ? "Di luar rentang klasifikasi Ic" : "SBT zona \(value)"
    }
}

struct VerticalProfilePoint: Sendable {
    let depthFrom: Double
    let depthTo: Double
    let depthCenter: Double
    let ic: Float
    let sbt: String
    let measured: Bool
    let estimatedRiskIc: Float?
}

struct VerticalProfile: Sendable, Identifiable {
    let id = UUID()
    let east: Double
    let north: Double
    let x: Int
    let y: Int
    let depthAvailable: Double
    let points: [VerticalProfilePoint]
    var deepestMeasured: Double? { points.last(where: \.measured)?.depthTo }

    static func inspect(east: Double, north: Double, volumes: [ReconstructionVolume],
                        risk: UncertaintyV2Map?) -> VerticalProfile? {
        for (volumeIndex, volume) in volumes.enumerated() {
            let grid = volume.grid
            let fx = (east-volume.westMeters)/grid.spacingMeters
            let fy = (north-volume.southMeters)/grid.northSpacingMeters
            guard fx.isFinite,fy.isFinite,fx >= 0,fy >= 0,
                  fx < Double(grid.nx),fy < Double(grid.ny) else { continue }
            let x = Int(floor(fx)), y = Int(floor(fy))
            guard volume.isValid(x:x,y:y) else { continue }
            let matchingRisk = volumeIndex == 0 && risk?.grid.nx == grid.nx &&
                risk?.grid.ny == grid.ny && risk?.grid.nz == grid.nz
            let rows = (0..<grid.nz).map { z -> VerticalProfilePoint in
                let index = volume.index(x:x,y:y,z:z)
                let ic = volume.values[index]
                return .init(depthFrom:Double(z)*grid.depthSpacingMeters,
                             depthTo:Double(z+1)*grid.depthSpacingMeters,
                             depthCenter:volume.depth(z:z),ic:ic,
                             sbt:IcSBTClassifier.label(ic),
                             measured:volume.observed[index],
                             estimatedRiskIc:matchingRisk ? risk?.value(x:x,y:y,z:z) : nil)
            }
            return .init(east:volume.east(x:x),north:volume.north(y:y),
                         x:x,y:y,depthAvailable:Double(grid.nz)*grid.depthSpacingMeters,
                         points:rows)
        }
        return nil
    }
}

enum TerrainRaycast {
    /// Returns the nearest hit against the actual terrain triangle buffer.
    static func firstHit(origin: SIMD3<Float>, direction: SIMD3<Float>,
                         positions: [SIMD3<Float>], indices: [UInt32]) -> SIMD3<Float>? {
        var nearest = Float.infinity
        var hit: SIMD3<Float>?
        for i in stride(from:0,to:indices.count,by:3) {
            let a = positions[Int(indices[i])]
            let b = positions[Int(indices[i+1])]
            let c = positions[Int(indices[i+2])]
            let edge1 = b-a, edge2 = c-a
            let p = simd_cross(direction,edge2)
            let determinant = simd_dot(edge1,p)
            if abs(determinant) < 1e-7 { continue }
            let inverse = 1/determinant
            let t = origin-a
            let u = simd_dot(t,p)*inverse
            if u < 0 || u > 1 { continue }
            let q = simd_cross(t,edge1)
            let v = simd_dot(direction,q)*inverse
            if v < 0 || u+v > 1 { continue }
            let distance = simd_dot(edge2,q)*inverse
            if distance > 0 && distance < nearest {
                nearest = distance
                hit = origin+direction*distance
            }
        }
        return hit
    }
}
