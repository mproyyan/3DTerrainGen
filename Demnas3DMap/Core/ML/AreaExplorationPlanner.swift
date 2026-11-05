import Foundation

struct AreaExplorationCandidate: Sendable {
    let coordinate: GeoPoint
    let nearestWindowAxisDistanceMeters: Double
}

/// Suggests an exploratory CPT where no measured CPT could share a 32 m DQN
/// window with the site. This is geometry-only, never an output of DQN.
enum AreaExplorationPlanner {
    static func recommend(terrain: TerrainMesh, points: [CPTPoint]) -> AreaExplorationCandidate? {
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty, complete.count == points.count, points.count < 32 else { return nil }
        let observed = complete.map { CoordinateTransformer.localMeters($0.coordinate, origin: terrain.origin) }
        let faces = terrain.indices.count / 3
        let strideSize = max(1, faces / 600)
        var best: AreaExplorationCandidate?
        for face in stride(from: 0, to: faces, by: strideSize) {
            let indices = (0..<3).map { Int(terrain.indices[face * 3 + $0]) }
            let coordinate = GeoPoint(
                longitude: indices.map { terrain.geographicVertices[$0].longitude }.reduce(0, +) / 3,
                latitude: indices.map { terrain.geographicVertices[$0].latitude }.reduce(0, +) / 3
            )
            let local = CoordinateTransformer.localMeters(coordinate, origin: terrain.origin)
            let nearest = observed.map { max(abs(local.x - $0.x), abs(local.y - $0.y)) }.min() ?? 0
            guard nearest > 32 + 1e-4, nearest > (best?.nearestWindowAxisDistanceMeters ?? 32),
                  terrain.surfacePosition(at: coordinate) != nil else { continue }
            best = AreaExplorationCandidate(coordinate: coordinate,
                                            nearestWindowAxisDistanceMeters: nearest)
        }
        return best
    }
}
