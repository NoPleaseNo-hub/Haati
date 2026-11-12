# 05 — CAD/CSG Level Design, `.fmesh` & Voxel SDF Destruction

---

## 1. Non-Destructive Half-Space CSG (`plugins/cad_csg/`)
- **Core Files**:
  - [`component_csg_volume.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/cad_csg/component_csg_volume.odin): `CSGVolume` component (`Additive`, `Subtractive`, `Intersect`; `Box`, `Cylinder`, `Sphere`, `Wedge`, `Convex_Hull`, `Custom_Poly`).
  - [`csg_solver.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/cad_csg/csg_solver.odin): Sutherland-Hodgman half-space polygon clipper with coplanar `ON_PLANE` splitting and wound inner-cap generation.
  - [`editor/cad_csg_editor.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/cad_csg/editor/cad_csg_editor.odin): Interactive face pull/push handles, 2D Sketch-to-Extrude (`L` line, `A` arc, `E` extrude), and Blender-style `V` / `E` / `F` Vertex/Edge/Face poly editing (`TAB`).

---

## 2. Faker CSG (`.fmesh`) Asset Pipeline ([`faker_mesh_io.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/cad_csg/faker_mesh_io.odin))
- `.fmesh` is Moonhug's native human-readable JSON mesh + CSG brush hierarchy format:
  - Stores vertices, normals, UVs, sub-meshes, material slots, and optional non-destructive CSG brush history.
  - Supports exporting to `.fmesh` or `.obj`, baking compound boolean brushes into a single static mesh, and generating matched Jolt physics colliders.

---

## 3. *Severed Steel*-Style Lazy Chunked Voxel SDF Destruction
- **Design**:
  - Static CSG/poly meshes have **zero voxel memory overhead** until the moment a destruction sphere/capsule/beam carves into them.
  - On first impact, only the intersected $16^3$ spatial chunks (`Voxel_Chunk_Key`) are lazily allocated and initialized from the analytic brush SDF (`smin` / `smax` smooth CSG booleans), carved with smooth subtraction (`op_smooth_subtract`), and meshed via Surface Nets / Dual Contouring with triplanar interior damage UVs.
