import Foundation

/// X east, Y north, Z positive downward; flattened storage is [Z,Y,X].
struct ReconstructionGrid: Sendable {
    let nx: Int
    let ny: Int
    let nz: Int
    let spacingMeters: Double
    let depthSpacingMeters: Double = 1

    static let fixed = ReconstructionGrid(nx: 24, ny: 24, nz: 12, spacingMeters: 1)
    var voxelCount: Int { nx * ny * nz }
    var shape: [Int] { [1, 1, nz, ny, nx] }
    func index(x: Int, y: Int, z: Int) -> Int { (z * ny + y) * nx + x }
    func xyIndex(x: Int, y: Int) -> Int { y * nx + x }

    /// Select a grid inside the verified Core ML shape bounds at 1 m spacing.
    /// One cell of margin keeps CPTs on polygon edges inside the grid.
    static func fitting(boundary: [GeoPoint], points: [CPTPoint], origin: GeoPoint) throws -> Self {
        guard boundary.count >= 3 else { throw MLIntegrationError.invalidInput("Batas area belum tersedia.") }
        let local = boundary.map { CoordinateTransformer.localMeters($0, origin: origin) }
        guard let eastMin = local.map(\.x).min(), let eastMax = local.map(\.x).max(),
              let northMin = local.map(\.y).min(), let northMax = local.map(\.y).max() else {
            throw MLIntegrationError.invalidInput("Batas area tidak valid.")
        }
        func dimension(_ span: Double, minimum: Int, maximum: Int) throws -> Int {
            guard span.isFinite, span > 0 else { throw MLIntegrationError.invalidInput("Rentang area tidak valid.") }
            let needed = Int(ceil(span + 1 - 1e-6))
            let rounded = max(minimum, ((needed + 3) / 4) * 4)
            guard rounded <= maximum else {
                throw MLIntegrationError.invalidInput("Model C Flexible hanya mendukung area hingga sekitar 47 m timur–barat × 31 m utara–selatan pada resolusi 1 m.")
            }
            return rounded
        }
        let nx = try dimension(eastMax - eastMin, minimum: 16, maximum: 48)
        let ny = try dimension(northMax - northMin, minimum: 16, maximum: 32)
        let complete = points.filter(\.isComplete)
        guard let availableDepth = complete.compactMap({ $0.interpretation?.values.last?.depth }).min() else {
            throw MLIntegrationError.invalidInput("Model C memerlukan minimal satu profil CPT tersimpan.")
        }
        let nz = availableDepth >= 15.5 ? 16 : availableDepth >= 11.5 ? 12 : availableDepth >= 7.5 ? 8 : 0
        guard nz > 0 else {
            throw MLIntegrationError.invalidInput("Profil CPT harus mencakup setidaknya kedalaman 0,5–7,5 m tanpa ekstrapolasi.")
        }
        return .init(nx: nx, ny: ny, nz: nz, spacingMeters: 1)
    }
}

struct ReconstructionVolume: Sendable {
    // The fixed grid remains the DQN V3 training contract.
    static let side = 24
    static let depthCount = 12
    static let spacingMeters = 1.0

    let terrainOrigin: GeoPoint
    let westMeters: Double
    let southMeters: Double
    let grid: ReconstructionGrid
    let values: [Float]
    let observed: [Bool]
    let validXY: [Bool]
    let observationOrigins: [CPTDataOrigin?]
    let depthResampled: [Bool]

    init(terrainOrigin: GeoPoint, westMeters: Double, southMeters: Double,
         grid: ReconstructionGrid = .fixed, values: [Float], observed: [Bool],
         validXY: [Bool], observationOrigins: [CPTDataOrigin?], depthResampled: [Bool]) {
        self.terrainOrigin = terrainOrigin
        self.westMeters = westMeters
        self.southMeters = southMeters
        self.grid = grid
        self.values = values
        self.observed = observed
        self.validXY = validXY
        self.observationOrigins = observationOrigins
        self.depthResampled = depthResampled
    }

    static func index(x: Int, y: Int, z: Int) -> Int { (z * side + y) * side + x }
    static func xyIndex(x: Int, y: Int) -> Int { y * side + x }
    func index(x: Int, y: Int, z: Int) -> Int { grid.index(x: x, y: y, z: z) }
    func east(x: Int) -> Double { westMeters + (Double(x) + 0.5) * grid.spacingMeters }
    func north(y: Int) -> Double { southMeters + (Double(y) + 0.5) * grid.spacingMeters }
    func depth(z: Int) -> Double { (Double(z) + 0.5) * grid.depthSpacingMeters }
    func isValid(x: Int, y: Int) -> Bool { validXY[grid.xyIndex(x: x, y: y)] }
    func ic(x: Int, y: Int, z: Int) -> Float { values[index(x: x, y: y, z: z)] }
}

struct ModelCPreparedInput: Sendable {
    let sparse: [Float]
    let mask: [Float]
    let idw: [Float]
    let observedIc: [Float]
    let terrainOrigin: GeoPoint
    let westMeters: Double
    let southMeters: Double
    let grid: ReconstructionGrid
    let validXY: [Bool]
    let observationOrigins: [CPTDataOrigin?]
    let depthResampled: [Bool]

    func volume(reconstruction: [Float]) throws -> ReconstructionVolume {
        guard reconstruction.count == grid.voxelCount,
              reconstruction.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidOutput("Model C physical Ic volume")
        }
        return ReconstructionVolume(
            terrainOrigin: terrainOrigin, westMeters: westMeters, southMeters: southMeters,
            grid: grid, values: reconstruction, observed: mask.map { $0 == 1 }, validXY: validXY,
            observationOrigins: observationOrigins, depthResampled: depthResampled
        )
    }
}
