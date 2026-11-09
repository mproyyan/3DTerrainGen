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

/// All coordinates are in the existing terrain-local metre frame: +X east,
/// -Z north, and negative Y downward. The renderer's shared root transform is
/// applied later to the ruler, terrain, voxel volume and markers together.
struct SceneRulerLayout: Sendable {
    let bounds: SubsurfaceBounds
    let depthMeters: Double
    let surfaceY: Double
    let depthScale: Double
    let offsetMeters: Double

    init?(volumes: [ReconstructionVolume], surfaceY: Double, depthScale: Double) {
        guard let bounds = SubsurfaceBounds(volumes:volumes),
              bounds.width > 0, bounds.height > 0,
              surfaceY.isFinite, depthScale.isFinite, depthScale > 0 else { return nil }
        self.bounds = bounds
        self.depthMeters = volumes.map { Double($0.grid.nz)*$0.grid.depthSpacingMeters }.max() ?? 0
        self.surfaceY = surfaceY
        self.depthScale = depthScale
        let spacing = volumes.map { max($0.grid.spacingMeters,$0.grid.northSpacingMeters) }.max() ?? 1
        self.offsetMeters = max(spacing*1.5, min(bounds.width,bounds.height)*0.035)
    }

    func point(east: Double, north: Double, depth: Double) -> SIMD3<Float> {
        SIMD3(Float(east),Float(surfaceY-depth*depthScale),Float(-north))
    }

    static func tickValues(length: Double, targetIntervals: Int = 5) -> [Double] {
        guard length.isFinite, length > 0 else { return [0] }
        let raw = length/Double(max(1,targetIntervals))
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0,2,5,10].map { $0*magnitude }.first { $0 >= raw } ?? 10*magnitude
        var values = stride(from:0.0,through:length,by:step).map { $0 }
        if let last = values.last, length-last > 1e-8 {
            if length-last < step*0.45 && values.count > 1 { values.removeLast() }
            values.append(length)
        }
        return values
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
    static func description(_ zone: Int) -> String {
        switch zone {
        case 2: "Organik / lempung"
        case 3: "Lempung"
        case 4: "Campuran lanau"
        case 5: "Campuran pasir"
        case 6: "Pasir"
        case 7: "Pasir kerikilan"
        default: "Di luar rentang Ic"
        }
    }
}

/// Ic/SBT identifies soil behavior, not strength or an allowable foundation load.
/// Keep these summaries explicit until a site-validated engineering method exists.
enum PreliminaryGroundAssessment {
    static let hardLayer = "Belum dapat ditentukan dari Ic/SBT saja. Kategori SBT tidak mengukur kekerasan; verifikasi dengan profil CPT dan interpretasi geoteknik."
    static let bearing = "Belum dapat dihitung untuk desain. Diperlukan geometri dan kedalaman pondasi, korelasi parameter tanah yang tervalidasi, serta pemeriksaan insinyur geoteknik."
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
    let volumeIndex: Int
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
            return .init(volumeIndex:volumeIndex,east:east,north:north,
                         x:x,y:y,depthAvailable:Double(grid.nz)*grid.depthSpacingMeters,
                         points:rows)
        }
        return nil
    }
}

enum TerrainRaycast {
    struct Box: Sendable {
        let center: SIMD3<Float>
        let size: SIMD3<Float>
    }

    /// Raycast the exact local-space bounds used by rendered RealityKit voxel boxes.
    /// The returned point, rather than the box center, determines the inspected XY.
    static func firstBoxHit(origin: SIMD3<Float>, direction: SIMD3<Float>,
                            boxes: [Box]) -> SIMD3<Float>? {
        var nearest = Float.infinity
        for box in boxes {
            let half = box.size/2
            let lower = box.center-half, upper = box.center+half
            var enter = -Float.infinity, leave = Float.infinity
            var misses = false
            for axis in 0..<3 {
                let component = direction[axis]
                if abs(component) < 1e-8 {
                    if origin[axis] < lower[axis] || origin[axis] > upper[axis] { misses = true; break }
                } else {
                    let first = (lower[axis]-origin[axis])/component
                    let second = (upper[axis]-origin[axis])/component
                    enter = max(enter,min(first,second))
                    leave = min(leave,max(first,second))
                    if enter > leave { misses = true; break }
                }
            }
            if misses { continue }
            let distance = enter > 1e-6 ? enter : leave > 1e-6 ? leave : Float.infinity
            nearest = min(nearest,distance)
        }
        return nearest.isFinite ? origin+direction*nearest : nil
    }

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
