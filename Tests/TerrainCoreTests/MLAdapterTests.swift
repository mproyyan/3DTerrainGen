import Testing
import Foundation
import CoreML
import Darwin
import simd
@testable import TerrainCore

@Test func offlineMetricsStateTheirScope() {
    let summary = ModelEvaluationMetrics.summary(observedCPTCount: 1, windowed: false)
    #expect(summary?.contains("0.17925") == true)
    #expect(summary?.contains("0.168331") == true)
    #expect(summary?.contains("bukan akurasi area ini") == true)
    #expect(ModelEvaluationMetrics.summary(observedCPTCount: 4, windowed: false) == nil)
    #expect(ModelEvaluationMetrics.summary(observedCPTCount: 1, windowed: true)?.contains("Windowed belum dievaluasi") == true)
}

@Test func displayResolutionIsChosenAutomaticallyFromArea() throws {
    let origin = GeoPoint(longitude: 110, latitude: -7)
    let boundary = [
        CoordinateTransformer.geographic(east: 0, north: 0, origin: origin),
        CoordinateTransformer.geographic(east: 1_000, north: 0, origin: origin),
        CoordinateTransformer.geographic(east: 1_000, north: 800, origin: origin),
        CoordinateTransformer.geographic(east: 0, north: 800, origin: origin)
    ]
    let extent = try MetricExtent(boundary: boundary, origin: origin)
    #expect(AdaptiveGrid.automaticDisplayResolution(extent: extent) > 6)
    #expect(AdaptiveGrid.automaticDisplayResolution(extent: extent) < 7)
}

private func mlFixture(span: Double = 0.00018) -> (TerrainMesh, [GeoPoint]) {
    let origin = GeoPoint(longitude: 110, latitude: -7)
    let boundary = [
        origin,
        GeoPoint(longitude: 110 + span, latitude: -7),
        GeoPoint(longitude: 110 + span, latitude: -7 + span),
        GeoPoint(longitude: 110, latitude: -7 + span)
    ]
    let positions = boundary.map { geo -> SIMD3<Float> in
        let local = CoordinateTransformer.localMeters(geo, origin: origin)
        return .init(Float(local.x), 0, Float(-local.y))
    }
    let metadata = DEMMetadata(width: 2, height: 2,
        transform: .init(x0: 110, a: span, b: 0, y0: -7, d: 0, e: span),
        epsg: 4326, noData: nil, verticalReference: "test metres",
        provenance: ["test"], footprint: boundary)
    let mesh = TerrainMesh(positions: positions,
        normals: positions.map { _ in .init(0, 1, 0) },
        indices: [0, 1, 2, 0, 2, 3], geographicVertices: boundary,
        elevations: Array(repeating: 100, count: 4), origin: origin,
        elevationOrigin: 100, minimum: 100, maximum: 100,
        areaSquareMeters: 400, metadata: metadata,
        sourceSampleCount: 4, gridSize: "test")
    return (mesh, boundary)
}

private func mlPoint(_ name: String, longitude: Double, latitude: Double, qc: Double = 10,
                     maxDepth: Double = 12) throws -> CPTPoint {
    var point = CPTPoint(id: UUID(), name: name,
        coordinate: .init(longitude: longitude, latitude: latitude), surfaceElevation: 100)
    let depths = stride(from: 0.5, through: maxDepth, by: 0.5)
    point.csv = ([CPTProcessor.header] + depths.map {
        String(format: "%.1f,%.1f,24,", $0, qc)
    }).joined(separator: "\n")
    point.interpretation = try CPTProcessor.interpret(csv: point.csv, assumptions: point.assumptions)
    point.updatedAt = Date()
    return point
}

@Test func modelCAdapterOneAndTwoCPTsPreserveTrainingTensorContract() throws {
    let (terrain, boundary) = mlFixture()
    let first = try mlPoint("CPT-1", longitude: 110.00006, latitude: -6.99994)
    let one = try ModelCInputAdapter.prepare(terrain: terrain, boundary: boundary, points: [first])
    #expect(one.sparse.count == 6912 && one.mask.count == 6912 && one.idw.count == 6912)
    #expect(one.mask.filter { $0 == 1 }.count == 12)
    #expect(one.validXY.contains(true))
    #expect(one.sparse.filter { !$0.isFinite }.isEmpty && one.idw.filter { !$0.isFinite }.isEmpty)
    for z in 0..<12 {
        let observedIndex = (z * 576)..<((z + 1) * 576)
        let values = observedIndex.filter { one.mask[$0] == 1 }
        #expect(values.count == 1)
        let i = values[0]
        #expect(abs(one.sparse[i] - (one.observedIc[i] - ModelCService.icMean) / ModelCService.icStd) < 1e-6)
        #expect(abs(one.idw[i] - one.sparse[i]) < 1e-6)
        #expect(abs(one.idw[observedIndex.lowerBound] - one.sparse[i]) < 1e-5)
        #expect(!one.depthResampled[i])
    }
    let second = try mlPoint("CPT-2", longitude: 110.00013, latitude: -6.99987, qc: 2)
    let two = try ModelCInputAdapter.prepare(terrain: terrain, boundary: boundary, points: [first, second])
    #expect(two.mask.filter { $0 == 1 }.count == 24)
    #expect(two.idw.filter { !$0.isFinite }.isEmpty)
}

@Test func modelCAdapterRejectsUnsupportedExtentAndDepth() throws {
    let (wide, wideBoundary) = mlFixture(span: 0.00030)
    let complete = try mlPoint("CPT-1", longitude: 110.00008, latitude: -6.99992)
    #expect(throws: MLIntegrationError.self) {
        try ModelCInputAdapter.prepare(terrain: wide, boundary: wideBoundary, points: [complete])
    }
    let (terrain, boundary) = mlFixture()
    let shallow = try mlPoint("CPT-2", longitude: 110.00008, latitude: -6.99992, maxDepth: 5)
    #expect(throws: MLIntegrationError.self) {
        try ModelCInputAdapter.prepare(terrain: terrain, boundary: boundary, points: [shallow])
    }
}

@Test func dqnFeatureAdapterProducesOrderedFinite28FeatureRows() throws {
    let (terrain, boundary) = mlFixture()
    let point = try mlPoint("CPT-1", longitude: 110.00006, latitude: -6.99994)
    let input = try ModelCInputAdapter.prepare(terrain: terrain, boundary: boundary, points: [point])
    let reconstruction = [Float](repeating: 2.4, count: 6912)
    let volume = try input.volume(reconstruction: reconstruction)
    let candidates = try DQNFeatureAdapter.candidates(volume: volume, terrain: terrain)
    #expect(!candidates.isEmpty)
    #expect(candidates.allSatisfy { $0.features.count == 28 && $0.features.filter { !$0.isFinite }.isEmpty })
    #expect(zip(candidates, candidates.dropFirst()).allSatisfy { a, b in a.x < b.x || (a.x == b.x && a.y < b.y) })
    #expect(candidates.allSatisfy { hypot($0.eastMeters - volume.east(x: $0.x), $0.northMeters - volume.north(y: $0.y)) < 1e-9 })
}

@Test func dqnFeatureRowMatchesPythonTrainingSchema() throws {
    let (terrain, _) = mlFixture(span: 0.00022)
    var observed = [Bool](repeating: false, count: 6912)
    for z in 0..<12 { observed[ReconstructionVolume.index(x: 5, y: 5, z: z)] = true }
    let volume = ReconstructionVolume(
        terrainOrigin: terrain.origin, westMeters: 0, southMeters: 0,
        values: [Float](repeating: 2.4, count: 6912), observed: observed,
        validXY: [Bool](repeating: true, count: 576),
        observationOrigins: [CPTDataOrigin?](repeating: nil, count: 6912),
        depthResampled: [Bool](repeating: false, count: 6912)
    )
    let candidates = try DQNFeatureAdapter.candidates(volume: volume, terrain: terrain)
    let first = try #require(candidates.first)
    #expect(first.x == 0 && first.y == 0)
    // Generated by dqn3d/v3/features.py::build_state using Grid(24,24,12,1,1,1),
    // a constant physical Ic=2.4 volume and one complete CPT at (5,5).
    let expected: [Float] = [
        0, 0, 0.20833333, 0, 1, 0.30694476, 0,
        0.30694473, 0.30694473, 0.30694473, 0.30694473,
        0, 0, 0, 0, 0.30694479, 1,
        0.10902239, 0.75, 0.75, 0.75, 0.5, 0.5, 0.5,
        0.30694479, 0, 1, 0.0017361111
    ]
    #expect(first.features.count == expected.count)
    for (actual, reference) in zip(first.features, expected) {
        #expect(abs(actual - reference) < 1e-5)
    }
}

@Test func flexibleModelCGridBuildsLargerTensorAndPreservesObservations() throws {
    let (terrain, boundary) = mlFixture(span: 0.00027)
    let point = try mlPoint("CPT-1", longitude: 110.00006, latitude: -6.99994, maxDepth: 16)
    let grid = try ReconstructionGrid.fitting(boundary: boundary, points: [point], origin: terrain.origin)
    #expect(grid.nx == 32 && grid.ny == 32 && grid.nz == 16)
    let input = try ModelCInputAdapter.prepare(terrain: terrain, boundary: boundary, points: [point], grid: grid)
    #expect(input.sparse.count == 16 * 32 * 32)
    #expect(input.mask.filter { $0 == 1 }.count == 16)
    #expect(input.validXY.count == 32 * 32)
    #expect(input.sparse.allSatisfy(\.isFinite) && input.idw.allSatisfy(\.isFinite))
    let volume = try input.volume(reconstruction: [Float](repeating: 2.4, count: grid.voxelCount))
    #expect(volume.grid.shape == [1, 1, 16, 32, 32])
    #expect(volume.observed.filter { $0 }.count == 16)
    #expect(volume.depth(z: 15) == 15.5)
    #expect(throws: MLIntegrationError.self) {
        try ReconstructionGrid.fitting(boundary: mlFixture(span: 0.0005).1, points: [point], origin: terrain.origin)
    }
}

@Test func dqn24MetreRecommendationUsesCoreMLInference() async throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let models = root.appendingPathComponent("Demnas3DMap/Models")
    let reconstructorURL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNReconstructor.mlpackage"))
    let scorerURL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNScorer.mlpackage"))
    let (terrain, boundary) = mlFixture()
    let point = try mlPoint("CPT-1", longitude: 110.00008, latitude: -6.99992)
    let candidate = try #require(try await DQNRecommendationService.recommend(
        terrain: terrain, boundary: boundary, points: [point],
        reconstructorURL: reconstructorURL, scorerURL: scorerURL
    ))
    #expect(terrain.surfacePosition(at: candidate) != nil)

    // Independently inspect the actual Core ML Q-values; the service result must
    // be the first maximum in candidate order, rather than the heuristic point.
    let prepared = try ModelCInputAdapter.prepare(
        terrain: terrain, boundary: boundary, points: [point],
        icMean: DQNReconstructorService.icMean, icStd: DQNReconstructorService.icStd
    )
    let reconstructor = try DQNReconstructorService(modelURL: reconstructorURL)
    let values = try await reconstructor.reconstruct(
        sparse: prepared.sparse, mask: prepared.mask, idw: prepared.idw,
        observedIc: prepared.observedIc
    )
    let volume = try prepared.volume(reconstruction: values)
    let actual = CoordinateTransformer.localMeters(point.coordinate, origin: terrain.origin)
    let candidates = try DQNFeatureAdapter.candidates(volume: volume, terrain: terrain)
        .filter { hypot($0.eastMeters - actual.x, $0.northMeters - actual.y) >= 2.001 }
    let scorer = try DQNScorerService(modelURL: scorerURL)
    let scores = try await scorer.score(candidateFeatures: candidates.map(\.features))
    #expect(scores.count == candidates.count && scores.allSatisfy(\.isFinite))
    let best = try #require(scores.indices.first { scores[$0] == scores.max()! })
    let selected = candidates[best]
    let local = CoordinateTransformer.localMeters(candidate, origin: terrain.origin)
    #expect(hypot(local.x - selected.eastMeters, local.y - selected.northMeters) < 0.05)
    #expect(hypot(local.x - actual.x, local.y - actual.y) >= 2)
}

@Test func dqnOversizedAreaReportsMeasuredLimitAndResolution() async throws {
    let (terrain, boundary) = mlFixture(span: 0.00030)
    let point = try mlPoint("CPT-1", longitude: 110.00008, latitude: -6.99992)
    do {
        _ = try await DQNRecommendationService.recommend(
            terrain: terrain, boundary: boundary, points: [point]
        )
        Issue.record("Expected an oversized-area fallback")
    } catch {
        let reason = error.localizedDescription
        #expect(reason.contains("Ukuran area"))
        #expect(reason.contains("24 × 24"))
        #expect(reason.contains("1 m/sel"))
        #expect(reason.contains("Heuristic"))
    }
}


@Test func dqnG16FeatureRowMatchesPythonTrainingSchema() throws {
    let (terrain, _) = mlFixture(span: 0.00030)
    let grid = ReconstructionGrid(nx: 16, ny: 16, nz: 16, spacingMeters: 2)
    var observed = [Bool](repeating: false, count: grid.voxelCount)
    for z in 0..<grid.nz { observed[grid.index(x: 5, y: 5, z: z)] = true }
    let volume = ReconstructionVolume(
        terrainOrigin: terrain.origin, westMeters: 0, southMeters: 0, grid: grid,
        values: [Float](repeating: 2.4, count: grid.voxelCount), observed: observed,
        validXY: [Bool](repeating: true, count: grid.nx * grid.ny),
        observationOrigins: [CPTDataOrigin?](repeating: nil, count: grid.voxelCount),
        depthResampled: [Bool](repeating: false, count: grid.voxelCount)
    )
    let candidates = try DQNFeatureAdapter.candidates(volume: volume, terrain: terrain)
    let first = try #require(candidates.first)
    #expect(first.x == 0 && first.y == 0)
    // Generated by Python dqn3d/v3/features.py::build_state for g16 (2×2×1 m).
    let expected: [Float] = [
        0, 0, 0.3125, 0, 1, 0.30694473, 0,
        0.30694473, 0.30694473, 0.30694473, 0.30694473,
        0, 0, 0, 0, 0.30694476, 1,
        0.12491218, 1, 1, 1, 1, 1, 0.5,
        0.30694479, 0, 1, 0.00390625
    ]
    #expect(first.features.count == expected.count)
    for (actual, reference) in zip(first.features, expected) {
        #expect(abs(actual - reference) < 1e-5)
    }
}

@Test func dqnG16RecommendationUsesCoreMLQValues() async throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let models = root.appendingPathComponent("Demnas3DMap/Models")
    let g16URL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNReconstructorG16.mlpackage"))
    let scorerURL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNScorer.mlpackage"))
    let (terrain, boundary) = mlFixture(span: 0.00027)
    let point = try mlPoint("CPT-1", longitude: 110.00008, latitude: -6.99992, maxDepth: 16)
    let recommended = try #require(try await DQNRecommendationService.recommend(
        terrain: terrain, boundary: boundary, points: [point],
        scorerURL: scorerURL, g16ReconstructorURL: g16URL
    ))
    let prepared = try DQNInputG16Adapter.prepare(terrain: terrain, boundary: boundary, points: [point])
    #expect(prepared.grid.shape == [1, 1, 16, 16, 16])
    #expect(prepared.grid.spacingMeters == 2 && prepared.grid.depthSpacingMeters == 1)
    #expect(prepared.mask.filter { $0 == 1 }.count == 16)
    let reconstructor = try DQNReconstructorG16Service(modelURL: g16URL)
    let values = try await reconstructor.reconstruct(
        sparse: prepared.sparse, mask: prepared.mask, idw: prepared.idw,
        observedIc: prepared.observedIc
    )
    let volume = try prepared.volume(reconstruction: values)
    let actual = CoordinateTransformer.localMeters(point.coordinate, origin: terrain.origin)
    let candidates = try DQNFeatureAdapter.candidates(volume: volume, terrain: terrain)
        .filter { hypot($0.eastMeters - actual.x, $0.northMeters - actual.y) >= 2.001 }
    let scorer = try DQNScorerService(modelURL: scorerURL)
    let scores = try await scorer.score(candidateFeatures: candidates.map(\.features))
    #expect(scores.count == candidates.count && scores.allSatisfy(\.isFinite))
    let best = try #require(scores.indices.first { scores[$0] == scores.max()! })
    let selected = candidates[best]
    let local = CoordinateTransformer.localMeters(recommended, origin: terrain.origin)
    #expect(hypot(local.x - selected.eastMeters, local.y - selected.northMeters) < 0.05)
    #expect(hypot(local.x - actual.x, local.y - actual.y) >= 2)
}


@Test func dqnG16RejectsShallowCPTInsteadOfScoringIncompatibleInput() async throws {
    let (terrain, boundary) = mlFixture(span: 0.00027)
    let point = try mlPoint("CPT-1", longitude: 110.00008, latitude: -6.99992, maxDepth: 12)
    do {
        _ = try await DQNRecommendationService.recommend(terrain: terrain, boundary: boundary, points: [point])
        Issue.record("Expected g16 depth compatibility failure")
    } catch {
        #expect(error.localizedDescription.contains("15.5") || error.localizedDescription.contains("15,5"))
    }
}


@Test(arguments: [
    (24.0, 24.0, 1.0), (32.0, 32.0, 2.0), (79.0, 71.0, 1.0),
    (200.0, 150.0, 2.0), (1000.0, 800.0, 5.0)
]) func adaptiveGridCoversPhysicalArea(width: Double, height: Double, resolution: Double) throws {
    let origin = GeoPoint(longitude: 110, latitude: -7)
    let boundary = [
        CoordinateTransformer.geographic(east: 0, north: 0, origin: origin),
        CoordinateTransformer.geographic(east: width, north: 0, origin: origin),
        CoordinateTransformer.geographic(east: width, north: height, origin: origin),
        CoordinateTransformer.geographic(east: 0, north: height, origin: origin)
    ]
    try AdaptiveGrid.validateResolution(resolution)
    let extent = try MetricExtent(boundary: boundary, origin: origin)
    #expect(abs(extent.width - width) < 0.01 && abs(extent.height - height) < 0.01)
    let windows = try AdaptiveGrid.windows(extent: extent, width: 48, height: 32, overlap: 8)
    #expect(!windows.isEmpty)
    for point in boundary {
        #expect(windows.contains { $0.contains(point, origin: origin) })
    }
    for y in stride(from: 0.0, through: height, by: max(resolution, height / 20)) {
        for x in stride(from: 0.0, through: width, by: max(resolution, width / 20)) {
            let point = CoordinateTransformer.geographic(east: x, north: y, origin: origin)
            #expect(windows.contains { $0.contains(point, origin: origin) })
        }
    }
    #expect(windows.allSatisfy { $0.width == 48 && $0.height == 32 })
}


@Test func tiledIcSamplerBlendsSeamAndPreservesObservedCPT() throws {
    let (terrain, _) = mlFixture(span: 0.00030)
    let grid = ReconstructionGrid(nx: 16, ny: 16, nz: 8, spacingMeters: 1)
    func volume(west: Double, value: Float, observedAtX: Int? = nil) -> ReconstructionVolume {
        var observed = [Bool](repeating: false, count: grid.voxelCount)
        if let observedAtX { observed[grid.index(x: observedAtX, y: 8, z: 0)] = true }
        return ReconstructionVolume(
            terrainOrigin: terrain.origin, westMeters: west, southMeters: 0, grid: grid,
            values: [Float](repeating: value, count: grid.voxelCount),
            observed: observed, validXY: [Bool](repeating: true, count: grid.nx * grid.ny),
            observationOrigins: [CPTDataOrigin?](repeating: nil, count: grid.voxelCount),
            depthResampled: [Bool](repeating: false, count: grid.voxelCount)
        )
    }
    let sampler = TiledIcSampler(volumes: [volume(west: 0, value: 2), volume(west: 8, value: 4, observedAtX: 4)], overlapMeters: 8)
    let samples = (8..<16).compactMap { sampler.sample(east: Double($0) + 0.5, north: 8.5, depthIndex: 1) }
    #expect(samples.count == 8)
    #expect(samples.first! < samples.last!)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { a, b in abs(b - a) < 0.5 })
    #expect(sampler.sample(east: 12.5, north: 8.5, depthIndex: 0) == 4)
    #expect(sampler.sample(east: 100, north: 100, depthIndex: 0) == nil)
}


private func metricMLFixture(width: Double, height: Double) -> (TerrainMesh, [GeoPoint], GeoPoint) {
    let origin = GeoPoint(longitude: 110, latitude: -7)
    let boundary = [
        CoordinateTransformer.geographic(east: 0, north: 0, origin: origin),
        CoordinateTransformer.geographic(east: width, north: 0, origin: origin),
        CoordinateTransformer.geographic(east: width, north: height, origin: origin),
        CoordinateTransformer.geographic(east: 0, north: height, origin: origin)
    ]
    let positions = boundary.map { geo -> SIMD3<Float> in
        let local = CoordinateTransformer.localMeters(geo, origin: origin)
        return .init(Float(local.x), 0, Float(-local.y))
    }
    let metadata = DEMMetadata(width: 2, height: 2,
        transform: .init(x0: origin.longitude, a: boundary[1].longitude - origin.longitude, b: 0,
                         y0: origin.latitude, d: 0, e: boundary[3].latitude - origin.latitude),
        epsg: 4326, noData: nil, verticalReference: "test metres",
        provenance: ["metric fixture"], footprint: boundary)
    let mesh = TerrainMesh(positions: positions,
        normals: positions.map { _ in .init(0, 1, 0) },
        indices: [0, 1, 2, 0, 2, 3], geographicVertices: boundary,
        elevations: Array(repeating: 100, count: 4), origin: origin,
        elevationOrigin: 100, minimum: 100, maximum: 100,
        areaSquareMeters: width * height, metadata: metadata,
        sourceSampleCount: 4, gridSize: "test")
    let centre = CoordinateTransformer.geographic(east: width / 2, north: height / 2, origin: origin)
    return (mesh, boundary, centre)
}

private func peakResidentBytes() -> Int {
    var usage = rusage()
    return getrusage(RUSAGE_SELF, &usage) == 0 ? Int(usage.ru_maxrss) : 0
}

@Test func tiledModelCInferenceAcrossTargetSizes() async throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let modelURL = try await MLModel.compileModel(at:
        root.appendingPathComponent("Demnas3DMap/Models/ModelC_Flexible.mlpackage"))
    for (width, height, resolution) in [
        (24.0, 24.0, 1.0), (32.0, 32.0, 2.0), (79.0, 71.0, 1.0),
        (200.0, 150.0, 2.0), (1000.0, 800.0, 5.0)
    ] {
        try AdaptiveGrid.validateResolution(resolution)
        let (terrain, boundary, centre) = metricMLFixture(width: width, height: height)
        let point = try mlPoint("CPT-1", longitude: centre.longitude, latitude: centre.latitude, maxDepth: 16)
        let result = try await TiledModelCReconstruction.reconstruct(
            terrain: terrain, boundary: boundary, points: [point], modelURL: modelURL
        )
        #expect(!result.volumes.isEmpty)
        #expect(result.volumes.allSatisfy { $0.values.allSatisfy(\.isFinite) })
        #expect(result.volumes.reduce(0) { $0 + $1.observed.filter { $0 }.count } >= 8)
        let centreMetres = CoordinateTransformer.localMeters(centre, origin: terrain.origin)
        #expect(result.volumes.contains { volume in
            guard let index = volume.observed.firstIndex(of: true) else { return false }
            let x = index % volume.grid.nx
            let y = (index / volume.grid.nx) % volume.grid.ny
            return hypot(volume.east(x: x) - centreMetres.x,
                         volume.north(y: y) - centreMetres.y) <= 1.5
        })
        #expect(result.estimatedVolumeBytes < 20_000_000)
        #expect(result.inferenceSeconds.isFinite && result.inferenceSeconds >= 0)
        if width > 48 || height > 32 { #expect(result.windowsWithoutCPT > 0) }
        print("Adaptive Model C \(Int(width))×\(Int(height)) m @ \(resolution) m: \(result.volumes.count)/\(result.plannedWindows) windows; \(String(format: "%.3f", result.inferenceSeconds)) s; resident volume estimate \(result.estimatedVolumeBytes) bytes; process peak RSS \(peakResidentBytes()) bytes")
    }
}


@Test func windowedDQNUsesOneWindowQValuesAndExperimentalStatus() async throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let models = root.appendingPathComponent("Demnas3DMap/Models")
    let g16URL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNReconstructorG16.mlpackage"))
    let scorerURL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNScorer.mlpackage"))
    let (terrain, boundary, centre) = metricMLFixture(width: 79, height: 71)
    let point = try mlPoint("CPT-1", longitude: centre.longitude, latitude: centre.latitude, maxDepth: 16)
    let result = try #require(try await AdaptiveDQNRecommendationService.recommend(
        terrain: terrain, boundary: boundary, points: [point],
        scorerURL: scorerURL, g16ReconstructorURL: g16URL
    ))
    #expect(result.windowed)
    #expect(result.explanation.contains("Experimental"))
    let extent = try MetricExtent(boundary: boundary, origin: terrain.origin)
    let windows = try AdaptiveGrid.windows(extent: extent, width: 32, height: 32, overlap: 8)
    let selected = try #require(windows.first { $0.contains(point.coordinate, origin: terrain.origin) })
    let direct = try #require(try await DQNRecommendationService.recommend(
        terrain: terrain, boundary: selected.clippedBoundary(boundary, origin: terrain.origin),
        points: [point], scorerURL: scorerURL, g16ReconstructorURL: g16URL
    ))
    let a = CoordinateTransformer.localMeters(result.coordinate, origin: terrain.origin)
    let b = CoordinateTransformer.localMeters(direct, origin: terrain.origin)
    #expect(hypot(a.x - b.x, a.y - b.y) < 0.05)
}


@Test func adaptiveDQNInferenceAcrossTargetSizes() async throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let models = root.appendingPathComponent("Demnas3DMap/Models")
    let g24URL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNReconstructor.mlpackage"))
    let g16URL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNReconstructorG16.mlpackage"))
    let scorerURL = try await MLModel.compileModel(at: models.appendingPathComponent("DQNScorer.mlpackage"))
    for (width, height, resolution) in [
        (24.0, 24.0, 1.0), (32.0, 32.0, 2.0), (79.0, 71.0, 1.0),
        (200.0, 150.0, 2.0), (1000.0, 800.0, 5.0)
    ] {
        try AdaptiveGrid.validateResolution(resolution)
        let (terrain, boundary, centre) = metricMLFixture(width: width, height: height)
        let point = try mlPoint("CPT-1", longitude: centre.longitude, latitude: centre.latitude, maxDepth: 16)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try #require(try await AdaptiveDQNRecommendationService.recommend(
            terrain: terrain, boundary: boundary, points: [point],
            reconstructorURL: g24URL, scorerURL: scorerURL, g16ReconstructorURL: g16URL
        ))
        #expect(result.windowed == (width > 32 || height > 32))
        #expect(terrain.surfacePosition(at: result.coordinate) != nil)
        #expect(ProcessInfo.processInfo.systemUptime - started < 10)
        print("Adaptive DQN \(Int(width))×\(Int(height)) m @ \(resolution) m: \(result.windowed ? "windowed experimental" : "single grid"); \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)) s")
    }
}


@Test func excessiveMLWindowCountFallsBackWithoutAProjectMetreLimit() throws {
    let (terrain, boundary, _) = metricMLFixture(width: 100_000, height: 100_000)
    let extent = try MetricExtent(boundary: boundary, origin: terrain.origin)
    #expect(extent.width > 99_000 && extent.height > 99_000)
    #expect(throws: MLIntegrationError.self) {
        try AdaptiveGrid.windows(extent: extent, width: 48, height: 32, overlap: 8)
    }
}


@Test func adaptiveRenderingLODBoundsVoxelEntityEstimate() {
    let cases = [(24, 24, 1.0), (32, 32, 2.0), (79, 71, 1.0),
                 (200, 150, 2.0), (1000, 800, 5.0)]
    for (width, height, resolution) in cases {
        let voxels = width * height * 16
        let step = AdaptiveGrid.renderStep(voxelCount: voxels, resolutionMetres: resolution)
        #expect(step >= Int(ceil(resolution)))
        #expect(Double(voxels) / pow(Double(step), 3) <= 12_000 + 1)
    }
}
