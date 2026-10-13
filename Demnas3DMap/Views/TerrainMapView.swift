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
    @State private var showInvestigation = false
    @State private var selectedPoint: CPTPoint?
    @State private var resetConfirmation = false

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if session.showFootprint, let metadata = session.imported?.metadata ?? session.mesh?.metadata {
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
                    ForEach(session.points) { point in
                        Annotation(point.name, coordinate: point.coordinate.coordinate) {
                            Button { if !session.placingCPT { selectedPoint = point } } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: point.isComplete ? "checkmark.circle.fill" : "mappin.circle.fill")
                                        .font(.title2).foregroundStyle(point.isComplete ? .green : .orange)
                                    Text(point.name).font(.caption2.bold()).foregroundStyle(.primary)
                                }.padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel("\(point.name), \(point.isComplete ? "hasil tersedia" : "menunggu data")")
                        }
                    }
                    if let candidate = session.recommendation {
                        Annotation("Rekomendasi simulasi", coordinate: candidate.coordinate) {
                            Image(systemName: "scope").font(.title).foregroundStyle(.pink)
                                .padding(6).background(.regularMaterial, in: .circle)
                        }
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
                    guard session.activity == nil, let coordinate = proxy.convert(value.location,from:.local) else { return }
                    do {
                        if session.placingCPT {
                            let id = try session.addCPT(at: GeoPoint(coordinate))
                            selectedPoint = session.points.first { $0.id == id }
                        } else if session.drawing && !session.selection.isFinished { try session.selection.add(coordinate) }
                    } catch { session.errorMessage = error.localizedDescription }
                })
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("CPT Terrain · PoC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    if let metadata = session.imported?.metadata ?? session.mesh?.metadata {
                        Button("Frame DEM",systemImage:"viewfinder") { frame(metadata.footprint) }
                    }
                }
            }
            .sheet(isPresented:$showImportOptions,onDismiss: {
                if chooseFilesAfterDismiss { chooseFilesAfterDismiss = false; showImporter = true }
            }) { importOptions }
            .sheet(isPresented: $showInvestigation) { CPTWorkspaceView(session: session) }
            .sheet(item: $selectedPoint) { point in
                NavigationStack {
                    CPTDetailView(session: session, pointID: point.id)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Tutup") { selectedPoint = nil } } }
                }
            }
            .confirmationDialog("Mulai area baru? Terrain dan seluruh titik CPT tersimpan akan dihapus.", isPresented: $resetConfirmation, titleVisibility: .visible) {
                Button("Hapus proyek & mulai baru", role: .destructive) { session.reset() }
            }
            .onAppear { if session.mesh != nil { frame(session.selection.coordinates.map { GeoPoint($0) }) } }
            .fileImporter(isPresented:$showImporter, allowedContentTypes:[.data], allowsMultipleSelection:true) { result in
                switch result {
                case .success(let urls): session.load(urls)
                case .failure(let error): session.errorMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented:$showImporterForManualCRS, allowedContentTypes:[.data], allowsMultipleSelection:true) { result in
                switch result {
                case .success(let urls):
                    session.pendingURLsForCRSSelection = urls
                    showCRSSelectionSheet = true
                case .failure(let error):
                    session.errorMessage = error.localizedDescription
                }
            }
            .alert("Unable to continue",isPresented:Binding(get:{session.errorMessage != nil},set:{ if !$0 { session.errorMessage = nil } })) {
                Button("OK",role:.cancel) { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .navigationDestination(isPresented:$showViewer) {
                if let mesh = session.mesh { Terrain3DView(terrain:mesh, session: session) }
            }
            .onChange(of:session.mesh == nil) { _, missing in if !missing { showViewer = true } }
        }
    }

    private var controls: some View {
        VStack(alignment:.leading,spacing:10) {
            if let activity = session.activity {
                HStack { ProgressView(); Text(activity).font(.subheadline); Spacer(); Button("Cancel") { session.cancel() } }
            } else if session.mesh != nil {
                investigationControls
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
                    Button("Generate 3D",systemImage:"mountain.2.fill") { session.generate() }
                        .buttonStyle(.borderedProminent).disabled(!session.selection.isFinished || session.imported == nil)
                }.font(.subheadline)
            }
        }
        .padding().background(.regularMaterial)
    }
    private var investigationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("SIMULASI", systemImage: "flask.fill").font(.caption.bold()).foregroundStyle(.orange)
                Spacer()
                Text("\(session.status.completed)/\(session.status.target) CPT").font(.caption.monospacedDigit())
                Button("Area baru", systemImage: "arrow.counterclockwise") { resetConfirmation = true }.font(.caption)
            }
            Text(session.placingCPT ? "Ketuk lokasi CPT di dalam area. Jarak antartitik minimal 2 m." : session.status.title).font(.subheadline)
            HStack {
                Button(session.placingCPT ? "Batal" : "Tambah CPT", systemImage: "mappin.and.ellipse") { session.placingCPT.toggle() }
                    .buttonStyle(.bordered)
                Button("Investigasi", systemImage: "list.bullet.clipboard") { session.placingCPT = false; showInvestigation = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button("3D", systemImage: "cube") { session.placingCPT = false; showViewer = true }.buttonStyle(.borderedProminent)
            }.font(.subheadline)
            if session.recommendation != nil { Text("Target merah muda: kandidat simulasi. Buka Investigasi untuk menetapkannya.").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private var importOptions: some View {
        NavigationStack {
            Form {
                Section("Standard Import") {
                    Text("Choose one .tif or .tiff file. The app reads embedded CRS metadata (GeoKeys, WKT2) or companion .tfw, .prj, .aux.xml sidecars.")
                        .font(.subheadline)
                    Button("Choose files…") { chooseFilesAfterDismiss = true; showImportOptions = false }
                }

                Section {
                    Text("Just like in QGIS: pick your raw GeoTIFF first, then select which Coordinate Reference System (CRS) it belongs to.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        showImportOptions = false
                        showImporterForManualCRS = true
                    } label: {
                        Label("Select DEM File, Then Choose CRS…", systemImage: "map.circle.fill")
                            .bold()
                    }
                } header: {
                    Text("Import Without CRS (Choose CRS After Selection)")
                } footer: {
                    Text("Recommended if you get 'Raster bounds are inconsistent' or 'CRS missing' errors with raw DEMNAS tiles.")
                }

                Section("Elevation Reference") {
                    Toggle("This is an original official DEMNAS file", isOn: $session.confirmedDEMNAS)
                    Text("Official DEMNAS heights are metres relative to EGM2008. This supplies missing vertical metadata without altering horizontal coordinates.").font(.footnote)
                    Link("Official DEMNAS download portal", destination: URL(string: "https://tanahair.indonesia.go.id/portal-web/unduh/demnas")!)
                }
            }
            .navigationTitle("Import Elevation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showImportOptions = false } } }
        }
    }

    private var crsSelectionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Important for DEMNAS:")
                            .font(.subheadline.bold())
                        Text("Raw DEMNAS tiles downloaded directly from BIG (tanahair.indonesia.go.id) are always in **WGS 84 Geographic degrees (EPSG:4326)**, including tiles in Central Java, Yogyakarta, and Java.\n\nOnly select **UTM Zone 49S (EPSG:32749)** if you previously reprojected the raster coordinates to UTM meters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Coordinate Reference System Selector")
                }

                Section("Standard Geodetic (Lat/Long) — Recommended for DEMNAS") {
                    crsRow(title: "WGS 84 (Geographic Lat/Lon)", code: 4326, description: "Default for all raw DEMNAS tiles across Indonesia")
                    crsRow(title: "WGS 84 / Pseudo-Mercator", code: 3857, description: "Web Mercator (Meters)")
                }

                Section("UTM Southern Hemisphere (Indonesia)") {
                    crsRow(title: "WGS 84 / UTM Zone 46S", code: 32746, description: "North Sumatra / Aceh")
                    crsRow(title: "WGS 84 / UTM Zone 47S", code: 32747, description: "Sumatra")
                    crsRow(title: "WGS 84 / UTM Zone 48S", code: 32748, description: "West Java / South Sumatra")
                    crsRow(title: "WGS 84 / UTM Zone 49S", code: 32749, description: "Central & East Java, Bali, West Kalimantan")
                    crsRow(title: "WGS 84 / UTM Zone 50S", code: 32750, description: "East Kalimantan, South Sulawesi, Lombok")
                    crsRow(title: "WGS 84 / UTM Zone 51S", code: 32751, description: "Maluku, Flores, Timor")
                    crsRow(title: "WGS 84 / UTM Zone 52S", code: 32752, description: "West Papua")
                    crsRow(title: "WGS 84 / UTM Zone 53S", code: 32753, description: "Papua")
                    crsRow(title: "WGS 84 / UTM Zone 54S", code: 32754, description: "East Papua")
                }

                Section("UTM Northern Hemisphere (Indonesia)") {
                    crsRow(title: "WGS 84 / UTM Zone 46N", code: 32646, description: "Northern Aceh")
                    crsRow(title: "WGS 84 / UTM Zone 47N", code: 32647, description: "North Sumatra")
                    crsRow(title: "WGS 84 / UTM Zone 48N", code: 32648, description: "Riau / Natuna")
                    crsRow(title: "WGS 84 / UTM Zone 49N", code: 32649, description: "North Kalimantan")
                    crsRow(title: "WGS 84 / UTM Zone 50N", code: 32650, description: "Tarakan / North Kalimantan")
                    crsRow(title: "WGS 84 / UTM Zone 51N", code: 32651, description: "North Sulawesi / Sangihe")
                    crsRow(title: "WGS 84 / UTM Zone 52N", code: 32652, description: "Morotai / North Maluku")
                }

                Section("Custom EPSG Code") {
                    HStack {
                        Text("EPSG:")
                        TextField("e.g. 4326", text: $customCRSText)
                            .keyboardType(.numberPad)
                        if let customCode = Int(customCRSText.trimmingCharacters(in: .whitespaces)) {
                            Button("Apply") {
                                selectedCRSForImport = customCode
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("Assign CRS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCRSSelectionSheet = false
                        session.pendingURLsForCRSSelection = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let epsgToUse: Int
                        if let custom = Int(customCRSText.trimmingCharacters(in: .whitespaces)), !customCRSText.isEmpty {
                            epsgToUse = custom
                        } else {
                            epsgToUse = selectedCRSForImport
                        }
                        showCRSSelectionSheet = false
                        if let urls = session.pendingURLsForCRSSelection {
                            session.load(urls, overrideEPSG: epsgToUse)
                        }
                    }
                    .bold()
                }
            }
        }
    }

    private func crsRow(title: String, code: Int, description: String) -> some View {
        Button {
            selectedCRSForImport = code
            customCRSText = ""
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .font(.body)
                    Text("\(description) · EPSG:\(code)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
                if selectedCRSForImport == code && customCRSText.isEmpty {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .bold()
                }
            }
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
