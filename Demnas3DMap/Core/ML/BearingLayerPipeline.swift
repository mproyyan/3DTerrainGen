import CoreML
import Foundation

struct BearingLayerResult: Sendable {
    struct Site: Sendable { let name: String; let x: Int; let y: Int }
    struct CandidateDetail: Sendable {
        let qcMPa: Double
        let ic: Double
        let nearestCPTMeters: Double
        let measuredAtCPT: Bool
        /// Presentation cue only; the frozen bearing decision is unchanged.
        let nearThreshold: Bool
    }
    struct Reliability: Sendable {
        let conditionalDepthP90Meters: Double?
        let highRiskAreaPercent: Double?
        let supportedAreaPercent: Double
        let fieldValidated: Bool
    }
    let grid: ReconstructionGrid
    let depthsYX: [Double?]
    let candidateDetailsYX: [CandidateDetail?]
    let sites: [Site]
    let qcMinimumMPa: Double
    let icMaximum: Double
    let minimumThicknessMeters: Double
    let reliability: Reliability?
}

enum BearingCandidateDetails {
    static func make(depths: [Double?], qc: [Float], ic: [Float], observed: [Bool],
                     grid: ReconstructionGrid, cptXYMeters: [Point2]) throws -> [BearingLayerResult.CandidateDetail?] {
        guard depths.count == grid.nx * grid.ny, qc.count == grid.voxelCount,
              ic.count == grid.voxelCount, observed.count == grid.voxelCount,
              !cptXYMeters.isEmpty else { throw MLIntegrationError.invalidInput("Bearing candidate detail shapes") }
        var details = [BearingLayerResult.CandidateDetail?](repeating:nil,count:depths.count)
        for y in 0..<grid.ny { for x in 0..<grid.nx {
            let xy = grid.xyIndex(x:x,y:y)
            guard let depth = depths[xy] else { continue }
            let z = Int((depth / grid.depthSpacingMeters).rounded())
            guard (0..<grid.nz).contains(z) else { throw MLIntegrationError.invalidOutput("Bearing candidate depth outside grid") }
            let i = grid.index(x:x,y:y,z:z)
            let q = Double(qc[i]), c = Double(ic[i])
            guard q.isFinite, c.isFinite else { throw MLIntegrationError.invalidOutput("Bearing candidate qc/Ic nonfinite") }
            let center = Point2(x:(Double(x)+0.5)*grid.spacingMeters,
                                y:(Double(y)+0.5)*grid.northSpacingMeters)
            let nearest = cptXYMeters.map { hypot(center.x-$0.x,center.y-$0.y) }.min()!
            // The 5% band is a qualitative display cue, not a changed model criterion or confidence.
            let near = q <= FlexibleBearingV1.qcMinimumMPa * 1.05 ||
                       c >= FlexibleBearingV1.icMaximum * 0.95
            details[xy] = .init(qcMPa:q,ic:c,nearestCPTMeters:nearest,
                                measuredAtCPT:observed[i],nearThreshold:near)
        } }
        return details
    }
}

struct QCFSNormalization: Decodable, Sendable {
    struct Qc: Decodable, Sendable { let transform: String; let mean: Double; let std: Double }
    struct Fs: Decodable, Sendable { let mean: Double; let std: Double }
    let qc: Qc
    let fs: Fs

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard qc.transform == "log1p_qc_mpa", qc.mean.isFinite, qc.std.isFinite, qc.std > 0,
              fs.mean.isFinite, fs.std.isFinite, fs.std > 0 else {
            throw MLIntegrationError.invalidContract("QC-FS normalization")
        }
    }
    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "QCFS_V3_D_Flexible_normalization", withExtension: "json") else {
            throw MLIntegrationError.missingModel("QCFS_V3_D_Flexible_normalization.json")
        }
        return try Self(data: Data(contentsOf: url))
    }
}

struct QCFSFlexibleManifest: Decodable, Sendable {
    let version: String
    let inputOrder: String
    let inputChannels: Int
    let minSpatialZYX: [Int]
    let maxSpatialZYX: [Int]
    enum CodingKeys: String, CodingKey {
        case version
        case inputOrder = "input_order"
        case inputChannels = "input_channels"
        case minSpatialZYX = "min_spatial_zyx"
        case maxSpatialZYX = "max_spatial_zyx"
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "QCFS_V3_D_Flexible_manifest", withExtension: "json") else {
            throw MLIntegrationError.missingModel("QCFS_V3_D_Flexible_manifest.json")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.version == "QCFS_CoreML_V2_Flexible", manifest.inputOrder == "B,C,Z,Y,X",
              manifest.inputChannels == 9, manifest.minSpatialZYX == [8,16,16],
              manifest.maxSpatialZYX == [32,128,128] else {
            throw MLIntegrationError.invalidContract("QC-FS Flexible V2 manifest")
        }
        return manifest
    }

    func validate(_ grid: ReconstructionGrid) throws {
        let shape = [grid.nz, grid.ny, grid.nx]
        guard zip(shape.indices, shape).allSatisfy({ index, value in
            (minSpatialZYX[index]...maxSpatialZYX[index]).contains(value)
        }) else {
            throw MLIntegrationError.invalidInput("QC-FS Flexible V2 mendukung Z 8–32, Y/X 16–128; grid proyek saat ini \(grid.nx) × \(grid.ny) × \(grid.nz). Tidak dilakukan resize.")
        }
    }
}

struct QCFSPreparedInput: Sendable {
    let grid: ReconstructionGrid
    let features: [Float]
    let sites: [BearingLayerResult.Site]
    let observedQC: [Float]
    let observedFS: [Float]
    let observed: [Bool]

    static func prepare(volume: ReconstructionVolume, points: [CPTPoint], boundary: [GeoPoint],
                        normalization: QCFSNormalization, manifest: QCFSFlexibleManifest) throws -> Self {
        let grid = volume.grid
        try manifest.validate(grid)
        guard volume.values.count == grid.voxelCount, volume.observed.count == grid.voxelCount,
              volume.validXY.count == grid.nx * grid.ny else {
            throw MLIntegrationError.invalidInput("Volume Ic dan mask QC-FS tidak sesuai grid")
        }
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty else { throw MLIntegrationError.invalidInput("Bearing Layer memerlukan minimal satu CPT dengan qc/fs tersimpan.") }
        let polygon = boundary.map { CoordinateTransformer.localMeters($0, origin: volume.terrainOrigin) }
        var sites = [BearingLayerResult.Site]()
        var qcProfiles = [[Float]](), fsProfiles = [[Float]]()
        var measuredQC = [Float](repeating: 0, count: grid.voxelCount)
        var measuredFS = measuredQC
        var mask = [Bool](repeating: false, count: grid.voxelCount)
        for point in complete {
            guard !point.csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MLIntegrationError.invalidInput("\(point.name): profil qc/fs belum tersimpan; Ic saja tidak cukup untuk Bearing Layer.")
            }
            let samples = try CPTProcessor.parse(point.csv)
            let local = CoordinateTransformer.localMeters(point.coordinate, origin: volume.terrainOrigin)
            let mapped = try V42CPTGridMapper.map(local, name: point.name, polygon: polygon,
                west: volume.westMeters, south: volume.southMeters,
                nx: grid.nx, ny: grid.ny, dx: grid.spacingMeters,
                dy: grid.northSpacingMeters, validXY: volume.validXY)
            guard !sites.contains(where: { $0.x == mapped.x && $0.y == mapped.y }) else {
                throw MLIntegrationError.invalidInput("Dua CPT jatuh pada sel QC-FS yang sama.")
            }
            var qc = [Float](), fs = [Float]()
            for z in 0..<grid.nz {
                let index = grid.index(x: mapped.x, y: mapped.y, z: z)
                let depth = (Double(z) + 0.5) * grid.depthSpacingMeters
                guard volume.observed[index], let first = samples.first, let last = samples.last,
                      first.depth <= depth, last.depth >= depth,
                      let upper = samples.firstIndex(where: { $0.depth >= depth }) else {
                    throw MLIntegrationError.invalidInput("\(point.name): QC-FS V3-D memerlukan profil qc/fs penuh hingga \(String(format: "%.2f", (Double(grid.nz)-0.5)*grid.depthSpacingMeters)) m pada grid aktif.")
                }
                let q: Double, f: Double
                if samples[upper].depth == depth {
                    q = samples[upper].qcMPa; f = samples[upper].fsKPa
                } else if upper > 0 {
                    let a = samples[upper-1], b = samples[upper]
                    let t = (depth - a.depth) / (b.depth - a.depth)
                    q = a.qcMPa + t * (b.qcMPa - a.qcMPa)
                    f = a.fsKPa + t * (b.fsKPa - a.fsKPa)
                } else {
                    throw MLIntegrationError.invalidInput("\(point.name): profil qc/fs tidak mencakup pusat sel kedalaman.")
                }
                guard q.isFinite, f.isFinite, q >= 0, f >= 0 else {
                    throw MLIntegrationError.invalidInput("\(point.name): qc/fs tidak valid.")
                }
                qc.append(Float((log1p(q) - normalization.qc.mean) / normalization.qc.std))
                fs.append(Float((log1p(f) - normalization.fs.mean) / normalization.fs.std))
                measuredQC[index] = Float(q); measuredFS[index] = Float(f); mask[index] = true
            }
            sites.append(.init(name: point.name, x: mapped.x, y: mapped.y))
            qcProfiles.append(qc); fsProfiles.append(fs)
        }
        let count = grid.voxelCount
        var features = [Float](repeating: 0, count: 9 * count)
        let logX = Float(log1p(grid.spacingMeters)), logY = Float(log1p(grid.northSpacingMeters))
        let logZ = Float(log1p(grid.depthSpacingMeters))
        let scale = max(Double(grid.nx) * grid.spacingMeters,
                        Double(grid.ny) * grid.northSpacingMeters, 1)
        for y in 0..<grid.ny { for x in 0..<grid.nx {
            let distances = sites.map { hypot(Double(x-$0.x) * grid.spacingMeters,
                                               Double(y-$0.y) * grid.northSpacingMeters) }
            let weights = distances.map { 1 / pow(max($0, 1e-5), 2) }
            let weightSum = weights.reduce(0, +)
            for z in 0..<grid.nz {
                let i = grid.index(x: x, y: y, z: z)
                let qcIDW = zip(weights, qcProfiles).reduce(0.0) { $0 + $1.0 * Double($1.1[z]) } / weightSum
                let fsIDW = zip(weights, fsProfiles).reduce(0.0) { $0 + $1.0 * Double($1.1[z]) } / weightSum
                let observed = mask[i]
                let measuredSite = sites.firstIndex(where: { $0.x == x && $0.y == y })
                features[i] = observed ? qcProfiles[measuredSite!][z] : 0
                features[count+i] = observed ? 1 : 0
                features[2*count+i] = observed ? features[i] : Float(qcIDW)
                features[3*count+i] = Float((distances.min() ?? 0) / scale)
                features[4*count+i] = logX
                features[5*count+i] = logY
                features[6*count+i] = logZ
                features[7*count+i] = observed ? fsProfiles[measuredSite!][z] : 0
                features[8*count+i] = observed ? features[7*count+i] : Float(fsIDW)
            }
        } }
        guard features.allSatisfy(\.isFinite) else { throw MLIntegrationError.invalidInput("Fitur QC-FS tidak berhingga.") }
        return .init(grid:grid,features:features,sites:sites,observedQC:measuredQC,
                     observedFS:measuredFS,observed:mask)
    }
}

struct QCFSFlexibleV2Service {
    let model: MLModel
    let normalization: QCFSNormalization
    let manifest: QCFSFlexibleManifest

    init(bundle: Bundle = .main) throws {
        normalization = try QCFSNormalization.bundled(bundle)
        manifest = try QCFSFlexibleManifest.bundled(bundle)
        guard let url = bundle.url(forResource: "QC_FS_V3_D_Flexible", withExtension: "mlmodelc") else {
            throw MLIntegrationError.missingModel("QC_FS_V3_D_Flexible.mlmodelc")
        }
        model = try MLModel(contentsOf: url)
        guard model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,9,24,24,24],
              model.modelDescription.outputDescriptionsByName["qc_normalized"]?.type == .multiArray,
              model.modelDescription.outputDescriptionsByName["fs_normalized"]?.type == .multiArray else {
            throw MLIntegrationError.invalidContract("QC-FS Flexible V2 input/output names or base shape")
        }
    }

    func predict(_ input: QCFSPreparedInput) throws -> (qc: [Float], fs: [Float]) {
        try manifest.validate(input.grid)
        let tensor = try MLMultiArray(shape:[1,9,NSNumber(value:input.grid.nz),NSNumber(value:input.grid.ny),NSNumber(value:input.grid.nx)],dataType:.float32)
        guard input.features.count == tensor.count else { throw MLIntegrationError.invalidInput("QC-FS Flexible V2 9-channel input size") }
        for i in input.features.indices { tensor[i] = NSNumber(value:input.features[i]) }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary:["features":tensor]))
        guard let qcArray = output.featureValue(for:"qc_normalized")?.multiArrayValue,
              let fsArray = output.featureValue(for:"fs_normalized")?.multiArrayValue,
              qcArray.shape.map(\.intValue) == [1,1,input.grid.nz,input.grid.ny,input.grid.nx],
              fsArray.shape.map(\.intValue) == [1,1,input.grid.nz,input.grid.ny,input.grid.nx] else {
            throw MLIntegrationError.invalidOutput("QC-FS Flexible V2 output shape")
        }
        var qc = [Float](repeating:0,count:input.grid.voxelCount)
        var fs = qc
        for i in qc.indices {
            let qcLog = min(6, max(0, Double(qcArray[i].floatValue) * normalization.qc.std + normalization.qc.mean))
            let fsLog = Double(fsArray[i].floatValue) * normalization.fs.std + normalization.fs.mean
            let q = expm1(qcLog), f = max(0, expm1(fsLog))
            guard q.isFinite, f.isFinite else { throw MLIntegrationError.invalidOutput("QC-FS Flexible V2 nonfinite output") }
            qc[i] = input.observed[i] ? input.observedQC[i] : Float(q)
            fs[i] = input.observed[i] ? input.observedFS[i] : Float(f)
        }
        return (qc, fs)
    }
}

enum FlexibleBearingV1 {
    static let qcMinimumMPa = 10.0
    static let icMaximum = 2.2
    static let minimumThicknessMeters = 1.0

    static func depths(qc: [Float], ic: [Float], validXY: [Bool], grid: ReconstructionGrid) throws -> [Double?] {
        guard qc.count == grid.voxelCount, ic.count == grid.voxelCount,
              validXY.count == grid.nx * grid.ny, grid.depthSpacingMeters > 0 else {
            throw MLIntegrationError.invalidInput("Bearing V1 input shapes")
        }
        let needed = max(1, Int(ceil(minimumThicknessMeters / grid.depthSpacingMeters - 1e-9)))
        var output = [Double?](repeating:nil,count:grid.nx*grid.ny)
        guard needed <= grid.nz else { return output }
        for y in 0..<grid.ny { for x in 0..<grid.nx where validXY[grid.xyIndex(x:x,y:y)] {
            var run = 0
            for z in 0..<grid.nz {
                let i = grid.index(x:x,y:y,z:z)
                guard qc[i].isFinite, ic[i].isFinite else { throw MLIntegrationError.invalidInput("Bearing V1 nonfinite valid voxel") }
                run = Double(qc[i]) >= qcMinimumMPa && Double(ic[i]) <= icMaximum ? run+1 : 0
                if run >= needed {
                    output[grid.xyIndex(x:x,y:y)] = Double(z-needed+1) * grid.depthSpacingMeters
                    break
                }
            }
        } }
        return output
    }
}

struct BearingReliabilityLookup: Decodable, Sendable {
    struct Criteria: Decodable, Sendable {
        let qcMinMPa: Double; let icMax: Double; let minThicknessM: Double
        enum CodingKeys: String, CodingKey {
            case qcMinMPa = "qc_min_mpa", icMax = "ic_max", minThicknessM = "min_thickness_m"
        }
    }
    struct Row: Decodable, Sendable {
        let cpt: Int
        let distanceMinM: Double
        let distanceMaxM: Double?
        let estimatedDetectionRisk: Double?
        let conditionalDepthP90M: Double?
        let supported: Bool
        enum CodingKeys: String, CodingKey {
            case cpt, supported
            case distanceMinM = "distance_min_m", distanceMaxM = "distance_max_m"
            case estimatedDetectionRisk = "estimated_detection_risk"
            case conditionalDepthP90M = "conditional_depth_p90_m"
        }
    }
    let version: String
    let criteria: Criteria
    let highRiskThreshold: Double
    let fieldValidated: Bool
    let lookup: [Row]
    enum CodingKeys: String, CodingKey {
        case version, criteria, lookup
        case highRiskThreshold = "high_risk_threshold", fieldValidated = "field_validated"
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource:"bearing_reliability_lookup",withExtension:"json") else {
            throw MLIntegrationError.missingModel("bearing_reliability_lookup.json")
        }
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
    }

    func summarize(depths: [Double?], validXY: [Bool], sites: [BearingLayerResult.Site],
                   grid: ReconstructionGrid, qcMinimum: Double, icMaximum: Double,
                   thickness: Double) -> BearingLayerResult.Reliability? {
        guard version == "BearingReliability_V1", !fieldValidated,
              abs(criteria.qcMinMPa-qcMinimum) < 1e-9,
              abs(criteria.icMax-icMaximum) < 1e-9,
              abs(criteria.minThicknessM-thickness) < 1e-9,
              !sites.isEmpty, depths.count == grid.nx*grid.ny,
              validXY.count == depths.count else { return nil }
        let rows = lookup.filter { $0.cpt == sites.count }
        guard !rows.isEmpty else { return nil }
        var supported = 0, highRisk = 0, total = 0
        var p90: Double?
        for y in 0..<grid.ny { for x in 0..<grid.nx where validXY[grid.xyIndex(x:x,y:y)] {
            total += 1
            let nearest = sites.map { hypot(Double(x-$0.x)*grid.spacingMeters,
                                            Double(y-$0.y)*grid.northSpacingMeters) }.min()!
            guard let row = rows.first(where: { nearest >= $0.distanceMinM &&
                nearest < ($0.distanceMaxM ?? .infinity) }), row.supported,
                let risk = row.estimatedDetectionRisk, let depthP90 = row.conditionalDepthP90M,
                risk.isFinite, depthP90.isFinite else { continue }
            supported += 1
            if risk >= highRiskThreshold { highRisk += 1 }
            if depths[grid.xyIndex(x:x,y:y)] != nil { p90 = max(p90 ?? depthP90, depthP90) }
        } }
        guard total > 0, supported > 0 else { return nil }
        return .init(conditionalDepthP90Meters:p90,
                     highRiskAreaPercent:100*Double(highRisk)/Double(supported),
                     supportedAreaPercent:100*Double(supported)/Double(total),
                     fieldValidated:fieldValidated)
    }
}

enum BearingLayerPipeline {
    static func run(volume: ReconstructionVolume, points: [CPTPoint], boundary: [GeoPoint],
                    bundle: Bundle = .main) throws -> BearingLayerResult {
        let service = try QCFSFlexibleV2Service(bundle:bundle)
        let input = try QCFSPreparedInput.prepare(volume:volume,points:points,boundary:boundary,
                                                  normalization:service.normalization,manifest:service.manifest)
        let prediction = try service.predict(input)
        let depths = try FlexibleBearingV1.depths(qc:prediction.qc,ic:volume.values,
                                                   validXY:volume.validXY,grid:volume.grid)
        let cptLocations = points.filter(\.isComplete).map { point in
            let local = CoordinateTransformer.localMeters(point.coordinate, origin:volume.terrainOrigin)
            return Point2(x:local.x-volume.westMeters,y:local.y-volume.southMeters)
        }
        let candidateDetails = try BearingCandidateDetails.make(depths:depths,qc:prediction.qc,
            ic:volume.values,observed:input.observed,grid:volume.grid,cptXYMeters:cptLocations)
        // The frozen synthetic lookup has no validation for the new flexible project grid.
        let referenceGrid = volume.grid.nx == 24 && volume.grid.ny == 24 && volume.grid.nz == 24
        let lookup = referenceGrid ? try? BearingReliabilityLookup.bundled(bundle) : nil
        let reliability = lookup?.summarize(depths:depths,validXY:volume.validXY,sites:input.sites,
            grid:volume.grid,qcMinimum:FlexibleBearingV1.qcMinimumMPa,
            icMaximum:FlexibleBearingV1.icMaximum,
            thickness:FlexibleBearingV1.minimumThicknessMeters)
        return .init(grid:volume.grid,depthsYX:depths,candidateDetailsYX:candidateDetails,sites:input.sites,
                     qcMinimumMPa:FlexibleBearingV1.qcMinimumMPa,
                     icMaximum:FlexibleBearingV1.icMaximum,
                     minimumThicknessMeters:FlexibleBearingV1.minimumThicknessMeters,
                     reliability:reliability)
    }
}
