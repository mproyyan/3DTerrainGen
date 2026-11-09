import SwiftUI
import RealityKit
import Combine

struct Terrain3DView: View {
    let terrain: TerrainMesh
    @Bindable var session: TerrainSession
    @State private var resource: MeshResource?
    @State private var failure: String?
    @State private var resetID = 0
    @State private var showDetails = false
    @State private var showLegend = false
    @State private var showAnalysis = false
    @State private var loader: AnyCancellable?
    @State private var columns: [SubsurfaceColumn] = []
    @State private var columnVersion = 0
    @State private var displayMode = 0
    @State private var riskMode = RiskVisualizationMode.ic
    @State private var slice = SubsurfaceSlice()
    @State private var showSliceControls = false
    @State private var selectedProfile: VerticalProfile?
    @State private var profileMetric = SoilProfileMetric.ic
    @State private var hasInspectedModel = false
    @State private var inspectionMessage: String?
    @State private var depthScale: Float = 1
    @State private var showInvestigation = false
    @State private var buildingLayers = false
    @State private var layerFailure: String?

    var body: some View {
        ZStack {
            Color(red:0.06,green:0.08,blue:0.1).ignoresSafeArea()
            if let resource {
                GeometryReader { geometry in
                    TerrainRenderer(resource:resource, terrain:terrain, points:session.points, recommendation:session.recommendation, recommendationSource:session.recommendationSource, columns:columns, columnVersion:columnVersion, volume:session.reconstruction, volumes:session.reconstructionTiles, estimatedRisk:session.estimatedRisk, riskVersion:session.estimatedRiskVersion, displayResolutionMeters:session.spatialResolutionMeters, volumeVersion:session.reconstructionVersion, displayMode:displayMode, riskMode:riskMode, slice:slice, depthScale:depthScale, resetID:resetID,
                                    onMetrics:{ session.rendererDiagnostics = $0 },
                                    onSelect:{ position in
                        let active = session.reconstructionTiles.isEmpty ? session.reconstruction.map { [$0] } ?? [] : session.reconstructionTiles
                        selectedProfile = VerticalProfile.inspect(east:position.x,north:position.y,
                                                                  volumes:active,risk:session.estimatedRisk)
                        profileMetric = .ic
                        if selectedProfile != nil { hasInspectedModel = true }
                        if selectedProfile == nil { inspectionMessage = "Lokasi ini belum memiliki rekonstruksi Ic yang valid." }
                    })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel("3D terrain. Drag to orbit, pinch to zoom, and drag with two fingers to pan.")
                }
            } else if let failure {
                ContentUnavailableView("Unable to display terrain",systemImage:"exclamationmark.triangle",description:Text(failure))
            } else { ProgressView("Preparing terrain surface…").tint(.white).foregroundStyle(.white) }
        }
        .safeAreaInset(edge:.bottom) {
            ScrollView {
            VStack(spacing:8) {
                HStack {
                    Label("3D Subsurface",systemImage:"cube.transparent")
                        .font(.subheadline.bold())
                    Spacer()
                    Button(showAnalysis ? "Tutup analisis" : "Analisis & legenda") { showAnalysis.toggle() }
                        .font(.caption.bold())
                }
                if session.reconstruction != nil && !hasInspectedModel {
                    Label("Tap model untuk periksa profil tanah",systemImage:"hand.tap")
                        .font(.caption).foregroundStyle(.teal)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }
                if session.points.isEmpty == false && session.reconstruction == nil {
                    Text(session.reconstructionError ?? "Rekonstruksi Ic menunggu profil CPT atau sedang diproses.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if !session.points.isEmpty {
                    HStack {
                        Label("SIMULASI", systemImage: "flask.fill").font(.caption.bold()).foregroundStyle(.orange)
                        Spacer()
                        Button("Investigasi · \(session.status.completed)/\(session.status.target) CPT") { showInvestigation = true }
                            .font(.caption.bold())
                    }
                    if session.status.pending > 0 {
                        Button {
                            showInvestigation = true
                        } label: {
                            Label("\(session.status.pending) titik belum punya hasil tersimpan. Buka Investigasi → CPT, isi/import CSV, lalu ketuk Simpan & generate lapisan.", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .tint(.orange)
                    }
                    HStack {
                        ForEach(Array(["Permukaan", "Lapisan", "Potongan"].enumerated()), id: \.offset) { index, title in
                            Button { displayMode = index } label: { Text(title).frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(displayMode == index ? .teal : .gray.opacity(0.3))
                                .accessibilityAddTraits(displayMode == index ? .isSelected : [])
                        }
                    }.font(.caption)
                    if displayMode != 0 && session.reconstruction != nil {
                        Picker("Visualisasi", selection:$riskMode) {
                            ForEach(RiskVisualizationMode.allCases,id:\.self) { mode in Text(mode.rawValue).tag(mode) }
                        }.pickerStyle(.segmented)
                        if riskMode != .ic && session.estimatedRisk == nil {
                            Text("Estimated Reconstruction Risk sedang dihitung; warna Ic tetap tampil sampai risk siap.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if riskMode != .ic {
                            HStack(spacing: 8) {
                                Text("Risk Ic").foregroundStyle(.secondary)
                                Circle().fill(Color(red:0.10,green:0.65,blue:0.92)).frame(width:9,height:9)
                                Text("0")
                                Circle().fill(Color(red:0.98,green:0.82,blue:0.20)).frame(width:9,height:9)
                                Text("0,25")
                                Circle().fill(Color(red:0.93,green:0.18,blue:0.24)).frame(width:9,height:9)
                                Text("≥0,50")
                            }.font(.caption2.monospacedDigit())
                        }
                        if let bounds = SubsurfaceBounds(volumes:session.reconstructionTiles.isEmpty ? session.reconstruction.map { [$0] } ?? [] : session.reconstructionTiles) {
                            DisclosureGroup("Slice X/Y",isExpanded:$showSliceControls) {
                                VStack(spacing:7) {
                                    HStack {
                                        Text("X Slice")
                                        Slider(value:Binding(get:{ slice.eastLimit.map { $0-bounds.west } ?? bounds.width },
                                                             set:{ slice.eastLimit = bounds.west+$0 }),
                                               in:0...bounds.width)
                                        Text(String(format:"%.1f m",slice.eastLimit.map { $0-bounds.west } ?? bounds.width))
                                            .monospacedDigit().frame(width:62,alignment:.trailing)
                                    }
                                    HStack {
                                        Text("Y Slice")
                                        Slider(value:Binding(get:{ slice.northLimit.map { $0-bounds.south } ?? bounds.height },
                                                             set:{ slice.northLimit = bounds.south+$0 }),
                                               in:0...bounds.height)
                                        Text(String(format:"%.1f m",slice.northLimit.map { $0-bounds.south } ?? bounds.height))
                                            .monospacedDigit().frame(width:62,alignment:.trailing)
                                    }
                                    HStack {
                                        Text("Geser slider untuk membuka penampang; tap model untuk profil vertikal.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Reset") { slice = .init() }
                                    }
                                }.font(.caption)
                            }.font(.caption)
                        }
                    }
                    HStack {
                        Text("Skala depth").font(.caption)
                        ForEach([1,5,10], id: \.self) { scale in
                            Button { depthScale = Float(scale) } label: { Text("\(scale)×").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(depthScale == Float(scale) ? .teal : .gray.opacity(0.3))
                                .accessibilityLabel("Skala kedalaman \(scale) kali")
                        }
                    }
                    if depthScale > 1 {
                        Text("Kedalaman diperbesar \(Int(depthScale))× hanya untuk tampilan.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if session.reconstruction != nil {
                        HStack(spacing:6) {
                            Text("SBT").font(.caption2.bold())
                            ForEach(SBTVisualPalette.zones,id:\.self) { zone in
                                HStack(spacing:2) {
                                    Circle().fill(Color(SBTVisualPalette.color(zone)))
                                        .frame(width:9,height:9)
                                    Text("\(zone)")
                                }
                            }
                            Spacer(minLength:0)
                        }.font(.caption2.monospacedDigit())
                    }
                    DisclosureGroup("Legenda lapisan", isExpanded: $showLegend) {
                        VStack(alignment: .leading, spacing: 4) {
                            if session.reconstruction != nil {
                                ForEach(SBTVisualPalette.zones,id:\.self) { zone in
                                    HStack(spacing:8) {
                                        Circle().fill(Color(SBTVisualPalette.color(zone)))
                                            .frame(width:12,height:12)
                                        Text("Zona \(zone) · \(IcSBTClassifier.description(zone))")
                                        Spacer()
                                    }
                                }
                                HStack(spacing:8) {
                                    Circle().fill(Color(SBTVisualPalette.color(0))).frame(width:12,height:12)
                                    Text("Di luar rentang Ic")
                                }
                            }
                            if session.reconstruction == nil {
                                Text("Kolom mengikuti profil CPT terdekat; area abu-abu belum diketahui.")
                            } else {
                                Text(session.reconstructionStatus == .ready ? "Warna lapisan: klasifikasi SBT dari Ic SchemaGAN V4.2; Potongan menampilkan bagian dalam." : "Warna lapisan Ic belum tersedia.")
                                Text("Hanya window dengan CPT yang direkonstruksi. Permukaan transparan menunjukkan konteks DEMNAS; area lain belum diketahui.")
                                if session.estimatedRisk != nil {
                                    Text("Estimated Reconstruction Risk: biru 0, kuning 0,25, merah ≥0,50 Ic. Mode Gabungan memakai warna SBT asli dan transparansi risiko pada skala yang sama. Lapisan mempertahankan seluruh cakupan area; gunakan Potongan untuk penampang. CPT terukur tetap solid. Bukan calibrated confidence.")
                                }
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }.font(.caption2)
                }
                if showAnalysis {
                VStack(alignment:.leading,spacing:8) {
                    if session.reconstruction != nil {
                        hardLayerCard(for:nil)
                        bearingCapacityCard
                    }
                    Text("Tap model 3D untuk profil Ic per kedalaman. Hasil rekonstruksi bersifat perkiraan dan perlu investigasi tambahan.")
                }.font(.caption)
                }
                if showAnalysis && buildingLayers && session.reconstruction == nil { ProgressView("Memperbarui lapisan…").font(.caption) }
                if showAnalysis {
                switch session.reconstructionStatus {
                case .loading, .reconstructing:
                    ProgressView("Merekonstruksi Ic…").font(.caption)
                case .ready:
                    Text(session.reconstructionSummary ?? "Volume Ic siap").font(.caption2).foregroundStyle(.green)
                case .error:
                    Text("Rekonstruksi belum tersedia: \(session.reconstructionError ?? "input tidak memenuhi kontrak model")")
                        .font(.caption2).foregroundStyle(.orange)
                case .unavailable:
                    if session.points.isEmpty == false && session.status.completed == 0 {
                        Text("Rekonstruksi menunggu profil CPT yang sudah disimpan.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let layerFailure { Text(layerFailure).font(.caption).foregroundStyle(.red) }
                if session.estimatedRisk != nil {
                    Text("Estimated Reconstruction Risk · 0–0,50 Ic · CPT terukur solid")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let riskError = session.estimatedRiskError {
                    Text("Estimated Reconstruction Risk belum tersedia: \(riskError)")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let detail = session.v42Detail { Text(detail).font(.caption2).foregroundStyle(session.dqnRecommendationSource == .dqnV46A ? .green : .orange) }
                if session.recommendationSource == .dqnV46A, let q = session.v42QValue {
                    Text(String(format: "Q-score rekomendasi DQN V4.6-A: %.6f", Double(q)))
                        .font(.caption.monospacedDigit().bold()).foregroundStyle(.pink)
                    Text("Skor model, bukan persentase confidence.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if session.recommendationSource == .dqnV46A, session.recommendation != nil {
                    Text("Titik merah muda: rekomendasi DQN V4.6-A.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                }
                HStack {
                    Label("\(terrain.minimum, specifier:"%.1f")–\(terrain.maximum, specifier:"%.1f") m",systemImage:"mountain.2")
                    Spacer()
                    Text("\(terrain.areaSquareMeters/1_000_000, specifier:"%.3f") km²")
                }.font(.subheadline.monospacedDigit())
                Text("Geser: putar · Cubit: zoom · Dua jari: geser").font(.caption2).foregroundStyle(.secondary)
            }.padding().frame(maxWidth:.infinity).background(.regularMaterial)
            }.frame(maxHeight:310)
        }
        .navigationTitle("3D terrain").navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement:.topBarTrailing) {
                Button("Investigasi", systemImage: "list.bullet.clipboard") { showInvestigation = true }
                Button("Lihat seluruh area",systemImage:"arrow.counterclockwise") { resetID += 1 }
                Button("Terrain details",systemImage:"info.circle") { showDetails = true }
            }
        }
        .sheet(isPresented:$showDetails) { details }
        .sheet(isPresented:$showInvestigation) { CPTWorkspaceView(session: session) }
        .sheet(item:$selectedProfile) { profile in verticalProfilePanel(profile) }
        .alert("Profil belum tersedia",isPresented:Binding(get:{inspectionMessage != nil},set:{if !$0 { inspectionMessage = nil }})) {
            Button("OK",role:.cancel) { inspectionMessage = nil }
        } message: { Text(inspectionMessage ?? "") }
        .onChange(of:session.reconstructionVersion) { _, _ in
            slice = .init(); selectedProfile = nil; hasInspectedModel = false
        }
        .task(id: session.revision) {
            buildingLayers = true; layerFailure = nil
            let points = session.points, scenario = session.scenario
            let boundary = session.selection.coordinates.map { GeoPoint($0) }
            let job = Task.detached(priority: .userInitiated) {
                try SubsurfaceModel.columns(terrain: terrain, boundary: boundary, points: points, scenario: scenario)
            }
            do {
                let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                columns = result; columnVersion += 1; buildingLayers = false
            } catch is CancellationError { } catch { layerFailure = error.localizedDescription; buildingLayers = false }
        }
        .task {
            guard resource == nil, loader == nil else { return }
            var descriptor = MeshDescriptor(name:"DEMNAS terrain")
            descriptor.positions = .init(terrain.positions)
            descriptor.normals = .init(terrain.normals)
            descriptor.primitives = .triangles(terrain.indices)
            // Async publisher works on iOS 17 too; heavy raster/mesh math already ran off-main.
            loader = MeshResource.generateAsync(from:[descriptor])
                .receive(on:DispatchQueue.main)
                .sink(receiveCompletion: { completion in
                    if case .failure(let error) = completion { failure = error.localizedDescription }
                },receiveValue: { resource = $0 })
        }
        .onDisappear { loader?.cancel(); loader = nil }
    }
    private var details: some View {
        NavigationStack {
            List {
                LabeledContent("Horizontal CRS",value:"EPSG:\(terrain.metadata.epsg)")
                LabeledContent("Source samples checked",value:terrain.sourceSampleCount.formatted())
                LabeledContent("Rendering grid",value:terrain.gridSize)
                LabeledContent("Triangles",value:(terrain.indices.count/3).formatted())
                LabeledContent("Relative height origin",value:String(format:"%.3f m",terrain.elevationOrigin))
                Text(terrain.metadata.verticalReference)
                Text("Heights retain their original vertical datum. Rendering subtracts a common height origin and uses a local WGS 84 east/north metric frame. No geoid-to-ellipsoid conversion is applied.")
                Text("Large selections are sampled onto a bounded grid. Boundary heights are interpolated on its triangles; small terrain features may be smoothed. Elevation range includes original samples within the selection and interpolated boundary heights.")
                if !session.points.isEmpty {
                    NavigationLink("Diagnostics (Simulasi)") { diagnosticsPanel }
                }
                ForEach(terrain.metadata.provenance,id:\.self) { Text($0) }
            }.navigationTitle("Terrain metadata")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { showDetails = false } } }
        }
    }
    private func verticalProfilePanel(_ profile: VerticalProfile) -> some View {
        let measured = measuredCPT(for:profile)
        let samples = measured.flatMap { HardLayerAnalysisService.measuredSamples(for:$0) }
        return NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text(String(format:"East %.2f m · North %.2f m · grid (%d,%d)",
                                profile.east,profile.north,profile.x,profile.y))
                        .font(.caption.monospacedDigit())
                    Text(String(format:"Kedalaman rekonstruksi %.2f m · terukur terdalam %@",
                                profile.depthAvailable,
                                profile.deepestMeasured.map { String(format:"%.2f m",$0) } ?? "tidak ada"))
                        .font(.caption)
                    hardLayerCard(for:profile, measured:measured, samples:samples)
                    bearingCapacityCard
                    Picker("Profil",selection:$profileMetric) {
                        ForEach(SoilProfileMetric.allCases.filter { $0 == .ic || $0 == .sbt ||
                            (samples != nil && ($0 != .u2 || samples!.contains { $0.u2KPa != nil })) }) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }.pickerStyle(.segmented)
                    if profileMetric != .sbt {
                        let series = profileSeries(profile:profile,samples:samples,metric:profileMetric)
                        if series.count > 1 {
                            profileChart(series,maximumDepth:profileMetric == .ic ? profile.depthAvailable : (samples?.last?.depth ?? profile.depthAvailable))
                        }
                    }
                    if profileMetric == .ic || profileMetric == .sbt {
                    ForEach(Array(profile.points.enumerated()),id:\.offset) { _, row in
                        HStack(alignment:.top) {
                            Text(String(format:"%.1f–%.1f m",row.depthFrom,row.depthTo))
                                .frame(width:95,alignment:.leading)
                            VStack(alignment:.leading,spacing:2) {
                                Text(String(format:"Ic %.3f · %@",row.ic,row.sbt))
                                Text(row.measured ? "Measured (CPT)" : "Estimated (SchemaGAN)")
                                    .foregroundStyle(row.measured ? Color.green : Color.secondary)
                                if let risk = row.estimatedRiskIc {
                                    Text(String(format:"Estimated Reconstruction Risk %.3f Ic",risk))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }.font(.caption.monospacedDigit())
                        Divider()
                    }
                    } else if let samples {
                        ForEach(Array(samples.enumerated()),id:\.offset) { _, sample in
                            if let value = profileMetric.value(sample) {
                                HStack {
                                    Text(String(format:"%.2f m",sample.depth))
                                    Spacer()
                                    Text(String(format:"%.3f %@",value,profileMetric.unit))
                                }.font(.caption.monospacedDigit())
                            }
                        }
                    }
                    Text("Profil ini deskriptif; tidak menentukan kapan investigasi CPT dihentikan.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Vertical Soil Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) {
                Button("Done") { selectedProfile = nil }
            } }
        }
    }
    private func measuredCPT(for profile: VerticalProfile) -> CPTPoint? {
        let active = session.reconstructionTiles.isEmpty ? session.reconstruction.map { [$0] } ?? [] : session.reconstructionTiles
        guard active.indices.contains(profile.volumeIndex) else { return nil }
        return HardLayerAnalysisService.measuredPoint(gridX:profile.x,gridY:profile.y,
            volume:active[profile.volumeIndex],points:session.points,
            boundary:session.selection.coordinates.map { GeoPoint($0) })
    }
    private func profileSeries(profile: VerticalProfile, samples: [CPTSample]?,
                               metric: SoilProfileMetric) -> [(depth:Double,value:Double)] {
        if metric == .ic { return profile.points.map { ($0.depthCenter,Double($0.ic)) } }
        return samples?.compactMap { sample in metric.value(sample).map { (sample.depth,$0) } } ?? []
    }
    private func profileChart(_ values: [(depth:Double,value:Double)], maximumDepth: Double) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text("\(profileMetric.rawValue) → · Depth ↓").font(.caption.bold())
            GeometryReader { geometry in
                let lower = values.map(\.value).min() ?? 0
                let upper = values.map(\.value).max() ?? 1
                let span = max(upper-lower,0.1)
                Path { path in
                    for (index,row) in values.enumerated() {
                        let x = 12+CGFloat((row.value-lower)/span)*(geometry.size.width-24)
                        let y = CGFloat(row.depth/max(maximumDepth,0.1))*geometry.size.height
                        if index == 0 { path.move(to:CGPoint(x:x,y:y)) }
                        else { path.addLine(to:CGPoint(x:x,y:y)) }
                    }
                }.stroke(.teal,lineWidth:2)
            }.frame(height:140).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
        }
    }
    private func hardLayerCard(for profile: VerticalProfile?, measured: CPTPoint? = nil,
                               samples: [CPTSample]? = nil) -> some View {
        let indication = samples.flatMap { HardLayerAnalysisService.indication(samples:$0) }
        return GroundMetricStatusCard(
            title:"Indikasi Lapisan Keras",
            unavailableStatus:samples == nil ? "Belum tersedia di lokasi ini" : "Belum teridentifikasi",
            selectedLocation:profile.map { String(format:"Selected location: X %.2f m · Y %.2f m",
                                                    $0.east,$0.north) },
            explanation:samples == nil
                ? "Analisis membutuhkan profil CPT langsung pada lokasi tersebut."
                : indication == nil
                    ? "Profil CPT ini belum menunjukkan tahanan konus tinggi yang persisten sesuai criterion saat ini."
                    : "Diidentifikasi dari tahanan konus (qc) yang persisten pada CPT ini.",
            available:[],required:[],
            details:hardLayerDetails(indication:indication, hasMeasured:samples != nil),
            estimate:indication.map { String(format:"%.2f m",$0.depth) },
            estimateLabel:indication == nil ? nil : "PoC / experimental")
    }
    private func hardLayerDetails(indication: HardLayerIndication?, hasMeasured: Bool) -> String {
        var details = String(format:"qc threshold: %.3f MPa · minimum continuous thickness: %.2f m · PoC / experimental. Bukan kedalaman lapisan keras yang tervalidasi untuk desain pondasi.",
                             HardLayerAnalysisService.qcThresholdMPa,HardLayerAnalysisService.minimumContinuousThicknessM)
        if let indication {
            details += String(format:" Confirmed until: %.2f m · qc at candidate depth: %.3f MPa · mean qc: %.3f MPa.",
                              indication.confirmedUntilDepth,indication.startQcMPa,indication.meanQcMPa)
        } else if !hasMeasured { details += " Memerlukan profil CPT aktual; Ic/SBT rekonstruksi tidak digunakan untuk menghitung qc." }
        return details
    }
    private var bearingCapacityCard: some View {
        GroundMetricStatusCard(
            title:"Bearing Capacity",
            unavailableStatus:"Belum cukup data untuk menghitung kapasitas",
            explanation:"Data yang tersedia belum cukup untuk menghitung kapasitas dukung secara andal.",
            available:[],
            required:["CPT qc/fs untuk perhitungan","Foundation type / geometry",
                      "Foundation depth","Validated geotechnical method / correlation"],
            details:PreliminaryGroundAssessment.bearing)
    }
    private var diagnosticsPanel: some View {
        ScrollView {
            Text(diagnosticsText).font(.caption.monospaced())
                .frame(maxWidth:.infinity,alignment:.leading).padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                Button("Copy Diagnostics") { UIPasteboard.general.string = diagnosticsText }
            }
        }
    }
    private var diagnosticsText: String {
        var lines = ["Demnas3DMap · Simulation Diagnostics",
                     "SchemaGAN: \(session.reconstructionStatus.rawValue) · \(session.reconstructionSummary ?? session.reconstructionError ?? "belum tersedia")",
                     "Uncertainty V3: \(session.estimatedRisk != nil ? "ready" : session.estimatedRiskError ?? "menunggu")",
                     "CPT Ic lengkap: \(session.points.filter(\.isComplete).count) / \(session.points.count)"]
        if let volume = session.reconstruction {
            let grid = volume.grid
            lines.append(String(format:"Grid: %d×%d×%d · dx %.3f m · dy %.3f m · dz %.3f m",
                                grid.nx,grid.ny,grid.nz,grid.spacingMeters,grid.northSpacingMeters,grid.depthSpacingMeters))
            lines.append("Voxel valid: \(volume.validXY.filter { $0 }.count * grid.nz) · terukur: \(volume.observed.filter { $0 }.count)")
        }
        if let risk = session.estimatedRisk {
            if let stats = risk.statistics {
                lines.append(String(format:"Estimated Reconstruction Risk (Ic): min %.4f · mean %.4f · max %.4f · prediksi %d",
                                    stats.minimum,stats.mean,stats.maximum,stats.count))
            }
            lines.append(String(format:"Risk timing: fitur %.3f s · trees %.3f s",risk.featureSeconds,risk.treeSeconds))
        }
        if let renderer = session.rendererDiagnostics {
            lines.append("Renderer: \(renderer.mode.rawValue) · voxel dirender \(renderer.renderedVoxelCount)")
            lines.append(String(format:"Opacity diterapkan: min %.3f · mean %.3f · max %.3f",renderer.minimumOpacity,renderer.meanOpacity,renderer.maximumOpacity))
            lines.append(String(format:"Pembaruan renderer: %.3f s",renderer.updateSeconds))
            lines.append("Geometri terlihat: terrain \(renderer.terrainVisible ? "ya" : "tidak"), cutaway \(renderer.cutaway ? "ya" : "tidak"), LOD \(renderer.lodStep), marker entity \(renderer.markerCount), parent bersama \(renderer.sharedParent ? "ya" : "tidak")")
            lines.append(String(format:"Root scale %.6f · offset (%.4f, %.4f, %.4f) · rotasi (%.4f, %.4f, %.4f, %.4f)",
                                renderer.rootScale,renderer.rootPosition.x,renderer.rootPosition.y,renderer.rootPosition.z,
                                renderer.rootRotation.x,renderer.rootRotation.y,renderer.rootRotation.z,renderer.rootRotation.w))
            func coordinate(_ value: SIMD3<Float>?) -> String {
                guard let value else { return "tidak tersedia" }
                return String(format:"(%.5f, %.5f, %.5f)",value.x,value.y,value.z)
            }
            lines.append("Marker lokal X/Y/Z: \(coordinate(renderer.markerLocal))")
            lines.append("Marker world: \(coordinate(renderer.markerWorld))")
            lines.append("Segitiga terrain #\(renderer.surfaceTriangle.map(String.init) ?? "tidak ada") world: \(coordinate(renderer.surfaceWorld))")
            if let gap = renderer.markerSurfaceGapWorld {
                lines.append(String(format:"Jarak horizontal marker–segitiga: %.7f world unit (%.4f m)",gap,Double(gap/max(renderer.rootScale,0.000001))))
            }
            lines.append("Voxel Lapisan pendukung world: \(coordinate(renderer.supportingVoxelWorld))")
            if let gap = renderer.supportingVoxelGapWorld {
                lines.append(String(format:"Jarak horizontal pusat marker–pusat voxel LOD: %.5f world unit",gap))
            }
        }
        if session.recommendationSource == .dqnV46A, let recommendation = session.recommendation {
            lines.append(String(format:"DQN V4.6-A: lat %.7f · lon %.7f · Q %.6f",
                                recommendation.latitude,recommendation.longitude,Double(session.v42QValue ?? .nan)))
            if let info = session.dqnInfo { lines.append(info) }
        } else {
            lines.append("DQN: \(session.v42Detail ?? "belum tersedia")")
        }
        lines.append("Risk adalah estimated error, bukan calibrated confidence. Q bukan confidence.")
        return lines.joined(separator:"\n")
    }
}

private enum SoilProfileMetric: String, CaseIterable, Identifiable {
    case ic = "Ic", qc = "qc", fs = "fs", u2 = "u2", sbt = "SBT"
    var id: String { rawValue }
    var unit: String {
        switch self { case .qc: "MPa"; case .fs, .u2: "kPa"; default: "" }
    }
    func value(_ sample: CPTSample) -> Double? {
        switch self {
        case .qc: sample.qcMPa
        case .fs: sample.fsKPa
        case .u2: sample.u2KPa
        case .ic, .sbt: nil
        }
    }
}

private struct GroundMetricStatusCard: View {
    let title: String
    let unavailableStatus: String
    var selectedLocation: String? = nil
    let explanation: String
    let available: [String]
    let required: [String]
    let details: String
    var estimate: String? = nil
    var estimateLabel: String? = nil
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            Text(title).font(.headline)
            if let selectedLocation {
                Text(selectedLocation).font(.caption.monospacedDigit()).foregroundStyle(.teal)
            }
            HStack(alignment:.firstTextBaseline,spacing:7) {
                Image(systemName:estimate == nil ? "questionmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(estimate == nil ? Color.orange : Color.green)
                Text(estimate ?? unavailableStatus)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(estimate == nil ? Color.primary : Color.green)
                    .minimumScaleFactor(0.8)
            }
            if let estimateLabel {
                Text(estimateLabel).font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text(explanation).font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("Details",isExpanded:$showsDetails) {
                VStack(alignment:.leading,spacing:6) {
                    if !available.isEmpty {
                        Text("Data tersedia").font(.caption.bold())
                        ForEach(available,id:\.self) { Label($0,systemImage:"checkmark.circle.fill") }
                    }
                    if !required.isEmpty {
                        Text("Masih dibutuhkan").font(.caption.bold())
                        ForEach(required,id:\.self) { Label($0,systemImage:"circle.dotted") }
                    }
                    Text(details).font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            }.font(.caption)
        }
        .font(.caption)
        .frame(maxWidth:.infinity,alignment:.leading)
        .padding(14)
        .background(.thinMaterial,in:RoundedRectangle(cornerRadius:14))
    }
}

private enum SBTVisualPalette {
    static let zones = [2,3,4,5,6,7]
    static func color(_ zone: Int) -> UIColor {
        switch zone {
        case 2: UIColor(red:0.76,green:0.23,blue:0.24,alpha:1)
        case 3: UIColor(red:0.94,green:0.49,blue:0.20,alpha:1)
        case 4: UIColor(red:0.78,green:0.68,blue:0.48,alpha:1)
        case 5: UIColor(red:0.61,green:0.76,blue:0.43,alpha:1)
        case 6: UIColor(red:0.23,green:0.67,blue:0.65,alpha:1)
        case 7: UIColor(red:0.20,green:0.35,blue:0.61,alpha:1)
        default: UIColor(white:0.62,alpha:1)
        }
    }
}

private struct TerrainRenderer: UIViewRepresentable {
    let resource: MeshResource
    let terrain: TerrainMesh
    let points: [CPTPoint]
    let recommendation: GeoPoint?
    let recommendationSource: RecommendationSource
    let columns: [SubsurfaceColumn]
    let columnVersion: Int
    let volume: ReconstructionVolume?
    let volumes: [ReconstructionVolume]
    let estimatedRisk: UncertaintyV2Map?
    let riskVersion: Int
    let displayResolutionMeters: Double
    let volumeVersion: Int
    let displayMode: Int
    let riskMode: RiskVisualizationMode
    let slice: SubsurfaceSlice
    let depthScale: Float
    let resetID: Int
    let onMetrics: (RendererDiagnostics) -> Void
    let onSelect: (Point2) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame:.zero,cameraMode:.nonAR,automaticallyConfigureSession:false)
        view.environment.background = .color(.init(red:0.06,green:0.08,blue:0.1,alpha:1))
        let anchor = AnchorEntity(world:.zero)
        var material = SimpleMaterial(color:.init(red:0.42,green:0.67,blue:0.48,alpha:1),roughness:0.85,isMetallic:false)
        if #available(iOS 18.0, *) { material.faceCulling = .none }
        let model = ModelEntity(mesh:resource,materials:[material])
        let bounds = model.visualBounds(relativeTo:nil)
        let span = max(bounds.extents.x,bounds.extents.y,bounds.extents.z,1)
        context.coordinator.terrainModel = model
        context.coordinator.terrain = terrain
        context.coordinator.onSelect = onSelect
        context.coordinator.root.addChild(model)
        context.coordinator.root.addChild(context.coordinator.subsoil)
        context.coordinator.root.addChild(context.coordinator.markers)
        context.coordinator.root.addChild(context.coordinator.ruler)
        context.coordinator.root.addChild(context.coordinator.inspectionSelection)
        context.coordinator.root.scale = .init(repeating: 2/span)
        context.coordinator.root.position = -bounds.center * (2/span)
        anchor.addChild(context.coordinator.root)
        let light = DirectionalLight()
        light.light.intensity = 2500
        light.look(at:.zero,from:[-3,5,2],relativeTo:nil)
        anchor.addChild(light)
        let fill = DirectionalLight()
        fill.light.intensity = 750
        fill.look(at:.zero,from:[3,2,-2],relativeTo:nil)
        anchor.addChild(fill)
        anchor.addChild(context.coordinator.camera)
        view.scene.addAnchor(anchor)
        let orbit = UIPanGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.zoom(_:)))
        for gesture in [orbit,pan,pinch] { view.addGestureRecognizer(gesture) }
        view.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,
                                                          action:#selector(Coordinator.inspect(_:))))
        context.coordinator.reset()
        return view
    }
    func updateUIView(_ uiView: ARView,context:Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.currentVolumes = volumes.isEmpty ? volume.map { [$0] } ?? [] : volumes
        if coordinator.volumeVersion != volumeVersion { coordinator.clearSelection() }
        let shouldFocusModel = displayMode != 0 && !volumes.isEmpty &&
            (coordinator.displayMode != displayMode || coordinator.volumeVersion != volumeVersion)
        if coordinator.columnVersion != columnVersion || coordinator.volumeVersion != volumeVersion || coordinator.riskVersion != riskVersion || coordinator.riskMode != riskMode || coordinator.slice != slice || coordinator.depthScale != depthScale || coordinator.displayMode != displayMode || coordinator.pointIDs != points.map(\.id) || coordinator.recommendation != recommendation || coordinator.recommendationSource != recommendationSource {
            coordinator.columnVersion = columnVersion; coordinator.volumeVersion = volumeVersion; coordinator.depthScale = depthScale; coordinator.displayMode = displayMode
            coordinator.riskVersion = riskVersion; coordinator.riskMode = riskMode; coordinator.slice = slice
            coordinator.pointIDs = points.map(\.id); coordinator.recommendation = recommendation; coordinator.recommendationSource = recommendationSource
            let metrics = coordinator.rebuild(terrain: terrain, columns: columns, volume: volume, volumes: volumes, estimatedRisk: estimatedRisk, displayResolutionMeters: displayResolutionMeters, points: points, recommendation: recommendation, recommendationSource: recommendationSource)
            Task { @MainActor in onMetrics(metrics) }
            if shouldFocusModel { coordinator.focus(on: volumes, terrain: terrain) }
        }
        if context.coordinator.resetID != resetID { context.coordinator.resetID = resetID; context.coordinator.reset() }
    }
    @MainActor final class Coordinator: NSObject {
        let camera = PerspectiveCamera()
        let root = Entity()
        let subsoil = Entity()
        let markers = Entity()
        let ruler = Entity()
        let inspectionSelection = Entity()
        var inspectedHitLocal: SIMD3<Float>?
        var inspectableBoxes: [TerrainRaycast.Box] = []
        var currentVolumes: [ReconstructionVolume] = []
        let rulerSliceMarkers = Entity()
        var rulerLabels: [ModelEntity] = []
        var rulerSignature: String?
        var terrainModel: ModelEntity?
        var recommendationMarker: ModelEntity?
        var supportingVoxel: ModelEntity?
        var lodStep = 1
        var columnVersion = -1
        var volumeVersion = -1
        var riskVersion = -1
        var riskMode = RiskVisualizationMode.ic
        var slice = SubsurfaceSlice()
        var terrain: TerrainMesh?
        var onSelect: ((Point2) -> Void)?
        var renderedVoxelCount = 0
        var opacityMinimum = 1.0
        var opacityMaximum = 0.0
        var opacityTotal = 0.0
        var depthScale: Float = 1
        var displayMode = 1
        var pointIDs: [UUID] = []
        var recommendation: GeoPoint?
        var recommendationSource = RecommendationSource.none
        func rebuild(terrain: TerrainMesh, columns: [SubsurfaceColumn], volume: ReconstructionVolume?, volumes: [ReconstructionVolume], estimatedRisk: UncertaintyV2Map?, displayResolutionMeters: Double, points: [CPTPoint], recommendation: GeoPoint?, recommendationSource: RecommendationSource) -> RendererDiagnostics {
            let renderStart = Date()
            renderedVoxelCount = 0; opacityMinimum = 1; opacityMaximum = 0; opacityTotal = 0
            subsoil.children.removeAll(); markers.children.removeAll()
            inspectableBoxes.removeAll(keepingCapacity:true)
            recommendationMarker = nil; supportingVoxel = nil; lodStep = 1
            let cutaway = AdaptiveGrid.usesCutaway(displayMode:displayMode) && !slice.isActive
            terrainModel?.isEnabled = !cutaway || (columns.isEmpty && volume == nil)
            var terrainMaterial = SimpleMaterial(
                color: UIColor(red: 0.42, green: 0.67, blue: 0.48,
                               alpha: displayMode == 0 ? 1 : 0.16),
                roughness: 0.85, isMetallic: false
            )
            if #available(iOS 18.0, *) { terrainMaterial.faceCulling = .none }
            terrainModel?.model?.materials = [terrainMaterial]
            let midX = ((terrain.positions.map(\.x).min() ?? 0) + (terrain.positions.map(\.x).max() ?? 0))/2
            if displayMode != 0, let volume {
                renderModelC(volumes.isEmpty ? [volume] : volumes, estimatedRisk: estimatedRisk, terrain: terrain, displayResolutionMeters: displayResolutionMeters, cutaway:cutaway, recommendation:recommendation)
            } else if displayMode != 0 {
                for column in columns {
                    if displayMode == 2 && !column.observed && column.surface.x > midX { continue }
                    let height = Float(column.bottom-column.top)*depthScale
                    let color: UIColor = column.behavior.map { UIColor($0.color) } ?? UIColor(white: 0.65, alpha: 0.16)
                    let material = SimpleMaterial(color: color, roughness: 0.85, isMetallic: column.observed)
                    let entity = ModelEntity(mesh: .generateBox(size: [column.width, height, column.length]), materials: [material])
                    entity.position = column.surface - SIMD3<Float>(0, Float((column.top+column.bottom)/2)*depthScale, 0)
                    subsoil.addChild(entity)
                }
            }
            let minX = terrain.positions.map(\.x).min() ?? 0, maxX = terrain.positions.map(\.x).max() ?? 1
            let minZ = terrain.positions.map(\.z).min() ?? 0, maxZ = terrain.positions.map(\.z).max() ?? 1
            let markerRadius = max(0.4, max(maxX-minX, maxZ-minZ)*0.008)
            func marker(_ geo: GeoPoint, _ color: UIColor, _ name: String) -> ModelEntity? {
                guard let center = terrain.markerCenter(at: geo, radius:markerRadius) else { return nil }
                let sphere = ModelEntity(mesh: .generateSphere(radius: markerRadius), materials: [SimpleMaterial(color: color, isMetallic: false)])
                sphere.position = center
                sphere.name = name; markers.addChild(sphere)
                return sphere
            }
            for point in points { _ = marker(point.coordinate, point.isComplete ? .systemGreen : .systemOrange, point.name) }
            if recommendationSource == .dqnV46A, let recommendation { recommendationMarker = marker(recommendation, .systemPink, "DQN V4.6-A") }
            let maxDepth = Float(volume == nil ? (columns.map(\.bottom).max() ?? 0) : Double(volume!.grid.nz) * volume!.grid.depthSpacingMeters)*depthScale
            let low = Float(terrain.minimum-terrain.elevationOrigin)-maxDepth
            let high = Float(terrain.maximum-terrain.elevationOrigin)+Float(markerRadius*3)
            let span = max(maxX-minX, maxZ-minZ, high-low, 1)
            root.scale = .init(repeating: 2/span)
            root.position = -SIMD3<Float>((minX+maxX)/2, (low+high)/2, (minZ+maxZ)/2)*(2/span)
            if let volume {
                let activeVolumes = volumes.isEmpty ? [volume] : volumes
                if let bounds = SubsurfaceBounds(volumes:activeVolumes) {
                    let centerEast = (bounds.west+bounds.east)/2
                    let centerNorth = (bounds.south+bounds.north)/2
                    let referenceY = terrain.surfacePosition(x:Float(centerEast),z:Float(-centerNorth))?.y
                        ?? Float((terrain.minimum+terrain.maximum)/2-terrain.elevationOrigin)
                    if let layout = SceneRulerLayout(volumes:activeVolumes,
                                                     surfaceY:Double(referenceY),depthScale:Double(depthScale)) {
                        updateRuler(layout:layout,terrain:terrain)
                    }
                }
            } else {
                ruler.children.removeAll(); rulerLabels.removeAll(); rulerSignature = nil
                clearSelection()
            }
            if let inspectedHitLocal { drawSelection(at:inspectedHitLocal,terrain:terrain) }
            let sample = recommendation.flatMap { terrain.surfaceSample(at:$0) }
            let markerWorld = recommendationMarker?.position(relativeTo:nil)
            let surfaceWorld = sample.flatMap { terrainModel?.convert(position:$0.position,to:nil) }
            let markerBaseWorld = recommendationMarker?.convert(position:[0,-markerRadius,0],to:nil)
            let markerGap = markerBaseWorld.flatMap { base in surfaceWorld.map { surface in
                hypot(base.x-surface.x,base.z-surface.z)
            } }
            let voxelWorld = supportingVoxel?.position(relativeTo:nil)
            let voxelGap = markerWorld.flatMap { marker in voxelWorld.map { voxel in
                hypot(marker.x-voxel.x,marker.z-voxel.z)
            } }
            return .init(mode:riskMode,renderedVoxelCount:renderedVoxelCount,
                         minimumOpacity:renderedVoxelCount == 0 ? 1 : opacityMinimum,
                         meanOpacity:renderedVoxelCount == 0 ? 1 : opacityTotal/Double(renderedVoxelCount),
                         maximumOpacity:renderedVoxelCount == 0 ? 1 : opacityMaximum,
                         updateSeconds:Date().timeIntervalSince(renderStart),
                         cutaway:cutaway,lodStep:lodStep,markerCount:markers.children.count,
                         terrainVisible:terrainModel?.isEnabled ?? false,
                         sharedParent:markers.parent === root && terrainModel?.parent === root,
                         rootScale:root.scale.x,rootPosition:root.position,
                         rootRotation:root.orientation.vector,
                         markerLocal:recommendationMarker?.position,markerWorld:markerWorld,
                         surfaceWorld:surfaceWorld,surfaceTriangle:sample?.triangle,
                         markerSurfaceGapWorld:markerGap,supportingVoxelWorld:voxelWorld,
                         supportingVoxelGapWorld:voxelGap)
        }

        private func updateRuler(layout: SceneRulerLayout, terrain: TerrainMesh) {
            let b = layout.bounds
            let signature = String(format:"%d:%.7f:%.7f:%.4f:%.4f:%.4f:%.4f:%.4f:%.4f:%.4f:%.2f",
                                   volumeVersion,terrain.origin.longitude,terrain.origin.latitude,
                                   b.west,b.south,b.east,b.north,layout.depthMeters,
                                   layout.surfaceY,layout.offsetMeters,layout.depthScale)
            let axisEast = b.west-layout.offsetMeters
            let axisNorth = b.south-layout.offsetMeters
            let bottomDepth = layout.depthMeters
            let labelSize = max(max(b.width,b.height)*0.014,layout.depthMeters*0.055)
            let thickness = Float(max(labelSize*0.035,layout.offsetMeters*0.025))
            let tickSize = max(layout.offsetMeters*0.38,labelSize*0.45)
            func tickCount(length: Double, labelSpacing: Double) -> Int {
                max(1,min(5,Int(floor(length/max(labelSpacing,0.001)))))
            }
            let eastColor = UIColor(red:0.18,green:0.78,blue:0.95,alpha:1)
            let northColor = UIColor(red:0.65,green:0.85,blue:0.32,alpha:1)
            let depthColor = UIColor(red:1,green:0.66,blue:0.25,alpha:1)
            if rulerSignature != signature {
                ruler.children.removeAll()
                rulerLabels.removeAll()
                ruler.addChild(rulerSliceMarkers)
                rulerSignature = signature

                func line(_ a: SIMD3<Float>,_ c: SIMD3<Float>,color: UIColor, width: Float = 0) {
                    let delta = c-a, length = simd_length(delta)
                    guard length > 1e-6 else { return }
                    let w = width > 0 ? width : thickness
                    let entity = ModelEntity(mesh:.generateBox(size:[w,w,length]),
                                             materials:[UnlitMaterial(color:color)])
                    entity.position = (a+c)/2
                    entity.orientation = simd_quatf(from:[0,0,1],to:delta/length)
                    ruler.addChild(entity)
                }
                func label(_ value: String,at point: SIMD3<Float>,color: UIColor) {
                    let mesh = MeshResource.generateText(value,extrusionDepth:0,
                                                         font:.systemFont(ofSize:CGFloat(labelSize),weight:.semibold))
                    let entity = ModelEntity(mesh:mesh,materials:[UnlitMaterial(color:color)])
                    entity.position = point
                    ruler.addChild(entity)
                    rulerLabels.append(entity)
                }
                let corner = layout.point(east:axisEast,north:axisNorth,depth:bottomDepth)
                line(layout.point(east:b.west,north:axisNorth,depth:bottomDepth),
                     layout.point(east:b.east,north:axisNorth,depth:bottomDepth),color:eastColor)
                line(layout.point(east:axisEast,north:b.south,depth:bottomDepth),
                     layout.point(east:axisEast,north:b.north,depth:bottomDepth),color:northColor)
                line(layout.point(east:axisEast,north:axisNorth,depth:0),corner,color:depthColor)
                for metres in SceneRulerLayout.tickValues(
                    length:b.width,targetIntervals:tickCount(length:b.width,labelSpacing:labelSize*4)) {
                    let east = b.west+metres
                    line(layout.point(east:east,north:axisNorth,depth:bottomDepth),
                         layout.point(east:east,north:axisNorth-tickSize,depth:bottomDepth),color:eastColor)
                    label(String(format:"%.1f m",metres),
                          at:layout.point(east:east,north:axisNorth-tickSize-labelSize*0.6,depth:bottomDepth),
                          color:eastColor)
                }
                for metres in SceneRulerLayout.tickValues(
                    length:b.height,targetIntervals:tickCount(length:b.height,labelSpacing:labelSize*4)) {
                    let north = b.south+metres
                    line(layout.point(east:axisEast,north:north,depth:bottomDepth),
                         layout.point(east:axisEast-tickSize,north:north,depth:bottomDepth),color:northColor)
                    label(String(format:"%.1f m",metres),
                          at:layout.point(east:axisEast-tickSize-labelSize*2.5,north:north,depth:bottomDepth),
                          color:northColor)
                }
                for metres in SceneRulerLayout.tickValues(
                    length:layout.depthMeters,
                    targetIntervals:tickCount(length:layout.depthMeters,
                                              labelSpacing:labelSize*1.8/layout.depthScale)) {
                    line(layout.point(east:axisEast,north:axisNorth,depth:metres),
                         layout.point(east:axisEast-tickSize,north:axisNorth,depth:metres),color:depthColor)
                    label(String(format:"-%.1f m",metres),
                          at:layout.point(east:axisEast-tickSize-labelSize*2.5,north:axisNorth,depth:metres),
                          color:depthColor)
                }
                label("Easting (X)",at:layout.point(east:b.east+layout.offsetMeters*0.2,
                    north:axisNorth,depth:bottomDepth),color:eastColor)
                label("Northing (Y)",at:layout.point(east:axisEast,north:b.north+layout.offsetMeters*0.2,
                    depth:bottomDepth),color:northColor)
                label("Depth (Z, center ref)",at:layout.point(east:axisEast,north:axisNorth,
                    depth:bottomDepth+layout.offsetMeters*0.2),color:depthColor)
            }
            rulerSliceMarkers.children.removeAll()
            func indicator(_ point: SIMD3<Float>,color: UIColor) {
                let entity = ModelEntity(mesh:.generateSphere(radius:Float(max(labelSize*0.35,Double(thickness)*2))),
                                         materials:[UnlitMaterial(color:color)])
                entity.position = point
                rulerSliceMarkers.addChild(entity)
            }
            if let east = slice.eastLimit, east >= b.west, east <= b.east {
                indicator(layout.point(east:east,north:axisNorth,depth:bottomDepth),color:.systemPink)
            }
            if let north = slice.northLimit, north >= b.south, north <= b.north {
                indicator(layout.point(east:axisEast,north:north,depth:bottomDepth),color:.systemPink)
            }
            faceRulerLabelsToCamera()
        }

        private func faceRulerLabelsToCamera() {
            let cameraLocal = root.convert(position:camera.position(relativeTo:nil),from:nil)
            for label in rulerLabels {
                let delta = cameraLocal-label.position
                guard simd_length_squared(delta) > 1e-8 else { continue }
                label.orientation = simd_quatf(from:[0,0,1],to:simd_normalize(delta))
            }
        }
        /// Six Ic-only SBT zones from synthetic3d/v2/core.py::classify_sbt.
        /// Unknown extremes remain gray. Observed synthetic CPTs use lower opacity.
        /// Each model window is a RealityKit chunk. LOD caps exposed voxel entities
        /// while the physical sampler blends overlap and preserves measured CPT voxels.
        private func renderModelC(_ volumes: [ReconstructionVolume], estimatedRisk: UncertaintyV2Map?, terrain: TerrainMesh,
                                  displayResolutionMeters: Double, cutaway: Bool, recommendation: GeoPoint?) {
            func zone(_ ic: Float) -> Int { IcSBTClassifier.zone(ic) }
            let palette = Dictionary(uniqueKeysWithValues:[0,2,3,4,5,6,7].map {
                ($0,SBTVisualPalette.color($0))
            })
            func riskColor(_ fraction: Double) -> UIColor {
                let low = (r:0.10,g:0.65,b:0.92)
                let middle = (r:0.98,g:0.82,b:0.20)
                let high = (r:0.93,g:0.18,b:0.24)
                let pair = fraction <= 0.5 ? (low,middle,fraction*2) : (middle,high,(fraction-0.5)*2)
                return UIColor(red:pair.0.r+(pair.1.r-pair.0.r)*pair.2,
                               green:pair.0.g+(pair.1.g-pair.0.g)*pair.2,
                               blue:pair.0.b+(pair.1.b-pair.0.b)*pair.2,alpha:1)
            }
            let estimated = volumes.reduce(0) { $0 + $1.grid.voxelCount }
            let step = AdaptiveGrid.renderStep(voxelCount: estimated, resolutionMetres: displayResolutionMeters)
            lodStep = step
            let sampler = TiledIcSampler(volumes: volumes, overlapMeters: 8)
            let recommendedLocal = recommendation.map { CoordinateTransformer.localMeters($0,origin:terrain.origin) }
            let anchorEast = volumes.first?.westMeters ?? 0
            let anchorNorth = volumes.first?.southMeters ?? 0
            var rendered = Set<[Int]>()
            for volume in volumes {
                let chunk = Entity()
                subsoil.addChild(chunk)
                var meshCache = [String:MeshResource]()
                let midEast = volume.westMeters + Double(volume.grid.nx) * volume.grid.spacingMeters / 2
                for z in stride(from: 0, to: volume.grid.nz, by: step) {
                    for y in stride(from: 0, to: volume.grid.ny, by: step) {
                        for x in stride(from: 0, to: volume.grid.nx, by: step) {
                          for block in AdaptiveGrid.renderBlocks(volume:volume,x:x,y:y,z:z,step:step) {
                            let bx = block.x, by = block.y
                            guard let sliced = slice.clip(block) else { continue }
                            let east = sliced.centerEast, north = sliced.centerNorth
                            if cutaway && east > midEast { continue }
                            let edgeCell = step > 1 && (block.countX == 1 || block.countY == 1)
                            let sliceFace = sliced.widthMeters < block.widthMeters - 1e-6 ||
                                sliced.northMeters < block.northMeters - 1e-6 ||
                                (slice.eastLimit.map { abs(block.centerEast + block.widthMeters/2 - $0) < volume.grid.spacingMeters*Double(step) } ?? false) ||
                                (slice.northLimit.map { abs(block.centerNorth + block.northMeters/2 - $0) < volume.grid.northSpacingMeters*Double(step) } ?? false)
                            let exposed = sliceFace || edgeCell || z == 0 || z + step >= volume.grid.nz ||
                                bx == 0 || bx + block.countX >= volume.grid.nx ||
                                by == 0 || by + block.countY >= volume.grid.ny ||
                                !volume.isValid(x: max(bx - step, 0), y: by) ||
                                !volume.isValid(x: min(bx + step, volume.grid.nx - 1), y: by) ||
                                !volume.isValid(x: bx, y: max(by - step, 0)) ||
                                !volume.isValid(x: bx, y: min(by + step, volume.grid.ny - 1)) ||
                                (cutaway && bx + block.countX >= volume.grid.nx / 2)
                            guard exposed else { continue }
                            let key = [Int(round((east - anchorEast)*1000)), Int(round((north - anchorNorth)*1000)), z]
                            guard rendered.insert(key).inserted else { continue }
                            let sampleX = min(bx+block.countX-1,max(bx,Int(floor((east-volume.westMeters)/volume.grid.spacingMeters))))
                            let sampleY = min(by+block.countY-1,max(by,Int(floor((north-volume.southMeters)/volume.grid.northSpacingMeters))))
                            let sampleZ = z+(block.countZ-1)/2
                            guard let surface = terrain.surfacePosition(x: Float(east), z: Float(-north)),
                                  let ic = sampler.sample(east: east, north: north, depthIndex: sampleZ) else { continue }
                            let index = volume.index(x:sampleX,y:sampleY,z:sampleZ)
                            let sbt = zone(ic)
                            let observed = volume.observed[index]
                            let risk = estimatedRisk?.grid.nx == volume.grid.nx &&
                                estimatedRisk?.grid.ny == volume.grid.ny && estimatedRisk?.grid.nz == volume.grid.nz
                                ? estimatedRisk?.value(x:sampleX,y:sampleY,z:sampleZ) : nil
                            // Fixed visual scale across CPT counts; measured CPT voxels remain solid.
                            let alphaValue = UncertaintyV2Visual.opacity(estimatedErrorIc:risk,observed:observed,mode:riskMode)
                            let alpha = CGFloat(alphaValue)
                            let baseColor = riskMode == .risk && !observed
                                ? UncertaintyV2Visual.riskFraction(risk).map(riskColor) ?? (palette[sbt] ?? palette[0]!)
                                : (palette[sbt] ?? palette[0]!)
                            let color = baseColor.withAlphaComponent(alpha)
                            let meshKey = String(format:"%.4f:%.4f:%d",sliced.widthMeters,sliced.northMeters,block.countZ)
                            let cellMesh: MeshResource
                            if let cached = meshCache[meshKey] { cellMesh = cached }
                            else {
                                // A coarse block is centered over the cells it represents;
                                // its last block uses the actual remaining width.
                                cellMesh = .generateBox(size:[Float(sliced.widthMeters)*1.002,
                                    Float(block.depthMeters)*depthScale*1.002,
                                    Float(sliced.northMeters)*1.002])
                                meshCache[meshKey] = cellMesh
                            }
                            let entity = ModelEntity(mesh: cellMesh, materials: [
                                SimpleMaterial(color: color, roughness: 0.85, isMetallic: observed)
                            ])
                            entity.position = surface - SIMD3<Float>(0, Float(block.centerDepth) * depthScale, 0)
                            entity.name = observed ? "CPT observed SBT \(sbt)" : "Predicted SBT \(sbt)"
                            chunk.addChild(entity)
                            inspectableBoxes.append(.init(center:entity.position,
                                size:[Float(sliced.widthMeters)*1.002,
                                      Float(block.depthMeters)*depthScale*1.002,
                                      Float(sliced.northMeters)*1.002]))
                            if z == 0, let local = recommendedLocal,
                               abs(local.x-east) <= sliced.widthMeters/2,
                               abs(local.y-north) <= sliced.northMeters/2 { supportingVoxel = entity }
                            renderedVoxelCount += 1
                            opacityMinimum = min(opacityMinimum,alphaValue)
                            opacityMaximum = max(opacityMaximum,alphaValue)
                            opacityTotal += alphaValue
                          }
                        }
                    }
                }
                if estimatedRisk != nil {
                    // Measured CPT columns stay visible at their native cell size even
                    // when prediction voxels use a coarser rendering LOD.
                    for z in 0..<volume.grid.nz { for y in 0..<volume.grid.ny { for x in 0..<volume.grid.nx {
                        let index = volume.index(x:x,y:y,z:z)
                        guard volume.observed[index], volume.isValid(x:x,y:y) else { continue }
                        let block = AdaptiveGrid.renderBlock(volume:volume,x:x,y:y,z:z,step:1)
                        guard let sliced = slice.clip(block) else { continue }
                        let east = sliced.centerEast, north = sliced.centerNorth
                        guard let surface = terrain.surfacePosition(x:Float(east),z:Float(-north)) else { continue }
                        let color = palette[zone(volume.values[index])] ?? palette[0]!
                        let measuredMesh = MeshResource.generateBox(size: [Float(sliced.widthMeters) * 1.04,
                            Float(block.depthMeters) * depthScale * 1.04,
                            Float(sliced.northMeters) * 1.04])
                        let entity = ModelEntity(mesh:measuredMesh,materials:[
                            SimpleMaterial(color:color.withAlphaComponent(1),roughness:0.7,isMetallic:true)
                        ])
                        entity.position = surface - SIMD3<Float>(0,Float(block.centerDepth)*depthScale,0)
                        entity.name = "CPT observed SBT \(zone(volume.values[index]))"
                        chunk.addChild(entity)
                        inspectableBoxes.append(.init(center:entity.position,
                            size:[Float(sliced.widthMeters)*1.04,
                                  Float(block.depthMeters)*depthScale*1.04,
                                  Float(sliced.northMeters)*1.04]))
                        renderedVoxelCount += 1
                        opacityMinimum = min(opacityMinimum,1)
                        opacityMaximum = max(opacityMaximum,1)
                        opacityTotal += 1
                    } } }
                }
            }
        }
        var resetID = 0
        var yaw: Float = 0.45, pitch: Float = 0.45, distance: Float = 4
        var target = SIMD3<Float>.zero
        func clearSelection() {
            inspectedHitLocal = nil
            inspectionSelection.children.removeAll()
        }
        private func drawSelection(at hit: SIMD3<Float>,terrain: TerrainMesh) {
            inspectionSelection.children.removeAll()
            let east = Double(hit.x), north = Double(-hit.z)
            guard let profile = VerticalProfile.inspect(east:east,north:north,
                                                        volumes:currentVolumes,risk:nil) else { return }
            let surfaceY = terrain.surfacePosition(x:hit.x,z:hit.z)?.y ?? hit.y
            let cellSize = currentVolumes.map { min($0.grid.spacingMeters,$0.grid.northSpacingMeters) }.min() ?? 1
            let radius = Float(max(0.08,cellSize*0.18))
            let pin = ModelEntity(mesh:.generateSphere(radius:radius),
                                  materials:[UnlitMaterial(color:.systemYellow)])
            pin.position = hit + SIMD3<Float>(0,radius*0.5,0)
            pin.name = "Selected inspection point"
            inspectionSelection.addChild(pin)
            let height = Float(profile.depthAvailable)*depthScale
            if height > 0 {
                let line = ModelEntity(mesh:.generateBox(size:[radius*0.22,height,radius*0.22]),
                                       materials:[UnlitMaterial(color:.systemYellow.withAlphaComponent(0.75))])
                line.position = SIMD3<Float>(hit.x,surfaceY-height/2,hit.z)
                line.name = "Inspected soil column"
                inspectionSelection.addChild(line)
            }
        }
        @objc func inspect(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? ARView,
                  let terrain, !currentVolumes.isEmpty,
                  let ray = view.ray(through:gesture.location(in:view)) else { return }
            let localOrigin = root.convert(position:ray.origin,from:nil)
            let localEnd = root.convert(position:ray.origin + ray.direction,from:nil)
            let localDirection = simd_normalize(localEnd-localOrigin)
            var hits = [SIMD3<Float>]()
            if terrainModel?.isEnabled == true,
               let terrainHit = TerrainRaycast.firstHit(origin:localOrigin,direction:localDirection,
                                                        positions:terrain.positions,indices:terrain.indices) {
                hits.append(terrainHit)
            }
            if let boxHit = TerrainRaycast.firstBoxHit(origin:localOrigin,direction:localDirection,
                                                       boxes:inspectableBoxes) { hits.append(boxHit) }
            for hit in hits.sorted(by:{ simd_distance(localOrigin,$0) < simd_distance(localOrigin,$1) }) {
                let selected = Point2(x:Double(hit.x),y:Double(-hit.z))
                guard VerticalProfile.inspect(east:selected.x,north:selected.y,
                                              volumes:currentVolumes,risk:nil) != nil else { continue }
                inspectedHitLocal = hit
                drawSelection(at:hit,terrain:terrain)
                onSelect?(selected)
                return
            }
        }
        func reset() { yaw = 0.45; pitch = 0.45; distance = 4; target = .zero; update() }
        func focus(on volumes: [ReconstructionVolume], terrain: TerrainMesh) {
            guard let first = volumes.first else { return }
            let west = volumes.map(\.westMeters).min() ?? first.westMeters
            let east = volumes.map { $0.westMeters + Double($0.grid.nx) * $0.grid.spacingMeters }.max() ?? west
            let south = volumes.map(\.southMeters).min() ?? first.southMeters
            let north = volumes.map { $0.southMeters + Double($0.grid.ny) * $0.grid.northSpacingMeters }.max() ?? south
            let centerEast = (west + east) / 2, centerNorth = (south + north) / 2
            let surfaceY = terrain.surfacePosition(x: Float(centerEast), z: Float(-centerNorth))?.y ?? 0
            let modelDepth = Float(volumes.map { Double($0.grid.nz) * $0.grid.depthSpacingMeters }.max() ?? 0) * depthScale
            let localCenter = SIMD3<Float>(Float(centerEast), surfaceY - modelDepth / 2, Float(-centerNorth))
            target = localCenter * root.scale.x + root.position
            let horizontalSpan = Float(max(east - west, north - south)) * root.scale.x
            let verticalSpan = modelDepth * root.scale.x
            distance = min(20, max(0.45, max(horizontalSpan, verticalSpan) * 2.2))
            update()
        }
        func update() {
            camera.camera.near = 0.001; camera.camera.far = 100
            let offset = SIMD3<Float>(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))*distance
            camera.look(at:target,from:target+offset,relativeTo:nil)
            faceRulerLabelsToCamera()
        }
        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in:gesture.view); gesture.setTranslation(.zero,in:gesture.view)
            yaw -= Float(delta.x)*0.006
            pitch = min(1.5,max(0.04,pitch+Float(delta.y)*0.006)); update()
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in:gesture.view); gesture.setTranslation(.zero,in:gesture.view)
            let right = SIMD3<Float>(cos(yaw),0,-sin(yaw)), forward = SIMD3<Float>(sin(yaw),0,cos(yaw))
            target += (-right*Float(delta.x)+forward*Float(delta.y))*(distance*0.0015)
            target = simd_clamp(target,SIMD3<Float>(repeating:-5),SIMD3<Float>(repeating:5)); update()
        }
        @objc func zoom(_ gesture: UIPinchGestureRecognizer) {
            distance = min(20,max(0.3,distance/Float(gesture.scale))); gesture.scale = 1; update()
        }
    }
}
