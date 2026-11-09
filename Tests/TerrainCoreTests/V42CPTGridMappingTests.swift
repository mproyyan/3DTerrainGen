import Foundation
import Testing
@testable import TerrainCore

private let mappingPolygon = [Point2(x: 0, y: 0), Point2(x: 8, y: 0),
                              Point2(x: 8, y: 8), Point2(x: 0, y: 8)]

@Test func cptNaturalCellAndXYOrdering() throws {
    let mask = [Bool](repeating: true, count: 16)
    let result = try V42CPTGridMapper.map(.init(x: 6.2, y: 2.2), name: "CPT-1",
                                          polygon: mappingPolygon, west: 0, south: 0,
                                          nx: 4, ny: 4, dx: 2, dy: 2, validXY: mask)
    #expect(result.naturalCellValid)
    #expect(result.x == 3 && result.y == 1)
    #expect(result.center == Point2(x: 7, y: 3))
    #expect(abs(result.distanceMeters - hypot(0.8, 0.8)) < 1e-12)
}

@Test func cptNearPolygonEdgeSnapsToNearestValidPhysicalCell() throws {
    var mask = [Bool](repeating: true, count: 16)
    mask[0] = false
    let result = try V42CPTGridMapper.map(.init(x: 0.3, y: 0.3), name: "CPT-2",
                                          polygon: mappingPolygon, west: 0, south: 0,
                                          nx: 4, ny: 4, dx: 2, dy: 2, validXY: mask)
    #expect(!result.naturalCellValid)
    #expect(result.naturalX == 0 && result.naturalY == 0)
    #expect(result.x == 1 && result.y == 0)
    #expect(abs(result.distanceMeters - hypot(2.7, 0.7)) < 1e-12)
    #expect(result.distanceMeters <= hypot(2, 2))
}

@Test func cptOutsideValidAreaAndToleranceIsRejected() throws {
    var mask = [Bool](repeating: false, count: 16)
    mask[15] = true
    #expect(throws: MLIntegrationError.self) {
        try V42CPTGridMapper.map(.init(x: 0.2, y: 0.2), name: "CPT-3",
                                 polygon: mappingPolygon, west: 0, south: 0,
                                 nx: 4, ny: 4, dx: 2, dy: 2, validXY: mask)
    }
    #expect(throws: MLIntegrationError.self) {
        try V42CPTGridMapper.map(.init(x: -0.2, y: 1), name: "CPT-4",
                                 polygon: mappingPolygon, west: 0, south: 0,
                                 nx: 4, ny: 4, dx: 2, dy: 2,
                                 validXY: [Bool](repeating: true, count: 16))
    }
}

@Test func snappedModelInputPreservesOriginalCPTMapCoordinate() throws {
    let (terrain, _, original) = try v42Fixture(metres: 23.8, spacingOverride: 1)
    let origin = terrain.origin
    let localPolygon = [Point2(x: 0, y: 0), Point2(x: 23.8, y: 0),
                        Point2(x: 21, y: 23.8), Point2(x: 0, y: 23.8)]
    let boundary = localPolygon.map { CoordinateTransformer.geographic(east: $0.x, north: $0.y, origin: origin) }
    let extent = try MetricExtent(boundary: boundary, origin: origin)
    let plan = try V42GridPlan.make(extent: extent, points: [original], preferredMeters: 1)
    let west = (extent.west + extent.east - Double(plan.nx) * plan.horizontalMeters) / 2
    let south = (extent.south + extent.north - Double(plan.ny) * plan.northMeters) / 2
    var valid = [Bool](repeating: false, count: plan.nx * plan.ny)
    for y in 0..<plan.ny { for x in 0..<plan.nx {
        let center = Point2(x: west + (Double(x) + 0.5) * plan.horizontalMeters,
                            y: south + (Double(y) + 0.5) * plan.northMeters)
        valid[y * plan.nx + x] = Geometry.contains(center, in: localPolygon)
    } }
    var snapped: (Point2, V42CPTGridMapping)?
    for yi in 1..<238 { for xi in 1..<238 where snapped == nil {
        let local = Point2(x: Double(xi) / 10, y: Double(yi) / 10)
        guard Geometry.contains(local, in: localPolygon) else { continue }
        let naturalX = Int(floor((local.x - west) / plan.horizontalMeters))
        let naturalY = Int(floor((local.y - south) / plan.northMeters))
        guard (0..<plan.nx).contains(naturalX), (0..<plan.ny).contains(naturalY),
              !valid[naturalY * plan.nx + naturalX] else { continue }
        if let mapping = try? V42CPTGridMapper.map(local, name: "CPT-boundary", polygon: localPolygon,
                                                   west: west, south: south, nx: plan.nx, ny: plan.ny,
                                                   dx: plan.horizontalMeters, dy: plan.northMeters,
                                                   validXY: valid) {
            snapped = (local, mapping)
        }
    } }
    let (local, mapping) = try #require(snapped)
    let coordinate = CoordinateTransformer.geographic(east: local.x, north: local.y, origin: origin)
    var point = CPTPoint(id: original.id, name: "CPT-boundary", coordinate: coordinate, surfaceElevation: 100)
    point.interpretation = original.interpretation
    let input = try V42Input.prepare(terrain: terrain, boundary: boundary, points: [point], preferredMeters: 1)
    #expect(point.coordinate == coordinate)
    #expect(input.observed[input.index(mapping.x, mapping.y, 0)])
    #expect(input.validXY[input.xy(mapping.x, mapping.y)])
    #expect(mapping.distanceMeters <= hypot(input.horizontalMeters, input.northMeters))
}
