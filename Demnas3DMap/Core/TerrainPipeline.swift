import Foundation
import simd

protocol DEMRasterSource {
    var metadata: DEMMetadata { get }
    func sample(column: Int, row: Int) throws -> Double
}

final class GeoTIFFSource: DEMRasterSource {
    let reader: TIFFReader
    let metadata: DEMMetadata
    init(url: URL, confirmedDEMNAS: Bool, manualEPSG: Int? = nil) throws {
        reader = try TIFFReader(url: url)
        metadata = try DEMMetadataValidator.validate(reader, companion: CompanionMetadata.read(beside: url),
                                                     confirmedDEMNAS: confirmedDEMNAS, manualEPSG: manualEPSG)
    }
    func sample(column: Int, row: Int) throws -> Double { try reader.sample(column: column, row: row) }
}

struct ImportedDEM: Sendable {
    let url: URL
    let directory: URL
    let metadata: DEMMetadata
    let confirmedDEMNAS: Bool
    let manualEPSG: Int?
}

enum DEMImporter {
    /// Copy while security-scoped access is active. A source never outlives its permission.
    static func load(urls: [URL], confirmedDEMNAS: Bool, manualEPSG: Int? = nil) throws -> ImportedDEM {
        let rasters = urls.filter { ["tif","tiff"].contains($0.pathExtension.lowercased()) }
        guard rasters.count == 1, let raster = rasters.first else { throw TerrainError("Select exactly one .tif/.tiff DEM, optionally with its matching .tfw, .prj, or .tif.aux.xml companions.") }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("DEMNAS-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let base = raster.deletingPathExtension().lastPathComponent.lowercased()
            let accepted = Set([raster.lastPathComponent.lowercased(), base+".tfw",base+".tifw",base+".wld",base+".prj",raster.lastPathComponent.lowercased()+".aux.xml"])
            guard urls.count <= 7 else { throw TerrainError("Select only the DEM and its companion metadata.") }
            for url in urls {
                try Task.checkCancellation()
                guard accepted.contains(url.lastPathComponent.lowercased()) else { throw TerrainError("\(url.lastPathComponent) does not match the selected DEM's basename.") }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= (url == raster ? 2_000_000_000 : 1_000_000) else { throw TerrainError("DEM files are limited to 2 GB and companion files to 1 MB.") }
                let destination = directory.appendingPathComponent(url.lastPathComponent.lowercased())
                try fm.copyItem(at: url, to: destination)
            }
            let local = directory.appendingPathComponent(raster.lastPathComponent.lowercased())
            let source = try GeoTIFFSource(url: local, confirmedDEMNAS: confirmedDEMNAS, manualEPSG: manualEPSG)
            return .init(url: local, directory: directory, metadata: source.metadata,
                         confirmedDEMNAS: confirmedDEMNAS, manualEPSG: manualEPSG)
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}

struct ElevationGrid: Sendable {
    let columns: [Double], rows: [Double] // Pixel coordinates at sample centers.
    let elevations: [Double]
    let mask: [Bool]
    let polygon: [Point2]
    let polygonTriangles: [[Point2]]
    let minElevation: Double, maxElevation: Double
    let originalSampleCount: Int
    let metadata: DEMMetadata
    var width: Int { columns.count }
}

enum RasterClippingService {
    static func clip(source: any DEMRasterSource, polygon: [GeoPoint], maxAxis: Int = 160) throws -> ElevationGrid {
        try Geometry.validate(polygon.map(\.point))
        guard (2...256).contains(maxAxis), let origin = polygon.first,
              polygon.allSatisfy({ CoordinateTransformer.localMeters($0, origin: origin).length < 25_000 }) else {
            throw TerrainError("Choose a local area within 25 km of the first vertex. Larger areas need a curved-earth terrain renderer.")
        }
        let m = source.metadata, crs = try CoordinateTransformer(epsg:m.epsg)
        // Densify map-straight (Mercator) edges until projected midpoint error is < .02 pixels.
        let mapCRS = try CoordinateTransformer(epsg:3857)
        func pixel(_ g: GeoPoint) throws -> Point2 { m.transform.pixel(try crs.project(g)) }
        func edge(_ a: GeoPoint, _ b: GeoPoint, _ depth: Int) throws -> [Point2] {
            let pa = try pixel(a), pb = try pixel(b)
            let midpoint = try mapCRS.unproject((try mapCRS.project(a) + mapCRS.project(b)) * 0.5)
            let pm = try pixel(midpoint)
            if (pm - (pa+pb)*0.5).length <= 0.02 { return [pa] }
            guard depth < 12 else { throw TerrainError("The polygon cannot be transformed with sufficient accuracy. Select a smaller area.") }
            return try edge(a,midpoint,depth+1) + edge(midpoint,b,depth+1)
        }
        var p = [Point2]()
        for i in polygon.indices { p += try edge(polygon[i],polygon[(i+1)%polygon.count],0) }
        guard p.count <= 128 else { throw TerrainError("The transformed boundary is too complex. Select a smaller or simpler polygon.") }
        // The sample-center hull is narrower than the raster footprint by half a pixel.
        guard p.allSatisfy({ $0.x >= 0.5 && $0.y >= 0.5 && $0.x <= Double(m.width)-0.5 && $0.y <= Double(m.height)-0.5 }) else {
            throw TerrainError("The entire polygon must lie inside the DEM's sample coverage, including a half-pixel interpolation margin. Move the boundary inward or import a covering tile.")
        }
        let triangles = try Geometry.triangulate(p)
        let left = max(0,Int(floor(p.map(\.x).min()! - 0.5))), right = min(m.width-1,Int(ceil(p.map(\.x).max()! - 0.5)))
        let top = max(0,Int(floor(p.map(\.y).min()! - 0.5))), bottom = min(m.height-1,Int(ceil(p.map(\.y).max()! - 0.5)))
        let width = right-left+1, height = bottom-top+1
        guard width >= 2, height >= 2, width*height <= 4_000_000 else { throw TerrainError("Selection needs more than four million source samples. Draw a smaller polygon to stay within iPhone memory limits.") }
        var window = [Double](repeating: .nan, count: width*height)
        var low = Double.infinity, high = -Double.infinity
        func valid(_ value: Double) -> Bool { value.isFinite && (m.noData == nil || value != m.noData!) }
        for row in top...bottom {
            if row % 16 == 0 { try Task.checkCancellation() }
            for col in left...right {
                let value = try source.sample(column: col,row: row)
                let point = Point2(x:Double(col)+0.5,y:Double(row)+0.5)
                let inside = Geometry.contains(point,in:p)
                if !valid(value) {
                    // Also detect a NoData cell that crosses the boundary, even if its center is outside.
                    let cell = [Point2(x:Double(col),y:Double(row)),Point2(x:Double(col+1),y:Double(row)),Point2(x:Double(col+1),y:Double(row+1)),Point2(x:Double(col),y:Double(row+1))]
                    if inside || triangles.contains(where: { abs(Geometry.area(Geometry.clip(cell,to:$0))) > 1e-12 }) {
                        throw TerrainError("The selected polygon includes NoData or non-finite elevation cells. Choose a fully covered region; missing heights are never filled silently.")
                    }
                } else {
                    window[(row-top)*width+col-left] = value
                    if inside { low = min(low,value); high = max(high,value) }
                }
            }
        }
        func axis(_ first: Int,_ last: Int) -> [Int] {
            let step = max(1,Int(ceil(Double(last-first)/Double(maxAxis-1))))
            var values = Array(stride(from:first,through:last,by:step))
            if values.last != last { values.append(last) }
            return values
        }
        let columns = axis(left,right), rows = axis(top,bottom)
        var elevations = [Double](), mask = [Bool]()
        for row in rows { for col in columns {
            elevations.append(window[(row-top)*width+col-left])
            mask.append(Geometry.contains(.init(x:Double(col)+0.5,y:Double(row)+0.5),in:p))
        } }
        return .init(columns:columns.map { Double($0)+0.5 }, rows:rows.map { Double($0)+0.5 }, elevations:elevations, mask:mask, polygon:p, polygonTriangles:triangles, minElevation:low, maxElevation:high, originalSampleCount:width*height, metadata:m)
    }
}

struct TerrainMesh: Sendable {
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
    let geographicVertices: [GeoPoint]
    let elevations: [Double]
    let origin: GeoPoint
    let elevationOrigin: Double
    let minimum: Double, maximum: Double
    let areaSquareMeters: Double
    let metadata: DEMMetadata
    let sourceSampleCount: Int
    let gridSize: String
}

enum TerrainMeshGenerator {
    private struct VertexKey: Hashable { let x: Int64, y: Int64 }
    static func generate(_ grid: ElevationGrid) throws -> TerrainMesh {
        let crs = try CoordinateTransformer(epsg:grid.metadata.epsg)
        let affine = grid.metadata.transform
        let center = grid.polygon.reduce(Point2(x:0,y:0),+) * (1/Double(grid.polygon.count))
        let origin = try crs.unproject(affine.world(center))
        var positions = [SIMD3<Float>](), normals = [SIMD3<Float>](), indices = [UInt32]()
        var geoVertices = [GeoPoint](), elevations = [Double](), lookup = [VertexKey:UInt32]()
        // Preserve the first valid source height as a numeric offset only; original heights remain attached.
        guard let base = grid.elevations.first(where: \.isFinite) else { throw TerrainError("The selection has no valid elevation samples.") }
        func vertex(_ p: Point2, elevation: Double) throws -> UInt32 {
            let key = VertexKey(x:Int64((p.x*1e7).rounded()),y:Int64((p.y*1e7).rounded()))
            if let index = lookup[key] { return index }
            guard positions.count < 200_000, elevation.isFinite else { throw TerrainError("Terrain exceeds the 200,000 vertex budget or contains invalid heights. Select a smaller boundary.") }
            let geo = try crs.unproject(affine.world(p)), local = CoordinateTransformer.localMeters(geo,origin:origin)
            let pos = SIMD3<Float>(Float(local.x),Float(elevation-base),Float(-local.y))
            guard pos.x.isFinite, pos.y.isFinite, pos.z.isFinite else { throw TerrainError("Elevation values exceed the rendering range.") }
            let index = UInt32(positions.count)
            lookup[key] = index; positions.append(pos); normals.append(.zero); geoVertices.append(geo); elevations.append(elevation)
            return index
        }
        for y in 0..<(grid.rows.count-1) {
            try Task.checkCancellation()
            for x in 0..<(grid.columns.count-1) {
                let a = Point2(x:grid.columns[x],y:grid.rows[y]), b = Point2(x:grid.columns[x+1],y:grid.rows[y])
                let c = Point2(x:grid.columns[x+1],y:grid.rows[y+1]), d = Point2(x:grid.columns[x],y:grid.rows[y+1])
                let i = y*grid.width+x
                let faces: [([Point2],[Double])] = [([a,b,c],[grid.elevations[i],grid.elevations[i+1],grid.elevations[i+grid.width+1]]),([a,c,d],[grid.elevations[i],grid.elevations[i+grid.width+1],grid.elevations[i+grid.width]])]
                for (face, heights) in faces {
                    for boundary in grid.polygonTriangles {
                        if boundary.map(\.x).max()! < a.x || boundary.map(\.x).min()! > c.x || boundary.map(\.y).max()! < a.y || boundary.map(\.y).min()! > c.y { continue }
                        let clipped = Geometry.clip(face,to:boundary)
                        guard clipped.count >= 3, abs(Geometry.area(clipped)) > 1e-10 else { continue }
                        guard heights.allSatisfy(\.isFinite) else { throw TerrainError("Boundary interpolation would use NoData outside the polygon. Move the boundary away from the missing-data edge.") }
                        let denominator = Geometry.cross(face[1]-face[0],face[2]-face[0])
                        let ids = try clipped.map { p in
                            let u = Geometry.cross(p-face[0],face[2]-face[0])/denominator
                            let v = Geometry.cross(face[1]-face[0],p-face[0])/denominator
                            return try vertex(p,elevation:heights[0]*(1-u-v)+heights[1]*u+heights[2]*v)
                        }
                        for j in 1..<(ids.count-1) {
                            var tri = [ids[0],ids[j],ids[j+1]]
                            var normal = simd_cross(positions[Int(tri[1])]-positions[Int(tri[0])],positions[Int(tri[2])]-positions[Int(tri[0])])
                            if simd_length_squared(normal) < 1e-12 { continue }
                            if normal.y < 0 { tri.swapAt(1,2); normal = -normal }
                            indices += tri
                            for index in tri { normals[Int(index)] += normal }
                            guard indices.count <= 600_000 else { throw TerrainError("Terrain exceeds the 200,000 triangle budget. Simplify the polygon.") }
                        }
                    }
                }
            }
        }
        guard !indices.isEmpty else { throw TerrainError("Selection is too small to produce a terrain surface.") }
        normals = normals.map { simd_length_squared($0) > 1e-12 ? simd_normalize($0) : .init(0,1,0) }
        let metricBoundary = try grid.polygon.map { CoordinateTransformer.localMeters(try crs.unproject(affine.world($0)),origin:origin) }
        let low = min(grid.minElevation,elevations.min()!), high = max(grid.maxElevation,elevations.max()!)
        return .init(positions:positions,normals:normals,indices:indices,geographicVertices:geoVertices,elevations:elevations,origin:origin,elevationOrigin:base,minimum:low,maximum:high,areaSquareMeters:abs(Geometry.area(metricBoundary)),metadata:grid.metadata,sourceSampleCount:grid.originalSampleCount,gridSize:"\(grid.columns.count) × \(grid.rows.count)")
    }
}
