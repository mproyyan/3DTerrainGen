# SchemaGAN V4.2 Flexible + DQN V4.2 on device

The app bundles `SchemaGAN_V4_2_Flexible.mlpackage` from
`cpt_super_learn/model_export/Demnas3DMap_Integration_Flexible`. The DQN
SingleCandidate package and normalization constants are unchanged. Model file
hashes were compared with their source packages. The old fixed SchemaGAN
package remains in the repository but the V4.2 service loads the Flexible one.

## Runtime contract

- Core ML input: `[1,7,nz,ny,nx]`, with `nx` and `ny` in 16...96 and `nz` in
  8...32. The app checks these ranges against the compiled model metadata.
- The grid planner uses the user's display resolution as preferred horizontal
  spacing and coarsens it only when needed to fit the polygon bounding box
  into at most 96 cells per horizontal dimension. It pads small dimensions to
  the Core ML minimum. Vertical spacing is 1 m; 12, 16, 24 or 32 layers are
  selected from the deepest completed CPT. Profiles beyond 32 m are rejected
  with a visible reason. No unmeasured Ic values are invented.
- Preprocessing follows `dqn3d/v4/adapter.py`: normalized sparse Ic, observed
  mask, depth aware inverse square IDW, physical nearest site distance divided
  by maximum grid extent, and log1p of physical dx/dy/dz. Memory order is
  `[Z,Y,X]` inside every channel. Observed Ic voxels are restored exactly.
- DQN features follow `dqn3d/v4/features.py`: 17 local candidate values and
  11 global values. Every legal cell centre inside the terrain and polygon is
  scored using the unchanged SingleCandidate Core ML model. The highest
  Q value wins; no cross grid Q values are compared.
- MapKit and 3D use the same grid origin, spacing and coordinates. The UI shows
  `DQN V4.2`, the actual Q value and active grid dimensions when V4.2 succeeds.
  If V4.2 cannot run, it shows a specific reason before using an older path.
  Access masks are supported by the service but the current UI has no access
  mask editor; field access still needs human review.

## Verification and limits

The Swift tests compare the 24×24×12 recommendation, Q value and sample
reconstruction against existing Python reference fixtures at 1 m and 5 m
spacing. Core ML inference, observed Ic preservation and all candidate scoring
pass on synthetic 24×24×12, 32×32×16, 48×48×24, 64×64×32 and 96×96×32 grids.
An end to end test passes on a 200×200 m physical area. Python numeric
reference fixtures for the larger grids are not in this repository, so those
tests establish executable shape compatibility, not numerical parity with
PyTorch or field accuracy at larger scales.

On a Mac test run, 96×96×32 SchemaGAN inference took about 0.6 s and DQN
scored 9,215 legal candidates in about 0.3 s. The seven channel float32 input
alone is 8,257,536 bytes at that size; Swift arrays, output volumes, the
renderer and Core ML internals consume additional memory. iPhone inference
time and peak memory have not yet been measured. Coarsening a large area
changes physical feature spacing and may be outside the training distribution;
it does not prove the recommendation is geotechnically accurate.
