import Foundation

/// A project can have any finite local-metre extent. ML windows retain their own model grid contracts.
struct MetricExtent: Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
    var width: Double { east - west }
    var height: Double { north - south }

    init(boundary: [GeoPoint], origin: GeoPoint) throws {
        guard boundary.count >= 3 else { throw MLIntegrationError.invalidInput("Batas area belum tersedia.") }
        let local = boundary.map { CoordinateTransformer.localMeters($0, origin: origin) }
        guard let west = local.map(\.x).min(), let east = local.map(\.x).max(),
              let south = local.map(\.y).min(), let north = local.map(\.y).max(),
              [west, east, south, north].allSatisfy(\.isFinite), east > west, north > south else {
            throw MLIntegrationError.invalidInput("Ukuran area dalam meter tidak valid.")
        }
        self.west = west; self.south = south; self.east = east; self.north = north
    }
}

struct AdaptiveWindow: Sendable, Equatable {
    let column: Int
    let row: Int
    let west: Double
    let south: Double
    let width: Double
    let height: Double
    var east: Double { west + width }
    var north: Double { south + height }

    func contains(_ point: GeoPoint, origin: GeoPoint) -> Bool {
        let local = CoordinateTransformer.localMeters(point, origin: origin)
        let epsilon = 0.01 // inverse WGS84 round-trip tolerance at window edges
        return local.x >= west - epsilon && local.x <= east + epsilon && local.y >= south - epsilon && local.y <= north + epsilon
    }

    func clippedBoundary(_ boundary: [GeoPoint], origin: GeoPoint) -> [GeoPoint] {
        let local = boundary.map { CoordinateTransformer.localMeters($0, origin: origin) }
        let rect = [Point2(x: west, y: south), Point2(x: east, y: south),
                    Point2(x: east, y: north), Point2(x: west, y: north)]
        let clipped = Geometry.clip(local, to: rect)
        return clipped.map { CoordinateTransformer.geographic(east: $0.x, north: $0.y, origin: origin) }
    }
}

enum AdaptiveGrid {
    /// Only the explicit cross-section mode removes part of the volume. Risk
    /// coloring must not make a legal DQN cell disappear from the visible mesh.
    static func usesCutaway(displayMode: Int) -> Bool { displayMode == 2 }

    static func renderBlock(volume: ReconstructionVolume, x: Int, y: Int, z: Int,
                            step: Int) -> RenderVoxelBlock {
        let grid = volume.grid
        let countX = min(step,grid.nx-x), countY = min(step,grid.ny-y), countZ = min(step,grid.nz-z)
        return renderBlock(volume:volume,x:x,y:y,z:z,countX:countX,countY:countY,countZ:countZ)
    }

    /// Keep partial blocks on the polygon edge at native XY cell size. A
    /// coarse box spanning invalid cells would visually extend the polygon.
    static func renderBlocks(volume: ReconstructionVolume, x: Int, y: Int, z: Int,
                             step: Int) -> [RenderVoxelBlock] {
        let full = renderBlock(volume:volume,x:x,y:y,z:z,step:step)
        var valid = [(Int,Int)]()
        for yy in y..<(y+full.countY) { for xx in x..<(x+full.countX) {
            if volume.isValid(x:xx,y:yy) { valid.append((xx,yy)) }
        } }
        if valid.count == full.countX*full.countY { return [full] }
        return valid.map { renderBlock(volume:volume,x:$0.0,y:$0.1,z:z,
                                       countX:1,countY:1,countZ:full.countZ) }
    }

    private static func renderBlock(volume: ReconstructionVolume, x: Int, y: Int, z: Int,
                                    countX: Int, countY: Int, countZ: Int) -> RenderVoxelBlock {
        let grid = volume.grid
        return RenderVoxelBlock(x:x,y:y,z:z,countX:countX,countY:countY,countZ:countZ,
            centerEast:volume.east(x:x)+Double(countX-1)*grid.spacingMeters/2,
            centerNorth:volume.north(y:y)+Double(countY-1)*grid.northSpacingMeters/2,
            centerDepth:volume.depth(z:z)+Double(countZ-1)*grid.depthSpacingMeters/2,
            widthMeters:Double(countX)*grid.spacingMeters,
            northMeters:Double(countY)*grid.northSpacingMeters,
            depthMeters:Double(countZ)*grid.depthSpacingMeters)
    }
    /// Choose terrain display detail from the area and the bounded raster grid.
    /// Model C and DQN keep their own trained input resolutions.
    static func automaticDisplayResolution(extent: MetricExtent, maxAxis: Int = 160) -> Double {
        guard maxAxis >= 2 else { return 1 }
        return max(1, max(extent.width, extent.height) / Double(maxAxis - 1))
    }

    static func validateResolution(_ metres: Double) throws {
        guard metres.isFinite, metres > 0 else {
            throw MLIntegrationError.invalidInput("Resolusi spasial harus angka positif dalam meter per sel.")
        }
    }

    /// Conservative voxel display step for chunked RealityKit output.
    static func renderStep(voxelCount: Int, resolutionMetres: Double, entityBudget: Int = 12_000) -> Int {
        guard voxelCount > 0, entityBudget > 0 else { return 1 }
        let budgetStep = Int(ceil(pow(max(1, Double(voxelCount) / Double(entityBudget)), 1.0 / 3.0)))
        let resolutionStep = resolutionMetres.isFinite && resolutionMetres > 0
            ? Int(min(1024, ceil(max(1, resolutionMetres)))) : 1
        return max(1, budgetStep, resolutionStep)
    }

    /// Returns overlapping physical windows, independent of the user's display resolution.
    /// The ML caller selects a window size and overlap that its model can process.
    static func windows(extent: MetricExtent, width: Double, height: Double,
                        overlap: Double) throws -> [AdaptiveWindow] {
        guard [width, height, overlap].allSatisfy(\.isFinite), width > 0, height > 0,
              overlap >= 0, overlap < min(width, height) else {
            throw MLIntegrationError.invalidInput("Ukuran atau overlap window ML tidak valid.")
        }
        let xs = try origins(minimum: extent.west, maximum: extent.east, size: width, step: width - overlap)
        let ys = try origins(minimum: extent.south, maximum: extent.north, size: height, step: height - overlap)
        guard xs.count <= Int.max / ys.count, xs.count * ys.count <= 20_000 else {
            throw MLIntegrationError.invalidInput("Jumlah window ML melampaui anggaran pemrosesan perangkat; proyek tetap dapat disimpan, tetapi ML area ini belum didukung.")
        }
        return ys.enumerated().flatMap { row, south in
            xs.enumerated().map { column, west in
                AdaptiveWindow(column: column, row: row, west: west, south: south,
                               width: width, height: height)
            }
        }
    }

    private static func origins(minimum: Double, maximum: Double, size: Double, step: Double) throws -> [Double] {
        let span = maximum - minimum
        if span <= size { return [(minimum + maximum - size) / 2] }
        let rawCount = ceil((span - size) / step) + 1
        guard rawCount.isFinite, rawCount < Double(Int.max), rawCount <= 20_000 else {
            throw MLIntegrationError.invalidInput("Jumlah window ML tidak dapat direpresentasikan.")
        }
        let count = Int(rawCount)
        return (0..<count).map { minimum + Double($0) * step }
    }
}

struct RenderVoxelBlock: Sendable {
    let x: Int, y: Int, z: Int
    let countX: Int, countY: Int, countZ: Int
    let centerEast: Double, centerNorth: Double, centerDepth: Double
    let widthMeters: Double, northMeters: Double, depthMeters: Double
    func covers(east: Double, north: Double) -> Bool {
        abs(east-centerEast) <= widthMeters/2 && abs(north-centerNorth) <= northMeters/2
    }
}
