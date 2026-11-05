"""Export read-only Python V4.5 parity fixtures for Swift tests."""
import json
import sys
from pathlib import Path
import numpy as np
from synthetic3d.v2.core import Grid
from dqn3d.v45.features import build_state

ROOT = Path(__file__).resolve().parents[1]
EXPORT = Path(sys.argv[1])

cases = []
for nx, ny, nz, dx, dy, dz, sites in [
    (24, 24, 12, 1.0, 1.0, 1.0, [(6, 6)]),
    (32, 20, 16, 2.0, 2.0, 1.0, [(5, 7), (24, 12)]),
    (32, 20, 16, 2.0, 3.0, 1.5, [(5, 7), (24, 12)]),
]:
    x, y, z = np.meshgrid(np.arange(nx), np.arange(ny), np.arange(nz), indexing="ij")
    rec = (2.3 + .011*x + .017*y + .025*z + .003*x*y/nx).astype(np.float32)
    observed = np.zeros((nx,ny,nz), dtype=bool)
    for sx, sy in sites:
        observed[sx,sy,:] = True
    valid = np.ones_like(observed)
    grid = Grid(nx=nx,ny=ny,nz=nz,dx_m=dx,dy_m=dy,dz_m=dz)
    state = build_state(rec,observed,valid,grid)
    selected = [(0,0),(6,7),(nx//2,ny//2),(nx-1,ny-1)]
    rows = {f"{sx},{sy}": state.features[np.flatnonzero(np.all(state.candidate_xy == (sx,sy), axis=1))[0]].tolist()
            for sx,sy in selected if (sx,sy) not in sites}
    cases.append(dict(nx=nx,ny=ny,nz=nz,dx=dx,dy=dy,dz=dz,sites=sites,global_context=state.global_context.tolist(),rows=rows))
(ROOT / "Tests/TerrainCoreTests/V45PythonFeatures.json").write_text(json.dumps(cases,separators=(",",":")))

source = np.load(EXPORT / "full_candidate_parity.npz")
parity = {key: source[key].tolist() for key in ("features","expected_q","candidate_xy","lengths","initial_counts")}
(ROOT / "Tests/TerrainCoreTests/V45FullCandidateParity.json").write_text(json.dumps(parity,separators=(",",":")))
