// Same six measured CPT sites and common hidden profiles as evaluate_real_cpt_dqn.py.
// Run with the Python pilot JSON, field CSV, and the app's ModelC_Flexible.mlpackage.
import CoreML
import CryptoKit
import Foundation

struct Site {
    let x: Int
    let y: Int
    var ic: [Float]
}

func fail(_ message: String) -> Never {
    fatalError(message)
}

guard CommandLine.arguments.count == 5 else {
    fail("Usage: swift evaluate_model_c_real.swift FIELD.csv PILOT.json MODEL.mlpackage OUTPUT.json")
}
let fieldURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pilotURL = URL(fileURLWithPath: CommandLine.arguments[2])
let modelURL = URL(fileURLWithPath: CommandLine.arguments[3])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[4])
func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

let lines = try String(contentsOf: fieldURL, encoding: .utf8)
    .components(separatedBy: .newlines).filter { !$0.isEmpty }
let header = lines[0].split(separator: ",").map(String.init)
func field(_ name: String) -> Int {
    guard let index = header.firstIndex(of: name) else { fail("Missing CSV column: \(name)") }
    return index
}
let scenarioIndex = field("scenario"), idIndex = field("cpt_id")
let xIndex = field("grid_x"), yIndex = field("grid_y"), zIndex = field("grid_z"), icIndex = field("Ic")
var sites: [String: Site] = [:]
for line in lines.dropFirst() {
    let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard cells.count == header.count else { fail("Malformed field CSV row") }
    guard cells[scenarioIndex] == "dry_gamma18" else { continue }
    let id = cells[idIndex]
    guard let x = Int(cells[xIndex]), let y = Int(cells[yIndex]),
          let z = Int(cells[zIndex]), let ic = Float(cells[icIndex]),
          (0..<24).contains(x), (0..<24).contains(y), (0..<12).contains(z), ic.isFinite else {
        fail("Invalid field CPT row")
    }
    if sites[id] == nil { sites[id] = Site(x: x, y: y, ic: Array(repeating: .nan, count: 12)) }
    guard sites[id]!.x == x, sites[id]!.y == y, sites[id]!.ic[z].isNaN else {
        fail("Duplicate or inconsistent field CPT row")
    }
    sites[id]!.ic[z] = ic
}
guard sites.count == 6, sites.values.allSatisfy({ $0.ic.allSatisfy(\.isFinite) }) else {
    fail("Expected six complete 12-depth profiles")
}

let pilot = try JSONSerialization.jsonObject(with: Data(contentsOf: pilotURL)) as? [String: Any]
guard let cases = pilot?["cases"] as? [[String: Any]],
      pilot?["protocol"] as? String == "six-field-CPT-known-site-retrospective-pilot-v1" else {
    fail("Unexpected pilot report")
}
let compiled = try MLModel.compileModel(at: modelURL)
let model = try MLModel(contentsOf: compiled)
let mean: Float = 2.305778080072476
let std: Float = 0.3108808206093057
let shape = [1, 1, 12, 24, 24].map(NSNumber.init(value:))
func index(_ x: Int, _ y: Int, _ z: Int) -> Int { z * 24 * 24 + y * 24 + x }

func reconstruction(_ ids: Set<String>) throws -> [Float] {
    let profiles = ids.sorted().map { (sites[$0]!.x, sites[$0]!.y, sites[$0]!.ic) }
    let sparse = try MLMultiArray(shape: shape, dataType: .float32)
    let mask = try MLMultiArray(shape: shape, dataType: .float32)
    let idw = try MLMultiArray(shape: shape, dataType: .float32)
    var observed: [Int: Float] = [:]
    for z in 0..<12 {
        for y in 0..<24 {
            for x in 0..<24 {
                let i = index(x, y, z)
                if let profile = profiles.first(where: { $0.0 == x && $0.1 == y }) {
                    let value = profile.2[z]
                    observed[i] = value
                    let norm = (value - mean) / std
                    sparse[i] = NSNumber(value: norm)
                    mask[i] = 1
                    idw[i] = NSNumber(value: norm)
                } else {
                    sparse[i] = 0
                    mask[i] = 0
                    var weighted = 0.0, total = 0.0
                    for (sx, sy, values) in profiles {
                        let d2 = Double((x - sx) * (x - sx) + (y - sy) * (y - sy))
                        let weight = 1 / max(d2, 1e-12)
                        weighted += weight * Double(values[z])
                        total += weight
                    }
                    idw[i] = NSNumber(value: (Float(weighted / total) - mean) / std)
                }
            }
        }
    }
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "sparse": sparse, "mask": mask, "idw": idw
    ])
    let prediction = try model.prediction(from: input)
    guard let output = prediction.featureValue(for: "reconstruction")?.multiArrayValue,
          output.count == 12 * 24 * 24 else { fail("Unexpected Model C output") }
    return (0..<output.count).map { i in
        observed[i] ?? (output[i].floatValue * std + mean)
    }
}

var results: [[String: Any]] = []
for start in sites.keys.sorted() {
    for count in [2, 3] {
        var selected: [String: Set<String>] = [:]
        for policy in ["dqn", "uniform"] {
            let rows = cases.filter {
                $0["initial_cpt"] as? String == start &&
                $0["policy"] as? String == policy &&
                (($0["observed_cpt_count"] as? Int) ?? 0) <= count
            }
            guard rows.count == count - 1 else { fail("Missing pilot selection") }
            var ids: Set<String> = [start]
            for row in rows {
                guard let xy = row["selected_xy"] as? [Int], xy.count == 2,
                      let id = sites.first(where: { $0.value.x == xy[0] && $0.value.y == xy[1] })?.key else {
                    fail("Selected XY is not a measured CPT")
                }
                ids.insert(id)
            }
            guard ids.count == count else { fail("Duplicate selected CPT") }
            selected[policy] = ids
        }
        let hidden = Set(sites.keys).subtracting(selected["dqn"]!).subtracting(selected["uniform"]!)
        guard !hidden.isEmpty else { fail("No common hidden CPT") }
        for policy in ["dqn", "uniform"] {
            guard let pilotRow = cases.first(where: {
                $0["initial_cpt"] as? String == start &&
                $0["policy"] as? String == policy &&
                $0["observed_cpt_count"] as? Int == count
            }), pilotRow["common_hidden_cpt_count"] as? Int == hidden.count else {
                fail("Pilot and Model C common hidden sets differ")
            }
            let values = try reconstruction(selected[policy]!)
            let errors = hidden.sorted().flatMap { id -> [Double] in
                let site = sites[id]!
                return (0..<12).map { z in
                    Double(values[index(site.x, site.y, z)] - site.ic[z])
                }
            }
            let rmse = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
            results.append([
                "initial_cpt": start, "observed_cpt_count": count,
                "policy": policy, "common_hidden_cpt_count": hidden.count,
                "common_hidden_ic_rmse_model_c_flexible": rmse
            ])
        }
    }
}
var summary: [String: Any] = [:]
for count in [2, 3] {
    var means: [String: Double] = [:]
    for policy in ["dqn", "uniform"] {
        let rows = results.filter {
            $0["observed_cpt_count"] as? Int == count && $0["policy"] as? String == policy
        }
        means[policy] = rows.compactMap { $0["common_hidden_ic_rmse_model_c_flexible"] as? Double }
            .reduce(0, +) / Double(rows.count)
    }
    summary[String(count)] = means
}
let report: [String: Any] = [
    "protocol": "model-c-flexible-on-frozen-dqn-pilot-selections-v1",
    "truth_scope": "same six real CPT sites and common hidden profiles as Python pilot",
    "model": "ModelC_Flexible.mlpackage used by app 3D display",
    "field_profiles_sha256": try sha256(fieldURL),
    "pilot_selection_sha256": try sha256(pilotURL),
    "model_spec_sha256": try sha256(modelURL.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")),
    "summary": summary, "cases": results
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outputURL)
print(String(data: data, encoding: .utf8)!)
