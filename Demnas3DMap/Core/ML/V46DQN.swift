import CoreML
import Foundation

struct V46Contract: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        let combinedOrder: [String]
        let candidateFeatureCount: Int
        let globalContextCount: Int
        let candidateFeatureNames: [String]
        let globalContextNames: [String]
    }
    struct Normalization: Decodable, Sendable {
        let schemaGANMean: Double
        let schemaGANStd: Double
    }
    let name: String
    let stoppingCriterion: Bool
    let input: Input
    let normalization: Normalization

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard name == "DQN V4.6-A", !stoppingCriterion,
              input.candidateFeatureCount == 18, input.globalContextCount == 11,
              input.candidateFeatureNames == V46FeatureAdapter.candidateNames,
              input.globalContextNames == V46FeatureAdapter.globalNames,
              input.combinedOrder == input.candidateFeatureNames + input.globalContextNames,
              normalization.schemaGANMean.isFinite,
              normalization.schemaGANStd.isFinite, normalization.schemaGANStd > 0,
              abs(normalization.schemaGANMean - Double(V42Input.mean)) < 1e-6,
              abs(normalization.schemaGANStd - Double(V42Input.std)) < 1e-6 else {
            throw MLIntegrationError.invalidContract("DQN V4.6-A frozen 29-feature contract")
        }
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "DQN_V4_6_A_contract", withExtension: "json") else {
            throw MLIntegrationError.missingModel("DQN_V4_6_A_contract.json")
        }
        return try Self(data: Data(contentsOf: url))
    }
}

enum V46FeatureAdapter {
    static let candidateNames = V45FeatureAdapter.candidateNames
    static let globalNames = V45FeatureAdapter.globalNames

    static func recommendationSpacing(grid: ReconstructionGrid) -> Double {
        0.10 * hypot(Double(grid.nx - 1) * grid.spacingMeters,
                     Double(grid.ny - 1) * grid.northSpacingMeters)
    }

    static func build(volume: ReconstructionVolume, contract: V46Contract,
                      accessMask: [Bool]? = nil, minimumSpacingMeters: Double? = nil,
                      occupiedMeters: [Point2]? = nil) throws -> V42State {
        let grid = volume.grid
        let nx = grid.nx, ny = grid.ny, nz = grid.nz
        let dx = grid.spacingMeters, dy = grid.northSpacingMeters, dz = grid.depthSpacingMeters
        guard nx >= 2, ny >= 2, nz >= 2, [dx,dy,dz].allSatisfy({ $0.isFinite && $0 > 0 }),
              volume.values.count == grid.voxelCount, volume.observed.count == grid.voxelCount,
              volume.validXY.count == nx * ny,
              accessMask == nil || accessMask?.count == nx * ny,
              minimumSpacingMeters == nil || (minimumSpacingMeters!.isFinite && minimumSpacingMeters! >= 0),
              contract.input.combinedOrder.count == 29 else {
            throw MLIntegrationError.invalidInput("DQN V4.6-A grid, access mask, or feature contract")
        }
        func xy(_ x: Int, _ y: Int) -> Int { grid.xyIndex(x:x,y:y) }
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int { grid.index(x:x,y:y,z:z) }
        var sites = [(Int,Int)]()
        var validCount = 0, observedCount = 0
        var globalValues = [Double]()
        var profileMeans = [Double](repeating: 0, count: nx * ny)
        let meanIc = contract.normalization.schemaGANMean
        let stdIc = contract.normalization.schemaGANStd
        for x in 0..<nx { for y in 0..<ny {
            let cell = xy(x,y)
            guard volume.validXY[cell] else { continue }
            validCount += 1
            var sum = 0.0, hasObserved = false
            for z in 0..<nz {
                let i = index(x,y,z)
                let value = Double(volume.values[i])
                guard value.isFinite else { throw MLIntegrationError.invalidInput("Nonfinite V4.6-A reconstruction") }
                sum += value
                globalValues.append((value - meanIc) / stdIc)
                if volume.observed[i] { observedCount += 1; hasObserved = true }
            }
            profileMeans[cell] = sum / Double(nz)
            if hasObserved { sites.append((x,y)) }
        } }
        guard validCount > 0, !sites.isEmpty, observedCount <= validCount * nz else {
            throw MLIntegrationError.invalidInput("DQN V4.6-A needs valid grid cells and measured CPT")
        }
        func average(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0,+) / Double(values.count)
        }
        func deviation(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let avg = average(values)
            return sqrt(values.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(values.count))
        }
        let global: [Float] = [
            Float(log1p(Double(sites.count)) / max(log1p(Double(validCount)), 1e-6)),
            Float(log1p(Double(nx) * dx / 32)), Float(log1p(Double(ny) * dy / 32)),
            Float(log1p(Double(nz) * dz / 16)),
            Float(log1p(dx / 2)), Float(log1p(dy / 2)), Float(log1p(dz / 2)),
            Float(average(globalValues)), Float(deviation(globalValues)),
            Float(Double(validCount) / Double(nx * ny)),
            Float(Double(observedCount) / Double(validCount * nz))
        ]
        let diagonal = hypot(Double(nx) * dx, Double(ny) * dy)
        let radius = max(4.0, 2.0 * max(dx,dy))
        let radiusX = Int(ceil(radius / dx)), radiusY = Int(ceil(radius / dy))
        let occupied = occupiedMeters ?? sites.map { Point2(x: volume.east(x:$0.0), y: volume.north(y:$0.1)) }
        var candidates = [V42Candidate]()
        for x in 0..<nx { for y in 0..<ny {
            let cell = xy(x,y)
            guard volume.validXY[cell], accessMask?[cell] ?? true,
                  !sites.contains(where: { $0.0 == x && $0.1 == y }) else { continue }
            let east = volume.east(x:x), north = volume.north(y:y)
            if let minimumSpacingMeters,
               occupied.contains(where: { hypot(east - $0.x, north - $0.y) < minimumSpacingMeters }) { continue }
            let nearest = sites.map { hypot(Double(x - $0.0) * dx, Double(y - $0.1) * dy) }.min()!
            var neighborhoodCount = 0, observedNearby = 0
            var surroundingCount = 0, surroundingValid = 0
            var surroundingValues = [Double]()
            for xx in max(0,x-radiusX)..<min(nx,x+radiusX+1) {
                for yy in max(0,y-radiusY)..<min(ny,y+radiusY+1) {
                    guard hypot(Double(x - xx) * dx, Double(y - yy) * dy) <= radius + 1e-9 else { continue }
                    neighborhoodCount += 1
                    if sites.contains(where: { $0.0 == xx && $0.1 == yy }) { observedNearby += 1 }
                    guard xx != x || yy != y else { continue }
                    surroundingCount += 1
                    if volume.validXY[xy(xx,yy)] {
                        surroundingValid += nz
                        for z in 0..<nz {
                            surroundingValues.append((Double(volume.ic(x:xx,y:yy,z:z)) - meanIc) / stdIc)
                        }
                    }
                }
            }
            // Python falls back to the full neighborhood if no surrounding valid voxel exists.
            if surroundingValid == 0 {
                surroundingCount = neighborhoodCount
                surroundingValid = nz
                surroundingValues = (0..<nz).map { (Double(volume.ic(x:x,y:y,z:$0)) - meanIc) / stdIc }
            }
            let profile = (0..<nz).map { (Double(volume.ic(x:x,y:y,z:$0)) - meanIc) / stdIc }
            var binMeans = [Double](), binEmpty = [Double]()
            let quotient = nz / 4, remainder = nz % 4
            for bin in 0..<4 {
                let start = bin * quotient + min(bin, remainder)
                let length = quotient + (bin < remainder ? 1 : 0)
                let values = Array(profile[start..<(start + length)])
                binMeans.append(average(values))
                binEmpty.append(values.isEmpty ? 1 : 0)
            }
            func axisGradient(_ eastAxis: Bool) -> Double {
                var total = 0.0, count = 0
                for offset in [-1,1] {
                    let xx = eastAxis ? x + offset : x
                    let yy = eastAxis ? y : y + offset
                    guard (0..<nx).contains(xx), (0..<ny).contains(yy), volume.validXY[xy(xx,yy)] else { continue }
                    total += abs(profileMeans[xy(xx,yy)] - profileMeans[cell]) / (eastAxis ? dx : dy)
                    count += 1
                }
                return count == 0 ? 0 : total / Double(count)
            }
            let gradient = hypot(axisGradient(true), axisGradient(false)) / max(stdIc, 1e-6)
            let local: [Float] = [
                Float(Double(x) / Double(max(nx - 1, 1))),
                Float(Double(y) / Double(max(ny - 1, 1))),
                Float(min(nearest / max(diagonal,1e-6), 1)),
                Float(Double(observedNearby) / Double(max(neighborhoodCount,1))),
                1, Float(average(profile)), Float(deviation(profile))
            ] + binMeans.map(Float.init) + binEmpty.map(Float.init) + [
                Float(average(surroundingValues)),
                Float(Double(surroundingValid) / Double(max(surroundingCount * nz, 1))),
                Float(gradient)
            ]
            guard local.count == 18, local.allSatisfy(\.isFinite) else {
                throw MLIntegrationError.invalidInput("DQN V4.6-A candidate features")
            }
            candidates.append(.init(x:x,y:y,local:local))
        } }
        guard global.count == 11, global.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidInput("DQN V4.6-A global features")
        }
        #if DEBUG
        // These counts distinguish polygon/terrain clipping from access-mask filtering.
        var gridCells = [Int](repeating: 0, count: 3)
        var validCells = [Int](repeating: 0, count: 3)
        var accessibleValidCells = [Int](repeating: 0, count: 3)
        var legalCells = [Int](repeating: 0, count: 3)
        for x in 0..<nx { for y in 0..<ny {
            let group = min(2, x * 3 / nx), cell = xy(x,y)
            gridCells[group] += 1
            if volume.validXY[cell] {
                validCells[group] += 1
                if accessMask?[cell] ?? true { accessibleValidCells[group] += 1 }
            }
        } }
        for candidate in candidates { legalCells[min(2, candidate.x * 3 / nx)] += 1 }
        for group in 0..<3 {
            let label = ["LEFT", "MIDDLE", "RIGHT"][group]
            print("[DQN V4.6-A] \(label) grid cells=\(gridCells[group]), validMask accepted=\(validCells[group]), accessMask accepted=\(accessibleValidCells[group]), legal candidates=\(legalCells[group])")
        }
        let spacingDescription = minimumSpacingMeters.map { String($0) } ?? "none"
        print("[DQN V4.6-A] accessMask=\(accessMask == nil ? "none" : "provided"); minimum spacing=\(spacingDescription) m")
        #endif
        return .init(candidates:candidates,global:global)
    }
}

actor V46DQNService {
    private let model: MLModel
    private var didLogOutputShape = false

    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource: "DQN_V4_6_A", withExtension: "mlmodelc") else {
            throw MLIntegrationError.missingModel("DQN_V4_6_A")
        }
        #if DEBUG
        print("DQN V4.6-A model loading: \(url.lastPathComponent)")
        #endif
        model = try MLModel(contentsOf: url)
        #if DEBUG
        print("DQN V4.6-A model loaded; input=\(model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape.description ?? "missing"), output=\(model.modelDescription.outputDescriptionsByName["q_values"]?.multiArrayConstraint?.shape.description ?? "missing")")
        #endif
        guard let input = model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint,
              input.shape.last?.intValue == 29,
              model.modelDescription.outputDescriptionsByName["q_values"] != nil else {
            throw MLIntegrationError.invalidContract("DQN V4.6-A features [N,29] / q_values")
        }
    }

    func score(_ features: [Float]) throws -> Float {
        guard features.count == 29, features.allSatisfy(\.isFinite) else {
            throw MLIntegrationError.invalidInput("DQN V4.6-A requires exactly 29 finite features")
        }
        let array = try MLMultiArray(shape: [1,29], dataType: .float32)
        for i in features.indices { array[i] = NSNumber(value: features[i]) }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": array]))
        guard let output = result.featureValue(for: "q_values")?.multiArrayValue,
              output.count == 1, output[0].floatValue.isFinite else {
            throw MLIntegrationError.invalidOutput("DQN V4.6-A Q-value")
        }
        #if DEBUG
        if !didLogOutputShape {
            print("DQN V4.6-A CoreML runtime output shape=\(output.shape)")
            didLogOutputShape = true
        }
        #endif
        return output[0].floatValue
    }

    func best(_ state: V42State, volume: ReconstructionVolume? = nil,
              measuredCPT: [GeoPoint]? = nil) throws -> (candidate: V42Candidate, score: Float)? {
        guard state.global.count == 11 else { throw MLIntegrationError.invalidInput("DQN V4.6-A global context") }
        var best: (candidate: V42Candidate, score: Float)?
        var minimumQ = Float.infinity, maximumQ = -Float.infinity
        #if DEBUG
        var scored = [(candidate: V42Candidate, q: Float, index: Int)]()
        scored.reserveCapacity(state.candidates.count)
        #endif
        for candidate in state.candidates {
            try Task.checkCancellation()
            let row = candidate.local + state.global
            guard row.count == 29 else { throw MLIntegrationError.invalidInput("DQN V4.6-A feature count \(row.count), expected 29") }
            let q = try score(row)
            minimumQ = min(minimumQ, q); maximumQ = max(maximumQ, q)
            #if DEBUG
            scored.append((candidate, q, scored.count))
            #endif
            // Python's np.argmax keeps the first x,y-ordered candidate on ties.
            if best == nil || q > best!.score { best = (candidate,q) }
        }
        #if DEBUG
        if let best {
            print("DQN V4.6-A legal candidates=\(state.candidates.count), features=29, CoreML input=[1,29], output=[1], Q range=[\(minimumQ),\(maximumQ)], argmax=(\(best.candidate.x),\(best.candidate.y)), Q=\(best.score)")
            if let volume {
                let grid = volume.grid, nx = grid.nx, ny = grid.ny, nz = grid.nz
                let sites = (0..<nx).flatMap { x in (0..<ny).compactMap { y -> (Int, Int)? in
                    (0..<nz).contains { volume.observed[grid.index(x:x,y:y,z:$0)] } ? (x,y) : nil
                } }
                let originalSites = measuredCPT?.map { CoordinateTransformer.localMeters($0, origin: volume.terrainOrigin) }
                func nearestMeters(_ candidate: V42Candidate) -> Double {
                    if let originalSites, !originalSites.isEmpty {
                        return originalSites.map { hypot(volume.east(x:candidate.x) - $0.x,
                                                         volume.north(y:candidate.y) - $0.y) }.min() ?? .nan
                    }
                    return sites.map { hypot(Double(candidate.x - $0.0) * grid.spacingMeters,
                                             Double(candidate.y - $0.1) * grid.northSpacingMeters) }.min() ?? .nan
                }
                var grouped = [(count: Int, sumQ: Double, maxQ: Double, sumNearest: Double)](
                    repeating: (0, 0, -.infinity, 0), count: 3)
                var minNearest = Double.infinity, maxNearest = -Double.infinity, sumNearest = 0.0
                for item in scored {
                    let distance = nearestMeters(item.candidate)
                    let group = min(2, item.candidate.x * 3 / nx)
                    grouped[group].count += 1
                    grouped[group].sumQ += Double(item.q)
                    grouped[group].maxQ = max(grouped[group].maxQ, Double(item.q))
                    grouped[group].sumNearest += distance
                    minNearest = min(minNearest, distance)
                    maxNearest = max(maxNearest, distance)
                    sumNearest += distance
                }
                print("[DQN V4.6-A] legal total=\(scored.count); distance reference=\(originalSites == nil ? "model-grid CPT centers" : "original map CPT coordinates"); nearest CPT distance min/mean/max=\(minNearest)/\(sumNearest / Double(scored.count))/\(maxNearest) m")
                for group in 0..<3 {
                    let item = grouped[group], label = ["LEFT", "MIDDLE", "RIGHT"][group]
                    print("[DQN V4.6-A] \(label): count=\(item.count), mean Q=\(item.count > 0 ? item.sumQ / Double(item.count) : .nan), max Q=\(item.maxQ), mean nearest CPT=\(item.count > 0 ? item.sumNearest / Double(item.count) : .nan) m")
                }
                let left = CoordinateTransformer.geographic(east: volume.east(x:0), north: volume.north(y:0), origin:volume.terrainOrigin)
                let right = CoordinateTransformer.geographic(east: volume.east(x:nx-1), north: volume.north(y:0), origin:volume.terrainOrigin)
                let south = CoordinateTransformer.geographic(east: volume.east(x:0), north: volume.north(y:0), origin:volume.terrainOrigin)
                let north = CoordinateTransformer.geographic(east: volume.east(x:0), north: volume.north(y:ny-1), origin:volume.terrainOrigin)
                print("[DQN V4.6-A] orientation: x=0 east=\(volume.east(x:0)) m lon=\(left.longitude); x=\(nx-1) east=\(volume.east(x:nx-1)) m lon=\(right.longitude); y=0 north=\(volume.north(y:0)) m lat=\(south.latitude); y=\(ny-1) north=\(volume.north(y:ny-1)) m lat=\(north.latitude)")
                let top = scored.sorted { $0.q == $1.q ? $0.index < $1.index : $0.q > $1.q }.prefix(20)
                for (rank, item) in top.enumerated() {
                    let candidate = item.candidate
                    print("[DQN V4.6-A] top \(rank + 1): grid=(\(candidate.x),\(candidate.y)), physical=(\(volume.east(x:candidate.x)),\(volume.north(y:candidate.y))) m, x_local_fraction=\(candidate.local[0]), y_local_fraction=\(candidate.local[1]), nearest_cpt_distance_fraction=\(candidate.local[2]), nearest CPT=\(nearestMeters(candidate)) m, Q=\(item.q)")
                }
                print("[DQN V4.6-A] selected global argmax: grid=(\(best.candidate.x),\(best.candidate.y)), nearest CPT=\(nearestMeters(best.candidate)) m, Q=\(best.score)")
            }
        } else { print("DQN V4.6-A no recommendation: legal candidate count=0") }
        #endif
        return best
    }
}

struct V46Recommendation: Sendable {
    let coordinate: GeoPoint
    let qValue: Float
    let candidateX: Int
    let candidateY: Int
    let legalCount: Int
}

enum V46RecommendationService {
    static func recommend(volume: ReconstructionVolume, terrain: TerrainMesh,
                          accessMask: [Bool]? = nil, minimumSpacingMeters: Double? = nil,
                          measuredCPT: [GeoPoint]? = nil,
                          modelURL: URL? = nil, contractURL: URL? = nil) async throws -> V46Recommendation? {
        let contract = try contractURL.map { try V46Contract(data: Data(contentsOf: $0)) } ?? V46Contract.bundled()
        let occupied = measuredCPT?.map { CoordinateTransformer.localMeters($0, origin: volume.terrainOrigin) }
        let state = try V46FeatureAdapter.build(volume: volume, contract: contract,
                                                accessMask: accessMask,
                                                minimumSpacingMeters: minimumSpacingMeters,
                                                occupiedMeters: occupied)
        let scorer = try V46DQNService(modelURL: modelURL)
        guard let best = try await scorer.best(state, volume: volume, measuredCPT: measuredCPT) else { return nil }
        let coordinate = CoordinateTransformer.geographic(east: volume.east(x:best.candidate.x),
                                                          north: volume.north(y:best.candidate.y),
                                                          origin: terrain.origin)
        guard terrain.surfacePosition(at: coordinate) != nil else {
            throw MLIntegrationError.invalidOutput("DQN V4.6-A candidate coordinate")
        }
        return .init(coordinate: coordinate, qValue: best.score,
                     candidateX: best.candidate.x, candidateY: best.candidate.y,
                     legalCount: state.candidates.count)
    }
}
