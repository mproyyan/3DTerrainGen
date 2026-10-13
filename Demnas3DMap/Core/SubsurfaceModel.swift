import Foundation
import simd

struct SubsurfaceColumn: Sendable {
    let surface: SIMD3<Float>
    let width: Float
    let length: Float
    let top: Double
    let bottom: Double
    let behavior: SoilBehavior?
    let observed: Bool
}

enum SubsurfaceModel {
    /// A bounded grid of columns, not a geological interpolation or a probabilistic uncertainty model.
    static func columns(terrain: TerrainMesh, boundary: [GeoPoint], points: [CPTPoint], scenario: InvestigationScenario) throws -> [SubsurfaceColumn] {
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty else { return [] }
        let locations = complete.map { CoordinateTransformer.localMeters($0.coordinate, origin: terrain.origin) }
        let maxDepth = complete.compactMap { $0.interpretation?.layers.last?.bottom }.max() ?? 20
        let xs = terrain.positions.map(\.x), zs = terrain.positions.map(\.z)
        guard let minX = xs.min(), let maxX = xs.max(), let minZ = zs.min(), let maxZ = zs.max() else { return [] }
        let width = (maxX-minX)/14, length = (maxZ-minZ)/14
        guard width > 0, length > 0 else { return [] }
        let polygon = boundary.map { geo -> Point2 in
            let p = CoordinateTransformer.localMeters(geo, origin: terrain.origin)
            return .init(x: p.x, y: -p.y)
        }
        var result = [SubsurfaceColumn]()
        func append(_ surface: SIMD3<Float>, _ w: Float, _ l: Float, _ top: Double, _ bottom: Double, _ behavior: SoilBehavior?, _ observed: Bool) {
            guard bottom > top else { return }
            result.append(.init(surface: surface, width: w, length: l, top: top, bottom: bottom, behavior: behavior, observed: observed))
        }
        for row in 0..<14 {
            try Task.checkCancellation()
            for col in 0..<14 {
                let x = minX + (Float(col)+0.5)*width, z = minZ + (Float(row)+0.5)*length
                let corners = [Point2(x: Double(x-width/2), y: Double(z-length/2)), Point2(x: Double(x+width/2), y: Double(z-length/2)),
                               Point2(x: Double(x+width/2), y: Double(z+length/2)), Point2(x: Double(x-width/2), y: Double(z+length/2))]
                guard corners.allSatisfy({ Geometry.contains($0, in: polygon) }) else { continue }
                // Reject cells spanning a concave notch, even if all four corners happen to lie inside.
                let crosses = polygon.indices.contains { i in
                    corners.indices.contains { j in Geometry.intersects(polygon[i], polygon[(i+1)%polygon.count], corners[j], corners[(j+1)%4]) }
                }
                guard !crosses, let surface = terrain.surfacePosition(x: x, z: z) else { continue }
                if !InvestigationSimulator.supported(at: surface, points: points, terrain: terrain, scenario: scenario) {
                    append(surface, width*0.96, length*0.96, 0, maxDepth, nil, false)
                    continue
                }
                let nearest = locations.indices.min { a, b in
                    hypot(Double(x)-locations[a].x, Double(z)+locations[a].y) < hypot(Double(x)-locations[b].x, Double(z)+locations[b].y)
                }!
                let layers = complete[nearest].interpretation!.layers
                append(surface, width*0.96, length*0.96, 0, layers.first!.top, nil, false)
                for layer in layers { append(surface, width*0.96, length*0.96, layer.top, layer.bottom, layer.behavior, false) }
                append(surface, width*0.96, length*0.96, layers.last!.bottom, maxDepth, nil, false)
            }
        }
        // Measured-location interpretations are visible as narrow, brighter columns.
        let pinWidth = max(0.3, min(width,length)*0.12)
        for point in complete {
            guard let surface = terrain.surfacePosition(at: point.coordinate), let layers = point.interpretation?.layers else { continue }
            for layer in layers { append(surface, pinWidth, pinWidth, layer.top, layer.bottom, layer.behavior, true) }
        }
        return result
    }
}
