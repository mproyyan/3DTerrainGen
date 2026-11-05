import Foundation
import Observation

enum ReconstructionStatus: String {
    case unavailable, loading, reconstructing, ready, error
}

enum RecommendationSource: String {
    case none, heuristic, dqn
    case dqnV42 = "DQN V4.2"
    case dqnV45 = "DQN V4.5"
    case explorationHeuristic = "Explorasi Heuristic"
    case dqnWindowedExperimental = "DQN Windowed Experimental"
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
    var explorationRecommendation: GeoPoint?
    var dqnRecommendation: GeoPoint?
    var dqnRecommendationSource = RecommendationSource.none
    var dqnStatus = DQNStatus.unavailable
    var dqnError: String?
    var dqnInfo: String?
    var v42Detail: String?
    var v42QValue: Float?
    var v45Diagnostics: V45RunDiagnostics?
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
        let exploration = mesh.flatMap { AreaExplorationPlanner.recommend(terrain: $0, points: points) }
        explorationRecommendation = exploration?.coordinate
        dqnRecommendation = nil
        dqnRecommendationSource = .none
        recommendation = explorationRecommendation ?? mesh.flatMap {
            InvestigationSimulator.recommendation(points: points, scenario: scenario, terrain: $0)
        }
        recommendationSource = exploration != nil ? .explorationHeuristic : recommendation == nil ? .none : .heuristic
        refreshReconstructionIfNeeded()
        refreshDQNIfNeeded()
    }

    private func refreshDQNIfNeeded() {
        let key = points.map { "\($0.id.uuidString):\($0.updatedAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|") + ":\(scenario.rawValue)"
        // A refreshed recommendation must rerun ML even when CPT timestamps are unchanged.
        dqnInputKey = key
        dqnGeneration += 1
        dqnTask?.cancel()
        v42Task?.cancel()
        dqnTask = nil
        v42Task = nil
        dqnError = nil
        dqnInfo = nil
        v42QValue = nil
        v45Diagnostics = nil
        guard let mesh else {
            dqnStatus = .unavailable
            v42Detail = "DQN V4.5 belum dijalankan: terrain belum dibuat."
            return
        }
        guard status.completed > 0 else {
            dqnStatus = .unavailable
            v42Detail = "DQN V4.5 menunggu minimal satu CPT dengan profil Ic tersimpan."
            return
        }
        guard status.pending == 0 else {
            dqnStatus = .unavailable
            v42Detail = "DQN V4.5 menunggu hasil semua titik CPT yang sudah ditetapkan (\(status.pending) belum lengkap)."
            return
        }
        let currentGeneration = dqnGeneration
        let boundary = selection.coordinates.map { GeoPoint($0) }
        let complete = points.filter(\.isComplete)
        guard let extent = try? MetricExtent(boundary: boundary, origin: mesh.origin) else {
            dqnStatus = .fallback
            v42Detail = "DQN V4.5 belum dijalankan: ukuran poligon tidak dapat dihitung dalam meter."
            return
        }
        if let plan = try? V42GridPlan.make(extent: extent, points: complete, preferredMeters: spatialResolutionMeters) {
            v42Detail = String(format: "SchemaGAN V4.2 Flexible + DQN V4.5 sedang menghitung area %.1f × %.1f m pada grid %d × %d × %d @ %.2f m/sel.", extent.width, extent.height, plan.nx, plan.ny, plan.nz, plan.horizontalMeters)
            dqnStatus = .recommending
            let preferredMeters = spatialResolutionMeters
            let job = Task.detached(priority: .userInitiated) {
                try await V45RecommendationService.recommend(terrain: mesh, boundary: boundary, points: complete,
                                                            preferredMeters: preferredMeters)
            }
            v42Task = job
            Task {
                do {
                    let result = try await job.value
                    guard !job.isCancelled, currentGeneration == dqnGeneration else { return }
                    guard let result else {
                        dqnStatus = .fallback
                        dqnError = "Tidak ada kandidat legal DQN V4.5; pilih titik manual atau eksplorasi."
                        v42Detail = "DQN V4.5 dijalankan tetapi tidak menemukan kandidat legal pada grid yang dipilih."
                        return
                    }
                    dqnRecommendation = result.coordinate
                    dqnRecommendationSource = .dqnV45
                    recommendation = result.coordinate
                    recommendationSource = .dqnV45
                    dqnInfo = "DQN V4.5 on-device: \(result.volume.grid.nx) × \(result.volume.grid.ny) × \(result.volume.grid.nz) sel @ \(result.volume.grid.spacingMeters.formatted()) m; Q-value seluruh kandidat legal dibandingkan pada satu grid."
                    v42QValue = result.qValue
                    v45Diagnostics = result.v45Diagnostics
                    v42Detail = String(format: "DQN V4.5 aktif dengan SchemaGAN V4.2 Flexible: area %.1f × %.1f m, grid %d × %d × %d @ %.2f m/sel horizontal.", extent.width, extent.height, result.volume.grid.nx, result.volume.grid.ny, result.volume.grid.nz, result.volume.grid.spacingMeters)
                    dqnStatus = .ready
                    reconstruction = result.volume
                    reconstructionError = nil
                    reconstructionTiles = [result.volume]
                    reconstructionSummary = "SchemaGAN V4.2 Flexible: Ic 3D pada grid \(result.volume.grid.nx) × \(result.volume.grid.ny) × \(result.volume.grid.nz); nilai CPT terukur dipertahankan."
                    reconstructionVersion += 1
                    reconstructionStatus = .ready
                    let riskJob = Task.detached(priority: .utility) {
                        let model = try UncertaintyV2Model.bundled()
                        return try UncertaintyV2Features.makeMap(volume: result.volume, model: model)
                    }
                    uncertaintyTask = riskJob
                    Task {
                        do {
                            let risk = try await riskJob.value
                            guard !riskJob.isCancelled, currentGeneration == dqnGeneration else { return }
                            estimatedRisk = risk
                            estimatedRiskVersion += 1
                        } catch is CancellationError { return }
                        catch {
                            guard !riskJob.isCancelled, currentGeneration == dqnGeneration else { return }
                            estimatedRiskError = error.localizedDescription
                        }
                    }
                } catch is CancellationError { return }
                catch {
                    guard !job.isCancelled, currentGeneration == dqnGeneration else { return }
                    dqnStatus = .fallback
                    dqnError = error.localizedDescription
                    v42Detail = "DQN V4.5 dijalankan tetapi gagal: \(error.localizedDescription)"
                }
            }
            return
        }
        let planningError: String
        do { _ = try V42GridPlan.make(extent: extent, points: complete, preferredMeters: spatialResolutionMeters); planningError = "Grid tidak kompatibel." }
        catch { planningError = error.localizedDescription }
        v42Detail = "DQN V4.5 tidak tersedia: \(planningError) Mencoba pipeline V3 lokal eksperimental; titik eksplorasi tetap Heuristic."
        dqnStatus = .recommending
        let job = Task.detached(priority: .userInitiated) {
            try await AdaptiveDQNRecommendationService.recommend(terrain: mesh, boundary: boundary, points: complete)
        }
        dqnTask = job
        Task {
            do {
                let candidate = try await job.value
                guard !job.isCancelled, currentGeneration == dqnGeneration else { return }
                if let candidate {
                    dqnRecommendation = candidate.coordinate
                    dqnRecommendationSource = candidate.windowed ? .dqnWindowedExperimental : .dqn
                    recommendation = candidate.coordinate
                    recommendationSource = dqnRecommendationSource
                    dqnInfo = candidate.explanation
                    dqnStatus = .ready
                } else {
                    dqnStatus = .fallback
                    dqnError = "Tidak ada kandidat DQN yang memenuhi batas area dan jarak CPT."
                }
            } catch is CancellationError {
                return
            } catch {
                guard !job.isCancelled, currentGeneration == dqnGeneration else { return }
                dqnStatus = .fallback
                dqnError = error.localizedDescription
            }
        }
    }

    func chooseRecommendation(_ source: RecommendationSource) {
        switch source {
        case .explorationHeuristic:
            guard let explorationRecommendation else { return }
            recommendation = explorationRecommendation
            recommendationSource = .explorationHeuristic
        case .dqn, .dqnWindowedExperimental, .dqnV42, .dqnV45:
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
                if dqnRecommendationSource == .dqnV45 { return }
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
        reconstructionTask?.cancel(); uncertaintyTask?.cancel(); estimatedRisk = nil; estimatedRiskError = nil; estimatedRiskVersion += 1; reconstructionInputKey = nil; reconstruction = nil; reconstructionTiles = []; reconstructionSummary = nil; reconstructionVersion += 1
        dqnTask?.cancel(); v42Task?.cancel(); v42Task = nil; dqnInputKey = nil; dqnStatus = .unavailable; dqnError = nil; dqnInfo = nil; v42Detail = nil; v42QValue = nil
        dqnRecommendation = nil; dqnRecommendationSource = .none; explorationRecommendation = nil
        refreshInvestigation(); persist()
    }
    func cancel() { importing?.cancel(); generating?.cancel() }
    func reset() {
        selection.reset(); mesh = nil; terrainRevision += 1; drawing = false; placingCPT = false; spatialResolutionMeters = 1
        points = []; recommendation = nil; recommendationSource = .none; savedAt = nil; revision += 1
        dqnTask?.cancel(); v42Task?.cancel(); dqnTask = nil; v42Task = nil; dqnInputKey = nil; dqnError = nil; dqnInfo = nil; v42Detail = nil; v42QValue = nil; dqnStatus = .unavailable
        dqnRecommendation = nil; dqnRecommendationSource = .none; explorationRecommendation = nil
        reconstructionTask?.cancel(); uncertaintyTask?.cancel(); uncertaintyTask = nil; estimatedRisk = nil; estimatedRiskError = nil; estimatedRiskVersion += 1; reconstructionTask = nil; reconstructionInputKey = nil
        reconstruction = nil; reconstructionTiles = []; reconstructionSummary = nil; reconstructionVersion += 1; reconstructionError = nil; reconstructionStatus = .unavailable
        if let importedDEM { try? FileManager.default.removeItem(at: importedDEM.directory); self.importedDEM = nil }
        do {
            if FileManager.default.fileExists(atPath: projectURL.path) { try FileManager.default.removeItem(at: projectURL) }
        } catch { errorMessage = "Tidak dapat menghapus proyek tersimpan: \(error.localizedDescription)" }
    }
    isolated deinit {
        generating?.cancel()
        importing?.cancel()
        reconstructionTask?.cancel()
        uncertaintyTask?.cancel()
        dqnTask?.cancel()
        v42Task?.cancel()
        if let importedDEM { try? FileManager.default.removeItem(at: importedDEM.directory) }
    }
}
