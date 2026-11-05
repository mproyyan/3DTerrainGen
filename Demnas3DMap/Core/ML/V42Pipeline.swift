import CoreML
import Foundation

/// The flexible Core ML export accepts [1,7,nz,ny,nx], with x/y 16...96 and z 8...32.
/// Values are stored in contiguous [Z,Y,X] order. Grid spacing is measured in metres.
struct V42GridPlan: Sendable {
    let nx: Int
    let ny: Int
    let nz: Int
    let horizontalMeters: Double
    let northMeters: Double
    let depthMeters: Double
    static let minXY = 16, maxXY = 96, minZ = 8, maxZ = 32

    static func make(extent: MetricExtent, points: [CPTPoint], preferredMeters: Double? = nil,
                     preferredNorthMeters: Double? = nil, preferredDepthMeters: Double = 1) throws -> Self {
        let preferred = preferredMeters ?? (max(extent.width, extent.height) <= 24.0001 ? 1 : 5)
        let preferredNorth = preferredNorthMeters ?? preferred
        guard preferred.isFinite, preferred > 0, preferredNorth.isFinite, preferredNorth > 0,
              preferredDepthMeters.isFinite, preferredDepthMeters > 0,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw MLIntegrationError.invalidInput("Resolusi atau ukuran area V4.2 tidak valid.")
        }
        // A coarser physical spacing keeps every cell in the polygon's bounding rectangle
        // within the model limit, without imposing a fixed maximum area in metres.
        let spacingX = max(min(preferred,extent.width/2), extent.width / Double(maxXY))
        let spacingY = max(min(preferredNorth,extent.height/2), extent.height / Double(maxXY))
        let nx = max(minXY, Int(ceil(extent.width / spacingX - 1e-8)))
        let ny = max(minXY, Int(ceil(extent.height / spacingY - 1e-8)))
        guard nx <= maxXY, ny <= maxXY else {
            throw MLIntegrationError.invalidInput("Grid V4.2 melampaui 96 × 96 sel.")
        }
        let deepest = points.compactMap { $0.interpretation?.values.last?.depth }.max() ?? 0
        guard deepest.isFinite, deepest > 0 else {
            throw MLIntegrationError.invalidInput("Kedalaman CPT tidak valid.")
        }
        let spacingZ = max(preferredDepthMeters, deepest / Double(maxZ))
        let required = max(minZ, Int(ceil(deepest / spacingZ)))
        let nz = [8, 12, 16, 24, 32].first(where: { $0 >= required }) ?? maxZ
        return .init(nx:nx, ny:ny, nz:nz, horizontalMeters:spacingX,
                     northMeters:spacingY, depthMeters:spacingZ)
    }
}

struct V42Input: Sendable {
    static let mean: Float = 2.7903323310879604
    static let std: Float = 0.7723778445702414
    let nx: Int
    let ny: Int
    let nz: Int
    let horizontalMeters: Double
    let northMeters: Double
    let depthMeters: Double
    let origin: GeoPoint
    let west: Double
    let south: Double
    let observedIc: [Float]
    let observed: [Bool]
    let validXY: [Bool]
    let features: [Float]
    var count: Int { nx * ny * nz }
    func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }
    func xy(_ x: Int, _ y: Int) -> Int { y * nx + x }
    func east(_ x: Int) -> Double { west + (Double(x) + 0.5) * horizontalMeters }
    func north(_ y: Int) -> Double { south + (Double(y) + 0.5) * northMeters }

    static func prepare(terrain: TerrainMesh, boundary: [GeoPoint], points: [CPTPoint],
                        preferredMeters: Double? = nil, preferredNorthMeters: Double? = nil,
                        preferredDepthMeters: Double = 1) throws -> Self {
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty, complete.count == points.count else {
            throw MLIntegrationError.invalidInput("SchemaGAN V4.2 menunggu minimal satu profil CPT lengkap.")
        }
        let extent = try MetricExtent(boundary: boundary, origin: terrain.origin)
        let plan = try V42GridPlan.make(extent: extent, points: complete, preferredMeters: preferredMeters,
                                        preferredNorthMeters: preferredNorthMeters,
                                        preferredDepthMeters: preferredDepthMeters)
        let nx = plan.nx, ny = plan.ny, nz = plan.nz
        let spacing = plan.horizontalMeters, northSpacing = plan.northMeters, depthSpacing = plan.depthMeters
        let count = nx * ny * nz
        let west = (extent.west + extent.east - Double(nx) * spacing) / 2
        let south = (extent.south + extent.north - Double(ny) * northSpacing) / 2
        let polygon = boundary.map { CoordinateTransformer.localMeters($0, origin: terrain.origin) }
        var validXY = [Bool](repeating: false, count: nx * ny)
        func index(_ x:Int,_ y:Int,_ z:Int) -> Int { (z * ny + y) * nx + x }
        func xy(_ x:Int,_ y:Int) -> Int { y * nx + x }
        for x in 0..<nx { for y in 0..<ny {
            let east = west + (Double(x) + 0.5) * spacing
            let north = south + (Double(y) + 0.5) * northSpacing
            validXY[xy(x,y)] = Geometry.contains(.init(x:east,y:north), in:polygon)
                && terrain.surfacePosition(x:Float(east), z:Float(-north)) != nil
        } }
        guard validXY.contains(true) else { throw MLIntegrationError.invalidInput("Tidak ada pusat sel V4.2 di dalam poligon.") }
        var observedIc = [Float](repeating: 0, count: count)
        var observed = [Bool](repeating: false, count: count)
        var sites = [(x:Int,y:Int)]()
        for point in complete {
            let local = CoordinateTransformer.localMeters(point.coordinate, origin:terrain.origin)
            let x = Int(floor((local.x - west) / spacing))
            let y = Int(floor((local.y - south) / northSpacing))
            guard (0..<nx).contains(x), (0..<ny).contains(y), validXY[xy(x,y)] else {
                throw MLIntegrationError.invalidInput("\(point.name): posisi CPT tidak jatuh pada sel valid grid V4.2; ubah area atau resolusi.")
            }
            guard !sites.contains(where: { $0.x == x && $0.y == y }) else {
                throw MLIntegrationError.invalidInput(String(format: "Dua CPT berada pada sel %.2f × %.2f m yang sama; V4.2 tidak dapat mewakilinya sebagai situs terpisah.", spacing, northSpacing))
            }
            guard let values = point.interpretation?.values, values.count >= 2 else {
                throw MLIntegrationError.invalidInput("\(point.name): profil Ic belum tersedia.")
            }
            sites.append((x,y))
            for z in 0..<nz {
                let target = (Double(z) + 0.5) * depthSpacing
                guard let first = values.first, let last = values.last,
                      first.depth <= target, last.depth >= target,
                      let upper = values.firstIndex(where: { $0.depth >= target }) else { continue }
                let ic: Double
                if values[upper].depth == target { ic = values[upper].ic }
                else if upper > 0 {
                    let lower = values[upper-1]
                    ic = lower.ic + (values[upper].ic-lower.ic) * (target-lower.depth)/(values[upper].depth-lower.depth)
                } else { continue }
                guard ic.isFinite else { throw MLIntegrationError.invalidInput("\(point.name): Ic tidak berhingga.") }
                let i = index(x,y,z)
                observed[i] = true; observedIc[i] = Float(ic)
            }
        }
        guard observed.contains(true) else { throw MLIntegrationError.invalidInput("Tidak ada Ic terukur pada pusat sel kedalaman V4.2.") }
        var normalized = [Float](repeating: 0, count: count)
        for i in 0..<count where observed[i] { normalized[i] = (observedIc[i] - mean) / std }
        var idw = [Float](repeating: 0, count: count)
        var hasDepth = [Bool](repeating: false, count: nz)
        for z in 0..<nz {
            let active = sites.filter { observed[index($0.x,$0.y,z)] }
            guard !active.isEmpty else { continue }
            hasDepth[z] = true
            for x in 0..<nx { for y in 0..<ny {
                let i = index(x,y,z)
                var numerator = 0.0, denominator = 0.0
                for site in active {
                    let dx = Double(x-site.x)*spacing, dy = Double(y-site.y)*northSpacing
                    let weight = 1.0 / pow(max(hypot(dx,dy), 1e-5), 2)
                    numerator += weight * Double(normalized[index(site.x,site.y,z)])
                    denominator += weight
                }
                idw[i] = Float(numerator / denominator)
            } }
        }
        for z in 0..<nz where !hasDepth[z] {
            guard let nearest = (0..<nz).filter({ hasDepth[$0] }).min(by: { abs($0-z) < abs($1-z) }) else { continue }
            for x in 0..<nx { for y in 0..<ny { idw[index(x,y,z)] = idw[index(x,y,nearest)] } }
        }
        // Match adapter.py's np.where(mask, sparse, idw): a measured Ic is exact,
        // even when several CPTs contribute to the same depth slice.
        for i in 0..<count where observed[i] { idw[i] = normalized[i] }
        var features = [Float](repeating: 0, count: count * 7)
        let logX = Float(log1p(spacing)), logY = Float(log1p(northSpacing)), logZ = Float(log1p(depthSpacing))
        for x in 0..<nx { for y in 0..<ny {
            let nearest = sites.map { hypot(Double(x-$0.x)*spacing, Double(y-$0.y)*northSpacing) }.min()!
            for z in 0..<nz {
                let i = index(x,y,z)
                features[i] = normalized[i]
                features[count+i] = observed[i] ? 1 : 0
                features[2*count+i] = idw[i]
                features[3*count+i] = Float(nearest / max(max(Double(nx)*spacing, Double(ny)*northSpacing), 1))
                features[4*count+i] = logX
                features[5*count+i] = logY
                features[6*count+i] = logZ
            }
        } }
        guard features.allSatisfy(\.isFinite) else { throw MLIntegrationError.invalidInput("Fitur SchemaGAN V4.2 tidak berhingga.") }
        return .init(nx:nx,ny:ny,nz:nz,horizontalMeters:spacing,northMeters:northSpacing,depthMeters:depthSpacing,
                     origin:terrain.origin,west:west,south:south,
                     observedIc:observedIc,observed:observed,validXY:validXY,features:features)
    }

    func volume(_ values: [Float]) throws -> ReconstructionVolume {
        guard values.count == count, values.allSatisfy(\.isFinite) else { throw MLIntegrationError.invalidOutput("SchemaGAN V4.2 Ic") }
        return ReconstructionVolume(terrainOrigin:origin, westMeters:west, southMeters:south,
            grid:.init(nx:nx,ny:ny,nz:nz,spacingMeters:horizontalMeters,
                       northSpacingMeters:northMeters,depthSpacingMeters:depthMeters),
            values:values, observed:observed, validXY:validXY,
            observationOrigins:[CPTDataOrigin?](repeating:nil,count:count),
            depthResampled:[Bool](repeating:false,count:count))
    }
}

actor V42SchemaGANService {
    private let model: MLModel
    init(bundle: Bundle = .main, modelURL: URL? = nil) throws {
        guard let url = modelURL ?? bundle.url(forResource:"SchemaGAN_V4_2_Flexible",withExtension:"mlmodelc") else {
            throw MLIntegrationError.missingModel("SchemaGAN_V4_2_Flexible")
        }
        model = try MLModel(contentsOf:url)
        guard let input = model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint,
              input.shape.map(\.intValue) == [1,7,12,24,24],
              input.shapeConstraint.sizeRangeForDimension.count == 5 else {
            throw MLIntegrationError.invalidContract("SchemaGAN V4.2 Flexible features/var_124")
        }
        let ranges = input.shapeConstraint.sizeRangeForDimension.map(\.rangeValue)
        guard
              ranges[2].location <= V42GridPlan.minZ, NSMaxRange(ranges[2]) >= V42GridPlan.maxZ + 1,
              ranges[3].location <= V42GridPlan.minXY, NSMaxRange(ranges[3]) >= V42GridPlan.maxXY + 1,
              ranges[4].location <= V42GridPlan.minXY, NSMaxRange(ranges[4]) >= V42GridPlan.maxXY + 1,
              model.modelDescription.outputDescriptionsByName["var_124"]?.multiArrayConstraint != nil else {
            throw MLIntegrationError.invalidContract("SchemaGAN V4.2 Flexible features/var_124")
        }
    }
    func reconstruct(_ input: V42Input) throws -> [Float] {
        let array = try MLMultiArray(shape:[1,7,NSNumber(value:input.nz),NSNumber(value:input.ny),NSNumber(value:input.nx)],dataType:.float32)
        for i in input.features.indices { array[i] = NSNumber(value:input.features[i]) }
        let result = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["features":array]))
        guard let output = result.featureValue(for:"var_124")?.multiArrayValue,
              output.shape.map(\.intValue) == [1,1,input.nz,input.ny,input.nx],
              output.count == input.count, output.dataType == .float32 else {
            throw MLIntegrationError.invalidOutput("SchemaGAN V4.2 Flexible output shape")
        }
        var physical = [Float](repeating:0,count:input.count)
        for i in physical.indices {
            let value = output[i].floatValue * V42Input.std + V42Input.mean
            guard value.isFinite else { throw MLIntegrationError.invalidOutput("SchemaGAN V4.2 nonfinite Ic") }
            physical[i] = input.observed[i] ? input.observedIc[i] : value
        }
        return physical
    }
}
