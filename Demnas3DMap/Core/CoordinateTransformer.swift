import Foundation

struct AffineTransform: Codable, Sendable, Equatable {
    // Coordinates refer to pixel corners; samples live at (column + .5, row + .5).
    let x0: Double, a: Double, b: Double, y0: Double, d: Double, e: Double
    var determinant: Double { a * e - b * d }
    func world(_ pixel: Point2) -> Point2 { .init(x: x0 + a * pixel.x + b * pixel.y, y: y0 + d * pixel.x + e * pixel.y) }
    func pixel(_ world: Point2) -> Point2 {
        let dx = world.x - x0, dy = world.y - y0
        return .init(x: (e * dx - b * dy) / determinant, y: (a * dy - d * dx) / determinant)
    }
    func validate() throws {
        guard [x0,a,b,y0,d,e].allSatisfy(\.isFinite), abs(determinant) > 1e-20 else {
            throw TerrainError("The pixel-to-world transform is singular or invalid.")
        }
    }
}

struct CoordinateTransformer: Sendable {
    let epsg: Int
    init(epsg: Int) throws {
        guard epsg == 4326 || epsg == 3857 || (32601...32660).contains(epsg) || (32701...32760).contains(epsg) else {
            throw TerrainError("EPSG:\(epsg) is not supported by this native reader. Use a WGS 84 geographic, Web Mercator, or WGS 84 UTM DEM. Other datums require a PROJ-backed reader.")
        }
        self.epsg = epsg
    }
    private let radius = 6378137.0
    private let ecc = 0.0066943799901413165
    private var zone: Int { epsg % 100 }
    private var south: Bool { epsg >= 32701 && epsg <= 32760 }
    func project(_ geo: GeoPoint) throws -> Point2 {
        guard geo.latitude.isFinite, geo.longitude.isFinite, abs(geo.latitude) <= 90, abs(geo.longitude) <= 180 else { throw TerrainError("Invalid geographic coordinate.") }
        if epsg == 4326 { return geo.point }
        let lat = geo.latitude * .pi / 180, lon = geo.longitude * .pi / 180
        if epsg == 3857 {
            guard abs(geo.latitude) < 85.051129 else { throw TerrainError("Selection exceeds Web Mercator's latitude range.") }
            return .init(x: radius * lon, y: radius * log(tan(.pi / 4 + lat / 2)))
        }
        guard geo.latitude >= -80 && geo.latitude <= 84, abs(geo.longitude - Double(zone * 6 - 183)) <= 6 else { throw TerrainError("Selection lies outside this UTM zone's supported range.") }
        let ep = ecc / (1 - ecc), n = radius / sqrt(1 - ecc * pow(sin(lat), 2))
        let t = pow(tan(lat), 2), c = ep * pow(cos(lat), 2)
        let aa = cos(lat) * (lon - Double(zone * 6 - 183) * .pi / 180)
        let m = radius * ((1 - ecc / 4 - 3 * ecc * ecc / 64 - 5 * pow(ecc,3) / 256) * lat
            - (3 * ecc / 8 + 3 * ecc * ecc / 32 + 45 * pow(ecc,3) / 1024) * sin(2 * lat)
            + (15 * ecc * ecc / 256 + 45 * pow(ecc,3) / 1024) * sin(4 * lat)
            - 35 * pow(ecc,3) / 3072 * sin(6 * lat))
        let x = 500000 + 0.9996 * n * (aa + (1 - t + c) * pow(aa,3) / 6 + (5 - 18*t + t*t + 72*c - 58*ep) * pow(aa,5) / 120)
        let y = 0.9996 * (m + n * tan(lat) * (aa*aa / 2 + (5 - t + 9*c + 4*c*c) * pow(aa,4) / 24 + (61 - 58*t + t*t + 600*c - 330*ep) * pow(aa,6) / 720))
        return .init(x: x, y: y + (south ? 10000000 : 0))
    }
    func unproject(_ world: Point2) throws -> GeoPoint {
        let result: GeoPoint
        if epsg == 4326 { result = .init(longitude: world.x, latitude: world.y) }
        else if epsg == 3857 {
            result = .init(longitude: world.x / radius * 180 / .pi, latitude: (2 * atan(exp(world.y / radius)) - .pi / 2) * 180 / .pi)
        } else {
            let y = world.y - (south ? 10000000 : 0), x = world.x - 500000
            let e1 = (1 - sqrt(1 - ecc)) / (1 + sqrt(1 - ecc))
            let mu = y / 0.9996 / (radius * (1 - ecc / 4 - 3 * ecc*ecc / 64 - 5 * pow(ecc,3) / 256))
            let fp = mu + (3*e1/2 - 27*pow(e1,3)/32) * sin(2*mu) + (21*e1*e1/16 - 55*pow(e1,4)/32) * sin(4*mu) + 151*pow(e1,3)/96 * sin(6*mu) + 1097*pow(e1,4)/512 * sin(8*mu)
            let ep = ecc / (1-ecc), c = ep * pow(cos(fp),2), t = pow(tan(fp),2)
            let n = radius / sqrt(1 - ecc * pow(sin(fp),2))
            let r = radius * (1-ecc) / pow(1 - ecc * pow(sin(fp),2),1.5)
            let dd = x / (n * 0.9996)
            let lat = fp - n * tan(fp) / r * (dd*dd/2 - (5+3*t+10*c-4*c*c-9*ep)*pow(dd,4)/24 + (61+90*t+298*c+45*t*t-252*ep-3*c*c)*pow(dd,6)/720)
            let lon = (dd - (1+2*t+c)*pow(dd,3)/6 + (5-2*c+28*t-3*c*c+8*ep+24*t*t)*pow(dd,5)/120) / cos(fp)
            result = .init(longitude: Double(zone*6-183) + lon*180 / .pi, latitude: lat*180 / .pi)
        }
        guard result.longitude.isFinite, result.latitude.isFinite, abs(result.longitude) <= 180, abs(result.latitude) <= 90 else {
            if epsg != 4326 && abs(world.x) <= 180 && abs(world.y) <= 90 {
                throw TerrainError("Raster coordinates look like degrees (longitude: \(String(format: "%.4f", world.x)), latitude: \(String(format: "%.4f", world.y))), but EPSG:\(epsg) expects projected coordinates (meters). Official DEMNAS tiles are stored in WGS 84 Geographic (EPSG:4326). Please select EPSG:4326.")
            } else if epsg == 4326 && (abs(world.x) > 180 || abs(world.y) > 90) {
                throw TerrainError("Raster coordinates look like projected meters (X: \(String(format: "%.1f", world.x)), Y: \(String(format: "%.1f", world.y))), but EPSG:4326 expects geographic degrees (-180 to 180). Please select the appropriate UTM Zone CRS.")
            } else {
                throw TerrainError("Raster bounds (\(String(format: "%.2f", world.x)), \(String(format: "%.2f", world.y))) are inconsistent with EPSG:\(epsg). Check your CRS selection.")
            }
        }
        return result
    }
    /// WGS 84 ECEF projected onto the origin's east/north axes. Height is kept separately.
    static func localMeters(_ geo: GeoPoint, origin: GeoPoint) -> Point2 {
        func ecef(_ g: GeoPoint) -> SIMD3<Double> {
            let p = g.latitude * .pi / 180, l = g.longitude * .pi / 180
            let n = 6378137 / sqrt(1 - 0.0066943799901413165 * sin(p)*sin(p))
            return .init(n*cos(p)*cos(l), n*cos(p)*sin(l), n*(1-0.0066943799901413165)*sin(p))
        }
        let v = ecef(geo) - ecef(origin), p = origin.latitude * .pi / 180, l = origin.longitude * .pi / 180
        return .init(x: -sin(l)*v.x + cos(l)*v.y, y: -sin(p)*cos(l)*v.x - sin(p)*sin(l)*v.y + cos(p)*v.z)
    }
}
