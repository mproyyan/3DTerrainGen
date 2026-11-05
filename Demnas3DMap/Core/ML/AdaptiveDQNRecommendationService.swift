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
        guard !complete.isEmpty else {
            throw MLIntegrationError.invalidInput("Window DQN memerlukan CPT lengkap.")
        }
        let supported = Set([1, 2, 3, 5, 8])
        let eligible = windows.compactMap { window -> (AdaptiveWindow, [GeoPoint], [CPTPoint])? in
            let localPoints = complete.filter { window.contains($0.coordinate, origin: terrain.origin) }
            guard supported.contains(localPoints.count) else { return nil }
            let clipped = window.clippedBoundary(boundary, origin: terrain.origin)
            guard clipped.count >= 3 else { return nil }
            // A clipped 32 m window uses g16; narrower slices may use g24.
            let local = clipped.map { CoordinateTransformer.localMeters($0, origin: terrain.origin) }
            let width = (local.map(\.x).max() ?? 0) - (local.map(\.x).min() ?? 0)
            let height = (local.map(\.y).max() ?? 0) - (local.map(\.y).min() ?? 0)
            let requiredDepth = width > 24 || height > 24 ? 15.5 : 11.5
            guard localPoints.allSatisfy({ ($0.interpretation?.values.last?.depth ?? 0) >= requiredDepth }) else { return nil }
            return (window, clipped, localPoints)
        }
        // Window choice is a deterministic physical coverage rule, not a Q-value comparison.
        guard let selected = selectWindow(eligible, allPoints: complete, origin: terrain.origin) else {
            throw MLIntegrationError.invalidInput("Belum ada window DQN dengan 1, 2, 3, 5, atau 8 profil CPT lengkap dan kedalaman memadai. Fallback Heuristic.")
        }
        let clippedExtent = try MetricExtent(boundary: selected.1, origin: terrain.origin)
        // Site-planning constraint only for experimental windowed inference.
        // It changes the legal action set, so this is not the validated training policy.
        let minimumSpacing = max(2.001, min(clippedExtent.width, clippedExtent.height) / 4)
        guard let coordinate = try await DQNRecommendationService.recommend(
            terrain: terrain, boundary: selected.1, points: selected.2,
            reconstructorURL: reconstructorURL, scorerURL: scorerURL,
            g16ReconstructorURL: g16ReconstructorURL,
            minimumSpacingMeters: minimumSpacing, spacingPoints: complete
        ) else {
            throw MLIntegrationError.invalidInput(String(format: "Tidak ada kandidat DQN dalam window terpilih yang berjarak minimal %.1f m dari CPT; fallback Heuristic.", minimumSpacing))
        }
        return .init(coordinate: coordinate, windowed: true,
                     explanation: String(format: "DQN Windowed Experimental: window lokal (%.0f, %.0f)–(%.0f, %.0f) m dipilih dari cakupan area yang belum teramati; kandidat DQN dibatasi jarak minimal %.1f m dari CPT. Ini aturan survei tambahan yang belum divalidasi. Q-value antar-window tidak dibandingkan.", selected.0.west, selected.0.south, selected.0.east, selected.0.north, minimumSpacing))
    }

    /// Prefer valid physical area farther from all existing CPTs, capped at 16 m per
    /// sample so a single remote corner cannot dominate. This is only a window
    /// selection heuristic; the frozen DQN still scores candidates inside it.
    static func selectWindow(_ eligible: [(AdaptiveWindow, [GeoPoint], [CPTPoint])],
                             allPoints: [CPTPoint], origin: GeoPoint) -> (AdaptiveWindow, [GeoPoint], [CPTPoint])? {
        let observed = allPoints.map { CoordinateTransformer.localMeters($0.coordinate, origin: origin) }
        return eligible.max { lhs, rhs in
            let left = coverageScore(window: lhs.0, polygon: lhs.1, observed: observed, origin: origin)
            let right = coverageScore(window: rhs.0, polygon: rhs.1, observed: observed, origin: origin)
            if abs(left - right) > 1e-8 { return left < right }
            if lhs.0.row != rhs.0.row { return lhs.0.row > rhs.0.row }
            return lhs.0.column > rhs.0.column
        }
    }

    private static func coverageScore(window: AdaptiveWindow, polygon: [GeoPoint],
                                      observed: [Point2], origin: GeoPoint) -> Double {
        let localPolygon = polygon.map { CoordinateTransformer.localMeters($0, origin: origin) }
        var score = 0.0
        for y in stride(from: 2.0, to: window.height, by: 4.0) {
            for x in stride(from: 2.0, to: window.width, by: 4.0) {
                let site = Point2(x: window.west + x, y: window.south + y)
                guard Geometry.contains(site, in: localPolygon) else { continue }
                let nearest = observed.map { hypot(site.x - $0.x, site.y - $0.y) }.min() ?? 0
                score += min(nearest, 16) / 16
            }
        }
        return score
    }
}
