import Foundation
import Observation

enum ReconstructionStatus: String {
    case unavailable, loading, reconstructing, ready, error
}

enum RecommendationSource: String {
    case none, heuristic, dqn
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
    var spatialResolutionMeters = 1.0
    var revision = 0
    var savedAt: Date?
    var recommendation: GeoPoint?
    var recommendationSource = RecommendationSource.none
    var dqnStatus = DQNStatus.unavailable
    var dqnError: String?
    var dqnInfo: String?
    private var dqnTask: Task<AdaptiveDQNResult?, Error>?
    private var dqnInputKey: String?
    private var dqnGeneration = 0
    var reconstruction: ReconstructionVolume?
    var reconstructionTiles: [ReconstructionVolume] = []
    var reconstructionSummary: String?
    var reconstructionVersion = 0
    var reconstructionStatus = ReconstructionStatus.unavailable
    var reconstructionError: String?
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
            mesh = project.terrain; points = project.points; scenario = project.scenario
            if let extent = try? MetricExtent(boundary: project.boundary, origin: project.terrain.origin) {
                spatialResolutionMeters = AdaptiveGrid.automaticDisplayResolution(extent: extent)
            }
            savedAt = try projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            refreshInvestigation()
        } catch { errorMessage = "Proyek tersimpan tidak dapat dibuka: \(error.localizedDescription)" }
    }

    func refreshInvestigation() {
        revision += 1
        recommendation = mesh.flatMap { InvestigationSimulator.recommendation(points: points, scenario: scenario, terrain: $0) }
        recommendationSource = recommendation == nil ? .none : .heuristic
        refreshReconstructionIfNeeded()
        refreshDQNIfNeeded()
    }

    private func refreshDQNIfNeeded() {
        let key = points.map { "\($0.id.uuidString):\($0.updatedAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|") + ":\(scenario.rawValue)"
        guard key != dqnInputKey else { return }
        dqnInputKey = key
        dqnGeneration += 1
        dqnTask?.cancel()
        dqnTask = nil
        dqnError = nil
        dqnInfo = nil
        guard let mesh, status.completed > 0, status.pending == 0, !status.finished else {
            dqnStatus = .unavailable
            return
        }
        let currentGeneration = dqnGeneration
        let boundary = selection.coordinates.map { GeoPoint($0) }
        let complete = points.filter(\.isComplete)
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
                    recommendation = candidate.coordinate
                    recommendationSource = candidate.windowed ? .dqnWindowedExperimental : .dqn
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

    private func refreshReconstructionIfNeeded() {
        let complete = points.filter(\.isComplete)
        let key = complete.map { "\($0.id.uuidString):\($0.updatedAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
        guard key != reconstructionInputKey else { return }
        reconstructionInputKey = key
        reconstructionGeneration += 1
        reconstructionTask?.cancel()
        reconstructionTask = nil
        reconstruction = nil
        reconstructionTiles = []
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
        guard points.count < 32 else { throw TerrainError("PoC dibatasi 32 titik per proyek.") }
        guard points.allSatisfy({ CoordinateTransformer.localMeters(coordinate, origin: $0.coordinate).length >= 2 }) else {
            throw TerrainError("Jarak titik CPT minimal 2 m dari titik lain.")
        }
        let id = UUID()
        let used = Set(points.map(\.name))
        let number = (1...33).first { !used.contains("CPT-\($0)") }!
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
    var mesh: TerrainMesh?
    var errorMessage: String?
    var activity: String?
    private var generating: Task<TerrainMesh, Error>?

    func fetchDEMNASAndGenerate() {
        guard activity == nil, selection.isFinished else { return }
        let polygon = selection.coordinates.map { GeoPoint($0) }
        guard let extent = try? MetricExtent(boundary: polygon, origin: polygon[0]) else {
            errorMessage = "Ukuran area dalam meter tidak valid."
            return
        }
        spatialResolutionMeters = AdaptiveGrid.automaticDisplayResolution(extent: extent)
        activity = "Downloading DEMNAS, clipping elevations, and building terrain…"
        let job = Task.detached(priority: .userInitiated) {
            let dem = try await DEMNASImageServer.download(for: polygon)
            defer { try? FileManager.default.removeItem(at: dem.directory) }
            let source = try GeoTIFFSource(url: dem.url, metadata: dem.metadata)
            let grid = try RasterClippingService.clip(source: source, polygon: polygon, maxAxis: 160)
            return try TerrainMeshGenerator.generate(grid)
        }
        generating = job
        Task {
            defer { activity = nil; generating = nil }
            do {
                let result = try await job.value
                if !job.isCancelled {
                    mesh = result; points = []; recommendation = nil; placingCPT = false
                    reconstructionTask?.cancel(); reconstructionInputKey = nil; reconstruction = nil; reconstructionTiles = []; reconstructionSummary = nil; reconstructionVersion += 1
                    dqnTask?.cancel(); dqnInputKey = nil; dqnStatus = .unavailable; dqnError = nil; dqnInfo = nil
                    refreshInvestigation(); persist()
                }
            }
            catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }
    func cancel() { generating?.cancel() }
    func reset() {
        selection.reset(); mesh = nil; drawing = false; placingCPT = false; spatialResolutionMeters = 1
        points = []; recommendation = nil; recommendationSource = .none; savedAt = nil; revision += 1
        dqnTask?.cancel(); dqnTask = nil; dqnInputKey = nil; dqnError = nil; dqnInfo = nil; dqnStatus = .unavailable
        reconstructionTask?.cancel(); reconstructionTask = nil; reconstructionInputKey = nil
        reconstruction = nil; reconstructionTiles = []; reconstructionSummary = nil; reconstructionVersion += 1; reconstructionError = nil; reconstructionStatus = .unavailable
        do {
            if FileManager.default.fileExists(atPath: projectURL.path) { try FileManager.default.removeItem(at: projectURL) }
        } catch { errorMessage = "Tidak dapat menghapus proyek tersimpan: \(error.localizedDescription)" }
    }
    isolated deinit {
        generating?.cancel()
        reconstructionTask?.cancel()
        dqnTask?.cancel()
    }
}
