import Foundation

struct TiledModelCResult: Sendable {
    let volumes: [ReconstructionVolume]
    let plannedWindows: Int
    let windowsWithoutCPT: Int
    let unsupportedWindows: Int
    let inferenceSeconds: Double

    /// Resident voxel arrays only include windows with a supported observed CPT.
    var estimatedVolumeBytes: Int {
        volumes.reduce(0) { $0 + $1.grid.voxelCount * (MemoryLayout<Float>.size + 3 * MemoryLayout<Bool>.size) }
    }
}

/// Runs fixed-size Model C Flexible inputs one at a time. Empty windows remain unknown.
enum TiledModelCReconstruction {
    static func reconstruct(terrain: TerrainMesh, boundary: [GeoPoint], points: [CPTPoint], modelURL: URL? = nil) async throws -> TiledModelCResult {
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty else { throw MLIntegrationError.invalidInput("Model C memerlukan profil CPT lengkap.") }
        let extent = try MetricExtent(boundary: boundary, origin: terrain.origin)
        let service = try ModelCService(modelURL: modelURL)
        let started = ProcessInfo.processInfo.systemUptime
        if extent.width <= 47, extent.height <= 31 {
            let grid = try ReconstructionGrid.fitting(boundary: boundary, points: complete, origin: terrain.origin)
            let prepared = try ModelCInputAdapter.prepare(terrain: terrain, boundary: boundary, points: complete, grid: grid)
            let values = try await service.reconstruct(sparse: prepared.sparse, mask: prepared.mask,
                                                        idw: prepared.idw, observedIc: prepared.observedIc, grid: grid)
            return TiledModelCResult(volumes: [try prepared.volume(reconstruction: values)],
                                     plannedWindows: 1, windowsWithoutCPT: 0, unsupportedWindows: 0,
                                     inferenceSeconds: ProcessInfo.processInfo.systemUptime - started)
        }
        let windows = try AdaptiveGrid.windows(extent: extent, width: 48, height: 32, overlap: 8)
        var volumes = [ReconstructionVolume]()
        var empty = 0, unsupported = 0
        for window in windows {
            try Task.checkCancellation()
            let localPoints = complete.filter { window.contains($0.coordinate, origin: terrain.origin) }
            guard !localPoints.isEmpty else { empty += 1; continue }
            let clipped = window.clippedBoundary(boundary, origin: terrain.origin)
            guard clipped.count >= 3 else { unsupported += 1; continue }
            let availableDepth = localPoints.compactMap { $0.interpretation?.values.last?.depth }.min() ?? 0
            let nz = availableDepth >= 15.5 ? 16 : availableDepth >= 11.5 ? 12 : availableDepth >= 7.5 ? 8 : 0
            guard nz > 0 else { unsupported += 1; continue }
            let grid = ReconstructionGrid(nx: 48, ny: 32, nz: nz, spacingMeters: 1)
            do {
                let prepared = try ModelCInputAdapter.prepare(
                    terrain: terrain, boundary: clipped, points: localPoints, grid: grid,
                    westMeters: window.west, southMeters: window.south
                )
                let values = try await service.reconstruct(sparse: prepared.sparse, mask: prepared.mask,
                                                            idw: prepared.idw, observedIc: prepared.observedIc, grid: grid)
                volumes.append(try prepared.volume(reconstruction: values))
            } catch is CancellationError { throw CancellationError() }
            catch { unsupported += 1 }
        }
        guard !volumes.isEmpty else {
            throw MLIntegrationError.invalidInput("Tidak ada window Model C dengan CPT lengkap dan grid yang kompatibel; area lain tetap belum diketahui.")
        }
        return TiledModelCResult(volumes: volumes, plannedWindows: windows.count,
                                 windowsWithoutCPT: empty, unsupportedWindows: unsupported,
                                 inferenceSeconds: ProcessInfo.processInfo.systemUptime - started)
    }
}

/// Seam blending uses physical metres and keeps measured CPT voxels exact.
struct TiledIcSampler: Sendable {
    let volumes: [ReconstructionVolume]
    let overlapMeters: Double

    func sample(east: Double, north: Double, depthIndex: Int) -> Float? {
        var weighted = 0.0, weightSum = 0.0
        for volume in volumes where depthIndex < volume.grid.nz {
            let spacing = volume.grid.spacingMeters
            let x = Int(floor((east - volume.westMeters) / spacing))
            let y = Int(floor((north - volume.southMeters) / spacing))
            guard (0..<volume.grid.nx).contains(x), (0..<volume.grid.ny).contains(y),
                  volume.isValid(x: x, y: y) else { continue }
            let index = volume.index(x: x, y: y, z: depthIndex)
            if volume.observed[index] { return volume.values[index] }
            let edge = min(east - volume.westMeters,
                           volume.westMeters + Double(volume.grid.nx) * spacing - east,
                           north - volume.southMeters,
                           volume.southMeters + Double(volume.grid.ny) * spacing - north)
            let weight = max(0.01, min(1, edge / max(overlapMeters, spacing)))
            weighted += Double(volume.values[index]) * weight
            weightSum += weight
        }
        return weightSum > 0 ? Float(weighted / weightSum) : nil
    }
}
