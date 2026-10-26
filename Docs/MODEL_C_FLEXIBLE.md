# Model C Flexible integration

The app now bundles `ModelC_Flexible.mlpackage` from `cpt_super_learn/results/coreml_conversion/model_c_flexible_v1/`. The former fixed `ModelC.mlpackage` is no longer in the app target. The copied weights match the supplied package by SHA-256. Its conversion report shows PyTorch/Core ML parity on 16×16×8, 24×24×12, 32×32×16, and 48×32×16 tensors. A local Core ML smoke test also passed 32×24×16 and 48×32×12.

Inputs are Float32 `sparse`, `mask`, and `idw` in `[1,1,Z,Y,X]` order; output `reconstruction` is normalized Ic in the same shape. The app uses Ic mean `2.305778080072476` and standard deviation `0.3108808206093057`, builds physical inverse-distance-squared IDW, denormalizes predictions, and restores observed Ic exactly. Grid spacing remains 1 m. The app chooses X/Y dimensions in multiples of four, with X 16–48 and Y 16–32; depth uses 8, 12, or 16 cells depending on complete CPT profile coverage. It keeps a one-cell margin around the selected polygon. One inference supports an effective unrotated span of about 47 m east–west by 31 m north–south. Larger polygons use overlapping 1 m model windows only where complete CPT observations exist; spacing is not silently changed.

The displayed 3D volume uses the flexible Model C grid. DQN uses separately exported SchemaGAN V3 reconstructors paired with its scorer: g24 at 1 m XY up to 24 × 24 m, and g16 at 2 m XY up to 32 × 32 m. Model C Flexible remains only the displayed volume and was not changed to enable g16. Physical iPhone performance and field accuracy remain unverified.


Large project polygons now use adaptive 48 × 32 cell Model C windows at 1 m input spacing with 8 m overlap. Only CPT-bearing windows are reconstructed; empty windows remain unknown. This expands project support without changing the model package or claiming tiled output equals global inference. See `Docs/DYNAMIC_GRID_TILING.md`.
