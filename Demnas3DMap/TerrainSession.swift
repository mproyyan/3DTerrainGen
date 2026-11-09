import Foundation
import Observation

enum ReconstructionStatus: String {
    case unavailable, loading, reconstructing, ready, error
}

enum RecommendationSource: String {
    case none
    case dqnV46A = "DQN V4.6-A"
}

enum DQNStatus: String {
    case unavailable, recommending, ready, fallback
}

@MainActor @Observable
final class TerrainSession {
    var selection = PolygonSelectionModel()
    var drawing = false
    var placingCPT = false
    var points: [CPTPoint] = []
    var scenario = InvestigationScenario.variable
    private(set) var spatialResolutionMeters = 1.0
    var revision = 0
    var savedAt: Date?
    var recommendation: GeoPoint?
    var recommendationSource = RecommendationSource.none
    var dqnRecommendation: GeoPoint?
    var dqnRecommendationSource = RecommendationSource.none
    var dqnStatus = DQNStatus.unavailable
    var dqnError: String?
    var dqnInfo: String?
    var v42Detail: String?
    var v42QValue: Float?
    var v45Diagnostics: V45RunDiagnostics?
    private(set) var investigationAssessment: CoverageV1Assessment?
    private var coverageHistory = CoverageV1History()
    private var assessmentInputKey: String?
    private var assessmentGeneration = 0
    private var assessmentTask: Task<(ReconstructionVolume, CoverageV1Assessment, CoverageV1History), Error>?
    var minimumRecommendationSpacingMeters: Double?
    private var v46Task: Task<V46Recommendation?, Error>?
    var rendererDiagnostics: RendererDiagnostics?
    private var dqnTask: Task<AdaptiveDQNResult?, Error>?
    private var v42Task: Task<V42Recommendation?, Error>?
    private var dqnInputKey: String?
    private var dqnGeneration = 0
    var reconstruction: ReconstructionVolume?
    var reconstructionTiles: [ReconstructionVolume] = []
    var reconstructionSummary: String?
    var reconstructionVersion = 0
    var reconstructionStatus = ReconstructionStatus.unavailable
    /// Changes only when the terrain mesh changes; forces RealityKit to rebuild its mesh resource.
    var terrainRevision = 0
    var reconstructionError: String?
    var estimatedRisk: UncertaintyV2Map?
    var estimatedRiskError: String?
    var estimatedRiskVersion = 0
    private var uncertaintyTask: Task<UncertaintyV2Map, Error>?
    private var reconstructionTask: Task<TiledModelCResult, Error>?
    private var reconstructionInputKey: String?
    private var reconstructionGeneration = 0
    var status: InvestigationStatus { InvestigationSimulator.status(points: points, scenario: scenario) }
    private let projectURL: URL

    init() {
        projectURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CPT-PoC/project.json")
        guard FileManager.default.fileExists(atPath: projectURL.path) else { return }
        do {
            let project = try InvestigationProject.decode(Data(contentsOf: projectURL))
            guard project.version == 1 else { throw TerrainError("Versi proyek tersimpan belum didukung.") }
            for p in project.boundary { try selection.add(p.coordinate) }
            try selection.finish()
            mesh = project.terrain; terrainRevision += 1; points = project.points; scenario = project.scenario
            if let extent = try? MetricExtent(boundary: project.boundary, origin: project.terrain.origin) {
                spatialResolutionMeters = AdaptiveGrid.automaticDisplayResolution(extent: extent)
            }
            savedAt = try projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            refreshInvestigation()
        } catch { errorMessage = "Proyek tersimpan tidak dapat dibuka: \(error.localizedDescription)" }
    }

    func refreshInvestigation() {
        revision += 1
        refreshAssessmentIfNeeded()
    }

    private func refreshAssessmentIfNeeded() {
        let complete = points.filter(\.isComplete)
        if complete.count == 0 || (coverageHistory.evaluations.last?.count ?? 0) > complete.count {
            coverageHistory.reset()
            investigationAssessment = nil
        }
        let key = UncertaintyV2Features.inputKey(points: complete, resolutionMeters: spatialResolutionMeters,
                                                 boundary: selection.coordinates.map { GeoPoint($0) })
        guard key != assessmentInputKey else { return }
        assessmentInputKey = key
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel(); assessmentTask = nil
        v46Task?.cancel(); v46Task = nil
        dqnTask?.cancel(); v42Task?.cancel(); dqnTask = nil; v42Task = nil
        uncertaintyTask?.cancel(); estimatedRisk = nil; estimatedRiskError = nil; estimatedRiskVersion += 1
        reconstructionTask?.cancel(); reconstructionTask = nil
        reconstruction = nil; reconstructionTiles = []; reconstructionError = nil; reconstructionVersion += 1
        recommendation = nil; recommendationSource = .none
        dqnRecommendation = nil; dqnRecommendationSource = .none
        v42QValue = nil; v45Diagnostics = nil; dqnInfo = nil; dqnError = nil
        investigationAssessment = nil
        minimumRecommendationSpacingMeters = nil
        guard let mesh, !complete.isEmpty else {
            reconstructionStatus = .unavailable; dqnStatus = .unavailable
            return
        }
        let boundary = selection.coordinates.map { GeoPoint($0) }
        let resolution = spatialResolutionMeters
        let history = coverageHistory
        #if DEBUG
        print("[Coverage V1] CPT count=\(complete.count); preferred resolution=\(resolution) m")
        print("[Coverage V1] bundle=\(Bundle.main.bundlePath)")
        for name in ["CoverageV1", "UncertaintyV3"] {
            print("[Coverage V1] resource \(name).json: \(Bundle.main.url(forResource: name, withExtension: "json")?.path ?? "MISSING")")
        }
        print("[Coverage V1] resource DQN_V4_6_A.mlmodelc: \(Bundle.main.url(forResource: "DQN_V4_6_A", withExtension: "mlmodelc")?.path ?? "MISSING")")
        #endif
        reconstructionStatus = .reconstructing; dqnStatus = .unavailable
        v42Detail = "SchemaGAN V4.2 → Coverage V1 sedang dihitung."
        let job = Task.detached(priority: .userInitiated) { () throws -> (ReconstructionVolume, CoverageV1Assessment, CoverageV1History) in
            var stage = "CPT/grid preprocessing"
            do {
            #if DEBUG
            print("[Coverage V1] preparing SchemaGAN input")
            #endif
            let input = try V42Input.prepare(terrain: mesh, boundary: boundary, points: complete,
                                             preferredMeters: resolution)
            #if DEBUG
            print("[Coverage V1] SchemaGAN input grid=\(input.nx)×\(input.ny)×\(input.nz); valid XY=\(input.validXY.filter { $0 }.count); observed voxels=\(input.observed.filter { $0 }.count)")
            #endif
            stage = "SchemaGAN model load/inference"
            let schema = try V42SchemaGANService()
            let values = try await schema.reconstruct(input)
            try Task.checkCancellation()
            stage = "SchemaGAN output validation"
            let volume = try input.volume(values)
            #if DEBUG
            let validVoxelCount = volume.validXY.filter { $0 }.count * volume.grid.nz
            let observedValidCount = volume.observed.indices.filter { volume.observed[$0] }.count
            print("[Coverage V1] SchemaGAN reconstruction succeeded; grid=\(volume.grid.nx)×\(volume.grid.ny)×\(volume.grid.nz); valid voxels=\(validVoxelCount); unobserved valid voxels=\(validVoxelCount - observedValidCount)")
            #endif
            stage = "CoverageV1.json load / voxel inference"
            let coverage = try CoverageV1Service.bundled()
            var updatedHistory = history
            let assessment = try CoverageV1Pipeline.assess(volume: volume, nCPT: complete.count,
                                                            service: coverage, history: &updatedHistory)
            return (volume, assessment, updatedHistory)
            } catch {
                #if DEBUG
                print("[Coverage V1] stage=\(stage) FAILED: \(String(reflecting: error))")
                #endif
                throw error
            }
        }
        assessmentTask = job
        Task {
            do {
                let (volume, assessment, updatedHistory) = try await job.value
                guard !job.isCancelled, generation == assessmentGeneration else { return }
                coverageHistory = updatedHistory
                investigationAssessment = assessment
                minimumRecommendationSpacingMeters = V46FeatureAdapter.recommendationSpacing(grid: volume.grid)
                reconstruction = volume; reconstructionTiles = [volume]
                reconstructionVersion += 1; reconstructionStatus = .ready
                reconstructionError = nil
                reconstructionSummary = "SchemaGAN V4.2 Flexible: Ic 3D pada grid \(volume.grid.nx) × \(volume.grid.ny) × \(volume.grid.nz); nilai CPT terukur dipertahankan."
                if assessment.advisoryHigh {
                    v42Detail = "Kecukupan Investigasi: Tinggi. Verifikasi engineer tetap diperlukan; DQN dapat menyarankan titik tambahan."
                } else {
                    v42Detail = "Kecukupan Investigasi: Belum Memadai. Investigasi tambahan direkomendasikan."
                }
                    dqnStatus = .recommending
                    let dqnJob = Task.detached(priority: .userInitiated) {
                        try await V46RecommendationService.recommend(volume: volume, terrain: mesh,
                                                                      minimumSpacingMeters: V46FeatureAdapter.recommendationSpacing(grid: volume.grid),
                                                                      measuredCPT: complete.map(\.coordinate))
                    }
                    v46Task = dqnJob
                    do {
                        let result = try await CoverageV1RecommendationPolicy.next(assessment: assessment) {
                            try await dqnJob.value
                        }
                        guard !dqnJob.isCancelled, generation == assessmentGeneration else { return }
                        if let result {
                            dqnRecommendation = result.coordinate
                            dqnRecommendationSource = .dqnV46A
                            recommendation = result.coordinate
                            recommendationSource = .dqnV46A
                            v42QValue = result.qValue
                            dqnInfo = "DQN V4.6-A: \(result.legalCount) kandidat legal dinilai; Q-value hanya untuk ranking lokasi."
                            dqnStatus = .ready
                        } else {
                            dqnStatus = .unavailable
                            dqnError = "Rekomendasi DQN belum tersedia."
                            #if DEBUG
                            print("DQN V4.6-A failed: no legal candidate returned")
                            #endif
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard generation == assessmentGeneration else { return }
                        dqnStatus = .unavailable; dqnError = "Rekomendasi DQN belum tersedia."
                        #if DEBUG
                        print("DQN V4.6-A failed: \(error)")
                        #endif
                    }
                let riskJob = Task.detached(priority: .utility) {
                    let model = try UncertaintyV3Service.bundled()
                    return try UncertaintyV3MapFactory.makeMap(volume: volume, service: model)
                }
                uncertaintyTask = riskJob
                Task {
                    do {
                        let risk = try await riskJob.value
                        guard !riskJob.isCancelled, generation == assessmentGeneration else { return }
                        estimatedRisk = risk; estimatedRiskVersion += 1
                    } catch is CancellationError { return }
                    catch { if generation == assessmentGeneration { estimatedRiskError = error.localizedDescription } }
                }
            } catch is CancellationError { return }
            catch {
                guard !job.isCancelled, generation == assessmentGeneration else { return }
                reconstructionStatus = .error; reconstructionError = error.localizedDescription
                dqnStatus = .unavailable; dqnError = "Rekomendasi DQN belum tersedia."
                #if DEBUG
                print("[Coverage V1] ASSESSMENT UNAVAILABLE: \(String(reflecting: error))")
                print("[Coverage V1] DQN V4.6-A blocked because coverage assessment is unavailable")
                #endif
                v42Detail = "Predicted Coverage belum tersedia; DQN V4.6-A tidak dijalankan."
            }
        }
    }

    func chooseRecommendation(_ source: RecommendationSource) {
        switch source {
        case .dqnV46A:
            guard let dqnRecommendation else { return }
            recommendation = dqnRecommendation
            recommendationSource = dqnRecommendationSource
        default: break
        }
    }

    private func refreshReconstructionIfNeeded() {
        let complete = points.filter(\.isComplete)
        // A pending CPT has no new Ic observations; keep the previous risk map.
        // Coordinates, resolution, and polygon are part of the key so spatial
        // features cannot stay cached after a project geometry change.
        let key = UncertaintyV2Features.inputKey(points: complete, resolutionMeters: spatialResolutionMeters,
                                  boundary: selection.coordinates.map { GeoPoint($0) })
        guard key != reconstructionInputKey else { return }
        reconstructionInputKey = key
        reconstructionGeneration += 1
        reconstructionTask?.cancel()
        reconstructionTask = nil
        reconstruction = nil
        reconstructionTiles = []
        rendererDiagnostics = nil
        uncertaintyTask?.cancel(); estimatedRisk = nil; estimatedRiskError = nil; estimatedRiskVersion += 1
        reconstructionSummary = nil
        reconstructionVersion += 1
        reconstructionError = nil
        guard let mesh, !complete.isEmpty else {
            reconstructionStatus = .unavailable
            return
        }
        let boundary = selection.coordinates.map { GeoPoint($0) }
        let currentGeneration = reconstructionGeneration
        reconstructionStatus = .loading
        let job = Task.detached(priority: .userInitiated) { () throws -> TiledModelCResult in
            try await TiledModelCReconstruction.reconstruct(
                terrain: mesh, boundary: boundary, points: complete
            )
        }
        reconstructionTask = job
        reconstructionStatus = .reconstructing
        Task {
            do {
                let result = try await job.value
                guard !job.isCancelled, currentGeneration == reconstructionGeneration else { return }
                if assessmentTask != nil { return }
                reconstructionTiles = result.volumes
                reconstruction = result.volumes.first
                reconstructionSummary = "\(result.volumes.count)/\(result.plannedWindows) window Model C; \(result.windowsWithoutCPT) tanpa CPT, \(result.unsupportedWindows) tidak kompatibel. Overlap dibaurkan; bukan inference global."
                reconstructionVersion += 1
                reconstructionStatus = .ready
            } catch is CancellationError {
                return
            } catch {
                guard !job.isCancelled, currentGeneration == reconstructionGeneration else { return }
                reconstructionError = error.localizedDescription
                reconstructionStatus = .error
            }
        }
    }

    func persist() {
        guard let mesh else { return }
        do {
            let project = InvestigationProject(boundary: selection.coordinates.map { GeoPoint($0) }, terrain: mesh, points: points, scenario: scenario, spatialResolutionMeters: spatialResolutionMeters)
            try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try project.encoded().write(to: projectURL, options: .atomic)
            savedAt = Date()
        } catch { errorMessage = "Perubahan belum tersimpan: \(error.localizedDescription)" }
    }

    @discardableResult
    func addCPT(at coordinate: GeoPoint) throws -> UUID {
        guard activity == nil, let mesh, selection.isFinished,
              let position = mesh.surfacePosition(at: coordinate) else {
            throw TerrainError("Pilih titik di dalam terrain yang sudah dibuat.")
        }
        guard !points.contains(where: { $0.coordinate == coordinate }) else {
            throw TerrainError("Titik CPT pada koordinat ini sudah ada.")
        }
        let id = UUID()
        let used = Set(points.map(\.name))
        var number = 1
        while used.contains("CPT-\(number)") { number += 1 }
        points.append(.init(id: id, name: "CPT-\(number)", coordinate: coordinate,
                            surfaceElevation: Double(position.y) + mesh.elevationOrigin))
        placingCPT = false
        refreshInvestigation(); persist()
        return id
    }

    func saveCPT(id: UUID, csv: String, assumptions: CPTAssumptions, origin: CPTDataOrigin) throws {
        guard let index = points.firstIndex(where: { $0.id == id }) else { throw TerrainError("Titik CPT tidak ditemukan.") }
        let result = try CPTProcessor.interpret(csv: csv, assumptions: assumptions)
        points[index].csv = csv; points[index].assumptions = assumptions
        points[index].dataOrigin = origin; points[index].interpretation = result; points[index].updatedAt = Date(); points[index].draft = nil
        refreshInvestigation(); persist()
    }

    func saveDraft(id: UUID, csv: String, assumptions: CPTAssumptions, origin: CPTDataOrigin) {
        guard let index = points.firstIndex(where: { $0.id == id }), csv.utf8.count <= 1_000_000 else { return }
        points[index].draft = .init(csv: csv, assumptions: assumptions, origin: origin)
        persist()
    }

    func deleteCPT(id: UUID) {
        points.removeAll { $0.id == id }
        refreshInvestigation(); persist()
    }

    func setScenario(_ value: InvestigationScenario) {
        scenario = value; refreshInvestigation(); persist()
    }
    func setSpatialResolutionMeters(_ metres: Double) throws {
        try AdaptiveGrid.validateResolution(metres)
        guard spatialResolutionMeters != metres else { return }
        spatialResolutionMeters = metres
        refreshInvestigation(); persist()
    }
    var mesh: TerrainMesh?
    var importedDEM: ImportedDEM?
    var confirmedDEMNASImport = false
    var verticalMetresWithUnknownDatumImport = false
    var errorMessage: String?
    var activity: String?
    var activityStartedAt: Date?
    private var importing: Task<ImportedDEM, Error>?
    private var generating: Task<TerrainMesh, Error>?

    func fetchDEMNASAndGenerate() {
        guard activity == nil, selection.isFinished else { return }
        let polygon = selection.coordinates.map { GeoPoint($0) }
        guard let extent = try? MetricExtent(boundary: polygon, origin: polygon[0]) else {
            errorMessage = "Ukuran area dalam meter tidak valid."
            return
        }
        spatialResolutionMeters = AdaptiveGrid.automaticDisplayResolution(extent: extent)
        activityStartedAt = Date()
        activity = "Mengunduh elevasi DEMNAS…"
        let job = Task.detached(priority: .userInitiated) {
            let dem = try await DEMNASImageServer.download(for: polygon)
            defer { try? FileManager.default.removeItem(at: dem.directory) }
            try Task.checkCancellation()
            await MainActor.run { self.activity = "Membaca dan memotong DEMNAS sesuai poligon…" }
            let source = try GeoTIFFSource(url: dem.url, metadata: dem.metadata)
            let grid = try RasterClippingService.clip(source: source, polygon: polygon, maxAxis: 160)
            try Task.checkCancellation()
            await MainActor.run { self.activity = "Membangun permukaan terrain 3D…" }
            return try TerrainMeshGenerator.generate(grid)
        }
        generating = job
        Task {
            defer { activity = nil; activityStartedAt = nil; generating = nil }
            do {
                let result = try await job.value
                if !job.isCancelled {
                    adoptTerrain(result, fromImportedFile: false)
                }
            }
            catch is CancellationError { }
            catch let error as URLError where error.code == .timedOut {
                errorMessage = "Server DEMNAS tidak merespons sebelum batas waktu. Coba lagi saat koneksi stabil atau beberapa saat kemudian."
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func loadElevationFiles(_ urls: [URL], manualEPSG: Int? = nil) {
        guard activity == nil else { return }
        let confirmed = confirmedDEMNASImport
        let unknownDatum = verticalMetresWithUnknownDatumImport
        activityStartedAt = Date()
        activity = "Memeriksa GeoTIFF dan koordinatnya…"
        let job = Task.detached(priority: .userInitiated) {
            let result = try DEMImporter.load(urls: urls, confirmedDEMNAS: confirmed, manualEPSG: manualEPSG,
                                              verticalMetresWithUnknownDatum: unknownDatum)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: result.directory)
                throw CancellationError()
            }
            return result
        }
        importing = job
        Task {
            defer { activity = nil; activityStartedAt = nil; importing = nil }
            do {
                let result = try await job.value
                if job.isCancelled { try? FileManager.default.removeItem(at: result.directory); return }
                if let old = importedDEM { try? FileManager.default.removeItem(at: old.directory) }
                importedDEM = result
            } catch is CancellationError { }
            catch { errorMessage = "GeoTIFF tidak dapat dibaca: \(error.localizedDescription)" }
        }
    }

    func generateFromImportedDEM() {
        guard activity == nil, selection.isFinished, let importedDEM else { return }
        let polygon = selection.coordinates.map { GeoPoint($0) }
        guard let extent = try? MetricExtent(boundary: polygon, origin: polygon[0]) else {
            errorMessage = "Ukuran area dalam meter tidak valid."
            return
        }
        spatialResolutionMeters = AdaptiveGrid.automaticDisplayResolution(extent: extent)
        activityStartedAt = Date()
        activity = "Memotong GeoTIFF sesuai poligon…"
        let job = Task.detached(priority: .userInitiated) {
            let source = try GeoTIFFSource(url: importedDEM.url, confirmedDEMNAS: importedDEM.confirmedDEMNAS,
                                           manualEPSG: importedDEM.manualEPSG,
                                           verticalMetresWithUnknownDatum: importedDEM.verticalMetresWithUnknownDatum)
            try Task.checkCancellation()
            let grid = try RasterClippingService.clip(source: source, polygon: polygon, maxAxis: 160)
            try Task.checkCancellation()
            await MainActor.run { self.activity = "Membangun permukaan terrain 3D…" }
            return try TerrainMeshGenerator.generate(grid)
        }
        generating = job
        Task {
            defer { activity = nil; activityStartedAt = nil; generating = nil }
            do {
                let result = try await job.value
                if !job.isCancelled { adoptTerrain(result, fromImportedFile: true) }
            } catch is CancellationError { }
            catch { errorMessage = "GeoTIFF tidak dapat digunakan: \(error.localizedDescription)" }
        }
    }

    private func adoptTerrain(_ result: TerrainMesh, fromImportedFile: Bool) {
        if !fromImportedFile, let importedDEM {
            try? FileManager.default.removeItem(at: importedDEM.directory)
            self.importedDEM = nil
        }
        mesh = result; terrainRevision += 1; points = []; recommendation = nil; placingCPT = false
        assessmentTask?.cancel(); assessmentTask = nil; assessmentInputKey = nil; assessmentGeneration += 1
        v46Task?.cancel(); v46Task = nil
        coverageHistory.reset(); investigationAssessment = nil; minimumRecommendationSpacingMeters = nil
        reconstructionTask?.cancel(); uncertaintyTask?.cancel(); estimatedRisk = nil; estimatedRiskError = nil; estimatedRiskVersion += 1; reconstructionInputKey = nil; reconstruction = nil; reconstructionTiles = []; reconstructionSummary = nil; reconstructionVersion += 1
        dqnTask?.cancel(); v42Task?.cancel(); v42Task = nil; dqnInputKey = nil; dqnStatus = .unavailable; dqnError = nil; dqnInfo = nil; v42Detail = nil; v42QValue = nil
        dqnRecommendation = nil; dqnRecommendationSource = .none
        refreshInvestigation(); persist()
    }
    func cancel() { importing?.cancel(); generating?.cancel() }
    func reset() {
        assessmentTask?.cancel(); assessmentTask = nil; assessmentInputKey = nil; assessmentGeneration += 1
        v46Task?.cancel(); v46Task = nil
        coverageHistory.reset(); investigationAssessment = nil; minimumRecommendationSpacingMeters = nil
        selection.reset(); mesh = nil; terrainRevision += 1; drawing = false; placingCPT = false; spatialResolutionMeters = 1
        points = []; recommendation = nil; recommendationSource = .none; savedAt = nil; revision += 1
        dqnTask?.cancel(); v42Task?.cancel(); dqnTask = nil; v42Task = nil; dqnInputKey = nil; dqnError = nil; dqnInfo = nil; v42Detail = nil; v42QValue = nil; dqnStatus = .unavailable
        dqnRecommendation = nil; dqnRecommendationSource = .none
        reconstructionTask?.cancel(); uncertaintyTask?.cancel(); uncertaintyTask = nil; estimatedRisk = nil; estimatedRiskError = nil; estimatedRiskVersion += 1; reconstructionTask = nil; reconstructionInputKey = nil
        reconstruction = nil; reconstructionTiles = []; reconstructionSummary = nil; reconstructionVersion += 1; reconstructionError = nil; reconstructionStatus = .unavailable
        if let importedDEM { try? FileManager.default.removeItem(at: importedDEM.directory); self.importedDEM = nil }
        do {
            if FileManager.default.fileExists(atPath: projectURL.path) { try FileManager.default.removeItem(at: projectURL) }
        } catch { errorMessage = "Tidak dapat menghapus proyek tersimpan: \(error.localizedDescription)" }
    }
    isolated deinit {
        assessmentTask?.cancel()
        v46Task?.cancel()
        generating?.cancel()
        importing?.cancel()
        reconstructionTask?.cancel()
        uncertaintyTask?.cancel()
        dqnTask?.cancel()
        v42Task?.cancel()
        if let importedDEM { try? FileManager.default.removeItem(at: importedDEM.directory) }
    }
}
