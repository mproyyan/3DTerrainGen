import Foundation

struct DEMMetadata: Sendable {
    let width: Int, height: Int
    let transform: AffineTransform
    let epsg: Int
    let noData: Double?
    let verticalReference: String
    let provenance: [String]
    let footprint: [GeoPoint]
    var resolution: Point2 { .init(x: hypot(transform.a, transform.d), y: hypot(transform.b, transform.e)) }
}

struct CompanionMetadata: Sendable {
    var transform: AffineTransform?
    var epsg: Int?
    var noData: Double?
    var sources: [String] = []

    static func read(beside url: URL) throws -> Self {
        var result = Self()
        let stem = url.deletingPathExtension()
        let worldURLs = [stem.appendingPathExtension("tfw"), stem.appendingPathExtension("tifw"), stem.appendingPathExtension("wld")]
        for file in worldURLs where FileManager.default.fileExists(atPath: file.path) {
            let text = try boundedText(file)
            let v = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            guard v.count == 6, v.allSatisfy(\.isFinite) else { throw TerrainError("The world file must contain six finite affine coefficients.") }
            // World files reference the center of the upper-left sample, not the corner.
            let affine = AffineTransform(x0: v[4] - (v[0]+v[2])/2, a: v[0], b: v[2], y0: v[5] - (v[1]+v[3])/2, d: v[1], e: v[3])
            try result.merge(transform: affine, epsg: nil, source: file.lastPathComponent)
        }
        let prj = stem.appendingPathExtension("prj")
        if FileManager.default.fileExists(atPath: prj.path) {
            let epsg = try explicitEPSG(in: boundedText(prj))
            try result.merge(transform: nil, epsg: epsg, source: prj.lastPathComponent)
        }
        let aux = url.appendingPathExtension("aux.xml")
        if FileManager.default.fileExists(atPath: aux.path) {
            let parser = AuxiliaryParser()
            let xml = XMLParser(data: try boundedText(aux).data(using: .utf8)!)
            xml.shouldResolveExternalEntities = false; xml.delegate = parser
            guard xml.parse() else { throw TerrainError("The auxiliary metadata XML is malformed.") }
            if let scale = parser.values["Scale"], Double(scale.trimmingCharacters(in:.whitespacesAndNewlines)) != 1 {
                throw TerrainError("Auxiliary metadata declares scaled elevation samples. A GDAL-backed reader is required.")
            }
            if let offset = parser.values["Offset"], Double(offset.trimmingCharacters(in:.whitespacesAndNewlines)) != 0 {
                throw TerrainError("Auxiliary metadata declares an elevation offset. A GDAL-backed reader is required.")
            }
            if let unit = parser.values["UnitType"], !["m","metre","meter","metres","meters"].contains(unit.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()) {
                throw TerrainError("Auxiliary metadata does not declare metre elevation units.")
            }
            var transform: AffineTransform?
            if let text = parser.values["GeoTransform"] {
                let v = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard v.count == 6 else { throw TerrainError("Auxiliary geotransform must contain six coefficients.") }
                transform = .init(x0: v[0], a: v[1], b: v[2], y0: v[3], d: v[4], e: v[5])
            }
            let epsg = try parser.values["SRS"].map { try explicitEPSG(in: $0) }
            try result.merge(transform: transform, epsg: epsg, source: aux.lastPathComponent)
            if let value = parser.values["NoDataValue"] {
                guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TerrainError("Auxiliary NoData is invalid.") }
                result.noData = number
            }
        }
        return result
    }
    private mutating func merge(transform: AffineTransform?, epsg: Int?, source: String) throws {
        if let transform {
            try transform.validate()
            if let existing = self.transform, !DEMMetadataValidator.equivalent(existing, transform) { throw TerrainError("Companion files contain conflicting geotransforms.") }
            self.transform = transform
        }
        if let epsg {
            if let existing = self.epsg, existing != epsg { throw TerrainError("Companion files declare conflicting CRSs.") }
            self.epsg = epsg
        }
        sources.append(source)
    }
    private static func boundedText(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 1_000_000 else { throw TerrainError("Companion metadata exceeds 1 MB.") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    /// Accept an explicit identifier or a root WKT AUTHORITY/ID only, never a nested datum ID.
    static func explicitEPSG(in text: String) throws -> Int {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.uppercased().hasPrefix("EPSG:"), let code = Int(s.dropFirst(5)) { return code }
        let pattern = #"(?:AUTHORITY|ID)\s*\[\s*"EPSG"\s*,\s*"?(\d+)"?\s*\]\s*\]\s*$"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = s as NSString
        if let match = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            // Verify root depth: a projected CRS may end with a nested GEOGCS authority.
            let prefix = ns.substring(to: match.range.location)
            var depth = 0, quoted = false
            for c in prefix {
                if c == "\"" { quoted.toggle() }
                if !quoted { if c == "[" { depth += 1 }; if c == "]" { depth -= 1 } }
            }
            if depth == 1, let code = Int(ns.substring(with: match.range(at: 1))) { return code }
        }
        throw TerrainError("Companion CRS needs an explicit root EPSG identifier. An unnamed WKT datum cannot safely establish the raster CRS.")
    }
}

private final class AuxiliaryParser: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var current: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if ["SRS", "GeoTransform", "NoDataValue", "Scale", "Offset", "UnitType"].contains(name) { current = name; values[name] = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if let current { values[current, default: ""] += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if current == name { current = nil } }
}

enum DEMMetadataValidator {
    static func equivalent(_ a: AffineTransform, _ b: AffineTransform) -> Bool {
        [Point2(x: 0,y: 0), Point2(x: 1,y: 0), Point2(x: 0,y: 1)].allSatisfy {
            let u = a.world($0), v = b.world($0)
            return (u-v).length < max(1e-10, min(hypot(a.a,a.d), hypot(a.b,a.e))*1e-5)
        }
    }
    static func validate(_ reader: TIFFReader, companion: CompanionMetadata, confirmedDEMNAS: Bool) throws -> DEMMetadata {
        var keys: [Int:Int] = [:]
        if reader.tags[34735] != nil {
            let v = try reader.integers(34735)
            guard v.count >= 4, v[0] == 1, v.count == 4 + v[3]*4 else { throw TerrainError("Malformed GeoTIFF key directory.") }
            for i in 0..<v[3] {
                let p = 4+i*4
                if v[p+1] == 0, v[p+2] == 1 { keys[v[p]] = v[p+3] }
            }
        }
        var epsg: Int?
        if let model = keys[1024] {
            guard model == 1 || model == 2 else { throw TerrainError("Geocentric or user-defined GeoTIFF models require GDAL/PROJ.") }
            epsg = keys[model == 1 ? 3072 : 2048]
        } else if keys[3072] != nil { epsg = keys[3072] }
        else { epsg = keys[2048] }
        if epsg == 32767 || epsg == 0 { epsg = nil }
        if let embedded = epsg, let sidecar = companion.epsg, embedded != sidecar { throw TerrainError("Embedded and companion CRS identifiers conflict.") }
        var provenance = [String]()
        if epsg == nil { epsg = companion.epsg; if epsg != nil { provenance.append("CRS assigned from companion metadata; sample coordinates were not reprojected.") } }
        guard let epsg else { throw TerrainError("The raster CRS is missing. Select a matching .prj or .tif.aux.xml with authoritative CRS metadata alongside the TIFF. Geographic-looking values and the DEMNAS filename are not sufficient to assign EPSG:4326.") }
        let crs = try CoordinateTransformer(epsg: epsg)
        if let unit = keys[2054], epsg == 4326, unit != 9102 { throw TerrainError("The geographic CRS must use decimal degrees.") }
        if let unit = keys[3076], epsg != 4326, unit != 9001 { throw TerrainError("The projected CRS must use metres.") }
        if let unit = keys[4099], unit != 9001 { throw TerrainError("Vertical units must be metres; this reader does not silently convert elevation units.") }
        if let xml = reader.string(42112) {
            let metadata = GDALBandMetadataParser()
            let parser = XMLParser(data: Data(xml.utf8))
            parser.shouldResolveExternalEntities = false; parser.delegate = metadata
            guard parser.parse(), metadata.isIdentityMetres else {
                throw TerrainError("GDAL band scale, offset, or units require conversion. This reader accepts unscaled metre elevations only.")
            }
        }
        var transform: AffineTransform?
        let matrix = try reader.doubles(34264), scale = try reader.doubles(33550), tie = try reader.doubles(33922)
        guard matrix == nil || scale == nil else { throw TerrainError("Raster defines both matrix and scale transforms; resolve the conflicting georeferencing.") }
        if let m = matrix {
            guard m.count == 16, m.allSatisfy(\.isFinite), m[2] == 0, m[6] == 0, m[8] == 0, m[9] == 0, m[10] == 1, m[11] == 0, m[12] == 0, m[13] == 0, m[14] == 0, m[15] == 1 else { throw TerrainError("Unsupported GeoTIFF transformation matrix.") }
            transform = .init(x0: m[3], a: m[0], b: m[1], y0: m[7], d: m[4], e: m[5])
        } else if let s = scale, let t = tie {
            guard s.count == 3, s.allSatisfy(\.isFinite), s[0] > 0, s[1] > 0, t.count >= 6, t.count % 6 == 0, t.allSatisfy(\.isFinite) else { throw TerrainError("Invalid GeoTIFF scale/tiepoint metadata.") }
            let affine = AffineTransform(x0: t[3]-t[0]*s[0], a: s[0], b: 0, y0: t[4]+t[1]*s[1], d: 0, e: -s[1])
            for i in stride(from: 0, to: t.count, by: 6) {
                guard (affine.world(.init(x:t[i],y:t[i+1])) - Point2(x:t[i+3],y:t[i+4])).length < min(s[0],s[1])*1e-4 else { throw TerrainError("GeoTIFF tiepoints are inconsistent.") }
            }
            transform = affine
        }
        let rasterType = keys[1025] ?? 1
        guard rasterType == 1 || rasterType == 2 else { throw TerrainError("Unknown raster pixel interpretation.") }
        if rasterType == 2, let t = transform {
            transform = .init(x0:t.x0-(t.a+t.b)/2, a:t.a, b:t.b, y0:t.y0-(t.d+t.e)/2, d:t.d, e:t.e)
        }
        if let embedded = transform, let sidecar = companion.transform, !equivalent(embedded, sidecar) { throw TerrainError("Embedded georeferencing conflicts with the companion world transform.") }
        if transform == nil { transform = companion.transform; if transform != nil { provenance.append("Georeferencing recovered from companion metadata.") } }
        guard let transform else { throw TerrainError("Geographic reference information is required. Import the matching world file (.tfw) or auxiliary XML together with authoritative CRS metadata. Pixel dimensions alone cannot locate this DEM.") }
        try transform.validate()
        var footprint: [GeoPoint] = []
        let corners = [Point2(x:0,y:0), Point2(x:Double(reader.width),y:0), Point2(x:Double(reader.width),y:Double(reader.height)), Point2(x:0,y:Double(reader.height))]
        for i in 0..<4 {
            for j in 0..<16 {
                let p = corners[i] + (corners[(i+1)%4]-corners[i]) * (Double(j)/16)
                let world = transform.world(p), geo = try crs.unproject(world)
                let roundTrip = try crs.project(geo)
                guard (roundTrip-world).length < (epsg == 4326 ? 1e-8 : 0.1) else { throw TerrainError("Raster footprint cannot be transformed consistently in its declared CRS.") }
                footprint.append(geo)
            }
        }
        let noData: Double?
        if let text = reader.string(42113) {
            guard let n = Double(text) else { throw TerrainError("The TIFF NoData value is invalid.") }
            if let c = companion.noData, c != n && !(c.isNaN && n.isNaN) { throw TerrainError("Embedded and companion NoData values conflict.") }
            noData = n
        } else { noData = companion.noData }
        let vertical: String
        if let v = keys[4096], v != 32767, v != 0 {
            guard v == 3855 || keys[4099] == 9001 else { throw TerrainError("The vertical CRS needs explicit metre units.") }
            vertical = v == 3855 ? "EGM2008 orthometric height (EPSG:3855)" : "Vertical CRS EPSG:\(v); heights retained without datum conversion"
        } else {
            guard confirmedDEMNAS else { throw TerrainError("Vertical reference/units are absent. Confirm that this is an original official DEMNAS file (metres, EGM2008), or provide a GeoTIFF with explicit metre vertical units and reference.") }
            vertical = "EGM2008 orthometric height; official DEMNAS provenance confirmed by user"
        }
        provenance.append(contentsOf: companion.sources)
        return .init(width:reader.width, height:reader.height, transform:transform, epsg:epsg, noData:noData, verticalReference:vertical, provenance:provenance, footprint:footprint)
    }
}

/// Statistics and AREA_OR_POINT are harmless; nonidentity elevation semantics are not.
private final class GDALBandMetadataParser: NSObject, XMLParserDelegate {
    private var role: String?
    private var value = ""
    var isIdentityMetres = true
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        guard name == "Item" else { return }
        role = (attributes["role"] ?? attributes["name"] ?? "").lowercased()
        value = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if role != nil { value += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "Item", let role else { return }
        let v = value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        switch role {
        case "scale": isIdentityMetres = isIdentityMetres && Double(v) == 1
        case "offset": isIdentityMetres = isIdentityMetres && Double(v) == 0
        case "unittype", "unit": isIdentityMetres = isIdentityMetres && ["m","metre","meter","metres","meters"].contains(v)
        default: break
        }
        self.role = nil
    }
}
