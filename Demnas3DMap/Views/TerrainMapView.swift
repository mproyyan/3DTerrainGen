import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct TerrainMapView: View {
    @Bindable var session: TerrainSession
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: -7.54, longitude: 110.44), span: .init(latitudeDelta: 0.12, longitudeDelta: 0.12)))
    @State private var showViewer = false
    @State private var showInvestigation = false
    @State private var selectedPoint: CPTPoint?
    @State private var resetConfirmation = false
    @State private var showImportOptions = false
    @State private var showElevationImporter = false
    @State private var openImporterAfterDismiss = false
    @State private var importWithManualCRS = false
    @State private var pendingElevationURLs: [URL] = []
    @State private var showCRSSelection = false
    @State private var selectedEPSG = 0
    @State private var customEPSG = ""

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if let metadata = session.importedDEM?.metadata ?? session.mesh?.metadata {
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
                    if session.recommendationSource == .dqnV46A, let candidate = session.recommendation {
                        Annotation("", coordinate: candidate.coordinate) {
                            VStack(spacing: 3) {
                                Text("DQN V4.6-A").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.regularMaterial, in: Capsule())
                                if let q = session.v42QValue {
                                    Text(String(format: "Q %.6f", Double(q))).font(.caption2.monospacedDigit().bold())
                                        .padding(.horizontal, 6).padding(.vertical, 3).background(.regularMaterial, in: Capsule())
                                }
                                Image(systemName: "scope").font(.title).foregroundStyle(.pink)
                                    .padding(6).background(.regularMaterial, in: .circle)
                            }.accessibilityLabel("Rekomendasi DQN V4.6-A Core ML")
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
                    if let metadata = session.importedDEM?.metadata ?? session.mesh?.metadata {
                        Button("Frame DEM",systemImage:"viewfinder") { frame(metadata.footprint) }
                    }
                }
            }
            .sheet(isPresented: $showInvestigation) { CPTWorkspaceView(session: session) }
            .sheet(isPresented: $showImportOptions, onDismiss: {
                if openImporterAfterDismiss { openImporterAfterDismiss = false; showElevationImporter = true }
            }) { importOptions }
            .sheet(isPresented: $showCRSSelection) { crsSelection }
            .fileImporter(isPresented: $showElevationImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    if importWithManualCRS {
                        pendingElevationURLs = urls
                        showCRSSelection = true
                    } else {
                        session.loadElevationFiles(urls)
                    }
                case .failure(let error): session.errorMessage = error.localizedDescription
                }
            }
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
            .onChange(of: session.importedDEM?.url) { _, _ in
                if let imported = session.importedDEM { frame(imported.metadata.footprint) }
            }
            .alert("Unable to continue",isPresented:Binding(get:{session.errorMessage != nil},set:{ if !$0 { session.errorMessage = nil } })) {
                Button("OK",role:.cancel) { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .navigationDestination(isPresented:$showViewer) {
                if let mesh = session.mesh {
                    Terrain3DView(terrain:mesh, session: session)
                        .id(session.terrainRevision)
                }
            }
            .onChange(of:session.mesh == nil) { _, missing in if !missing { showViewer = true } }
        }
    }

    private var controls: some View {
        VStack(alignment:.leading,spacing:10) {
            if let activity = session.activity {
                HStack {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity).font(.subheadline)
                        if let started = session.activityStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text("Menunggu \(Int(max(0, context.date.timeIntervalSince(started)))) detik")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button("Batal") { session.cancel() }
                }
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
                if let imported = session.importedDEM {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(imported.url.lastPathComponent).font(.caption.bold()).lineLimit(1)
                            Text("\(imported.metadata.width) × \(imported.metadata.height) · EPSG:\(imported.metadata.epsg)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("Oranye: cakupan DEM · Biru: poligon pilihan")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button(session.importedDEM == nil ? "Impor DEM" : "Ganti DEM") { showImportOptions = true }
                        .buttonStyle(.bordered)
                    Spacer()
                    if session.importedDEM != nil {
                        Button("Buat 3D dari file") { session.generateFromImportedDEM() }
                            .buttonStyle(.borderedProminent).disabled(!session.selection.isFinished)
                        Button("API") { session.fetchDEMNASAndGenerate() }
                            .buttonStyle(.bordered).disabled(!session.selection.isFinished)
                    } else {
                        Button("Ambil DEMNAS & Buat 3D",systemImage:"mountain.2.fill") { session.fetchDEMNASAndGenerate() }
                            .buttonStyle(.borderedProminent).disabled(!session.selection.isFinished)
                    }
                }.font(.subheadline)
                Text("Pilih GeoTIFF atau ZIP berisi satu GeoTIFF. Elevasi dan cakupannya harus sesuai poligon.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding().background(.regularMaterial)
    }
    private var importOptions: some View {
        NavigationStack {
            Form {
                Section("Impor GeoTIFF elevasi") {
                    Text("Pilih satu .tif/.tiff atau ZIP berisi satu GeoTIFF. File .tfw, .prj, dan .tif.aux.xml dalam ZIP akan dibaca otomatis.")
                    Button("Baca CRS otomatis") {
                        importWithManualCRS = false
                        openImporterAfterDismiss = true
                        showImportOptions = false
                    }
                    Button("Pilih file lalu tetapkan CRS") {
                        importWithManualCRS = true
                        openImporterAfterDismiss = true
                        showImportOptions = false
                    }
                }
                Section("Referensi elevasi") {
                    Toggle("Berasal dari DEMNAS · meter, EGM2008", isOn: $session.confirmedDEMNASImport)
                        .onChange(of: session.confirmedDEMNASImport) { _, enabled in
                            if enabled { session.verticalMetresWithUnknownDatumImport = false }
                        }
                    Toggle("Elevasi meter · datum tidak diketahui", isOn: $session.verticalMetresWithUnknownDatumImport)
                        .onChange(of: session.verticalMetresWithUnknownDatumImport) { _, enabled in
                            if enabled { session.confirmedDEMNASImport = false }
                        }
                    Text("Pilih sesuai informasi sumber file bila metadata vertikal tidak tersimpan. Penetapan CRS hanya membaca koordinat file, bukan memproyeksikan ulang piksel.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impor DEM")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Tutup") { showImportOptions = false } } }
        }
    }

    private var crsSelection: some View {
        NavigationStack {
            Form {
                Section("CRS file sumber") {
                    Text("Jika CRS sudah tertulis di file, biarkan pilihan otomatis. Pilih EPSG manual hanya sesuai metadata sumber DEM.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("EPSG", selection: $selectedEPSG) {
                        Text("Baca CRS dari file").tag(0)
                        Text("WGS 84 · 4326").tag(4326)
                        Text("Web Mercator · 3857").tag(3857)
                        ForEach(46...54, id: \.self) { zone in
                            Text("UTM \(zone)S · \(32700 + zone)").tag(32700 + zone)
                        }
                        ForEach(46...52, id: \.self) { zone in
                            Text("UTM \(zone)N · \(32600 + zone)").tag(32600 + zone)
                        }
                    }
                    TextField("EPSG lain (opsional)", text: $customEPSG).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Tetapkan CRS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Batal") { pendingElevationURLs = []; showCRSSelection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Impor") {
                        let code: Int
                        if customEPSG.trimmingCharacters(in: .whitespaces).isEmpty { code = selectedEPSG }
                        else if let custom = Int(customEPSG.trimmingCharacters(in: .whitespaces)) { code = custom }
                        else { session.errorMessage = "Kode EPSG harus berupa angka."; return }
                        guard code == 0 || (try? CoordinateTransformer(epsg: code)) != nil else {
                            session.errorMessage = "EPSG:\(code) belum didukung. Gunakan WGS 84, Web Mercator, atau WGS 84 UTM."
                            return
                        }
                        let urls = pendingElevationURLs
                        pendingElevationURLs = []
                        showCRSSelection = false
                        session.loadElevationFiles(urls, manualEPSG: code == 0 ? nil : code)
                    }
                }
            }
        }
    }
    private var investigationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("SIMULASI", systemImage: "flask.fill").font(.caption.bold()).foregroundStyle(.orange)
                Spacer()
                Text("\(session.status.completed)/\(session.status.target) CPT").font(.caption.monospacedDigit())
                Button("Area baru", systemImage: "arrow.counterclockwise") { resetConfirmation = true }.font(.caption)
            }
            Text(session.placingCPT ? "Ketuk lokasi CPT di dalam area. Jarak antartitik minimal 2 m." : session.recommendation != nil ? "CPT berikutnya disarankan · simulasi" : session.status.title).font(.subheadline)
            HStack {
                Button(session.placingCPT ? "Batal" : "Tambah CPT", systemImage: "mappin.and.ellipse") { session.placingCPT.toggle() }
                    .buttonStyle(.bordered)
                Button("Investigasi", systemImage: "list.bullet.clipboard") { session.placingCPT = false; showInvestigation = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button("3D", systemImage: "cube") { session.placingCPT = false; showViewer = true }.buttonStyle(.borderedProminent)
            }.font(.subheadline)
            if let assessment = session.investigationAssessment {
                VStack(alignment:.leading,spacing:4) {
                    Text(String(format:"Predicted Coverage: %.1f%%",assessment.predictedCoverage * 100))
                        .font(.subheadline.monospacedDigit().bold())
                    Text(assessment.advisoryHigh ? "Kecukupan Investigasi: Tinggi" : "Kecukupan Investigasi: Belum Memadai")
                        .font(.subheadline.bold())
                    Text(assessment.advisoryHigh
                         ? "Model memperkirakan cakupan rekonstruksi telah memenuhi target eksperimen. Verifikasi engineer tetap diperlukan sebelum menghentikan investigasi."
                         : "Investigasi tambahan direkomendasikan.")
                        .font(.caption)
                    if let spacing = session.minimumRecommendationSpacingMeters {
                        Text(String(format:"Minimum Recommendation Spacing: %.1f m",spacing))
                            .font(.caption.monospacedDigit())
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                    .padding(10).background(.thinMaterial,in:RoundedRectangle(cornerRadius:10))
            }
            if session.dqnStatus == .recommending { ProgressView("DQN: menghitung lokasi CPT berikutnya…").font(.caption2) }
            if let detail = session.v42Detail {
                Text(detail).font(.caption2)
                    .foregroundStyle(session.dqnRecommendationSource == .dqnV46A ? .green : .orange)
            }
            if session.recommendationSource == .dqnV46A, let q = session.v42QValue {
                Text(String(format: "Q-score rekomendasi DQN V4.6-A: %.6f", Double(q)))
                    .font(.subheadline.monospacedDigit().bold()).foregroundStyle(.pink)
                Text("Skor model untuk ranking lokasi, bukan confidence.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if session.recommendationSource == .dqnV46A, session.recommendation != nil {
                Text("Target merah muda: rekomendasi DQN V4.6-A. Periksa akses dan izin lokasi di lapangan.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let candidate = session.recommendation,
                   let nearest = session.points.map({ CoordinateTransformer.localMeters(candidate, origin: $0.coordinate).length }).min() {
                    Text(String(format: "Jarak target dari CPT terdekat: %.1f m", nearest))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let info = session.dqnInfo, session.recommendationSource == .dqnV46A {
                Text(info).font(.caption2).foregroundStyle(.secondary)
            }
            if session.dqnError != nil { Text("Rekomendasi DQN belum tersedia.").font(.caption2).foregroundStyle(.orange) }
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
