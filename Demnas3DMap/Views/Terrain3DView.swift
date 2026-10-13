import SwiftUI
import RealityKit
import Combine

struct Terrain3DView: View {
    let terrain: TerrainMesh
    @State private var resource: MeshResource?
    @State private var failure: String?
    @State private var resetID = 0
    @State private var showDetails = false
    @State private var loader: AnyCancellable?

    var body: some View {
        ZStack {
            Color(red:0.06,green:0.08,blue:0.1).ignoresSafeArea()
            if let resource {
                TerrainRenderer(resource:resource,terrain:terrain,resetID:resetID)
                    .ignoresSafeArea(edges:.bottom)
                    .accessibilityLabel("3D terrain. Drag to orbit, pinch to zoom, and drag with two fingers to pan.")
            } else if let failure {
                ContentUnavailableView("Unable to display terrain",systemImage:"exclamationmark.triangle",description:Text(failure))
            } else { ProgressView("Preparing terrain surface…").tint(.white).foregroundStyle(.white) }
        }
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:6) {
                HStack {
                    Label("\(terrain.minimum, specifier:"%.1f")–\(terrain.maximum, specifier:"%.1f") m",systemImage:"mountain.2")
                    Spacer()
                    Text("\(terrain.areaSquareMeters/1_000_000, specifier:"%.3f") km²")
                }.font(.subheadline.monospacedDigit())
                Text("Drag: orbit · Pinch: zoom · Two-finger drag: pan").font(.caption)
                Text("Vertical scale 1× · North is −Z").font(.caption2).foregroundStyle(.secondary)
            }.padding().background(.regularMaterial)
        }
        .navigationTitle("3D terrain").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement:.topBarTrailing) {
                Button("Reset camera",systemImage:"arrow.counterclockwise") { resetID += 1 }
                Button("Terrain details",systemImage:"info.circle") { showDetails = true }
            }
        }
        .sheet(isPresented:$showDetails) { details }
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
        model.scale = .init(repeating:2/span)
        model.position = -bounds.center * (2/span)
        anchor.addChild(model)
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
        if context.coordinator.resetID != resetID { context.coordinator.resetID = resetID; context.coordinator.reset() }
    }
    @MainActor final class Coordinator: NSObject {
        let camera = PerspectiveCamera()
        var resetID = 0
        var yaw: Float = 0, pitch: Float = 0.8, distance: Float = 4
        var target = SIMD3<Float>.zero
        func reset() { yaw = 0; pitch = 0.8; distance = 4; target = .zero; update() }
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
