import Foundation
import simd

// All interpretations in this module are a deterministic PoC, not validated design parameters.
enum SoilBehavior: String, Codable, CaseIterable, Sendable {
    case sand, transitional, clay
    var title: String {
        switch self { case .sand: "Sand-like"; case .transitional: "Transisi"; case .clay: "Clay-like" }
    }
    static func classify(_ ic: Double) -> Self {
        ic < 2.05 ? .sand : ic < 2.6 ? .transitional : .clay
    }
}

enum InvestigationScenario: String, Codable, CaseIterable, Sendable {
    case homogeneous, variable
    var title: String { self == .homogeneous ? "Homogen · 1 CPT" : "Bervariasi · 3 CPT" }
    var requiredProfiles: Int { self == .homogeneous ? 1 : 3 }
}

enum CPTDataOrigin: String, Codable, CaseIterable, Sendable {
    case entered, example
    var title: String { self == .entered ? "Data pengguna" : "Contoh sintetis" }
}

struct CPTAssumptions: Codable, Equatable, Sendable {
    var coneAreaRatio = 0.8
    var unitWeight = 18.0 // Constant total unit weight, kN/m³.
    var waterTableDepth = 2.0 // Hydrostatic assumption, metres below local ground.
    var nkt = 15.0
    func validate() throws {
        guard [coneAreaRatio, unitWeight, waterTableDepth, nkt].allSatisfy(\.isFinite),
              (0...1).contains(coneAreaRatio), (10...30).contains(unitWeight),
              (0...200).contains(waterTableDepth), (5...30).contains(nkt) else {
            throw TerrainError("Asumsi tidak valid: a 0–1, γ 10–30 kN/m³, muka air 0–200 m, Nkt 5–30.")
        }
    }
}

struct CPTSample: Codable, Equatable, Sendable {
    let depth: Double
    let qcMPa: Double
    let fsKPa: Double
    let u2KPa: Double?
}

struct CPTValue: Codable, Sendable {
    let depth: Double
    let qt: Double // kPa
    let totalStress: Double
    let effectiveStress: Double
    let ic: Double
    let behavior: SoilBehavior
    let su: Double?
    let phi: Double?
}

struct SoilLayer: Codable, Identifiable, Sendable {
    var id: Int
    let top: Double
    let bottom: Double
    let behavior: SoilBehavior
    let meanIc: Double
    let su: Double?
    let phi: Double?
}

struct CPTInterpretation: Codable, Sendable {
    let values: [CPTValue]
    let layers: [SoilLayer]
    let notes: [String]
}

struct CPTDraft: Codable, Sendable {
    let csv: String
    let assumptions: CPTAssumptions
    let origin: CPTDataOrigin
}

struct CPTPoint: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let coordinate: GeoPoint
    let surfaceElevation: Double // DEM elevation, same datum as terrain.
    var csv = ""
    var assumptions = CPTAssumptions()
    var dataOrigin = CPTDataOrigin.entered
    var interpretation: CPTInterpretation?
    var updatedAt: Date?
    var draft: CPTDraft?
    var isComplete: Bool { interpretation != nil }
}

enum CPTProcessor {
    static let header = "depth_m,qc_mpa,fs_kpa,u2_kpa"
    static func parse(_ text: String) throws -> [CPTSample] {
        guard text.utf8.count <= 1_000_000 else { throw TerrainError("CSV dibatasi 1 MB.") }
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.first?.trimmingCharacters(in: .whitespaces).lowercased() == header else {
            throw TerrainError("Header wajib: \(header). Gunakan titik desimal dan koma sebagai pemisah.")
        }
        guard (2...5000).contains(lines.count - 1) else { throw TerrainError("Masukkan 2–5.000 baris kedalaman.") }
        var result = [CPTSample]()
        for (index, line) in lines.dropFirst().enumerated() {
            let fields = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 4,
                  let depth = Double(fields[0]), let qc = Double(fields[1]), let fs = Double(fields[2]),
                  [depth, qc, fs].allSatisfy(\.isFinite), depth > 0, depth <= 200, qc > 0, fs > 0,
                  depth > (result.last?.depth ?? 0) else {
                throw TerrainError("Baris \(index+2): depth harus naik, > 0 dan ≤ 200 m; qc dan fs harus positif dan berhingga.")
            }
            let u2 = fields[3].isEmpty ? nil : Double(fields[3])
            guard fields[3].isEmpty || (u2 != nil && u2!.isFinite) else {
                throw TerrainError("Baris \(index+2): u2 harus angka berhingga atau kosong.")
            }
            result.append(.init(depth: depth, qcMPa: qc, fsKPa: fs, u2KPa: u2))
        }
        return result
    }

    static func interpret(csv: String, assumptions a: CPTAssumptions) throws -> CPTInterpretation {
        try a.validate()
        let samples = try parse(csv)
        var values = [CPTValue]()
        for s in samples {
            let qt = s.qcMPa * 1000 + (s.u2KPa ?? 0) * (1 - a.coneAreaRatio)
            let total = a.unitWeight * s.depth
            let effective = total - 9.81 * max(0, s.depth - a.waterTableDepth)
            let net = qt - total
            guard qt.isFinite, net > 0, effective > 0 else {
                throw TerrainError("Kedalaman \(s.depth) m: qt − σv0 dan σ′v0 harus positif untuk normalisasi.")
            }
            let fr = 100 * s.fsKPa / net
            let ic = hypot(3.47 - log10(net / effective), 1.22 + log10(fr))
            guard ic.isFinite else { throw TerrainError("Normalisasi tidak berhingga pada \(s.depth) m.") }
            let behavior = SoilBehavior.classify(ic)
            // Deliberately illustrative lookup, NOT Kulhawy–Mayne or another calibrated correlation.
            let phi: Double? = behavior == .sand ? (ic < 1.31 ? 38 : ic < 1.8 ? 34 : 30) : nil
            values.append(.init(depth: s.depth, qt: qt, totalStress: total, effectiveStress: effective,
                                ic: ic, behavior: behavior, su: behavior == .clay ? net/a.nkt : nil, phi: phi))
        }
        // Three-sample median reduces isolated label flicker. Then merge runs thinner than 0.5 m.
        var labels = values.indices.map { i in
            let window = values[max(0,i-1)...min(values.count-1,i+1)].map(\.ic).sorted()
            return SoilBehavior.classify(window[window.count/2])
        }
        func runs() -> [Range<Int>] {
            var result = [Range<Int>](), start = 0
            for i in 1..<labels.count where labels[i] != labels[i-1] { result.append(start..<i); start = i }
            result.append(start..<labels.count)
            return result
        }
        func boundary(_ i: Int) -> Double {
            if i == 0 { return values[0].depth }
            if i == values.count { return values.last!.depth }
            return (values[i-1].depth + values[i].depth)/2
        }
        for _ in values.indices {
            let groups = runs()
            guard groups.count > 1, let thin = groups.firstIndex(where: { boundary($0.upperBound)-boundary($0.lowerBound) < 0.5 }) else { break }
            let replacement = labels[groups[thin == 0 ? 1 : thin-1].lowerBound]
            for i in groups[thin] { labels[i] = replacement }
        }
        let layers = runs().enumerated().map { index, run in
            let behavior = labels[run.lowerBound]
            let samples = values[run]
            // Average only estimates whose ORIGINAL classification supports the correlation.
            let su = samples.compactMap(\.su), phi = samples.compactMap(\.phi)
            return SoilLayer(id: index, top: boundary(run.lowerBound), bottom: boundary(run.upperBound), behavior: behavior,
                             meanIc: samples.map(\.ic).reduce(0,+)/Double(samples.count),
                             su: behavior == .clay && !su.isEmpty ? su.reduce(0,+)/Double(su.count) : nil,
                             phi: behavior == .sand && !phi.isEmpty ? phi.reduce(0,+)/Double(phi.count) : nil)
        }
        var notes = ["PoC: tiga kelompok perilaku dari Ic (Qt, log10, Fr dalam %), bukan klasifikasi laboratorium.",
                     "γ konstan; air tanah hidrostatik. Batas lapisan: median 3 sampel, penggabungan interval < 0,5 m; belum ditinjau engineer.",
                     "su = (qt − σv0)/Nkt hanya untuk clay-like. φ′ = 30/34/38° adalah lookup ilustratif untuk sand-like, bukan korelasi tervalidasi.",
                     "Transisi tidak diberi estimasi kekuatan. Di atas sampel pertama dan di bawah sampel terakhir tetap tidak diketahui."]
        if samples.contains(where: { $0.u2KPa == nil }) { notes.append("u2 kosong: qt ≈ qc pada baris tersebut; koreksi tekanan pori tidak tersedia.") }
        if zip(samples, samples.dropFirst()).contains(where: { $1.depth-$0.depth > 1 }) {
            notes.append("Jarak sampel > 1 m: lapisan tipis dapat terlewat; interval antarbaris diasumsikan kontinu.")
        }
        return .init(values: values, layers: layers, notes: notes)
    }

    static func example(variable: Bool, iteration: Int) -> String {
        var rows = [header]
        for i in 1...40 {
            let d = Double(i)*0.5
            let clay = variable && d < Double(5 + iteration*2)
            let transition = variable && !clay && d < Double(8 + iteration*2)
            rows.append(String(format: "%.1f,%.3f,%.1f,", d, clay ? 0.65 : transition ? 2.0 : 10.0, clay ? 42.0 : transition ? 35.0 : 24.0))
        }
        return rows.joined(separator: "\n")
    }
}

struct InvestigationStatus: Sendable {
    let completed: Int
    let target: Int
    let pending: Int
    var finished: Bool { completed >= target && pending == 0 }
    var title: String {
        if pending > 0 { return "\(pending) titik menunggu hasil CPT" }
        return finished ? "Skenario simulasi selesai" : completed == 0 ? "Tetapkan titik CPT pertama" : "CPT berikutnya disarankan · simulasi"
    }
}

// Geometry-only coverage heuristic. No DRL, probability, or claim of geological confidence.
enum InvestigationSimulator {
    static func status(points: [CPTPoint], scenario: InvestigationScenario) -> InvestigationStatus {
        .init(completed: points.filter(\.isComplete).count, target: scenario.requiredProfiles, pending: points.filter { !$0.isComplete }.count)
    }
    static func recommendation(points: [CPTPoint], scenario: InvestigationScenario, terrain: TerrainMesh) -> GeoPoint? {
        let state = status(points: points, scenario: scenario)
        guard state.completed > 0, !state.finished, state.pending == 0 else { return nil }
        // Triangle centroids remain in concave terrain polygons; fixed candidate budget keeps this bounded.
        let strideSize = max(1, terrain.indices.count / 3 / 600)
        var candidates = [(distance: Double, coordinate: GeoPoint)]()
        for face in stride(from: 0, to: terrain.indices.count/3, by: strideSize) {
            let ids = (0..<3).map { Int(terrain.indices[face*3+$0]) }
            let geo = GeoPoint(longitude: ids.map { terrain.geographicVertices[$0].longitude }.reduce(0,+)/3,
                               latitude: ids.map { terrain.geographicVertices[$0].latitude }.reduce(0,+)/3)
            let distance = points.map { CoordinateTransformer.localMeters(geo, origin: $0.coordinate).length }.min() ?? 0
            if distance >= 2 { candidates.append((distance, geo)) }
        }
        return candidates.sorted { $0.distance > $1.distance }.first { terrain.surfacePosition(at: $0.coordinate) != nil }?.coordinate
    }
    static func supported(at position: SIMD3<Float>, points: [CPTPoint], terrain: TerrainMesh, scenario: InvestigationScenario) -> Bool {
        let complete = points.filter(\.isComplete)
        guard !complete.isEmpty else { return false }
        if complete.count >= scenario.requiredProfiles { return true }
        let radius = sqrt(terrain.areaSquareMeters) * (0.22 + 0.1 * Double(complete.count-1))
        return complete.contains { point in
            let local = CoordinateTransformer.localMeters(point.coordinate, origin: terrain.origin)
            return hypot(Double(position.x)-local.x, Double(position.z)+local.y) <= radius
        }
    }
}

extension TerrainMesh {
    func surfacePosition(at geo: GeoPoint) -> SIMD3<Float>? {
        let p = CoordinateTransformer.localMeters(geo, origin: origin)
        return surfacePosition(x: Float(p.x), z: Float(-p.y))
    }
    func surfacePosition(x: Float, z: Float) -> SIMD3<Float>? {
        let p = Point2(x: Double(x), y: Double(z))
        for i in stride(from: 0, to: indices.count, by: 3) {
            let va = positions[Int(indices[i])], vb = positions[Int(indices[i+1])], vc = positions[Int(indices[i+2])]
            let a = Point2(x: Double(va.x), y: Double(va.z))
            let b = Point2(x: Double(vb.x), y: Double(vb.z))
            let c = Point2(x: Double(vc.x), y: Double(vc.z))
            if p.x < min(a.x,b.x,c.x)-1e-5 || p.x > max(a.x,b.x,c.x)+1e-5 || p.y < min(a.y,b.y,c.y)-1e-5 || p.y > max(a.y,b.y,c.y)+1e-5 { continue }
            let denominator = Geometry.cross(b-a,c-a)
            if abs(denominator) < 1e-12 { continue }
            let u = Geometry.cross(p-a,c-a)/denominator, w = Geometry.cross(b-a,p-a)/denominator
            if u >= -1e-6 && w >= -1e-6 && u+w <= 1+1e-6 {
                return .init(x, Float(Double(va.y)*(1-u-w)+Double(vb.y)*u+Double(vc.y)*w), z)
            }
        }
        return nil
    }
}

struct InvestigationProject: Codable, Sendable {
    var version = 1
    let boundary: [GeoPoint]
    let terrain: TerrainMesh
    let points: [CPTPoint]
    let scenario: InvestigationScenario
    var spatialResolutionMeters: Double? = nil

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // GeoTIFF NoData may legitimately be NaN.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let project = try decoder.decode(Self.self, from: data)
        guard project.version == 1 else { throw TerrainError("Versi proyek tersimpan belum didukung.") }
        return project
    }
}
