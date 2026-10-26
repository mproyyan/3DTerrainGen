import SwiftUI
import MapKit

struct TerrainMapView: View {
    @Bindable var session: TerrainSession
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: -7.54, longitude: 110.44), span: .init(latitudeDelta: 0.12, longitudeDelta: 0.12)))
    @State private var showViewer = false
    @State private var showInvestigation = false
    @State private var selectedPoint: CPTPoint?
    @State private var resetConfirmation = false

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if let metadata = session.mesh?.metadata {
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
                        Annotation("", coordinate: candidate.coordinate) {
                            VStack(spacing: 3) {
                                Text(session.recommendationSource == .dqn ? "DQN" : session.recommendationSource == .dqnWindowedExperimental ? "DQN · eksperimen" : "Heuristic")
                                    .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.regularMaterial, in: Capsule())
                                Image(systemName: "scope").font(.title).foregroundStyle(.pink)
                                    .padding(6).background(.regularMaterial, in: .circle)
                            }
                            .accessibilityLabel(session.recommendationSource == .dqnWindowedExperimental ? "Rekomendasi DQN window lokal, eksperimental" : session.recommendationSource == .dqn ? "Rekomendasi DQN" : "Rekomendasi Heuristic")
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
                    if let metadata = session.mesh?.metadata {
                        Button("Frame DEM",systemImage:"viewfinder") { frame(metadata.footprint) }
                    }
                }
            }
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
                HStack {
                    Spacer()
                    Button("Ambil DEMNAS & Buat 3D",systemImage:"mountain.2.fill") { session.fetchDEMNASAndGenerate() }
                        .buttonStyle(.borderedProminent).disabled(!session.selection.isFinished)
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
            if session.dqnStatus == .recommending { ProgressView("DQN: menghitung lokasi CPT berikutnya…").font(.caption2) }
            if session.recommendation != nil {
                Text(session.recommendationSource == .dqn ? "Target merah muda: rekomendasi DQN satu grid." : session.recommendationSource == .dqnWindowedExperimental ? "Target merah muda: DQN Windowed Experimental; belum divalidasi terhadap ground truth." : "Target merah muda: fallback Heuristic geometris.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if session.recommendationSource == .dqn || session.recommendationSource == .dqnWindowedExperimental {
                if let metric = ModelEvaluationMetrics.summary(
                    observedCPTCount: session.status.completed,
                    windowed: session.recommendationSource == .dqnWindowedExperimental
                ) {
                    Text(metric).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Titik DQN belum menilai jalan, vegetasi, akses, atau izin lokasi; periksa di lapangan.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let info = session.dqnInfo { Text(info).font(.caption2).foregroundStyle(.secondary) }
            if let reason = session.dqnError { Text("DQN belum tersedia: \(reason)").font(.caption2).foregroundStyle(.orange) }
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
