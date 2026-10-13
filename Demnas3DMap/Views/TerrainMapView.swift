import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct TerrainMapView: View {
    @Bindable var session: TerrainSession
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: -7.54, longitude: 110.44), span: .init(latitudeDelta: 0.12, longitudeDelta: 0.12)))
    @State private var showImporter = false
    @State private var showImportOptions = false
    @State private var showViewer = false
    @State private var chooseFilesAfterDismiss = false

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if session.showFootprint, let metadata = session.imported?.metadata {
                        MapPolygon(coordinates: metadata.footprint.map(\.coordinate))
                            .foregroundStyle(.orange.opacity(0.12))
                            .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6,4]))
                    }
                    if session.selection.isFinished {
                        MapPolygon(coordinates: session.selection.coordinates)
                            .foregroundStyle(.cyan.opacity(0.22)).stroke(.cyan,lineWidth:3)
                    } else if session.selection.coordinates.count > 1 {
                        MapPolyline(coordinates: session.selection.coordinates).stroke(.cyan,lineWidth:3)
                    }
                    ForEach(Array(session.selection.coordinates.enumerated()), id: \.offset) { index, coordinate in
                        Annotation("Vertex \(index+1)",coordinate:coordinate) {
                            Text("\(index+1)").font(.caption2.bold()).padding(6)
                                .background(.cyan,in:.circle).foregroundStyle(.black)
                                .accessibilityLabel("Polygon vertex \(index+1)")
                        }
                    }
                }
                .mapStyle(.hybrid(elevation: .flat))
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    guard session.drawing, session.activity == nil, !session.selection.isFinished,
                          let coordinate = proxy.convert(value.location,from:.local) else { return }
                    do { try session.selection.add(coordinate) }
                    catch { session.errorMessage = error.localizedDescription }
                })
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("DEMNAS Terrain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    if let metadata = session.imported?.metadata {
                        Button("Frame DEM",systemImage:"viewfinder") { frame(metadata.footprint) }
                    }
                }
            }
            .sheet(isPresented:$showImportOptions,onDismiss: {
                if chooseFilesAfterDismiss { chooseFilesAfterDismiss = false; showImporter = true }
            }) { importOptions }
            .fileImporter(isPresented:$showImporter, allowedContentTypes:[.data], allowsMultipleSelection:true) { result in
                switch result {
                case .success(let urls): session.load(urls)
                case .failure(let error): session.errorMessage = error.localizedDescription
                }
            }
            .alert("Unable to continue",isPresented:Binding(get:{session.errorMessage != nil},set:{ if !$0 { session.errorMessage = nil } })) {
                Button("OK",role:.cancel) { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .navigationDestination(isPresented:$showViewer) {
                if let mesh = session.mesh { Terrain3DView(terrain:mesh) }
            }
            .onChange(of:session.mesh == nil) { _, missing in if !missing { showViewer = true } }
        }
    }

    private var controls: some View {
        VStack(alignment:.leading,spacing:10) {
            if let activity = session.activity {
                HStack { ProgressView(); Text(activity).font(.subheadline); Spacer(); Button("Cancel") { session.cancel() } }
            } else {
                Text(session.selection.isFinished ? "Boundary ready · \(session.selection.coordinates.count) vertices" : session.drawing ? "Tap to add vertices. Drag or pinch to navigate." : "Navigate the map, then enable Draw to place vertices.")
                    .font(.subheadline)
                HStack {
                    Toggle("Draw",isOn:$session.drawing).toggleStyle(.button).disabled(session.selection.isFinished)
                    Button("Undo",systemImage:"arrow.uturn.backward") { session.selection.undo(); session.mesh = nil }
                        .disabled(session.selection.coordinates.isEmpty)
                    Button("Reset",systemImage:"trash") { session.reset() }.disabled(session.selection.coordinates.isEmpty)
                    Spacer()
                    Button("Finish") {
                        do { try session.selection.finish(); session.drawing = false }
                        catch { session.errorMessage = error.localizedDescription }
                    }.disabled(session.selection.coordinates.count < 3 || session.selection.isFinished)
                }.font(.subheadline).labelStyle(.iconOnly)
                if let imported = session.imported {
                    HStack {
                        VStack(alignment:.leading) {
                            Text(imported.url.lastPathComponent).lineLimit(1).font(.caption.bold())
                            Text("\(imported.metadata.width) × \(imported.metadata.height) · EPSG:\(imported.metadata.epsg)").font(.caption)
                        }
                        Spacer()
                        Toggle("DEM outline",isOn:$session.showFootprint).font(.caption).fixedSize()
                    }
                    Text("Orange: DEM footprint · Cyan: selection").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button(session.imported == nil ? "Import GeoTIFF" : "Replace DEM",systemImage:"square.and.arrow.down") { showImportOptions = true }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Generate 3D",systemImage:"mountain.2.fill") { session.mesh = nil; session.generate() }
                        .buttonStyle(.borderedProminent).disabled(!session.selection.isFinished || session.imported == nil)
                }.font(.subheadline)
            }
        }
        .padding().background(.regularMaterial)
    }
    private var importOptions: some View {
        NavigationStack {
            Form {
                Section("Select a DEM") {
                    Text("Choose one .tif or .tiff file. If georeferencing is missing, select its matching .tfw, .prj, or .tif.aux.xml files in the same picker selection.")
                    Text("Companion files must share the DEM's basename. They are read locally; no elevation data is uploaded.")
                }
                Section("Elevation reference") {
                    Toggle("This is an original official DEMNAS file",isOn:$session.confirmedDEMNAS)
                    Text("Use this only when you know the source. Official DEMNAS heights are metres relative to EGM2008. This confirmation supplies missing vertical metadata; it does not assign a horizontal CRS.").font(.footnote)
                    Link("Official DEMNAS download portal",destination:URL(string:"https://tanahair.indonesia.go.id/portal-web/unduh/demnas")!)
                }
                Section {
                    Button("Choose files…") { chooseFilesAfterDismiss = true; showImportOptions = false }
                }
            }.navigationTitle("Import elevation")
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { showImportOptions = false } } }
        }
    }
    private func frame(_ points: [GeoPoint]) {
        var rect = MKMapRect.null
        for geo in points {
            let p = MKMapPoint(geo.coordinate)
            rect = rect.union(.init(x:p.x,y:p.y,width:1,height:1))
        }
        camera = .rect(rect.insetBy(dx:-rect.width*0.12,dy:-rect.height*0.12))
    }
}
