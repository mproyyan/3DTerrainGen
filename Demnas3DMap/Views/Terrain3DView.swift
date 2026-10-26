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
    @State private var depthScale: Float = 1
    @State private var showInvestigation = false
    @State private var buildingLayers = false
    @State private var layerFailure: String?

    var body: some View {
        ZStack {
            Color(red:0.06,green:0.08,blue:0.1).ignoresSafeArea()
            if let resource {
                GeometryReader { geometry in
                    TerrainRenderer(resource:resource, terrain:terrain, points:session.points, recommendation:session.recommendation, recommendationSource:session.recommendationSource, columns:columns, columnVersion:columnVersion, volume:session.reconstruction, volumes:session.reconstructionTiles, displayResolutionMeters:session.spatialResolutionMeters, volumeVersion:session.reconstructionVersion, displayMode:displayMode, depthScale:depthScale, resetID:resetID)
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
                                Text("Warna lapisan: klasifikasi SBT dari prediksi Ic Model C; Potongan menampilkan bagian dalam.")
                                Text("Hanya window dengan CPT yang direkonstruksi. Permukaan transparan menunjukkan konteks DEMNAS; area lain belum diketahui.")
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }.font(.caption2)
                }
                if buildingLayers && session.reconstruction == nil { ProgressView("Memperbarui lapisan…").font(.caption) }
                switch session.reconstructionStatus {
                case .loading, .reconstructing:
                    ProgressView("Model C: merekonstruksi Ic…").font(.caption)
                case .ready:
                    Text(session.reconstructionSummary ?? "Model C: volume Ic siap").font(.caption2).foregroundStyle(.green)
                case .error:
                    Text("Model C belum tersedia: \(session.reconstructionError ?? "input tidak memenuhi kontrak model")")
                        .font(.caption2).foregroundStyle(.orange)
                case .unavailable:
                    if session.points.isEmpty == false && session.status.completed == 0 {
                        Text("Model C menunggu profil CPT yang sudah disimpan.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let layerFailure { Text(layerFailure).font(.caption).foregroundStyle(.red) }
                if session.recommendation != nil {
                    Text(session.recommendationSource == .dqnWindowedExperimental
                         ? "Titik merah muda: DQN Windowed Experimental, dihitung pada satu window lokal; belum divalidasi di lapangan."
                         : session.recommendationSource == .dqn
                         ? "Titik merah muda: rekomendasi DQN."
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
                ForEach(terrain.metadata.provenance,id:\.self) { Text($0) }
            }.navigationTitle("Terrain metadata")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { showDetails = false } } }
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
    let displayResolutionMeters: Double
    let volumeVersion: Int
    let displayMode: Int
    let depthScale: Float
    let resetID: Int
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
        context.coordinator.reset()
        return view
    }
    func updateUIView(_ uiView: ARView,context:Context) {
        let coordinator = context.coordinator
        let shouldFocusModel = displayMode != 0 && !volumes.isEmpty &&
            (coordinator.displayMode != displayMode || coordinator.volumeVersion != volumeVersion)
        if coordinator.columnVersion != columnVersion || coordinator.volumeVersion != volumeVersion || coordinator.depthScale != depthScale || coordinator.displayMode != displayMode || coordinator.pointIDs != points.map(\.id) || coordinator.recommendation != recommendation || coordinator.recommendationSource != recommendationSource {
            coordinator.columnVersion = columnVersion; coordinator.volumeVersion = volumeVersion; coordinator.depthScale = depthScale; coordinator.displayMode = displayMode
            coordinator.pointIDs = points.map(\.id); coordinator.recommendation = recommendation; coordinator.recommendationSource = recommendationSource
            coordinator.rebuild(terrain: terrain, columns: columns, volume: volume, volumes: volumes, displayResolutionMeters: displayResolutionMeters, points: points, recommendation: recommendation, recommendationSource: recommendationSource)
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
        var columnVersion = -1
        var volumeVersion = -1
        var depthScale: Float = 1
        var displayMode = 1
        var pointIDs: [UUID] = []
        var recommendation: GeoPoint?
        var recommendationSource = RecommendationSource.none
        func rebuild(terrain: TerrainMesh, columns: [SubsurfaceColumn], volume: ReconstructionVolume?, volumes: [ReconstructionVolume], displayResolutionMeters: Double, points: [CPTPoint], recommendation: GeoPoint?, recommendationSource: RecommendationSource) {
            subsoil.children.removeAll(); markers.children.removeAll()
            terrainModel?.isEnabled = displayMode != 2 || (columns.isEmpty && volume == nil)
            var terrainMaterial = SimpleMaterial(
                color: UIColor(red: 0.42, green: 0.67, blue: 0.48,
                               alpha: displayMode == 0 ? 1 : 0.16),
                roughness: 0.85, isMetallic: false
            )
            if #available(iOS 18.0, *) { terrainMaterial.faceCulling = .none }
            terrainModel?.model?.materials = [terrainMaterial]
            let midX = ((terrain.positions.map(\.x).min() ?? 0) + (terrain.positions.map(\.x).max() ?? 0))/2
            if displayMode != 0, let volume {
                renderModelC(volumes.isEmpty ? [volume] : volumes, terrain: terrain, displayResolutionMeters: displayResolutionMeters)
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
            func marker(_ geo: GeoPoint, _ color: UIColor, _ name: String) {
                guard let surface = terrain.surfacePosition(at: geo) else { return }
                let sphere = ModelEntity(mesh: .generateSphere(radius: markerRadius), materials: [SimpleMaterial(color: color, isMetallic: false)])
                sphere.position = surface + SIMD3<Float>(0, markerRadius*1.5, 0)
                sphere.name = name; markers.addChild(sphere)
            }
            for point in points { marker(point.coordinate, point.isComplete ? .systemGreen : .systemOrange, point.name) }
            if let recommendation { marker(recommendation, .systemPink, recommendationSource == .dqn ? "DQN" : recommendationSource == .dqnWindowedExperimental ? "DQN Windowed Experimental" : "Heuristic geometris") }
            let maxDepth = Float(volume == nil ? (columns.map(\.bottom).max() ?? 0) : Double(volume!.grid.nz) * volume!.grid.spacingMeters)*depthScale
            let low = Float(terrain.minimum-terrain.elevationOrigin)-maxDepth
            let high = Float(terrain.maximum-terrain.elevationOrigin)+Float(markerRadius*3)
            let span = max(maxX-minX, maxZ-minZ, high-low, 1)
            root.scale = .init(repeating: 2/span)
            root.position = -SIMD3<Float>((minX+maxX)/2, (low+high)/2, (minZ+maxZ)/2)*(2/span)
        }
        /// Six Ic-only SBT zones from synthetic3d/v2/core.py::classify_sbt.
        /// Unknown extremes remain gray. Observed synthetic CPTs use lower opacity.
        /// Each model window is a RealityKit chunk. LOD caps exposed voxel entities
        /// while the physical sampler blends overlap and preserves measured CPT voxels.
        private func renderModelC(_ volumes: [ReconstructionVolume], terrain: TerrainMesh,
                                  displayResolutionMeters: Double) {
            func zone(_ ic: Float) -> Int {
                if ic < 1 || ic > 4 { return 0 }
                if ic < 1.31 { return 7 }
                if ic < 2.05 { return 6 }
                if ic < 2.6 { return 5 }
                if ic < 2.95 { return 4 }
                if ic < 3.6 { return 3 }
                return 2
            }
            let palette: [Int: UIColor] = [
                0: UIColor(white: 0.65, alpha: 1),
                2: UIColor(red: 0.35, green: 0.28, blue: 0.68, alpha: 1),
                3: UIColor(red: 0.42, green: 0.39, blue: 0.76, alpha: 1),
                4: UIColor(red: 0.57, green: 0.54, blue: 0.83, alpha: 1),
                5: UIColor(red: 0.95, green: 0.55, blue: 0.22, alpha: 1),
                6: UIColor(red: 0.96, green: 0.75, blue: 0.27, alpha: 1),
                7: UIColor(red: 0.98, green: 0.87, blue: 0.43, alpha: 1)
            ]
            let estimated = volumes.reduce(0) { $0 + $1.grid.voxelCount }
            let step = AdaptiveGrid.renderStep(voxelCount: estimated, resolutionMetres: displayResolutionMeters)
            let sampler = TiledIcSampler(volumes: volumes, overlapMeters: 8)
            let anchorEast = volumes.first?.westMeters ?? 0
            let anchorNorth = volumes.first?.southMeters ?? 0
            var rendered = Set<[Int]>()
            for volume in volumes {
                let chunk = Entity()
                subsoil.addChild(chunk)
                let spacing = Float(volume.grid.spacingMeters)
                // Tiny overlap removes the gaps and visible internal faces of the old voxel boxes.
                let horizontalSize = Float(step) * spacing * 1.002
                let verticalSize = Float(step) * Float(volume.grid.depthSpacingMeters) * depthScale * 1.002
                let cellMesh = MeshResource.generateBox(size: [horizontalSize, verticalSize, horizontalSize])
                let midEast = volume.westMeters + Double(volume.grid.nx) * volume.grid.spacingMeters / 2
                for z in stride(from: 0, to: volume.grid.nz, by: step) {
                    for y in stride(from: 0, to: volume.grid.ny, by: step) {
                        for x in stride(from: 0, to: volume.grid.nx, by: step) where volume.isValid(x: x, y: y) {
                            let east = volume.east(x: x), north = volume.north(y: y)
                            if displayMode == 2 && east > midEast { continue }
                            let exposed = z == 0 || z + step >= volume.grid.nz ||
                                x == 0 || x + step >= volume.grid.nx ||
                                y == 0 || y + step >= volume.grid.ny ||
                                !volume.isValid(x: max(x - step, 0), y: y) ||
                                !volume.isValid(x: min(x + step, volume.grid.nx - 1), y: y) ||
                                !volume.isValid(x: x, y: max(y - step, 0)) ||
                                !volume.isValid(x: x, y: min(y + step, volume.grid.ny - 1)) ||
                                (displayMode == 2 && x + step >= volume.grid.nx / 2)
                            guard exposed else { continue }
                            let key = [Int(round(east - anchorEast)), Int(round(north - anchorNorth)), z]
                            guard rendered.insert(key).inserted else { continue }
                            guard let surface = terrain.surfacePosition(x: Float(east), z: Float(-north)),
                                  let ic = sampler.sample(east: east, north: north, depthIndex: z) else { continue }
                            let index = volume.index(x: x, y: y, z: z)
                            let sbt = zone(ic)
                            let origin = volume.observationOrigins[index]
                            let color = palette[sbt] ?? palette[0]!
                            let entity = ModelEntity(mesh: cellMesh, materials: [
                                SimpleMaterial(color: color, roughness: 0.85, isMetallic: origin == .entered)
                            ])
                            entity.position = surface - SIMD3<Float>(0, Float(volume.depth(z: z)) * depthScale, 0)
                            entity.name = origin == nil ? "Model C tiled predicted SBT \(sbt)" : "CPT observed SBT \(sbt)"
                            chunk.addChild(entity)
                        }
                    }
                }
            }
        }
        var resetID = 0
        var yaw: Float = 0.45, pitch: Float = 0.45, distance: Float = 4
        var target = SIMD3<Float>.zero
        func reset() { yaw = 0.45; pitch = 0.45; distance = 4; target = .zero; update() }
        func focus(on volumes: [ReconstructionVolume], terrain: TerrainMesh) {
            guard let first = volumes.first else { return }
            let west = volumes.map(\.westMeters).min() ?? first.westMeters
            let east = volumes.map { $0.westMeters + Double($0.grid.nx) * $0.grid.spacingMeters }.max() ?? west
            let south = volumes.map(\.southMeters).min() ?? first.southMeters
            let north = volumes.map { $0.southMeters + Double($0.grid.ny) * $0.grid.spacingMeters }.max() ?? south
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
