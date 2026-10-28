import Foundation
import Observation

@MainActor @Observable
final class TerrainSession {
    var selection = PolygonSelectionModel()
    var drawing = false
    var placingCPT = false
    var points: [CPTPoint] = []
    var scenario = InvestigationScenario.variable
    var revision = 0
    var savedAt: Date?
    var recommendation: GeoPoint?
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
            savedAt = try projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            refreshInvestigation()
        } catch { errorMessage = "Proyek tersimpan tidak dapat dibuka: \(error.localizedDescription)" }
    }

    func refreshInvestigation() {
        revision += 1
        recommendation = mesh.flatMap { InvestigationSimulator.recommendation(points: points, scenario: scenario, terrain: $0) }
    }

    func persist() {
        guard let mesh else { return }
        do {
            let project = InvestigationProject(boundary: selection.coordinates.map { GeoPoint($0) }, terrain: mesh, points: points, scenario: scenario)
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
    var showFootprint = true
    var confirmedDEMNAS = false
    // Manual CRS override – used only when the file carries no detectable CRS.
    var useManualEPSG = false
    var manualEPSGCode: String = ""
    /// Parsed integer override; nil when the toggle is off or the input is not a valid number.
    var manualEPSG: Int? { useManualEPSG ? Int(manualEPSGCode.trimmingCharacters(in: .whitespaces)) : nil }
    var imported: ImportedDEM?
    var mesh: TerrainMesh?
    var errorMessage: String?
    var activity: String?
    private var importing: Task<ImportedDEM, Error>?
    private var generating: Task<TerrainMesh, Error>?

    var pendingURLsForCRSSelection: [URL]? = nil

    func load(_ urls: [URL], overrideEPSG: Int? = nil) {
        guard activity == nil else { return }
        let confirmation = confirmedDEMNAS
        let epsgOverride = overrideEPSG ?? manualEPSG
        activity = "Reading GeoTIFF and validating georeferencing…"
        let job = Task.detached(priority: .userInitiated) {
            let result = try DEMImporter.load(urls: urls, confirmedDEMNAS: confirmation, manualEPSG: epsgOverride)
            if Task.isCancelled { try? FileManager.default.removeItem(at: result.directory); throw CancellationError() }
            return result
        }
        importing = job
        Task {
            defer { activity = nil; importing = nil }
            do {
                let result = try await job.value
                if job.isCancelled { try? FileManager.default.removeItem(at: result.directory); return }
                if let old = imported { try? FileManager.default.removeItem(at: old.directory) }
                imported = result; mesh = nil; points = []; recommendation = nil; placingCPT = false
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }

    func generate() {
        guard activity == nil, let imported, selection.isFinished else { return }
        let polygon = selection.coordinates.map { GeoPoint($0) }
        activity = "Checking coverage, clipping elevations, and building terrain…"
        let job = Task.detached(priority: .userInitiated) {
            let source = try GeoTIFFSource(url: imported.url, confirmedDEMNAS: imported.confirmedDEMNAS,
                                           manualEPSG: imported.manualEPSG)
            let grid = try RasterClippingService.clip(source: source, polygon: polygon)
            return try TerrainMeshGenerator.generate(grid)
        }
        generating = job
        Task {
            defer { activity = nil; generating = nil }
            do {
                let result = try await job.value
                if !job.isCancelled {
                    mesh = result; points = []; recommendation = nil; placingCPT = false
                    refreshInvestigation(); persist()
                }
            }
            catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }

    func fetchDEMNASAndGenerate() {
        guard activity == nil, selection.isFinished else { return }
        let polygon = selection.coordinates.map { GeoPoint($0) }
        activity = "Downloading DEMNAS, clipping elevations, and building terrain…"
        let job = Task.detached(priority: .userInitiated) {
            let dem = try await DEMNASImageServer.download(for: polygon)
            defer { try? FileManager.default.removeItem(at: dem.directory) }
            let source = try GeoTIFFSource(url: dem.url, metadata: dem.metadata)
            let grid = try RasterClippingService.clip(source: source, polygon: polygon)
            return try TerrainMeshGenerator.generate(grid)
        }
        generating = job
        Task {
            defer { activity = nil; generating = nil }
            do {
                let result = try await job.value
                if !job.isCancelled {
                    mesh = result; points = []; recommendation = nil; placingCPT = false
                    refreshInvestigation(); persist()
                }
            }
            catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancel() { importing?.cancel(); generating?.cancel() }

    func reset() {
        selection.reset(); mesh = nil; drawing = false; placingCPT = false
        points = []; recommendation = nil; savedAt = nil; revision += 1
        if let old = imported { try? FileManager.default.removeItem(at: old.directory); imported = nil }
        do {
            if FileManager.default.fileExists(atPath: projectURL.path) { try FileManager.default.removeItem(at: projectURL) }
        } catch { errorMessage = "Tidak dapat menghapus proyek tersimpan: \(error.localizedDescription)" }
    }

    isolated deinit {
        importing?.cancel(); generating?.cancel()
        if let imported { try? FileManager.default.removeItem(at: imported.directory) }
    }
}
