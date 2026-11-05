# Pilot urutan CPT nyata: DQN dan rekonstruksi

Evaluasi retrospektif ini menggunakan enam profil CPT lapangan dari `cpt_super_learn/results/real_world_testing/real_cpt_ic_profiles.csv` pada grid 24 × 24 × 12 sel, resolusi horizontal 1 m. Enam lokasi terukur menjadi satu-satunya kandidat dan ground truth yang bisa diperiksa. Dari setiap CPT awal, kebijakan memilih CPT kedua dan ketiga. Profil yang belum dipilih disisihkan untuk menghitung RMSE Ic. Pada setiap tahap, kebijakan DQN dan pembanding spasial dievaluasi pada profil tersembunyi yang sama. Keenam awal memakai kumpulan data yang sama, sehingga bukan enam eksperimen independen.

Kebijakan DQN memakai checkpoint SchemaGAN rekonstruktor dan DQN asli, tanpa perubahan bobot. Pembanding `Uniform` memilih lokasi terukur yang paling jauh dari CPT yang sudah dipilih. Output [`real_cpt_dqn_pilot.json`](real_cpt_dqn_pilot.json) mencatat hash checkpoint, konfigurasi, urutan pilihan, dan metrik per kasus.

| CPT terukur | SchemaGAN + DQN RMSE | SchemaGAN + Uniform RMSE | Awal yang dimenangkan DQN |
| --- | ---: | ---: | ---: |
| 2 | 0.46759 | 0.43280 | 0/6 |
| 3 | 0.38253 | 0.35648 | 2/6 |

Model C Flexible, yaitu model visual 3D aplikasi, diuji ulang dengan set CPT terpilih dan mask profil tersembunyi yang sama. Hasil ada di [`model_c_real_pilot.json`](model_c_real_pilot.json).

| CPT terukur | Model C pada titik DQN RMSE | Model C pada titik Uniform RMSE |
| --- | ---: | ---: |
| 2 | 0.41630 | 0.39573 |
| 3 | 0.31900 | 0.34030 |

Hasil ini belum mengukur ketepatan lapisan untuk seluruh poligon: tidak ada ground truth di antara enam CPT. Akurasi horizontal koordinat sumber juga belum terverifikasi. Hasil berlaku untuk urutan kandidat yang dibatasi enam lokasi, grid g24, dan skenario data ini. Selisih kecil pada 3 CPT untuk Model C tidak membuktikan keunggulan DQN umum; pengurutan DQN dilatih bersama rekonstruktor SchemaGAN, sedangkan visual aplikasi memakai Model C Flexible. Evaluasi ini tidak memvalidasi windowing pada area besar atau kelayakan akses lapangan.

Karena itu aplikasi mempertahankan label **DQN Windowed Experimental** saat inference DQN dipakai pada satu window. Di luar jangkauan window yang dapat memuat CPT terukur, aplikasi memberi titik **Eksplorasi Heuristic** berdasarkan cakupan geometris. Titik itu tidak disebut hasil DQN. Untuk menilai kualitas seluruh area diperlukan CPT tambahan yang lokasinya dicatat akurat, profil yang disisihkan secara prospektif, dan pembandingan kebijakan pada protokol yang sama. Tidak ada training ulang dalam perubahan ini.

Reproduksi dari akar proyek:

```sh
python3 Tools/evaluate_real_cpt_dqn.py --research-root /Users/daffaburanenugraha/Developer/cpt_super_learn --output Docs/real_cpt_dqn_pilot.json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Tools/evaluate_model_c_real.swift /Users/daffaburanenugraha/Developer/cpt_super_learn/results/real_world_testing/real_cpt_ic_profiles.csv Docs/real_cpt_dqn_pilot.json /Users/daffaburanenugraha/Developer/3DTerrainGen/Demnas3DMap/Models/ModelC_Flexible.mlpackage Docs/model_c_real_pilot.json
```

Skrip kedua menggunakan pilihan CPT dari JSON skrip pertama dan Model C Flexible lokal. Skrip Python memverifikasi hash checkpoint yang dibekukan. Kedua laporan merekam hash data/model agar input evaluasi dapat ditelusuri.
