import Foundation
import CoreLocation

struct TerrainError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Point2: Sendable, Equatable {
    var x: Double
    var y: Double
    static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Self, t: Double) -> Self { .init(x: a.x * t, y: a.y * t) }
    var length: Double { hypot(x, y) }
}

struct GeoPoint: Codable, Sendable, Equatable {
    let longitude: Double
    let latitude: Double
    init(longitude: Double, latitude: Double) { self.longitude = longitude; self.latitude = latitude }
    init(_ coordinate: CLLocationCoordinate2D) {
        longitude = coordinate.longitude; latitude = coordinate.latitude
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var point: Point2 { .init(x: longitude, y: latitude) }
}

enum Geometry {
    static let epsilon = 1e-9
    static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
    static func area(_ p: [Point2]) -> Double {
        guard p.count > 2 else { return 0 }
        let origin = p[0]
        return p.indices.reduce(0) { $0 + cross(p[$1] - origin, p[($1 + 1) % p.count] - origin) } / 2
    }
    static func onSegment(_ p: Point2, _ a: Point2, _ b: Point2) -> Bool {
        abs(cross(b - a, p - a)) < epsilon &&
        p.x >= min(a.x, b.x) - epsilon && p.x <= max(a.x, b.x) + epsilon &&
        p.y >= min(a.y, b.y) - epsilon && p.y <= max(a.y, b.y) + epsilon
    }
    static func intersects(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> Bool {
        let u = cross(b - a, c - a), v = cross(b - a, d - a)
        let s = cross(d - c, a - c), t = cross(d - c, b - c)
        return (u * v < 0 && s * t < 0) || onSegment(c, a, b) || onSegment(d, a, b) || onSegment(a, c, d) || onSegment(b, c, d)
    }
    static func contains(_ p: Point2, in polygon: [Point2]) -> Bool {
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if onSegment(p, a, b) { return true }
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    static func validate(_ polygon: [Point2]) throws {
        guard (3...128).contains(polygon.count) else { throw TerrainError("Select 3–128 distinct vertices.") }
        guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw TerrainError("The polygon contains invalid coordinates.") }
        for i in polygon.indices {
            for j in polygon.indices where j > i {
                guard (polygon[i] - polygon[j]).length > 1e-8 else { throw TerrainError("Polygon vertices must be distinct.") }
                if j == i + 1 || (i == 0 && j == polygon.count - 1) { continue }
                if intersects(polygon[i], polygon[(i + 1) % polygon.count], polygon[j], polygon[(j + 1) % polygon.count]) {
                    throw TerrainError("The polygon crosses or touches itself. Undo a vertex and redraw the boundary.")
                }
            }
            let a = polygon[(i + polygon.count - 1) % polygon.count], b = polygon[i], c = polygon[(i + 1) % polygon.count]
            guard abs(cross(b - a, c - b)) > epsilon else { throw TerrainError("Remove vertices that lie on the same straight line.") }
        }
        guard abs(area(polygon)) > epsilon else { throw TerrainError("The polygon has no usable area.") }
    }
    static func triangulate(_ polygon: [Point2]) throws -> [[Point2]] {
        try validate(polygon)
        var p = area(polygon) > 0 ? polygon : polygon.reversed()
        var triangles = [[Point2]]()
        while p.count > 3 {
            var found = false
            for i in p.indices {
                let before = (i + p.count - 1) % p.count, after = (i + 1) % p.count
                let a = p[before], b = p[i], c = p[after]
                if cross(b - a, c - b) <= epsilon { continue }
                if p.indices.contains(where: { $0 != before && $0 != i && $0 != after && contains(p[$0], in: [a,b,c]) }) { continue }
                triangles.append([a,b,c]); p.remove(at: i); found = true; break
            }
            guard found else { throw TerrainError("Unable to triangulate this boundary. Simplify the selection.") }
        }
        triangles.append(p)
        return triangles
    }
    /// Sutherland–Hodgman intersection with a counterclockwise convex boundary.
    static func clip(_ subject: [Point2], to boundary: [Point2]) -> [Point2] {
        var output = subject
        for i in boundary.indices {
            let a = boundary[i], edge = boundary[(i + 1) % boundary.count] - a
            let input = output; output = []
            guard var previous = input.last else { return [] }
            var pd = cross(edge, previous - a)
            for current in input {
                let cd = cross(edge, current - a)
                if (cd >= 0) != (pd >= 0) {
                    output.append(previous + (current - previous) * (pd / (pd - cd)))
                }
                if cd >= 0 { output.append(current) }
                previous = current; pd = cd
            }
        }
        return output
    }
}

struct PolygonSelectionModel {
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private(set) var isFinished = false
    mutating func add(_ coordinate: CLLocationCoordinate2D) throws {
        guard !isFinished else { return }
        guard CLLocationCoordinate2DIsValid(coordinate) else { throw TerrainError("The map tap did not produce a valid coordinate.") }
        guard coordinates.count < 128 else { throw TerrainError("Use at most 128 vertices.") }
        guard !coordinates.contains(where: { hypot($0.latitude - coordinate.latitude, $0.longitude - coordinate.longitude) < 1e-8 }) else { throw TerrainError("Choose a different point.") }
        coordinates.append(coordinate)
    }
    mutating func undo() { isFinished = false; if !coordinates.isEmpty { coordinates.removeLast() } }
    mutating func reset() { coordinates = []; isFinished = false }
    mutating func finish() throws {
        let points = coordinates.map { GeoPoint($0) }
        try Geometry.validate(points.map(\.point))
        let longitudes = points.map(\.longitude)
        guard (longitudes.max()! - longitudes.min()!) < 180 else {
            throw TerrainError("Antimeridian-crossing selections are unsupported.")
        }
        isFinished = true
    }
}
