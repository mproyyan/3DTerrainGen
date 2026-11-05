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
    @State private var loader: AnyCancellable?
    @State private var columns: [SubsurfaceColumn] = []
    @State private var columnVersion = 0
    @State private var displayMode = 0
    @State private var riskMode = RiskVisualizationMode.ic
    @State private var slice = SubsurfaceSlice()
    @State private var showSliceControls = false
    @State private var selectedProfile: VerticalProfile?
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
            VStack(spacing:6) {
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
                    DisclosureGroup("Arti warna dan cakupan", isExpanded: $showLegend) {
                        VStack(alignment: .leading, spacing: 4) {
                            if session.reconstruction == nil {
                                Text("Kolom mengikuti profil CPT terdekat; area abu-abu belum diketahui.")
                            } else {
                                Text(session.dqnRecommendationSource == .dqnV45 ? "Warna lapisan: klasifikasi SBT dari Ic SchemaGAN V4.2; Potongan menampilkan bagian dalam." : "Warna lapisan: klasifikasi SBT dari Ic Model C; Potongan menampilkan bagian dalam.")
                                Text("Hanya window dengan CPT yang direkonstruksi. Permukaan transparan menunjukkan konteks DEMNAS; area lain belum diketahui.")
                                if session.estimatedRisk != nil {
                                    Text("Estimated Reconstruction Risk: biru 0, kuning 0,25, merah ≥0,50 Ic. Mode Gabungan memakai warna SBT asli dan transparansi risiko pada skala yang sama. Lapisan mempertahankan seluruh cakupan area; gunakan Potongan untuk penampang. CPT terukur tetap solid. Bukan calibrated confidence.")
                                }
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }.font(.caption2)
                }
                if buildingLayers && session.reconstruction == nil { ProgressView("Memperbarui lapisan…").font(.caption) }
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
                if let detail = session.v42Detail { Text(detail).font(.caption2).foregroundStyle(session.dqnRecommendationSource == .dqnV45 ? .green : .orange) }
                if let q = session.v42QValue {
                    Text(String(format: "Q-value DQN V4.5: %.6f (bukan confidence)", Double(q)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if session.recommendation != nil {
                    Text(session.recommendationSource == .dqnV45
                         ? "Titik merah muda: DQN V4.5, dihitung dari rekonstruksi SchemaGAN V4.2 pada satu grid."
                         : session.recommendationSource == .dqnWindowedExperimental
                         ? "Titik merah muda: DQN Windowed Experimental, dihitung pada satu window lokal; belum divalidasi di lapangan."
                         : session.recommendationSource == .dqn
                         ? "Titik merah muda: rekomendasi DQN."
                         : session.recommendationSource == .explorationHeuristic
                         ? "Titik merah muda: eksplorasi cakupan geometris (Heuristic), bukan DQN."
                         : "Titik merah muda: rekomendasi Heuristic.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Label("\(terrain.minimum, specifier:"%.1f")–\(terrain.maximum, specifier:"%.1f") m",systemImage:"mountain.2")
                    Spacer()
                    Text("\(terrain.areaSquareMeters/1_000_000, specifier:"%.3f") km²")
                }.font(.subheadline.monospacedDigit())
                Text("Geser: putar · Cubit: zoom · Dua jari: geser").font(.caption2).foregroundStyle(.secondary)
            }.padding().background(.regularMaterial)
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
        .onChange(of:session.reconstructionVersion) { _, _ in slice = .init(); selectedProfile = nil }
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
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text(String(format:"East %.2f m · North %.2f m · grid (%d,%d)",
                                profile.east,profile.north,profile.x,profile.y))
                        .font(.caption.monospacedDigit())
                    Text(String(format:"Kedalaman rekonstruksi %.2f m · terukur terdalam %@",
                                profile.depthAvailable,
                                profile.deepestMeasured.map { String(format:"%.2f m",$0) } ?? "tidak ada"))
                        .font(.caption)
                    if profile.points.count > 1 {
                        Text("Ic → · Depth ↓").font(.caption.bold())
                        GeometryReader { geometry in
                            let lower = Double(profile.points.map(\.ic).min() ?? 0)
                            let upper = Double(profile.points.map(\.ic).max() ?? 1)
                            let span = max(upper-lower,0.1)
                            Path { path in
                                for (index,row) in profile.points.enumerated() {
                                    let x = 12+CGFloat((Double(row.ic)-lower)/span)*(geometry.size.width-24)
                                    let y = CGFloat(row.depthCenter/profile.depthAvailable)*geometry.size.height
                                    if index == 0 { path.move(to:CGPoint(x:x,y:y)) }
                                    else { path.addLine(to:CGPoint(x:x,y:y)) }
                                }
                            }.stroke(.teal,lineWidth:2)
                        }.frame(height:140).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    }
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
                     "Uncertainty V2: \(session.estimatedRisk != nil ? "ready" : session.estimatedRiskError ?? "menunggu")",
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
        if let diagnostics = session.v45Diagnostics, let volume = session.reconstruction {
            let scores = diagnostics.scores
            let expectedEast = volume.east(x:scores.best.x)
            let expectedNorth = volume.north(y:scores.best.y)
            lines.append(String(format:"DQN grid XY (%d,%d) → east %.4f m, north %.4f m → RealityKit local X %.4f, Z %.4f",
                                scores.best.x,scores.best.y,expectedEast,expectedNorth,expectedEast,-expectedNorth))
            if let marker = session.rendererDiagnostics?.markerLocal {
                lines.append(String(format:"Selisih grid–marker lokal horizontal: %.5f m",
                                    hypot(Double(marker.x)-expectedEast,Double(marker.z)+expectedNorth)))
            }
            lines.append(String(format:"DQN V4.5: %d kandidat legal · Q min %.6f · mean %.6f · max %.6f",
                                scores.legalCount,scores.minimumQ,scores.meanQ,scores.maximumQ))
            lines.append(String(format:"DQN timing: SchemaGAN %.3f s · fitur %.3f s · Q scoring %.3f s",
                                diagnostics.schemaSeconds,diagnostics.featureSeconds,diagnostics.scoringSeconds))
            if let rec = session.dqnRecommendation {
                let nearest = session.points.filter(\.isComplete).map {
                    CoordinateTransformer.localMeters($0.coordinate,origin:rec).length
                }.min() ?? .nan
                lines.append(String(format:"Rekomendasi: lat %.7f · lon %.7f · CPT terdekat %.2f m",
                                    rec.latitude,rec.longitude,nearest))
            }
            lines.append("10 kandidat Q terbaik:")
            for (rank,candidate) in scores.top.enumerated() {
                let geo = CoordinateTransformer.geographic(east:volume.east(x:candidate.x),
                                                           north:volume.north(y:candidate.y),origin:volume.terrainOrigin)
                lines.append(String(format:"%d. (%d,%d) lat %.7f lon %.7f Q %.6f",
                                    rank+1,candidate.x,candidate.y,geo.latitude,geo.longitude,candidate.qValue))
            }
        } else {
            lines.append("DQN: \(session.v42Detail ?? session.dqnError ?? "belum tersedia")")
        }
        lines.append("Risk adalah estimated error, bukan calibrated confidence. Q bukan confidence.")
        return lines.joined(separator:"\n")
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
            if let recommendation { recommendationMarker = marker(recommendation, .systemPink, recommendationSource == .dqnV45 ? "DQN V4.5" : recommendationSource == .dqn ? "DQN V3" : recommendationSource == .dqnWindowedExperimental ? "DQN Windowed Experimental" : recommendationSource == .explorationHeuristic ? "Eksplorasi Heuristic" : "Heuristic geometris") }
            let maxDepth = Float(volume == nil ? (columns.map(\.bottom).max() ?? 0) : Double(volume!.grid.nz) * volume!.grid.depthSpacingMeters)*depthScale
            let low = Float(terrain.minimum-terrain.elevationOrigin)-maxDepth
            let high = Float(terrain.maximum-terrain.elevationOrigin)+Float(markerRadius*3)
            let span = max(maxX-minX, maxZ-minZ, high-low, 1)
            root.scale = .init(repeating: 2/span)
            root.position = -SIMD3<Float>((minX+maxX)/2, (low+high)/2, (minZ+maxZ)/2)*(2/span)
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
        /// Six Ic-only SBT zones from synthetic3d/v2/core.py::classify_sbt.
        /// Unknown extremes remain gray. Observed synthetic CPTs use lower opacity.
        /// Each model window is a RealityKit chunk. LOD caps exposed voxel entities
        /// while the physical sampler blends overlap and preserves measured CPT voxels.
        private func renderModelC(_ volumes: [ReconstructionVolume], estimatedRisk: UncertaintyV2Map?, terrain: TerrainMesh,
                                  displayResolutionMeters: Double, cutaway: Bool, recommendation: GeoPoint?) {
            func zone(_ ic: Float) -> Int { IcSBTClassifier.zone(ic) }
            let palette: [Int: UIColor] = [
                0: UIColor(white: 0.65, alpha: 1),
                2: UIColor(red: 0.35, green: 0.28, blue: 0.68, alpha: 1),
                3: UIColor(red: 0.42, green: 0.39, blue: 0.76, alpha: 1),
                4: UIColor(red: 0.57, green: 0.54, blue: 0.83, alpha: 1),
                5: UIColor(red: 0.95, green: 0.55, blue: 0.22, alpha: 1),
                6: UIColor(red: 0.96, green: 0.75, blue: 0.27, alpha: 1),
                7: UIColor(red: 0.98, green: 0.87, blue: 0.43, alpha: 1)
            ]
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
        @objc func inspect(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? ARView,
                  let model = terrainModel, let terrain,
                  let ray = view.ray(through:gesture.location(in:view)) else { return }
            let localOrigin = model.convert(position:ray.origin,from:nil)
            let localEnd = model.convert(position:ray.origin + ray.direction,from:nil)
            let localDirection = simd_normalize(localEnd-localOrigin)
            guard let hit = TerrainRaycast.firstHit(origin:localOrigin,direction:localDirection,
                                                    positions:terrain.positions,indices:terrain.indices) else { return }
            onSelect?(Point2(x:Double(hit.x),y:Double(-hit.z)))
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
