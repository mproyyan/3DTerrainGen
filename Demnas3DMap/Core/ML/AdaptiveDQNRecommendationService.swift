import Foundation

struct AdaptiveDQNResult: Sendable {
    let coordinate: GeoPoint
    let windowed: Bool
    let explanation: String
}

/// A single physical window is chosen before scoring; Q-values are never compared across windows.
enum AdaptiveDQNRecommendationService {
    static func recommend(terrain: TerrainMesh, boundary: [GeoPoint], points: [CPTPoint],
                          reconstructorURL: URL? = nil, scorerURL: URL? = nil,
                          g16ReconstructorURL: URL? = nil) async throws -> AdaptiveDQNResult? {
        let complete = points.filter(\.isComplete)
        let extent = try MetricExtent(boundary: boundary, origin: terrain.origin)
        if extent.width <= 32 + 1e-4 && extent.height <= 32 + 1e-4 {
            guard let coordinate = try await DQNRecommendationService.recommend(
                terrain: terrain, boundary: boundary, points: complete,
                reconstructorURL: reconstructorURL, scorerURL: scorerURL,
                g16ReconstructorURL: g16ReconstructorURL
            ) else { return nil }
            return .init(coordinate: coordinate, windowed: false,
                         explanation: "DQN pada satu grid yang sesuai kontrak training.")
        }
        let windows = try AdaptiveGrid.windows(extent: extent, width: 32, height: 32, overlap: 8)
        guard let latest = complete.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) else {
            throw MLIntegrationError.invalidInput("Window DQN memerlukan CPT lengkap.")
        }
        let supported = Set([1, 2, 3, 5, 8])
        let eligible = windows.compactMap { window -> (AdaptiveWindow, [GeoPoint], [CPTPoint])? in
            guard window.contains(latest.coordinate, origin: terrain.origin) else { return nil }
            let localPoints = complete.filter { window.contains($0.coordinate, origin: terrain.origin) }
            guard supported.contains(localPoints.count) else { return nil }
            let clipped = window.clippedBoundary(boundary, origin: terrain.origin)
            guard clipped.count >= 3 else { return nil }
            return (window, clipped, localPoints)
        }
        // Deterministic pre-inference selection uses CPT coverage, then row/column.
        // No score from one window is compared with a score from another.
        guard let selected = eligible.sorted(by: {
            if $0.2.count != $1.2.count { return $0.2.count > $1.2.count }
            if $0.0.row != $1.0.row { return $0.0.row < $1.0.row }
            return $0.0.column < $1.0.column
        }).first else {
            throw MLIntegrationError.invalidInput("Belum ada window DQN 32 × 32 m di sekitar CPT terakhir dengan 1, 2, 3, 5, atau 8 profil lengkap. Fallback Heuristic.")
        }
        guard let coordinate = try await DQNRecommendationService.recommend(
            terrain: terrain, boundary: selected.1, points: selected.2,
            reconstructorURL: reconstructorURL, scorerURL: scorerURL,
            g16ReconstructorURL: g16ReconstructorURL
        ) else { return nil }
        return .init(coordinate: coordinate, windowed: true,
                     explanation: "DQN Windowed Experimental: satu window lokal 32 × 32 m dipilih dari kedekatan CPT terakhir; Q-value antar-window tidak dibandingkan. Belum divalidasi terhadap ground truth.")
    }
}
