import Foundation

/// Builds sparse, observed mask, and depth-wise physical IDW on a verified 1 m grid.
/// The default 24×24×12 grid is retained for the separately trained DQN reconstructor.
enum ModelCInputAdapter {
    static func prepare(terrain: TerrainMesh, boundary: [GeoPoint], points: [CPTPoint],
                        grid: ReconstructionGrid = .fixed,
                        icMean: Float = ModelCService.icMean,
                        icStd: Float = ModelCService.icStd,
                        westMeters: Double? = nil, southMeters: Double? = nil) throws -> ModelCPreparedInput {
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty else { throw MLIntegrationError.invalidInput("Model C memerlukan minimal satu CPT tersimpan.") }
        guard boundary.count >= 3 else { throw MLIntegrationError.invalidInput("Batas area belum tersedia.") }
        guard icMean.isFinite, icStd.isFinite, icStd > 0 else {
            throw MLIntegrationError.invalidInput("Statistik normalisasi Ic tidak valid.")
        }
        let localBoundary = boundary.map { CoordinateTransformer.localMeters($0, origin: terrain.origin) }
        guard let minEast = localBoundary.map(\.x).min(), let maxEast = localBoundary.map(\.x).max(),
              let minNorth = localBoundary.map(\.y).min(), let maxNorth = localBoundary.map(\.y).max(),
              maxEast - minEast <= Double(grid.nx) + 1e-6,
              maxNorth - minNorth <= Double(grid.ny) + 1e-6 else {
            throw MLIntegrationError.invalidInput("Area tidak muat pada grid \(grid.nx) × \(grid.ny) sel dengan resolusi 1 m.")
        }
        let west = westMeters ?? (minEast + maxEast) / 2 - Double(grid.nx) / 2
        let south = southMeters ?? (minNorth + maxNorth) / 2 - Double(grid.ny) / 2
        guard minEast >= west - 1e-6, maxEast <= west + Double(grid.nx) + 1e-6,
              minNorth >= south - 1e-6, maxNorth <= south + Double(grid.ny) + 1e-6 else {
            throw MLIntegrationError.invalidInput("Batas area tidak muat pada origin grid Model C 1 m.")
        }
        let polygon = localBoundary.map { Point2(x: $0.x, y: $0.y) }
        var sparse = [Float](repeating: 0, count: grid.voxelCount)
        var mask = [Float](repeating: 0, count: grid.voxelCount)
        var idw = [Float](repeating: 0, count: grid.voxelCount)
        var observed = [Float](repeating: 0, count: grid.voxelCount)
        var origins = [CPTDataOrigin?](repeating: nil, count: grid.voxelCount)
        var resampled = [Bool](repeating: false, count: grid.voxelCount)
        var validXY = [Bool](repeating: false, count: grid.nx * grid.ny)
        for y in 0..<grid.ny {
            for x in 0..<grid.nx {
                let east = west + Double(x) + 0.5
                let north = south + Double(y) + 0.5
                let inside = Geometry.contains(.init(x: east, y: north), in: polygon)
                validXY[grid.xyIndex(x: x, y: y)] = inside && terrain.surfacePosition(x: Float(east), z: Float(-north)) != nil
            }
        }
        var sites = [(x: Int, y: Int, values: [Float])]()
        for point in complete {
            guard let values = point.interpretation?.values, values.count >= 2 else {
                throw MLIntegrationError.invalidInput("\(point.name): interpretasi Ic belum lengkap.")
            }
            let local = CoordinateTransformer.localMeters(point.coordinate, origin: terrain.origin)
            let x = Int(floor(local.x - west)), y = Int(floor(local.y - south))
            guard (0..<grid.nx).contains(x), (0..<grid.ny).contains(y),
                  validXY[grid.xyIndex(x: x, y: y)] else {
                throw MLIntegrationError.invalidInput("\(point.name): pusat sel grid 1 m berada di luar area terrain.")
            }
            guard !sites.contains(where: { $0.x == x && $0.y == y }) else {
                throw MLIntegrationError.invalidInput("Dua CPT jatuh pada sel grid Model C yang sama.")
            }
            let lastCenter = Double(grid.nz) - 0.5
            guard values.first!.depth <= 0.5, values.last!.depth >= lastCenter else {
                throw MLIntegrationError.invalidInput("\(point.name): profil Ic harus mencakup kedalaman 0,5–\(lastCenter) m tanpa ekstrapolasi.")
            }
            var profile = [Float]()
            for z in 0..<grid.nz {
                let depth = Double(z) + 0.5
                guard let upper = values.firstIndex(where: { $0.depth >= depth }) else {
                    throw MLIntegrationError.invalidInput("\(point.name): kedalaman \(depth) m tidak tersedia.")
                }
                let ic: Double
                if values[upper].depth == depth { ic = values[upper].ic }
                else {
                    guard upper > 0 else { throw MLIntegrationError.invalidInput("\(point.name): profil tidak mencakup 0,5 m.") }
                    let a = values[upper - 1], b = values[upper]
                    let fraction = (depth - a.depth) / (b.depth - a.depth)
                    ic = a.ic + (b.ic - a.ic) * fraction
                }
                guard ic.isFinite else { throw MLIntegrationError.invalidInput("\(point.name): Ic tidak berhingga.") }
                let value = Float(ic)
                let index = grid.index(x: x, y: y, z: z)
                observed[index] = value
                sparse[index] = (value - icMean) / icStd
                mask[index] = 1
                origins[index] = point.dataOrigin
                resampled[index] = values[upper].depth != depth
                profile.append(value)
            }
            sites.append((x, y, profile))
        }
        for z in 0..<grid.nz {
            for y in 0..<grid.ny {
                for x in 0..<grid.nx {
                    let index = grid.index(x: x, y: y, z: z)
                    if mask[index] == 1 { idw[index] = sparse[index]; continue }
                    var weighted = 0.0, weightSum = 0.0
                    for site in sites {
                        let dx = Double(x - site.x), dy = Double(y - site.y)
                        let weight = 1 / max(dx * dx + dy * dy, 1e-12)
                        weighted += weight * Double(site.values[z])
                        weightSum += weight
                    }
                    let physical = Float(weighted / weightSum)
                    idw[index] = (physical - icMean) / icStd
                }
            }
        }
        return .init(sparse: sparse, mask: mask, idw: idw, observedIc: observed,
                     terrainOrigin: terrain.origin, westMeters: west, southMeters: south,
                     grid: grid, validXY: validXY, observationOrigins: origins, depthResampled: resampled)
    }
}
