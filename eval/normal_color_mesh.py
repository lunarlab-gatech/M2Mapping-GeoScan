"""mesh.ply (vertex-colored) -> normal-colored ply (or usdz).

Each vertex color encodes its surface normal:
    R = (nx + 1) / 2
    G = (ny + 1) / 2
    B = (nz + 1) / 2
This reproduces the top-row "surface reconstruction" visualization in the
M2Mapping paper (Fig. 1).

Usage:
    pip install trimesh usd-core numpy
    python3 normal_color_mesh.py <input.ply> <output.ply|output.usd|output.usdz> \
        [--min-component-faces 500] [--up Z]
"""
import argparse
from pathlib import Path

import numpy as np
import trimesh


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input_ply", type=Path)
    ap.add_argument("output", type=Path, help="*.ply, *.usd, or *.usdz")
    ap.add_argument("--min-component-faces", type=int, default=500)
    ap.add_argument("--up", default="Z", choices=["Z", "Y", "z", "y"])
    args = ap.parse_args()

    m = trimesh.load(str(args.input_ply), process=False, force="mesh")
    print(f"loaded: {len(m.vertices)} verts, {len(m.faces)} faces")

    if args.min_component_faces > 0:
        comps = m.split(only_watertight=False)
        keep = [c for c in comps if len(c.faces) >= args.min_component_faces]
        m = trimesh.util.concatenate(keep) if keep else m
        print(f"after floater removal: {len(m.vertices)} verts, {len(m.faces)} faces")

    # Trimesh computes vertex normals on access; ensure they exist.
    n = m.vertex_normals.astype(np.float32)
    n = n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-8)
    rgb = ((n + 1.0) * 0.5 * 255.0).clip(0, 255).astype(np.uint8)
    m.visual.vertex_colors = np.concatenate(
        [rgb, np.full((len(rgb), 1), 255, dtype=np.uint8)], axis=1)

    out = args.output
    if out.suffix.lower() == ".ply":
        m.export(str(out))
        print(f"wrote {out}")
        return

    # USD / USDZ path: reuse ply_to_usd's writer with shading=emissive.
    import sys
    sys.path.insert(0, str(Path(__file__).parent))
    from ply_to_usd import write_usd
    write_usd(m, out, args.up, shading="emissive", gamma=1.0, intensity=1.0)


if __name__ == "__main__":
    main()
