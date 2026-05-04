"""PLY (vertex-colored) -> USD/USDZ for Isaac Sim.

Usage:
    pip install trimesh usd-core numpy
    python3 ply_to_usd.py <input.ply> <output.usd|output.usdz> \
        [--min-component-faces 200] [--up Z]

Notes:
- Binds a UsdPreviewSurface that reads primvars:displayColor so the RTX
  viewport in Isaac Sim renders the vertex colors instead of flat gray.
- --min-component-faces drops small disconnected islands (the floaters
  you saw in your CloudCompare screenshot). 0 disables.
- --up Z|Y sets the stage's up-axis metadata (M2Mapping is Z-up).
"""
import argparse
from pathlib import Path

import numpy as np
import trimesh
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, Vt


def load_and_clean(ply_path: Path, min_component_faces: int) -> trimesh.Trimesh:
    m = trimesh.load(str(ply_path), process=False, force="mesh")
    print(f"loaded: {len(m.vertices)} verts, {len(m.faces)} faces")

    if min_component_faces > 0:
        comps = m.split(only_watertight=False)
        keep = [c for c in comps if len(c.faces) >= min_component_faces]
        if not keep:
            raise RuntimeError("all components dropped; lower --min-component-faces")
        m = trimesh.util.concatenate(keep)
        print(f"after floater removal: {len(m.vertices)} verts, {len(m.faces)} faces "
              f"(kept {len(keep)}/{len(comps)} components)")
    return m


def write_usd(m: trimesh.Trimesh, out_path: Path, up_axis: str,
              shading: str = "emissive", gamma: float = 2.2, intensity: float = 1.0) -> None:
    is_usdz = out_path.suffix.lower() == ".usdz"
    usd_path = out_path.with_suffix(".usd") if is_usdz else out_path

    stage = Usd.Stage.CreateNew(str(usd_path))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z if up_axis.upper() == "Z"
                           else UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    stage.SetDefaultPrim(UsdGeom.Xform.Define(stage, "/World").GetPrim())

    mesh = UsdGeom.Mesh.Define(stage, "/World/Mesh")
    mesh.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(m.vertices.astype(np.float32)))
    mesh.CreateFaceVertexCountsAttr(
        Vt.IntArray.FromNumpy(np.full(len(m.faces), 3, dtype=np.int32)))
    mesh.CreateFaceVertexIndicesAttr(
        Vt.IntArray.FromNumpy(m.faces.astype(np.int32).flatten()))
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)

    colors = m.visual.vertex_colors[:, :3].astype(np.float32) / 255.0
    if gamma != 1.0:
        colors = np.power(colors, gamma)
    if intensity != 1.0:
        colors = np.clip(colors * intensity, 0.0, 1.0)
    primvars_api = UsdGeom.PrimvarsAPI(mesh)
    color_pv = primvars_api.CreatePrimvar(
        "displayColor", Sdf.ValueTypeNames.Color3fArray, UsdGeom.Tokens.vertex)
    color_pv.Set(Vt.Vec3fArray.FromNumpy(colors))

    mat_path = "/World/Looks/VertexColorMat"
    UsdGeom.Scope.Define(stage, "/World/Looks")
    material = UsdShade.Material.Define(stage, mat_path)

    shader = UsdShade.Shader.Define(stage, mat_path + "/Surface")
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(1.0)
    shader.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)

    reader = UsdShade.Shader.Define(stage, mat_path + "/ColorReader")
    reader.CreateIdAttr("UsdPrimvarReader_float3")
    reader.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("displayColor")
    reader.CreateOutput("result", Sdf.ValueTypeNames.Float3)

    if shading == "emissive":
        # Unlit look: colors render as-is, independent of scene lighting.
        # diffuseColor = black so reflected light doesn't double-illuminate.
        shader.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(
            reader.GetOutput("result"))
        shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set((0.0, 0.0, 0.0))
    else:
        shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(
            reader.GetOutput("result"))
    material.CreateSurfaceOutput().ConnectToSource(
        shader.CreateOutput("surface", Sdf.ValueTypeNames.Token))
    UsdShade.MaterialBindingAPI(mesh).Bind(material)

    stage.GetRootLayer().Save()
    print(f"wrote {usd_path}")

    if is_usdz:
        from pxr import UsdUtils
        UsdUtils.CreateNewUsdzPackage(str(usd_path), str(out_path))
        print(f"packaged {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input_ply", type=Path)
    ap.add_argument("output", type=Path, help="*.usd or *.usdz")
    ap.add_argument("--min-component-faces", type=int, default=200,
                    help="drop connected components smaller than this (0 = keep all)")
    ap.add_argument("--up", default="Z", choices=["Z", "Y", "z", "y"])
    ap.add_argument("--shading", default="emissive", choices=["emissive", "diffuse"],
                    help="emissive: unlit, vertex colors render as-is (best for NeRF-style "
                         "meshes; appearance independent of scene lights). diffuse: physically "
                         "lit, requires scene lighting (dome light etc).")
    ap.add_argument("--gamma", type=float, default=2.2,
                    help="sRGB-to-linear gamma applied to vertex colors. PLY stores sRGB; "
                         "Isaac Sim's RTX shader expects linear inputs. 2.2 is correct for "
                         "most cases; 1.0 disables conversion.")
    ap.add_argument("--intensity", type=float, default=1.0,
                    help="multiply colors by this scalar after gamma correction. "
                         "Lower if Isaac Sim's tone-map still over-exposes.")
    args = ap.parse_args()

    m = load_and_clean(args.input_ply, args.min_component_faces)
    write_usd(m, args.output, args.up, args.shading, args.gamma, args.intensity)


if __name__ == "__main__":
    main()
