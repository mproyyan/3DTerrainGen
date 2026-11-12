import SwiftUI

/// Presentation data supplied by a Bearing Layer inference pipeline. Nil cells stay unclassified.
struct BearingLayerPresentation: Sendable {
    struct CPTLocation: Sendable, Identifiable {
        let id: String
        let x: Int
        let y: Int
    }
    struct Criteria: Sendable {
        let qcMinimumMPa: Double
        let icMaximum: Double
        let minimumThicknessMeters: Double
    }
    struct Reliability: Sendable {
        let conditionalDepthP90Meters: Double?
        let highRiskAreaPercent: Double?
        let supportedAreaPercent: Double?
        let fieldValidated: Bool
    }
    let nx: Int
    let ny: Int
    let dxMeters: Double
    let dyMeters: Double
    /// Row-major Y,X order, with Y increasing northward.
    let depthYX: [Double?]
    let candidateDetailsYX: [BearingLayerResult.CandidateDetail?]
    let cpts: [CPTLocation]
    let criteria: Criteria?
    let reliability: Reliability?

    init(_ result: BearingLayerResult) {
        nx = result.grid.nx; ny = result.grid.ny
        dxMeters = result.grid.spacingMeters; dyMeters = result.grid.northSpacingMeters
        depthYX = result.depthsYX
        candidateDetailsYX = result.candidateDetailsYX
        cpts = result.sites.map { .init(id:$0.name,x:$0.x,y:$0.y) }
        criteria = .init(qcMinimumMPa:result.qcMinimumMPa,icMaximum:result.icMaximum,
                         minimumThicknessMeters:result.minimumThicknessMeters)
        reliability = result.reliability.map { .init(conditionalDepthP90Meters:$0.conditionalDepthP90Meters,
            highRiskAreaPercent:$0.highRiskAreaPercent,supportedAreaPercent:$0.supportedAreaPercent,
            fieldValidated:$0.fieldValidated) }
    }

    var isValid: Bool {
        nx > 0 && ny > 0 && depthYX.count == nx * ny && candidateDetailsYX.count == nx * ny &&
        dxMeters.isFinite && dxMeters > 0 && dyMeters.isFinite && dyMeters > 0 &&
        depthYX.allSatisfy { value in value.map { $0.isFinite && $0 >= 0 } ?? true }
    }
    var depthRange: ClosedRange<Double>? {
        let depths = depthYX.compactMap { $0 }
        guard let low = depths.min(), let high = depths.max() else { return nil }
        return low...high
    }
    func depth(x: Int, y: Int) -> Double? {
        guard (0..<nx).contains(x), (0..<ny).contains(y) else { return nil }
        return depthYX[y * nx + x]
    }
    func candidate(x: Int, y: Int) -> BearingLayerResult.CandidateDetail? {
        guard (0..<nx).contains(x), (0..<ny).contains(y) else { return nil }
        return candidateDetailsYX[y * nx + x]
    }
}

struct BearingLayerView: View {
    @Bindable var session: TerrainSession
    private var result: BearingLayerPresentation? { session.bearingLayerResult.map(BearingLayerPresentation.init) }
    @State private var selectedCell: (x: Int, y: Int)?
    @State private var showPlanView = false
    private let panel = Color(red: 0.13, green: 0.17, blue: 0.20)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Bearing Layer").font(.largeTitle.bold())
                    Text("Indikasi kedalaman lapisan potensial di area investigasi")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let result, result.isValid {
                    if let range = result.depthRange {
                        heatmapCard(result: result, range: range)
                        depthSummary(range: range)
                    } else {
                        ContentUnavailableView("Belum ada kandidat lapisan yang terdeteksi berdasarkan kriteria saat ini",
                            systemImage:"square.dashed",
                            description:Text("Tidak ada interval yang memenuhi kriteria pada hasil inference ini. Ini bukan bukti bahwa lapisan tersebut tidak ada."))
                    }
                    criteriaCard(result.criteria)
                    reliabilityCard(result.reliability)
                } else {
                    ContentUnavailableView(session.bearingLayerLoading ? "Menghitung Bearing Layer…" : "Hasil Bearing Layer belum tersedia",
                                           systemImage: "square.grid.3x3.fill",
                                           description: Text(session.bearingLayerError ?? session.reconstructionError ?? "Simpan profil CPT qc/fs, lalu tunggu rekonstruksi Ic dan inference Bearing Layer."))
                    criteriaCard(nil)
                    reliabilityCard(nil)
                }
                Text("Indikasi lapisan potensial bukan konfirmasi lapisan dukung fondasi atau perhitungan bearing capacity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.06, green: 0.08, blue: 0.10).ignoresSafeArea())
        .foregroundStyle(.white)
        .navigationTitle("Bearing Layer")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func heatmapCard(result: BearingLayerPresentation, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Depth Heatmap").font(.headline)
                Text("Putar, cubit untuk zoom, atau tap lokasi untuk melihat kedalaman")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Tampilan", selection:$showPlanView) {
                Text("3D").tag(false)
                Text("Peta").tag(true)
            }.pickerStyle(.segmented)
            HStack(spacing: 16) {
                Label {
                    Text("CPT terukur")
                } icon: {
                    Circle().fill(.white).frame(width: 9, height: 9)
                }
                Label {
                    Text("Kandidat prediksi")
                } icon: {
                    Circle().fill(.teal).frame(width: 9, height: 9)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if !showPlanView {
                BearingDepthScene(result:result) { x,y in selectedCell = (x,y) }
                    .frame(height:300)
                    .clipShape(RoundedRectangle(cornerRadius:12))
            } else {
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let cellW = size.width / CGFloat(result.nx)
                        let cellH = size.height / CGFloat(result.ny)
                        for y in 0..<result.ny {
                            for x in 0..<result.nx {
                                guard let depth = result.depth(x: x, y: y) else { continue }
                                let rect = CGRect(x: CGFloat(x) * cellW,
                                                  y: CGFloat(result.ny - y - 1) * cellH,
                                                  width: cellW + 0.5, height: cellH + 0.5)
                                context.fill(Path(rect), with: .color(depthColor(depth, range: range)))
                            }
                        }
                    }
                    ForEach(result.cpts) { cpt in
                        if (0..<result.nx).contains(cpt.x), (0..<result.ny).contains(cpt.y) {
                            Circle().fill(.white).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.black.opacity(0.65), lineWidth: 1.5))
                                .position(x: (CGFloat(cpt.x) + 0.5) * width / CGFloat(result.nx),
                                          y: (CGFloat(result.ny - cpt.y) - 0.5) * height / CGFloat(result.ny))
                                .accessibilityLabel(cpt.id)
                        }
                    }
                    if let selectedCell {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 22, height: 22)
                            .shadow(color: .black, radius: 3)
                            .position(x: (CGFloat(selectedCell.x) + 0.5) * width / CGFloat(result.nx),
                                      y: (CGFloat(result.ny - selectedCell.y) - 0.5) * height / CGFloat(result.ny))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    selectedCell = (
                        x: min(result.nx - 1, max(0, Int(point.x / width * CGFloat(result.nx)))),
                        y: min(result.ny - 1, max(0, result.ny - 1 - Int(point.y / height * CGFloat(result.ny))))
                    )
                }
            }
            .aspectRatio(CGFloat(Double(result.nx) * result.dxMeters /
                                 max(Double(result.ny) * result.dyMeters, 1)), contentMode: .fit)
            .frame(maxHeight: 340)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            HStack {
                Text("Shallow").foregroundStyle(.orange)
                LinearGradient(colors: [.orange, .yellow, .green, .teal, .blue],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8).clipShape(Capsule())
                Text("Deep").foregroundStyle(.blue)
            }.font(.caption.bold())
            HStack {
                Text(String(format: "%.1f m", range.lowerBound))
                Spacer()
                Text(String(format: "%.1f m", range.upperBound))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let selectedCell {
                let depth = result.depth(x: selectedCell.x, y: selectedCell.y)
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.cyan)
                    Text(String(format: "X %.1f m · Y %.1f m",
                                (Double(selectedCell.x) + 0.5) * result.dxMeters,
                                (Double(selectedCell.y) + 0.5) * result.dyMeters))
                    Spacer()
                    Text(depth.map { String(format: "%.1f m", $0) } ?? "Belum terdeteksi")
                        .fontWeight(.semibold)
                }.font(.caption).monospacedDigit()
                if let depth, let candidate = result.candidate(x:selectedCell.x,y:selectedCell.y) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(candidate.measuredAtCPT ? "Didukung CPT terukur" : "Prediksi — perlu verifikasi lapangan")
                            .font(.caption.bold())
                            .foregroundStyle(candidate.measuredAtCPT ? .white : .orange)
                        HStack {
                            Text(String(format:"Kedalaman %.1f m",depth))
                            Spacer()
                            Text(String(format:"Jarak CPT terdekat %.1f m",candidate.nearestCPTMeters))
                        }
                        HStack {
                            Text(String(format:"qc %.3f MPa",candidate.qcMPa))
                            Spacer()
                            Text(String(format:"Ic %.3f",candidate.ic))
                        }
                        if candidate.nearThreshold {
                            Text("Dekat ambang kriteria (≤5%); status kandidat sensitif terhadap perubahan ambang. Ini bukan confidence model.")
                                .foregroundStyle(.orange)
                        }
                        Text("qc dan Ic ditampilkan pada awal interval lapisan yang memenuhi kriteria.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .padding(10)
                    .background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
                }
            }
        }
        .padding(14).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func depthSummary(range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Depth Summary").font(.headline)
            HStack(spacing: 8) {
                summaryValue("Shallowest", range.lowerBound)
                summaryValue("Deepest", range.upperBound)
                summaryValue("Variation", range.upperBound - range.lowerBound)
            }
        }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func summaryValue(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.1f m", value)).font(.subheadline.bold()).monospacedDigit()
                .minimumScaleFactor(0.75).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func criteriaCard(_ criteria: BearingLayerPresentation.Criteria?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Identification Criteria").font(.headline)
            if let criteria {
                criterion("Cone Resistance (qc)", String(format: "≥ %.1f MPa", criteria.qcMinimumMPa))
                criterion("Soil Behavior Index (Ic)", String(format: "≤ %.2f", criteria.icMaximum))
                criterion("Minimum Layer Thickness", String(format: "≥ %.1f m", criteria.minimumThicknessMeters))
            } else { Text("Menunggu kriteria dari hasil inference.").foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func criterion(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.semibold) }
            .font(.subheadline).padding(.vertical, 3)
    }

    private func reliabilityCard(_ reliability: BearingLayerPresentation.Reliability?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Prediction Reliability").font(.headline)
            if let reliability {
                if let p90 = reliability.conditionalDepthP90Meters {
                    criterion("Depth error P90, conditional", String(format: "± %.1f m", p90))
                }
                if let risk = reliability.highRiskAreaPercent {
                    criterion("High-risk area", String(format: "%.1f%%", risk))
                }
                if let supported = reliability.supportedAreaPercent {
                    criterion("Supported area", String(format: "%.1f%%", supported))
                }
                Text(reliability.fieldValidated ? "Field validated" : "Estimasi eksperimental; belum divalidasi di lapangan.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Belum cukup data").foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func depthColor(_ depth: Double, range: ClosedRange<Double>) -> Color {
        let fraction = range.upperBound > range.lowerBound
            ? (depth - range.lowerBound) / (range.upperBound - range.lowerBound) : 0.5
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.99, 0.43, 0.08)), (0.25, (0.99, 0.83, 0.15)),
            (0.5, (0.23, 0.79, 0.40)), (0.75, (0.05, 0.66, 0.69)),
            (1, (0.06, 0.28, 0.66))
        ]
        let scaled = min(1, max(0, fraction)) * 4
        let lower = min(3, Int(scaled)), t = scaled - Double(lower)
        let a = stops[lower].1, b = stops[lower + 1].1
        return Color(red: a.0 + (b.0 - a.0) * t,
                     green: a.1 + (b.1 - a.1) * t,
                     blue: a.2 + (b.2 - a.2) * t)
    }
}
