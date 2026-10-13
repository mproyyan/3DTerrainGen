import Foundation
import Observation

@MainActor @Observable
final class TerrainSession {
    var selection = PolygonSelectionModel()
    var drawing = false
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
                imported = result; mesh = nil
                pendingURLsForCRSSelection = nil
            } catch is CancellationError { } catch {
                errorMessage = error.localizedDescription
            }
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
            do { let result = try await job.value; if !job.isCancelled { mesh = result } }
            catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }
    func cancel() { importing?.cancel(); generating?.cancel() }
    func reset() { selection.reset(); mesh = nil; drawing = false }
    isolated deinit {
        importing?.cancel(); generating?.cancel()
        if let imported { try? FileManager.default.removeItem(at: imported.directory) }
    }
}
