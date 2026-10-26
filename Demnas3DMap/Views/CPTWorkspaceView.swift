import SwiftUI
import UniformTypeIdentifiers

extension SoilBehavior {
    var color: Color {
        switch self { case .sand: .yellow; case .transitional: .orange; case .clay: .indigo }
    }
}

struct CPTWorkspaceView: View {
    @Bindable var session: TerrainSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Investigasi CPT · SIMULASI", systemImage: "flask.fill").font(.headline)
                    Text(session.status.title)
                    Text("\(session.status.completed)/\(session.status.target) profil dalam skenario. Status selesai mengikuti jumlah profil, bukan bukti homogenitas atau hasil DRL.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Skenario", selection: Binding(get: { session.scenario }, set: { session.setScenario($0) })) {
                        ForEach(InvestigationScenario.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(session.points.contains(where: \.isComplete))
                    Text("Skenario dikunci setelah hasil pertama. Hapus hasil/titik untuk mengganti skenario.").font(.caption2)
                }
                Section("Titik investigasi") {
                    if session.points.isEmpty { Text("Kembali ke peta, pilih Tambah CPT, lalu ketuk lokasi pengujian.").foregroundStyle(.secondary) }
                    ForEach(session.points) { point in
                        NavigationLink {
                            CPTDetailView(session: session, pointID: point.id)
                        } label: {
                            HStack {
                                Image(systemName: point.isComplete ? "checkmark.circle.fill" : "clock").foregroundStyle(point.isComplete ? .green : .orange)
                                VStack(alignment: .leading) {
                                    Text(point.name)
                                    if point.draft != nil { Text("Draft belum diterapkan").font(.caption2).foregroundStyle(.orange) }
                                    Text(point.isComplete ? "\(point.dataOrigin.title) · \(point.interpretation?.layers.count ?? 0) lapisan simulasi" : "Menunggu pengujian / input hasil")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Langkah berikutnya") {
                    if let location = session.recommendation {
                        Text(session.recommendationSource == .dqn ? "DQN: kandidat dengan Q-value tertinggi pada satu grid valid. Akses lapangan belum diperhitungkan." : session.recommendationSource == .dqnWindowedExperimental ? "DQN Windowed Experimental: kandidat Q-value tertinggi dari satu window yang dipilih sebelum inference. Belum tervalidasi terhadap ground truth." : "Heuristic: kandidat terjauh dari titik yang sudah diuji. Ini fallback, bukan rekomendasi DQN; akses lapangan belum diperhitungkan.")
                        Text(String(format: "%.6f, %.6f", location.latitude, location.longitude)).font(.caption.monospaced())
                        Button("Tetapkan titik rekomendasi", systemImage: "mappin.and.ellipse") {
                            do { try session.addCPT(at: location) }
                            catch { session.errorMessage = error.localizedDescription }
                        }
                    } else if session.status.finished {
                        Label("Skenario selesai", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Lapisan diperluas sesuai asumsi demo. Kedalaman di luar data tetap tidak diketahui.")
                    } else if session.status.pending > 0 {
                        Text("Lakukan pengujian di titik yang ditetapkan, lalu buka titik tersebut untuk memasukkan profil.")
                    } else {
                        Text(session.status.completed == 0 ? "Tetapkan titik pertama di peta." : "Tidak ada kandidat yang memenuhi jarak minimum. Tambahkan titik manual atau tinjau ukuran area; skenario belum selesai.")
                    }
                    Button("Kembali ke peta") { dismiss() }
                }
                Section("Model PoC") {
                    Text("Model C: \(session.reconstructionStatus.rawValue)")
                    if let error = session.reconstructionError { Text(error).foregroundStyle(.orange) }
                    Text("DQN: \(session.dqnStatus.rawValue). Rekonstruktor SchemaGAN V3 yang cocok dengan training DQN dijalankan terpisah dari Model C.")
                    if let reason = session.dqnError { Text("Alasan fallback DQN: \(reason)").foregroundStyle(.orange) }
                    Text(session.reconstruction == nil ? "Fallback: warna lapisan mengikuti profil CPT terdekat; area abu-abu belum didukung radius simulasi." : "Volume Ic Model C eksperimental terlihat pada tampilan 3D. Kolom fallback disembunyikan saat volume tersedia.")
                    Text("Kekuatan, batas lapisan, dan cakupan belum tervalidasi untuk desain. Sumber rekomendasi: \(session.recommendationSource.rawValue).")
                    if let date = session.savedAt { Text("Tersimpan lokal: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }.font(.footnote)
            }
            .navigationTitle("Investigasi")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Tutup") { dismiss() } } }
            .alert("Investigasi", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("OK") { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
        }
    }
}

struct CPTDetailView: View {
    @Bindable var session: TerrainSession
    let pointID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var csv = ""
    @State private var assumptions = CPTAssumptions()
    @State private var origin = CPTDataOrigin.entered
    @State private var error: String?
    @State private var showImporter = false
    @State private var deleteConfirmation = false
    @State private var replaceExample = false
    @State private var initialized = false
    @State private var dirty = false
    private var point: CPTPoint? { session.points.first { $0.id == pointID } }

    var body: some View {
        Form {
            if let point {
                Section("Lokasi CPT") {
                    Text(String(format: "%.6f, %.6f", point.coordinate.latitude, point.coordinate.longitude)).font(.callout.monospaced())
                    Text("Elevasi permukaan DEM: \(point.surfaceElevation, specifier: "%.2f") m")
                    Text("Depth diukur ke bawah dari permukaan setempat. Elevasi memakai DEM, bukan survei kepala CPT.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Profil pengujian") {
                    Picker("Asal data", selection: $origin) {
                        ForEach(CPTDataOrigin.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("CSV: depth_m,qc_mpa,fs_kpa,u2_kpa\nSatuan m, MPa, kPa, kPa. Kosongkan u2 jika tidak tersedia; gunakan titik desimal.").font(.caption)
                    TextEditor(text: $csv).font(.system(.caption, design: .monospaced)).frame(minHeight: 180)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("Profil CPT CSV")
                    Button("Import CSV dari Files", systemImage: "square.and.arrow.down") { showImporter = true }
                    Button("Isi contoh sintetis", systemImage: "flask") {
                        if csv.isEmpty { fillExample() } else { replaceExample = true }
                    }
                }
                Section("Asumsi simulasi") {
                    numberField("Area ratio a", value: $assumptions.coneAreaRatio)
                    numberField("γ (kN/m³)", value: $assumptions.unitWeight)
                    numberField("Muka air (m)", value: $assumptions.waterTableDepth)
                    numberField("Nkt", value: $assumptions.nkt)
                    Text("Berat isi konstan dan air hidrostatik. qt ≈ qc jika u2 kosong. φ′ memakai lookup ilustratif, bukan korelasi desain.").font(.caption)
                }
                Section {
                    Button("Simpan & generate lapisan", systemImage: "cube.transparent") {
                        do {
                            try session.saveCPT(id: pointID, csv: csv, assumptions: assumptions, origin: origin)
                            dirty = false
                            if let message = session.errorMessage { self.error = message; session.errorMessage = nil }
                        } catch { self.error = error.localizedDescription }
                    }.font(.headline)
                    if dirty { Text("Draft disimpan saat menutup editor. Tekan Simpan & generate untuk menerapkannya; hasil di bawah masih dari penyimpanan terakhir.").font(.caption).foregroundStyle(.orange) }
                    if let saved = point.updatedAt { Text("Hasil diperbarui \(saved.formatted(date: .omitted, time: .shortened))").font(.caption) }
                }
                if let result = point.interpretation {
                    Section("Lapisan & kekuatan · SIMULASI") {
                        ForEach(result.layers) { layer in
                            HStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 3).fill(layer.behavior.color).frame(width: 10)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(layer.top, specifier: "%.2f")–\(layer.bottom, specifier: "%.2f") m · \(layer.behavior.title)").font(.subheadline.bold())
                                    Text("Ic rata-rata \(layer.meanIc, specifier: "%.2f")").font(.caption)
                                    if let su = layer.su { Text("su ≈ \(su, specifier: "%.1f") kPa · Nkt \(point.assumptions.nkt, specifier: "%.1f")").font(.caption) }
                                    else if let phi = layer.phi { Text("φ′ ilustratif ≈ \(phi, specifier: "%.1f")°").font(.caption) }
                                    else { Text("Kekuatan tidak diestimasi; perlu tinjauan.").font(.caption) }
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Section("Asumsi & keterbatasan hasil") {
                        ForEach(result.notes, id: \.self) { Text($0).font(.caption) }
                    }
                }
                Section {
                    Button("Hapus titik CPT", role: .destructive) { deleteConfirmation = true }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(point?.name ?? "CPT")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialized, let point else { return }
            csv = point.draft?.csv ?? point.csv
            assumptions = point.draft?.assumptions ?? point.assumptions
            origin = point.draft?.origin ?? point.dataOrigin
            initialized = true
            updateDirty()
        }
        .onDisappear {
            if dirty { session.saveDraft(id: pointID, csv: csv, assumptions: assumptions, origin: origin) }
        }
        .onChange(of: csv) { _, _ in updateDirty() }
        .onChange(of: assumptions) { _, _ in updateDirty() }
        .onChange(of: origin) { _, _ in updateDirty() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_000_000 else { throw TerrainError("CSV dibatasi 1 MB.") }
                let text = try String(contentsOf: url, encoding: .utf8)
                _ = try CPTProcessor.parse(text)
                csv = text; origin = .entered
            } catch { self.error = error.localizedDescription }
        }
        .alert("Data CPT", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Hapus titik dan hasilnya?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("Hapus titik", role: .destructive) { session.deleteCPT(id: pointID); dismiss() }
        }
        .confirmationDialog("Ganti profil di editor dengan contoh sintetis?", isPresented: $replaceExample, titleVisibility: .visible) {
            Button("Gunakan contoh", role: .destructive) { fillExample() }
        }
    }
    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(width: 100)
        }
    }
    private func fillExample() {
        csv = CPTProcessor.example(variable: session.scenario == .variable, iteration: session.points.firstIndex { $0.id == pointID } ?? 0)
        origin = .example
    }
    private func updateDirty() {
        guard let point else { return }
        dirty = csv != point.csv || assumptions != point.assumptions || origin != point.dataOrigin
    }
}
