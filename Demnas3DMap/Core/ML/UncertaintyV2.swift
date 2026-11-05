import Foundation

struct UncertaintyV2Model: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        let value: Double
        let feature: Int
        let threshold: Double
        let missingLeft: Bool
        let left: Int
        let right: Int
        let leaf: Bool
        enum CodingKeys: String, CodingKey {
            case value, feature, threshold, left, right, leaf
            case missingLeft = "missing_left"
        }
    }
    let formatVersion: Int
    let features: [String]
    let baseline: Double
    let trees: [[Node]]
    let calibrationCorrection: Double
    enum CodingKeys: String, CodingKey {
        case features, baseline, trees
        case formatVersion = "format_version"
        case calibrationCorrection = "calibration_correction"
    }
    static let featureNames = [
        "distance_to_cpt_m", "depth_m", "predicted_ic", "lateral_gradient",
        "vertical_gradient", "nearby_cpt_fraction_25m", "n_cpt",
        "dx_m", "dy_m", "dz_m"
    ]
    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard formatVersion == 1, features == Self.featureNames, trees.count == 84,
              baseline.isFinite, calibrationCorrection.isFinite,
              trees.allSatisfy({ tree in !tree.isEmpty && tree.indices.allSatisfy { index in
                  let node = tree[index]
                  return node.value.isFinite && (node.leaf ||
                      (features.indices.contains(node.feature) && node.threshold.isFinite &&
                       tree.indices.contains(node.left) && tree.indices.contains(node.right)))
              } }) else {
            throw MLIntegrationError.invalidContract("Uncertainty V2 JSON: 84 trees / 10 fitur")
        }
    }
    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "uncertainty_v2_trees", withExtension: "json") else {
            throw MLIntegrationError.missingModel("uncertainty_v2_trees.json")
        }
        return try Self(data: Data(contentsOf: url))
    }
    func predict(_ row: [Double]) throws -> Double {
        guard row.count == features.count, row.allSatisfy({ !$0.isInfinite }) else {
            throw MLIntegrationError.invalidInput("Uncertainty V2 memerlukan 10 fitur berhingga atau NaN untuk missing value.")
        }
        var prediction = baseline
        for tree in trees {
            var index = 0
            var reachedLeaf = false
            for _ in tree.indices {
                let node = tree[index]
                if node.leaf { prediction += node.value; reachedLeaf = true; break }
                let value = row[node.feature]
                index = (value.isNaN ? node.missingLeft : value <= node.threshold) ? node.left : node.right
            }
            guard reachedLeaf else { throw MLIntegrationError.invalidContract("Uncertainty V2 tree traversal tidak mencapai leaf.") }
        }
        return max(0, prediction) + calibrationCorrection
    }
}

struct UncertaintyV2Map: Sendable {
    let grid: ReconstructionGrid
    /// NaN means outside the valid mask or measured CPT; those voxels are not predictions.
    let estimatedErrorIc: [Float]
    let featureSeconds: Double
    let treeSeconds: Double
    func value(x: Int, y: Int, z: Int) -> Float? {
        let value = estimatedErrorIc[grid.index(x:x,y:y,z:z)]
        return value.isFinite ? value : nil
    }
    var statistics: (minimum: Float, mean: Float, maximum: Float, count: Int)? {
        var minimum = Float.infinity, maximum = -Float.infinity, total = 0.0, count = 0
        for value in estimatedErrorIc where value.isFinite {
            minimum = min(minimum,value); maximum = max(maximum,value)
            total += Double(value); count += 1
        }
        return count == 0 ? nil : (minimum,Float(total/Double(count)),maximum,count)
    }
}

struct RendererDiagnostics: Sendable {
    let mode: RiskVisualizationMode
    let renderedVoxelCount: Int
    let minimumOpacity: Double
    let meanOpacity: Double
    let maximumOpacity: Double
    let updateSeconds: Double
    let cutaway: Bool
    let lodStep: Int
    let markerCount: Int
    let terrainVisible: Bool
    let sharedParent: Bool
    let rootScale: Float
    let rootPosition: SIMD3<Float>
    let rootRotation: SIMD4<Float>
    let markerLocal: SIMD3<Float>?
    let markerWorld: SIMD3<Float>?
    let surfaceWorld: SIMD3<Float>?
    let surfaceTriangle: Int?
    let markerSurfaceGapWorld: Float?
    let supportingVoxelWorld: SIMD3<Float>?
    let supportingVoxelGapWorld: Float?
}

enum RiskVisualizationMode: String, CaseIterable, Sendable {
    case ic = "Lapisan Ic"
    case risk = "Risiko"
    case combined = "Gabungan"
}

enum UncertaintyV2Visual {
    /// Fixed visual range of 0...0.5 Ic error, never rescaled per CPT count.
    static let riskScaleMaximumIc = 0.5
    static func riskFraction(_ risk: Float?) -> Double? {
        guard let risk, risk.isFinite else { return nil }
        return min(max(Double(risk)/riskScaleMaximumIc,0),1)
    }
    static func opacity(estimatedErrorIc: Float?, observed: Bool,
                        mode: RiskVisualizationMode = .combined) -> Double {
        if observed || mode != .combined { return 1 }
        guard let fraction = riskFraction(estimatedErrorIc) else { return 1 }
        return 0.95 - 0.8 * fraction
    }
}

enum UncertaintyV2Features {
    static func inputKey(points: [CPTPoint], resolutionMeters: Double, boundary: [GeoPoint]) -> String {
        let sites = points.map {
            "\($0.id.uuidString):\($0.updatedAt?.timeIntervalSince1970 ?? 0):\($0.coordinate.longitude):\($0.coordinate.latitude)"
        }.joined(separator: "|")
        let polygon = boundary.map { "\($0.longitude):\($0.latitude)" }.joined(separator: "|")
        return "\(sites)#\(resolutionMeters)#\(polygon)"
    }

    static func row(volume: ReconstructionVolume, x: Int, y: Int, z: Int,
                    sites: [(Int, Int)]) -> [Double] {
        let grid = volume.grid
        let dx = grid.spacingMeters, dy = grid.northSpacingMeters, dz = grid.depthSpacingMeters
        func gradient(_ axis: Int) -> Double {
            let n = axis == 0 ? grid.nx : axis == 1 ? grid.ny : grid.nz
            let coordinate = axis == 0 ? x : axis == 1 ? y : z
            let spacing = axis == 0 ? dx : axis == 1 ? dy : dz
            func sample(_ offset: Int) -> Double {
                Double(volume.ic(x: x + (axis == 0 ? offset : 0),
                                 y: y + (axis == 1 ? offset : 0),
                                 z: z + (axis == 2 ? offset : 0)))
            }
            if n < 2 { return 0 }
            if coordinate == 0 { return (sample(1) - sample(0)) / spacing }
            if coordinate == n - 1 { return (sample(0) - sample(-1)) / spacing }
            return (sample(1) - sample(-1)) / (2 * spacing)
        }
        let gx = gradient(0), gy = gradient(1), gz = gradient(2)
        let distances = sites.map { hypot(Double(x-$0.0)*dx, Double(y-$0.1)*dy) }
        return [distances.min() ?? .nan, Double(z)*dz, Double(volume.ic(x:x,y:y,z:z)),
                hypot(gx,gy), abs(gz),
                Double(distances.filter { $0 <= 25 }.count)/Double(max(sites.count,1)),
                Double(sites.count), dx, dy, dz]
    }

    static func makeMap(volume: ReconstructionVolume, model: UncertaintyV2Model) throws -> UncertaintyV2Map {
        let grid = volume.grid
        guard grid.nx >= 2, grid.ny >= 2, grid.nz >= 2,
              [grid.spacingMeters,grid.northSpacingMeters,grid.depthSpacingMeters].allSatisfy({ $0.isFinite && $0 > 0 }),
              volume.values.count == grid.voxelCount, volume.observed.count == grid.voxelCount,
              volume.validXY.count == grid.nx*grid.ny else {
            throw MLIntegrationError.invalidInput("Uncertainty V2: ukuran volume atau resolusi grid tidak valid.")
        }
        let sites = (0..<grid.nx).flatMap { x in (0..<grid.ny).compactMap { y -> (Int,Int)? in
            (0..<grid.nz).contains { volume.observed[grid.index(x:x,y:y,z:$0)] } ? (x,y) : nil
        } }
        guard !sites.isEmpty else { throw MLIntegrationError.invalidInput("Uncertainty V2 memerlukan satu CPT terukur.") }
        var values = [Float](repeating: .nan, count: grid.voxelCount)
        var featureSeconds = 0.0, treeSeconds = 0.0
        for z in 0..<grid.nz {
            try Task.checkCancellation()
            let featureStart = Date()
            var rows = [(Int,[Double])]()
            for y in 0..<grid.ny { for x in 0..<grid.nx {
                let index = grid.index(x:x,y:y,z:z)
                guard volume.validXY[grid.xyIndex(x:x,y:y)], !volume.observed[index] else { continue }
                let features = row(volume:volume,x:x,y:y,z:z,sites:sites)
                guard features.allSatisfy(\.isFinite) else { throw MLIntegrationError.invalidInput("Uncertainty V2: fitur voxel tidak berhingga.") }
                rows.append((index,features))
            } }
            featureSeconds += Date().timeIntervalSince(featureStart)
            let treeStart = Date()
            for (index,features) in rows { values[index] = Float(try model.predict(features)) }
            treeSeconds += Date().timeIntervalSince(treeStart)
        }
        return .init(grid:grid,estimatedErrorIc:values,featureSeconds:featureSeconds,treeSeconds:treeSeconds)
    }
}
