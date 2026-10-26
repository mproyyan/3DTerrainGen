import Foundation

/// Exact 17+11 feature order from dqn3d/v3/features.py.
/// This adapter accepts only the volume from the matching SchemaGAN V3 checkpoint.
struct DQNCandidate: Sendable {
    let x: Int
    let y: Int
    let eastMeters: Double
    let northMeters: Double
    let features: [Float]
}

enum DQNFeatureAdapter {
    static let trainingMean = 2.314278231778639
    static let trainingStd = 0.27927494076233944
    static let featureCount = 28

    static func candidates(volume: ReconstructionVolume, terrain: TerrainMesh) throws -> [DQNCandidate] {
        let grid = volume.grid
        let side = grid.nx, depthCount = grid.nz
        let supportedGrid = (side == 24 && grid.ny == 24 && depthCount == 12 && grid.spacingMeters == 1)
            || (side == 16 && grid.ny == 16 && depthCount == 16 && grid.spacingMeters == 2)
        guard supportedGrid, grid.depthSpacingMeters == 1,
              volume.grid.shape == [1, 1, depthCount, side, side],
              volume.values.count == side * side * depthCount,
              volume.observed.count == volume.values.count,
              volume.validXY.count == side * side,
              volume.values.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidInput("DQN volume/mask shape or Ic invalid")
        }
        let observedXY = (0..<(side * side)).map { xy in
            (0..<depthCount).contains { volume.observed[$0 * side * side + xy] }
        }
        let sites = (0..<side).flatMap { x in (0..<side).compactMap { y -> (Double, Double)? in
            observedXY[y * side + x] ? (volume.east(x: x), volume.north(y: y)) : nil
        } }
        guard !sites.isEmpty else { throw MLIntegrationError.invalidInput("DQN needs at least one observed CPT") }
        let validVoxelCount = volume.validXY.filter { $0 }.count * depthCount
        guard validVoxelCount > 0 else { throw MLIntegrationError.invalidInput("DQN needs valid cells") }
        let normalized = volume.values.map { (Double($0) - trainingMean) / trainingStd }
        let validValues = (0..<depthCount).flatMap { z in
            (0..<side).flatMap { y in (0..<side).compactMap { x -> Double? in
                volume.isValid(x: x, y: y) ? normalized[volume.index(x: x, y: y, z: z)] : nil
            } }
        }
        let possibleSites = volume.validXY.filter { $0 }.count
        let observedCount = observedXY.filter { $0 }.count
        let observedVoxelCount = volume.observed.filter { $0 }.count
        let global: [Double] = [
            log1p(Double(observedCount)) / log1p(Double(possibleSites)),
            Double(grid.nx) * grid.spacingMeters / 32,
            Double(grid.ny) * grid.spacingMeters / 32,
            Double(grid.nz) * grid.depthSpacingMeters / 16,
            grid.spacingMeters / 2, grid.spacingMeters / 2, grid.depthSpacingMeters / 2,
            mean(validValues), standardDeviation(validValues),
            Double(validVoxelCount) / Double(volume.values.count),
            Double(observedVoxelCount) / Double(validVoxelCount)
        ]
        var result = [DQNCandidate]()
        // np.argwhere returns candidates lexicographically in x, then y.
        for x in 0..<side {
            for y in 0..<side where volume.isValid(x: x, y: y) && !observedXY[y * side + x] {
                let east = volume.east(x: x), north = volume.north(y: y)
                let nearest = sites.map { hypot(east - $0.0, north - $0.1) }.min()!
                guard nearest >= 2,
                      terrain.surfacePosition(x: Float(east), z: Float(-north)) != nil else { continue }
                var nearbyCount = 0, nearbyObserved = 0, nearbyValid = 0
                var nearbyValues = [Double]()
                for xx in 0..<side {
                    for yy in 0..<side where hypot(volume.east(x: xx) - east, volume.north(y: yy) - north) <= 4 + 1e-9 {
                        nearbyCount += 1
                        if observedXY[yy * side + xx] { nearbyObserved += 1 }
                        if volume.isValid(x: xx, y: yy) {
                            nearbyValid += depthCount
                            for z in 0..<depthCount {
                                nearbyValues.append(normalized[volume.index(x: xx, y: yy, z: z)])
                            }
                        }
                    }
                }
                let profile = (0..<depthCount).map { normalized[volume.index(x: x, y: y, z: $0)] }
                let bins = (0..<4).map { bin -> [Double] in
                    let start = bin * depthCount / 4
                    let end = (bin + 1) * depthCount / 4
                    return Array(profile[start..<end])
                }
                let local: [Double] = [
                    Double(x) / Double(side - 1), Double(y) / Double(side - 1),
                    min(nearest / hypot(Double(side) * grid.spacingMeters, Double(side) * grid.spacingMeters), 1),
                    Double(nearbyObserved) / Double(nearbyCount),
                    1, mean(profile), standardDeviation(profile)
                ] + bins.map(mean) + [0, 0, 0, 0] + [
                    mean(nearbyValues), Double(nearbyValid) / Double(nearbyCount * depthCount)
                ]
                let row = (local + global).map(Float.init)
                guard row.count == featureCount, row.allSatisfy(\.isFinite) else {
                    throw MLIntegrationError.invalidInput("DQN feature row is invalid")
                }
                result.append(.init(x: x, y: y, eastMeters: east, northMeters: north, features: row))
            }
        }
        return result
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
    private static func standardDeviation(_ values: [Double]) -> Double {
        let average = mean(values)
        return sqrt(values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count))
    }

}
