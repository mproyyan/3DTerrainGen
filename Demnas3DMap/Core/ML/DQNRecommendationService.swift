import Foundation

/// DQN V3 inference uses the frozen SchemaGAN V3 checkpoint paired with the scorer.
/// The displayed Model C volume is deliberately not fed into this policy.
enum DQNRecommendationService {
    static func recommend(terrain: TerrainMesh, boundary: [GeoPoint], points: [CPTPoint],
                          reconstructorURL: URL? = nil, scorerURL: URL? = nil,
                          g16ReconstructorURL: URL? = nil) async throws -> GeoPoint? {
        let complete = points.filter(\.isComplete)
        guard [1, 2, 3, 5, 8].contains(complete.count) else {
            throw MLIntegrationError.invalidInput("DQN mendukung 1, 2, 3, 5, atau 8 profil CPT lengkap.")
        }
        let localBoundary = boundary.map { CoordinateTransformer.localMeters($0, origin: terrain.origin) }
        guard let minEast = localBoundary.map(\.x).min(), let maxEast = localBoundary.map(\.x).max(),
              let minNorth = localBoundary.map(\.y).min(), let maxNorth = localBoundary.map(\.y).max() else {
            throw MLIntegrationError.invalidInput("Batas area DQN belum tersedia.")
        }
        let eastSpan = maxEast - minEast, northSpan = maxNorth - minNorth
        let useG16 = eastSpan > 24 || northSpan > 24
        guard eastSpan.isFinite, northSpan.isFinite, eastSpan > 0, northSpan > 0,
              eastSpan <= 32 + 1e-4, northSpan <= 32 + 1e-4 else {
            throw MLIntegrationError.invalidInput(String(format:
                "Ukuran area %.1f × %.1f m. DQN mendukung grid g24 24 × 24 sel @ 1 m (24 × 24 m) atau g16 16 × 16 sel @ 2 m (32 × 32 m), keduanya dengan kedalaman 1 m/sel. Area ini memakai fallback Heuristic.",
                eastSpan, northSpan))
        }
        let prepared = try useG16
            ? DQNInputG16Adapter.prepare(terrain: terrain, boundary: boundary, points: complete)
            : ModelCInputAdapter.prepare(
                terrain: terrain, boundary: boundary, points: complete,
                icMean: DQNReconstructorService.icMean, icStd: DQNReconstructorService.icStd
            )
        try Task.checkCancellation()
        let values: [Float]
        if useG16 {
            let reconstructor = try DQNReconstructorG16Service(modelURL: g16ReconstructorURL)
            values = try await reconstructor.reconstruct(
                sparse: prepared.sparse, mask: prepared.mask, idw: prepared.idw,
                observedIc: prepared.observedIc
            )
        } else {
            let reconstructor = try DQNReconstructorService(modelURL: reconstructorURL)
            values = try await reconstructor.reconstruct(
                sparse: prepared.sparse, mask: prepared.mask, idw: prepared.idw,
                observedIc: prepared.observedIc
            )
        }
        try Task.checkCancellation()
        let volume = try prepared.volume(reconstruction: values)
        let candidates = try DQNFeatureAdapter.candidates(volume: volume, terrain: terrain)
            .filter { candidate in
                complete.allSatisfy { point in
                    let actual = CoordinateTransformer.localMeters(point.coordinate, origin: terrain.origin)
                    return hypot(candidate.eastMeters - actual.x, candidate.northMeters - actual.y) >= 2.001
                }
            }
        guard !candidates.isEmpty else { return nil }
        let scorer = try DQNScorerService(modelURL: scorerURL)
        let scores = try await scorer.score(candidateFeatures: candidates.map(\.features))
        try Task.checkCancellation()
        // Candidates are ordered lexicographically (x,y); first argmax wins ties.
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] || (scores[$0] == scores[$1] && $0 > $1) }) else { return nil }
        let site = candidates[best]
        let coordinate = geographic(east: site.eastMeters, north: site.northMeters, origin: terrain.origin)
        let local = CoordinateTransformer.localMeters(coordinate, origin: terrain.origin)
        guard hypot(local.x - site.eastMeters, local.y - site.northMeters) < 0.05,
              terrain.surfacePosition(at: coordinate) != nil else {
            throw MLIntegrationError.invalidOutput("DQN candidate coordinate conversion")
        }
        return coordinate
    }

    /// Local ENU offsets are at most 32 m. Inverting with WGS84 radii is sub-centimetre here.
    private static func geographic(east: Double, north: Double, origin: GeoPoint) -> GeoPoint {
        let latitude = origin.latitude * .pi / 180
        let e2 = 0.0066943799901413165
        let sinLat = sin(latitude)
        let denominator = sqrt(1 - e2 * sinLat * sinLat)
        let primeVertical = 6378137.0 / denominator
        let meridional = 6378137.0 * (1 - e2) / pow(1 - e2 * sinLat * sinLat, 1.5)
        return GeoPoint(longitude: origin.longitude + east / (primeVertical * cos(latitude)) * 180 / .pi,
                        latitude: origin.latitude + north / meridional * 180 / .pi)
    }
}
