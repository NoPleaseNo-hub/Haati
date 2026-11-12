package control_rig

// ArmatureDeformedMesh: High-flexibility skeletal & hybrid mesh renderer for the Control Rig system.
// Features:
// 1. Hybrid Mesh Support: Accurately deforms skeletal meshes via joint palettes, while also supporting
//    unskinned static meshes (armor attachments, weapons, props) transformed by the actor or root bone.
// 2. Level Transform Anchoring: Binds deformation relative to the actor's transform in the level so the
//    character never sits frozen at world (0,0,0) or detaches from level placement.
// 3. Auto Material & Texture Resolution: Automatically associates textured materials so meshes never render blank.
// 4. Control Rig Synergy: Directly syncs with ControlRig component bone resolvers and Euphoria dynamics.

import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import cgltf "vendor:cgltf"
import engine "moonhug:engine"
import gfx "moonhug:engine/gfx"
import cad_csg "moonhug:packages/cad_csg"
import physics3d "moonhug:packages/physics3d"

@(component={menu="Animation/ArmatureDeformedMesh"})
@(typ_guid={guid = "9b4c718a-64d2-4e89-a215-3e91f07b1d42"})
ArmatureDeformedMesh :: struct {
	using base:             engine.CompData `inspect:"-"`,

	// Mesh reference (supports .glb, .gltf submeshes, and .mesh)
	mesh:                   engine.Asset_GUID `ext:"mesh,glb,gltf"`,
	materials:              [dynamic]engine.Asset_GUID `ext:"mat" expand`,

	// Where joint names are resolved from. Unset searches actor or parent subtree.
	root_bone:              engine.Ref_Local `ref:"Transform"`,

	// Guarantees the mesh moves with the character actor's level transform
	anchor_to_actor:        bool,

	// If true, static (unskinned) meshes render rigidly attached to actor/bone rather than disappearing
	allow_static_mesh:      bool,

	// Auto-resolves default material/texture when materials array is empty
	auto_resolve_materials: bool,

	// Cast real-time planar floor shadows from active shadow-casting lights in the scene
	cast_shadows:           bool,

	// Custom bones & weight overrides (persisted per entity in .scene)
	custom_joint_names:     [dynamic]string `expand`,
	custom_inverse_binds:   [dynamic]matrix[4, 4]f32 `inspect:"-"`,
	custom_skin:            [dynamic]engine.Mesh_Skin_Vertex `inspect:"-"`,

	// Runtime state
	joints:                 [dynamic]engine.Transform_Handle `json:"-" inspect:"-"`,
	posed:                  [dynamic]gfx.Vertex `json:"-" inspect:"-"`,
	gpu:                    gfx.Dynamic_Mesh `json:"-" inspect:"-"`,
	gpu_wire:               gfx.Mesh `json:"-" inspect:"-"`,
	shadow_mesh_guid:       engine.Asset_GUID `json:"-" inspect:"-"`,
	bound_guid:             engine.Asset_GUID `json:"-" inspect:"-"`,
	bound_part:             i32 `json:"-" inspect:"-"`,
	bound_root:             engine.Transform_Handle `json:"-" inspect:"-"`,
	bound_ready:            bool `json:"-" inspect:"-"`,
	posed_frame:            u64 `json:"-" inspect:"-"`,
	is_skinned:             bool `json:"-" inspect:"-"`,
	posed_min:              [3]f32 `json:"-" inspect:"-"`,
	posed_max:              [3]f32 `json:"-" inspect:"-"`,

	// Performance & pose caching
	last_palette:           [dynamic]matrix[4, 4]f32 `json:"-" inspect:"-"`,
	last_heatmap_idx:       int `json:"-" inspect:"-"`,
	last_heatmap_show:      bool `json:"-" inspect:"-"`,
	last_skin_count:        int `json:"-" inspect:"-"`,
	last_ghoul_blast_sig:   u64 `json:"-" inspect:"-"`,
	ghoul_clipped_guid:     engine.Asset_GUID `json:"-" inspect:"-"`,
	ghoul_cut_material_guid:engine.Asset_GUID `json:"-" inspect:"-"`,
	ghoul_active:           bool `json:"-" inspect:"-"`,
}

reset_ArmatureDeformedMesh :: proc(adm: ^ArmatureDeformedMesh) {
	adm.anchor_to_actor = true
	adm.allow_static_mesh = true
	adm.auto_resolve_materials = true
	adm.cast_shadows = true
	adm.bound_ready = false
	adm.last_heatmap_idx = -1
}

on_destroy_ArmatureDeformedMesh :: proc(adm: ^ArmatureDeformedMesh) {
	cleanup_ArmatureDeformedMesh(adm)
}

cleanup_ArmatureDeformedMesh :: proc(adm: ^ArmatureDeformedMesh) {
	if adm.bound_ready {
		gfx.dynamic_mesh_destroy(&adm.gpu)
		if adm.gpu_wire.ibuf != nil do gfx.dynamic_mesh_destroy_wire_indices(&adm.gpu_wire)
	}
	if !engine.asset_guid_is_empty(adm.shadow_mesh_guid) {
		engine.mesh_remove_procedural(adm.shadow_mesh_guid)
		adm.shadow_mesh_guid = {}
	}
	if !engine.asset_guid_is_empty(adm.ghoul_clipped_guid) {
		engine.mesh_remove_procedural(adm.ghoul_clipped_guid)
		adm.ghoul_clipped_guid = {}
	}
	delete(adm.joints)
	delete(adm.posed)
	delete(adm.last_palette)
	if adm.materials != nil do delete(adm.materials)
	for n in adm.custom_joint_names do delete(n)
	delete(adm.custom_joint_names)
	delete(adm.custom_inverse_binds)
	delete(adm.custom_skin)
	engine.comp_zero(adm)
}

armature_deformed_mesh_rebind :: proc(adm: ^ArmatureDeformedMesh) {
	adm.bound_ready = false
}

@(private = "file")
_spawn_gltf_bone_tree :: proc(data: ^cgltf.data, node: ^cgltf.node, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	name := string(node.name) if node.name != nil && len(string(node.name)) > 0 else fmt.tprintf("node_%d", cgltf.node_index(data, node))
	tH := engine.transform_new(name, parent)
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t != nil {
		if node.has_translation do t.position = node.translation
		if node.has_rotation do t.rotation = node.rotation
		if node.has_scale do t.scale = node.scale
	}
	for child in node.children {
		if child.mesh != nil && len(child.children) == 0 do continue
		_spawn_gltf_bone_tree(data, child, tH)
	}
	return tH
}

armature_deformed_mesh_spawn_skeleton :: proc(adm: ^ArmatureDeformedMesh) {
	w := engine.ctx_world()
	if w == nil do return

	owner_h := engine.Transform_Handle(adm.owner)
	if owner_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner_h)) do return

	mesh_guid := adm.mesh
	if engine.asset_guid_is_empty(mesh_guid) {
		_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
		if mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
			mesh_guid = mf.mesh.guid
		}
	}
	if engine.asset_guid_is_empty(mesh_guid) do return

	// 1. Clean up any existing "Armature" subtree under owner to prevent duplicate/corrupted bones
	ot := engine.pool_get(&w.transforms, engine.Handle(owner_h))
	if ot != nil {
		to_destroy := make([dynamic]engine.Transform_Handle, context.temp_allocator)
		for child in ot.children {
			ch := engine.Transform_Handle(child.handle)
			ct := engine.pool_get(&w.transforms, engine.Handle(ch))
			if ct != nil && strings.equal_fold(ct.name, "Armature") {
				append(&to_destroy, ch)
			}
		}
		for h in to_destroy {
			engine.transform_destroy(h)
		}
	}

	// 2. Attempt glTF parsing to reconstruct the true hierarchical bone tree with authentic rest orientations
	source_path, path_ok := engine.asset_db_get_path(uuid.Identifier(mesh_guid))
	gltf_spawned := false
	armature_root_h: engine.Transform_Handle = {}

	if path_ok {
		path_c := strings.clone_to_cstring(source_path, context.temp_allocator)
		opts := cgltf.options{}
		data, parse_res := cgltf.parse_file(opts, path_c)
		if parse_res == .success {
			defer cgltf.free(data)
			for &node in data.nodes {
				if node.parent == nil {
					if node.mesh != nil && len(node.children) == 0 do continue
					h := _spawn_gltf_bone_tree(data, &node, owner_h)
					if armature_root_h == {} do armature_root_h = h
					gltf_spawned = true
				}
			}
		}
	}

	// 3. Fallback if glTF source file was not available
	if !gltf_spawned {
		mesh, ok := engine.mesh_load(mesh_guid, adm.bound_part)
		if !ok || mesh == nil || len(mesh.joint_names) == 0 do return

		armature_root_h = engine.transform_new("Armature", owner_h)
		for i in 0 ..< len(mesh.joint_names) {
			name := mesh.joint_names[i]
			b_h := engine.transform_new(name, armature_root_h)
			if i < len(mesh.inverse_binds) {
				bind_m := linalg.inverse(mesh.inverse_binds[i])
				pos := bind_m[3].xyz
				engine.transform_set_local_position(b_h, pos)
			}
		}
	}

	if armature_root_h != {} {
		adm.root_bone = engine.Ref_Local{handle = engine.Handle(armature_root_h)}
	}
	adm.bound_ready = false

	if s := engine.sm_scene_get_active(); s != nil {
		s.dirty = true
	}
}

armature_deformed_mesh_reset_bind_pose :: proc(adm: ^ArmatureDeformedMesh) {
	w := engine.ctx_world()
	if w == nil do return

	owner_h := engine.Transform_Handle(adm.owner)
	if owner_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner_h)) do return

	adm.bound_ready = false
	adm.posed_frame = 0

	// When resetting to bind pose, we keep the rig active and will sync controls to rest pose
	_, rig := engine.transform_get_comp(owner_h, ControlRig)
	ot := engine.pool_get(&w.transforms, engine.Handle(owner_h))

	if s := engine.sm_scene_get_active(); s != nil {
		s.dirty = true
	}

	mesh_guid := adm.mesh
	if engine.asset_guid_is_empty(mesh_guid) {
		_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
		if mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
			mesh_guid = mf.mesh.guid
		}
	}
	if engine.asset_guid_is_empty(mesh_guid) do return

	search_root := owner_h
	if adm.root_bone.handle != {} && engine.pool_valid(&w.transforms, adm.root_bone.handle) {
		search_root = engine.Transform_Handle(adm.root_bone.handle)
	} else if ot != nil && ot.parent.handle != {} {
		parent_h := engine.Transform_Handle(ot.parent.handle)
		pt := engine.pool_get(&w.transforms, engine.Handle(parent_h))
		if pt != nil && pt.parent.handle != {} {
			search_root = parent_h
		}
	}

	// If no skeleton hierarchy exists yet under the actor, auto-detect or spawn it first
	if adm.root_bone.handle == {} || !engine.pool_valid(&w.transforms, adm.root_bone.handle) {
		has_bones := false
		if ot != nil {
			for child in ot.children {
				ch := engine.Transform_Handle(child.handle)
				ct := engine.pool_get(&w.transforms, engine.Handle(ch))
				if ct != nil && (strings.equal_fold(ct.name, "Armature") || strings.equal_fold(ct.name, "root") || strings.equal_fold(ct.name, "Hips") || strings.equal_fold(ct.name, "Pelvis")) {
					has_bones = true
					adm.root_bone = engine.Ref_Local{handle = engine.Handle(ch)}
					search_root = ch
					break
				}
			}
		}
		if !has_bones {
			armature_deformed_mesh_spawn_skeleton(adm)
			if adm.root_bone.handle != {} && engine.pool_valid(&w.transforms, adm.root_bone.handle) {
				search_root = engine.Transform_Handle(adm.root_bone.handle)
			}
		}
	}

	source_path, path_ok := engine.asset_db_get_path(uuid.Identifier(mesh_guid))
	gltf_reset := false

	if path_ok {
		path_c := strings.clone_to_cstring(source_path, context.temp_allocator)
		opts := cgltf.options{}
		data, parse_res := cgltf.parse_file(opts, path_c)
		if parse_res == .success {
			defer cgltf.free(data)
			for &node in data.nodes {
				if node.name == nil do continue
				name := string(node.name)
				if len(name) == 0 do continue

				bone_h, found := _adm_find_bone_recursive(search_root, name)
				if !found && search_root != owner_h {
					bone_h, found = _adm_find_bone_recursive(owner_h, name)
				}
				// Crucial safety check: NEVER modify the actor itself or the scene root!
				if found && bone_h != {} && bone_h != owner_h {
					bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
					if bt != nil && bt.parent.handle != {} {
						bt.position = node.translation if node.has_translation else [3]f32{0, 0, 0}
						bt.rotation = node.rotation if node.has_rotation else [4]f32{0, 0, 0, 1}
						bt.scale = node.scale if node.has_scale else [3]f32{1, 1, 1}
						gltf_reset = true
					}
				}
			}
		}
	}

	if !gltf_reset {
		mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
		if mok && mesh != nil && len(mesh.joint_names) > 0 {
			mesh_mats := make([]matrix[4, 4]f32, len(mesh.inverse_binds), context.temp_allocator)
			for i in 0 ..< len(mesh.inverse_binds) {
				mesh_mats[i] = linalg.inverse(mesh.inverse_binds[i])
			}

			for i in 0 ..< len(mesh.joint_names) {
				name := mesh.joint_names[i]
				bone_h, found := _adm_find_bone_recursive(search_root, name)
				if !found && search_root != owner_h {
					bone_h, found = _adm_find_bone_recursive(owner_h, name)
				}
				if found && bone_h != {} && bone_h != owner_h && i < len(mesh.inverse_binds) {
					bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
					if bt == nil || bt.parent.handle == {} do continue

					m_parent := linalg.MATRIX4F32_IDENTITY
					if bt.parent.handle != {} {
						parent_h := engine.Transform_Handle(bt.parent.handle)
						parent_t := engine.pool_get(&w.transforms, engine.Handle(parent_h))
						if parent_t != nil {
							for p_idx in 0 ..< len(mesh.joint_names) {
								if strings.equal_fold(mesh.joint_names[p_idx], parent_t.name) && p_idx < len(mesh_mats) {
									m_parent = mesh_mats[p_idx]
									break
								}
							}
						}
					}

					m_bone := mesh_mats[i]
					m_local := linalg.inverse(m_parent) * m_bone

					bt.position = m_local[3].xyz
					col0 := m_local[0].xyz
					col1 := m_local[1].xyz
					col2 := m_local[2].xyz
					sx := linalg.length(col0)
					sy := linalg.length(col1)
					sz := linalg.length(col2)
					bt.scale = [3]f32{sx, sy, sz}
					c0 := col0 / sx if sx > 0.0001 else [3]f32{1, 0, 0}
					c1 := col1 / sy if sy > 0.0001 else [3]f32{0, 1, 0}
					c2 := col2 / sz if sz > 0.0001 else [3]f32{0, 0, 1}
					rot_mat := matrix[3, 3]f32{
						c0.x, c1.x, c2.x,
						c0.y, c1.y, c2.y,
						c0.z, c1.z, c2.z,
					}
					bt.rotation = engine.quat_from_native(linalg.quaternion_from_matrix3(rot_mat))
				}
			}
		}
	}

	adm.bound_ready = false
	adm.posed_frame = 0

	target_rig := rig
	if target_rig == nil && ot != nil && ot.parent.handle != {} {
		_, prig := engine.transform_get_comp(engine.Transform_Handle(ot.parent.handle), ControlRig)
		target_rig = prig
	}
	if target_rig != nil {
		// Re-capture authentic rest pose while bones are in their restored glTF bind transforms
		skeleton_bind_humanoid(&target_rig.bones, target_rig.owner)
		control_rig_sync_from_skeleton(target_rig)
	}
	if _, hpd := engine.transform_get_comp(owner_h, HandPoseDriver); hpd != nil {
		hand_pose_driver_rebind(hpd)
	} else if target_rig != nil {
		if _, phpd := engine.transform_get_comp(target_rig.owner, HandPoseDriver); phpd != nil {
			hand_pose_driver_rebind(phpd)
		}
	}

	if s := engine.sm_scene_get_active(); s != nil {
		s.dirty = true
	}
}

// Collector registered into engine.render_register_collector
@(phase={key=engine.Phase.ImportersInit, order=3})
armature_deformed_mesh_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.render_register_collector(_collect_armature_deformed_meshes)
}

@(private = "file")
_collect_armature_deformed_meshes :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	w := engine.ctx_world()
	if w == nil do return

	it := engine.pool_iterator(armature_deformed_meshes(w))
	for adm, _ in engine.pool_next(&it) {
		if !adm.enabled do continue
		owner_h := engine.Transform_Handle(adm.owner)
		t := engine.pool_get(&w.transforms, engine.Handle(owner_h))
		if t == nil || !engine.transform_active_in_hierarchy(adm.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		// Determine mesh GUID & part
		mesh_guid := adm.mesh
		part: i32 = 0
		if engine.asset_guid_is_empty(mesh_guid) {
			// Fallback: check sibling MeshFilter on the same entity
			_, mf := engine.transform_get_comp(owner_h, engine.MeshFilter)
			if mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
				mesh_guid = mf.mesh.guid
				if p, ok := engine.mesh_filter_part(mf); ok do part = p
			}
		}

		if engine.asset_guid_is_empty(mesh_guid) do continue

		mesh, mesh_ok := engine.mesh_load(mesh_guid, part)
		if !mesh_ok do continue

		is_mesh_skinned := engine.mesh_is_skinned(mesh)
		adm.is_skinned = is_mesh_skinned

		// 1. Static Mesh Branch (armor, weapon, prop, or unrigged model)
		if !is_mesh_skinned {
			if !adm.allow_static_mesh do continue

			actor_tw := engine.transform_world(owner_h)
			model_mat := engine.trs_matrix(actor_tw.position, actor_tw.rotation, actor_tw.scale)

			// If a root_bone is explicitly set, attach to that bone instead
			if adm.root_bone.handle != {} && engine.pool_valid(&w.transforms, adm.root_bone.handle) {
				bone_tw := engine.transform_world(engine.Transform_Handle(adm.root_bone.handle))
				model_mat = engine.trs_matrix(bone_tw.position, bone_tw.rotation, bone_tw.scale)
			}

			append(out, engine.Render_Command{
				owner   = owner_h,
				variant = engine.Draw_Mesh{
					mesh      = mesh_guid,
					part      = part,
					materials = adm.materials[:],
					model     = model_mat,
				},
			})
			if adm.cast_shadows && view.kind != .Preview {
				_emit_armature_planar_shadows(w, adm, mesh, owner_h, model_mat, false, out)
			}
			continue
		}

		// 2. Skinned Mesh Branch
		if adm.bound_ready && !_adm_joints_alive(adm) {
			adm.bound_ready = false
		}

		if !_adm_bind(adm, mesh, mesh_guid, part, owner_h) do continue

		_adm_skin_pose(adm, mesh, owner_h)
		adm.posed_frame = gfx.frame_index

		// Hardware wireframe overlay: if active, draws topological line edges directly over posed vertices
		wire_mesh_ptr: ^gfx.Mesh = nil
		wire_col := [4]f32{0, 0, 0, 0}
		is_heatmap := ((show_bone_weights_heatmap && active_heatmap_joint_idx >= 0) || weight_painting_active) && heatmap_shading_unlit
		if show_mesh_wireframe && adm.gpu_wire.index_count > 0 && adm.gpu_wire.ibuf != nil {
			if weight_painting_active || show_bone_weights_heatmap {
				adm.gpu_wire.vbuf = adm.gpu.mesh.vbuf
				wire_mesh_ptr = &adm.gpu_wire
				wire_col = wireframe_overlay_color
			}
		}

		// Draw deformed mesh (or procedural Ghoul-clipped mesh when sliced/blasted/boolean-cut!)
		use_ghoul_mesh := adm.ghoul_active && !is_heatmap && !engine.asset_guid_is_empty(adm.ghoul_clipped_guid) && engine.mesh_is_cached(adm.ghoul_clipped_guid)
		draw_mats := adm.materials[:]
		if use_ghoul_mesh && !engine.asset_guid_is_empty(adm.ghoul_cut_material_guid) {
			ext_mats := make([]engine.Asset_GUID, len(adm.materials) + 1, context.temp_allocator)
			copy(ext_mats[:len(adm.materials)], adm.materials[:])
			ext_mats[len(adm.materials)] = adm.ghoul_cut_material_guid
			draw_mats = ext_mats
		}
		append(out, engine.Render_Command{
			owner   = owner_h,
			variant = engine.Draw_Mesh{
				mesh          = adm.ghoul_clipped_guid if use_ghoul_mesh else mesh_guid,
				part          = 0 if use_ghoul_mesh else part,
				materials     = draw_mats,
				model         = linalg.MATRIX4F32_IDENTITY,
				skinned       = nil if use_ghoul_mesh else &adm.gpu.mesh,
				wire_mesh     = nil if use_ghoul_mesh else wire_mesh_ptr,
				wire_color    = wire_col,
				unlit_heatmap = is_heatmap,
			},
		})
		if adm.cast_shadows && view.kind != .Preview {
			_emit_armature_planar_shadows(w, adm, mesh, owner_h, linalg.MATRIX4F32_IDENTITY, true, out)
		}
	}
}

@(private = "file")
_make_adm_ghoul_guid :: proc(tH: engine.Transform_Handle) -> engine.Asset_GUID {
	raw: [16]u8
	h_bits := transmute(u64)tH
	raw[0] = 0x47 // 'G'
	raw[1] = 0x48 // 'H'
	raw[2] = 0x4F // 'O'
	raw[3] = 0x55 // 'U'
	for i in 0 ..< 8 {
		raw[4 + i] = u8((h_bits >> (uint(i) * 8)) & 0xFF)
	}
	raw[12] = 0x99
	return engine.Asset_GUID(raw)
}

@(private = "file")
_make_adm_shadow_guid :: proc(tH: engine.Transform_Handle) -> engine.Asset_GUID {
	raw: [16]u8
	h_bits := transmute(u64)tH
	raw[0] = 0x41 // 'A'
	raw[1] = 0x44 // 'D'
	raw[2] = 0x4D // 'M'
	raw[3] = 0x53 // 'S'
	for i in 0 ..< 8 {
		raw[4 + i] = u8((h_bits >> (uint(i) * 8)) & 0xFF)
	}
	raw[12] = 0x77
	raw[13] = 0x88
	raw[14] = 0x99
	raw[15] = 0xAA
	return engine.Asset_GUID(raw)
}

// Projects real-time planar floor shadows for `ArmatureDeformedMesh` from ALL active shadow-casting
// lights in the scene that are within `light.range` of the character!
@(private = "file")
_emit_armature_planar_shadows :: proc(
	w:          ^engine.World,
	adm:        ^ArmatureDeformedMesh,
	mesh:       ^engine.Mesh,
	owner_h:    engine.Transform_Handle,
	model_mat:  matrix[4, 4]f32,
	is_skinned: bool,
	out:        ^[dynamic]engine.Render_Command,
) {
	if engine.asset_guid_is_empty(adm.shadow_mesh_guid) {
		adm.shadow_mesh_guid = _make_adm_shadow_guid(owner_h)
	}

	verts := adm.posed[:] if is_skinned else mesh.bind_vertices
	inds  := mesh.bind_indices
	if len(verts) < 3 || len(inds) < 3 do return

	mesh_center: [3]f32
	if is_skinned {
		mesh_center = (adm.posed_min + adm.posed_max) * 0.5
	} else {
		c_local := (mesh.aabb_min + mesh.aabb_max) * 0.5
		mesh_center = (model_mat * [4]f32{c_local.x, c_local.y, c_local.z, 1.0}).xyz
	}

	sh_verts := make([dynamic]gfx.Vertex, 0, 512, context.temp_allocator)
	sh_inds  := make([dynamic]u32, 0, 512, context.temp_allocator)

	tri_count := len(inds) / 3
	tri_step  := max(tri_count / 1200, 1)

	Adm_Shadow_Light :: struct {
		kind:      engine.Light_Type,
		pos:       [3]f32,
		to_l:      [3]f32,
		fwd:       [3]f32,
		outer_cos: f32,
		range:     f32,
		intensity: f32,
		ambient:   f32,
		strength:  f32,
		ground_y:  f32,
	}
	adm_lights := make([dynamic]Adm_Shadow_Light, 0, 8, context.temp_allocator)

	l_it := engine.pool_iterator(engine.lights(w))
	for l, _ in engine.pool_next(&l_it) {
		if !l.enabled || !l.cast_shadows || l.intensity <= 0.01 do continue
		if !engine.transform_active_in_hierarchy(l.owner) do continue
		ltw := engine.transform_world(engine.Transform_Handle(l.owner))
		rot := engine.quat_to_matrix3(ltw.rotation)
		fwd := linalg.normalize0([3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]})
		to_l := -fwd
		if to_l.y < -0.08 {
			to_l = -to_l
		} else if abs(to_l.y) <= 0.08 {
			to_l = linalg.normalize0([3]f32{to_l.x, 0.65, to_l.z})
		}
		append(&adm_lights, Adm_Shadow_Light{
			kind      = l.type,
			pos       = ltw.position,
			to_l      = to_l,
			fwd       = fwd,
			outer_cos = math.cos(math.to_radians(max(l.spot_angle, l.inner_spot_angle)) * 0.5),
			range     = max(l.range, 1.0),
			intensity = max(l.intensity, 0.05),
			ambient   = clamp(l.ambient, 0.05, 0.85),
			strength  = clamp(l.shadow_strength if l.shadow_strength > 0.01 else 0.72, 0.05, 1.0),
			ground_y  = l.shadow_ground_y,
		})
	}

	eval_adm_light_illum :: proc(al: Adm_Shadow_Light, pt: [3]f32) -> f32 {
		if al.kind == .Directional do return al.intensity * max(al.to_l.y, 0.15)
		diff := pt - al.pos
		d2 := linalg.length2(diff)
		if d2 >= al.range * al.range do return 0.0
		dist := math.sqrt(d2)
		ratio := dist / al.range
		a := clamp(1.0 - ratio * ratio, 0.0, 1.0)
		atten := a * a
		if al.kind == .Spot && dist > 1e-4 {
			cos_a := linalg.dot(diff / dist, al.fwd)
			atten *= clamp((cos_a - al.outer_cos) / 0.15, 0.0, 1.0)
		}
		return al.intensity * clamp(-diff.y / max(dist, 0.001), 0.15, 1.0) * atten
	}

	poly_a := make([dynamic][3]f32, 0, 16, context.temp_allocator)
	poly_b := make([dynamic][3]f32, 0, 16, context.temp_allocator)

	for al, light_idx in adm_lights {
		if al.kind != .Directional {
			if linalg.length(mesh_center - al.pos) > al.range do continue
		}
		if al.kind == .Spot {
			dir_to_char := linalg.normalize0(mesh_center - al.pos)
			if linalg.dot(dir_to_char, al.fwd) < al.outer_cos - 0.18 do continue
		}

		ground_y := al.ground_y
		receivers, _ := cad_csg.csg_collect_ground_receivers(ground_y, context.temp_allocator)
		if len(receivers) == 0 do continue // No floor receiver at `ground_y` -> do not cast shadows into empty air!

		y_step   := 0.015 + f32(light_idx) * 0.0012
		shadow_y := ground_y + y_step
		to_l     := al.to_l

		for ti := 0; ti < tri_count; ti += tri_step {
			i0 := inds[ti * 3 + 0]
			i1 := inds[ti * 3 + 1]
			i2 := inds[ti * 3 + 2]
			if int(i0) >= len(verts) || int(i1) >= len(verts) || int(i2) >= len(verts) do continue

			w0 := verts[i0].position
			w1 := verts[i1].position
			w2 := verts[i2].position
			if !is_skinned {
				w0 = (model_mat * [4]f32{w0.x, w0.y, w0.z, 1.0}).xyz
				w1 = (model_mat * [4]f32{w1.x, w1.y, w1.z, 1.0}).xyz
				w2 = (model_mat * [4]f32{w2.x, w2.y, w2.z, 1.0}).xyz
			}

			max_y := max(w0.y, max(w1.y, w2.y))
			if max_y <= ground_y + 0.05 do continue

			p0, p1, p2: [3]f32
			if al.kind == .Directional {
				inv_ly := 1.0 / max(to_l.y, 0.18)
				h0 := max(w0.y - ground_y, 0.0)
				h1 := max(w1.y - ground_y, 0.0)
				h2 := max(w2.y - ground_y, 0.0)
				p0 = {w0.x - to_l.x * h0 * inv_ly, shadow_y, w0.z - to_l.z * h0 * inv_ly}
				p1 = {w1.x - to_l.x * h1 * inv_ly, shadow_y, w1.z - to_l.z * h1 * inv_ly}
				p2 = {w2.x - to_l.x * h2 * inv_ly, shadow_y, w2.z - to_l.z * h2 * inv_ly}
			} else {
				dy0 := max(al.pos.y - w0.y, 0.25)
				dy1 := max(al.pos.y - w1.y, 0.25)
				dy2 := max(al.pos.y - w2.y, 0.25)
				t0 := clamp(max(w0.y - ground_y, 0.0) / dy0, 0.0, 4.0)
				t1 := clamp(max(w1.y - ground_y, 0.0) / dy1, 0.0, 4.0)
				t2 := clamp(max(w2.y - ground_y, 0.0) / dy2, 0.0, 4.0)
				p0 = {w0.x + (w0.x - al.pos.x) * t0, shadow_y, w0.z + (w0.z - al.pos.z) * t0}
				p1 = {w1.x + (w1.x - al.pos.x) * t1, shadow_y, w1.z + (w1.z - al.pos.z) * t1}
				p2 = {w2.x + (w2.x - al.pos.x) * t2, shadow_y, w2.z + (w2.z - al.pos.z) * t2}
			}

			cr := linalg.cross(p1 - p0, p2 - p0)
			if abs(cr.y) < 1e-5 do continue
			if cr.y < 0 do p1, p2 = p2, p1

			mid_p := (p0 + p1 + p2) * (1.0 / 3.0)
			c_ill := eval_adm_light_illum(al, mid_p)
			if c_ill <= 0.005 do continue
			o_ill: f32 = 0.0
			for ol, o_idx in adm_lights {
				if o_idx == light_idx do continue
				o_ill += eval_adm_light_illum(ol, mid_p)
			}
			tot_ill := max(al.ambient + (1.0 - al.ambient) * (c_ill + o_ill), 0.05)
			drop_f  := (((1.0 - al.ambient) * c_ill * al.strength) / tot_ill) * (c_ill / max(c_ill + 1.35 * o_ill, 0.001))
			if drop_f < 0.10 do continue
			keep_f := clamp(1.0 - drop_f, 0.16, 1.0)
			sh_col := [4]u8{
				u8(clamp(145.0 * keep_f, 16.0, 148.0)),
				u8(clamp(152.0 * keep_f, 18.0, 155.0)),
				u8(clamp(164.0 * keep_f, 22.0, 168.0)),
				255,
			}

			t_min_x := min(p0.x, min(p1.x, p2.x))
			t_max_x := max(p0.x, max(p1.x, p2.x))
			t_min_z := min(p0.z, min(p1.z, p2.z))
			t_max_z := max(p0.z, max(p1.z, p2.z))

			for r in receivers {
				if t_max_x <= r.min_xz.x + 1e-3 || t_min_x >= r.max_xz.x - 1e-3 ||
				   t_max_z <= r.min_xz.y + 1e-3 || t_min_z >= r.max_xz.y - 1e-3 {
					continue
				}
				if r.plane_count == 0 &&
				   t_min_x >= r.min_xz.x && t_max_x <= r.max_xz.x &&
				   t_min_z >= r.min_xz.y && t_max_z <= r.max_xz.y {
					y_use := max(p0.y, r.top_y + y_step)
					bv := u32(len(sh_verts))
					append(&sh_verts,
						gfx.Vertex{position = {p0.x, y_use, p0.z}, normal = {0, 1, 0}, uv = {0, 0}, color = sh_col},
						gfx.Vertex{position = {p1.x, y_use, p1.z}, normal = {0, 1, 0}, uv = {0, 0}, color = sh_col},
						gfx.Vertex{position = {p2.x, y_use, p2.z}, normal = {0, 1, 0}, uv = {0, 0}, color = sh_col},
					)
					append(&sh_inds, bv, bv + 1, bv + 2)
					break
				}
				cad_csg.csg_clip_shadow_tri_to_receiver(p0, p1, p2, r, y_step, &poly_a, &poly_b)
				if len(poly_a) < 3 do continue
				bv := u32(len(sh_verts))
				for pt in poly_a {
					append(&sh_verts, gfx.Vertex{position = pt, normal = {0, 1, 0}, uv = {0, 0}, color = sh_col})
				}
				tri_n := u32(len(poly_a) - 2)
				for k in 0 ..< tri_n {
					append(&sh_inds, bv, bv + k + 1, bv + k + 2)
				}
			}
		}
	}

	if len(sh_verts) >= 3 && len(sh_inds) >= 3 {
		engine.mesh_upsert_procedural(adm.shadow_mesh_guid, sh_verts[:], sh_inds[:], nil, keep_cpu_buffers = false)
		append(out, engine.Render_Command{
			owner   = owner_h,
			variant = engine.Draw_Mesh{
				mesh  = adm.shadow_mesh_guid,
				part  = 0,
				model = linalg.MATRIX4F32_IDENTITY,
			},
		})
	} else {
		engine.mesh_remove_procedural(adm.shadow_mesh_guid)
	}
}

@(private = "file")
_adm_joints_alive :: proc(adm: ^ArmatureDeformedMesh) -> bool {
	w := engine.ctx_world()
	if w == nil do return false
	for h in adm.joints {
		if h == {} do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do return false
	}
	return true
}

@(private = "file")
_adm_find_bone_recursive :: proc(root: engine.Transform_Handle, name: string) -> (engine.Transform_Handle, bool) {
	return skeleton_find_bone_by_name(root, name)
}

@(private = "file")
_adm_bind :: proc(adm: ^ArmatureDeformedMesh, mesh: ^engine.Mesh, guid: engine.Asset_GUID, part: i32, owner: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	if w == nil do return false

	// Resolve search root:
	// Priority 1: adm.root_bone
	// Priority 2: ControlRig search root (if ControlRig exists on owner or parent)
	// Priority 3: Parent transform (standard glTF layout where armature is sibling)
	// Priority 4: Owner transform
	root := owner
	if adm.root_bone.handle != {} && engine.pool_valid(&w.transforms, adm.root_bone.handle) {
		root = engine.Transform_Handle(adm.root_bone.handle)
	} else {
		// Look for ControlRig on owner
		_, rig := engine.transform_get_comp(owner, ControlRig)
		if rig != nil && rig.bones.search_root != {} {
			root = rig.bones.search_root
		} else {
			ot := engine.pool_get(&w.transforms, engine.Handle(owner))
			if ot != nil && ot.parent.handle != {} {
				parent_h := engine.Transform_Handle(ot.parent.handle)
				pt := engine.pool_get(&w.transforms, engine.Handle(parent_h))
				if pt != nil && pt.parent.handle != {} {
					// Also check parent for ControlRig
					_, prig := engine.transform_get_comp(parent_h, ControlRig)
					if prig != nil && prig.bones.search_root != {} {
						root = prig.bones.search_root
					} else {
						root = parent_h
					}
				}
			}
		}
	}

	if adm.bound_ready && adm.bound_guid == guid && adm.bound_part == part && adm.bound_root == root {
		if adm.gpu_wire.ibuf == nil && len(mesh.bind_indices) > 0 {
			adm.gpu_wire = gfx.dynamic_mesh_create_wire_indices(mesh.bind_indices, adm.gpu.mesh.vbuf)
		}
		return true
	}

	if adm.bound_ready {
		gfx.dynamic_mesh_destroy(&adm.gpu)
		if adm.gpu_wire.ibuf != nil do gfx.dynamic_mesh_destroy_wire_indices(&adm.gpu_wire)
	}
	adm.bound_ready = false

	if adm.joints == nil do adm.joints = make([dynamic]engine.Transform_Handle)
	clear(&adm.joints)

	missing := 0
	for name in mesh.joint_names {
		h, ok := _adm_find_bone_recursive(root, name)
		if !ok do missing += 1
		append(&adm.joints, h)
	}
	for name in adm.custom_joint_names {
		h, ok := _adm_find_bone_recursive(root, name)
		if !ok do missing += 1
		append(&adm.joints, h)
	}
	armature_sync_custom_inverse_binds(adm)

	indices := mesh.bind_indices
	if len(indices) == 0 do return false

	adm.gpu = gfx.dynamic_mesh_create(len(mesh.bind_vertices), indices)
	if adm.gpu.index_count == 0 do return false

	adm.gpu_wire = gfx.dynamic_mesh_create_wire_indices(indices, adm.gpu.mesh.vbuf)

	if adm.posed == nil do adm.posed = make([dynamic]gfx.Vertex)
	resize(&adm.posed, len(mesh.bind_vertices))

	adm.bound_guid = guid
	adm.bound_part = part
	adm.bound_root = root
	adm.bound_ready = true
	return true
}

@(private = "file")
_adm_skin_pose :: proc(adm: ^ArmatureDeformedMesh, mesh: ^engine.Mesh, owner: engine.Transform_Handle) {
	w := engine.ctx_world()
	if w == nil do return

	actor_tw := engine.transform_world(owner)
	actor_m := engine.trs_matrix(actor_tw.position, actor_tw.rotation, actor_tw.scale)

	armature_sync_custom_inverse_binds(adm)

	total_joints := len(mesh.inverse_binds) + len(adm.custom_inverse_binds)
	palette := make([]matrix[4, 4]f32, total_joints, context.temp_allocator)
	for j in 0 ..< total_joints {
		inv_bind: matrix[4, 4]f32
		if j < len(mesh.inverse_binds) {
			inv_bind = mesh.inverse_binds[j]
		} else {
			inv_bind = adm.custom_inverse_binds[j - len(mesh.inverse_binds)]
		}
		palette[j] = linalg.MATRIX4F32_IDENTITY
		if j >= len(adm.joints) do continue
		h := adm.joints[j]
		if h == {} || !engine.pool_valid(&w.transforms, engine.Handle(h)) {
			// If joint is missing and anchor_to_actor is true:
			// In bind pose, bone_transform * inverse_bind = IDENTITY.
			// Transforming that rest pose by actor_m gives actor_m * IDENTITY = actor_m.
			if adm.anchor_to_actor {
				palette[j] = actor_m
			} else {
				palette[j] = linalg.MATRIX4F32_IDENTITY
			}
			continue
		}
		tw := engine.transform_world(h)
		if math.is_nan(tw.position.x) || math.is_nan(tw.position.y) || math.is_nan(tw.position.z) ||
		   math.is_nan(tw.rotation.x) || math.is_nan(tw.rotation.y) || math.is_nan(tw.rotation.z) || math.is_nan(tw.rotation.w) {
			if adm.anchor_to_actor {
				palette[j] = actor_m
			} else {
				palette[j] = linalg.MATRIX4F32_IDENTITY
			}
			continue
		}
		palette[j] = engine.trs_matrix(tw.position, tw.rotation, tw.scale) * inv_bind
	}

	// HIGH-EFFICIENCY POSE CACHING: Skip vertex recalculation and PCIe GPU upload
	// if bone transforms and skinning parameters haven't changed!
	palette_changed := (len(adm.last_palette) != total_joints)
	if !palette_changed {
		for j in 0 ..< total_joints {
			if palette[j] != adm.last_palette[j] {
				palette_changed = true
				break
			}
		}
	}

	// Check for bone-attached Ghoul CSG wounds, Clip Plane slices, and Mesh Boolean cuts!
	bone_world_hulls := make([][dynamic]cad_csg.CSG_Convex, total_joints, context.temp_allocator)
	joint_damaged    := make([]bool, total_joints, context.temp_allocator)
	joint_severed    := make([]bool, total_joints, context.temp_allocator)
	is_trunk_bone    := make([]bool, total_joints, context.temp_allocator)
	ghoul_sig: u64   = 0
	any_joint_damaged := false

	// Identify core torso/trunk bones (`Hips`, `Pelvis`, `Spine`, `Chest`, `Torso`, `Root`)
	// so slicing or blasting the pelvis/spine carves a wound gash without deleting the entire upper body!
	for j in 0 ..< min(total_joints, len(adm.joints)) {
		jh := adm.joints[j]
		if jh == {} || !engine.pool_valid(&w.transforms, engine.Handle(jh)) do continue
		jt := engine.pool_get(&w.transforms, engine.Handle(jh))
		if jt == nil do continue

		// Check if `jh` has any parent inside `adm.joints`
		has_joint_parent := false
		curr_p := jt.parent.handle
		for step in 0 ..< 4 {
			if curr_p == {} do break
			ph := engine.Transform_Handle(curr_p)
			for cand_i in 0 ..< min(total_joints, len(adm.joints)) {
				if adm.joints[cand_i] == ph {
					has_joint_parent = true
					break
				}
			}
			if has_joint_parent do break
			pt := engine.pool_get(&w.transforms, curr_p)
			if pt == nil do break
			curr_p = pt.parent.handle
			_ = step
		}

		if !has_joint_parent {
			is_trunk_bone[j] = true
		} else if len(jt.name) > 0 {
			lower_n := strings.to_lower(jt.name, context.temp_allocator)
			if (strings.contains(lower_n, "hip") || strings.contains(lower_n, "pelvis") ||
			    strings.contains(lower_n, "spine") || strings.contains(lower_n, "chest") ||
			    strings.contains(lower_n, "torso") || strings.contains(lower_n, "abdomen") ||
			    strings.contains(lower_n, "waist") || strings.contains(lower_n, "root")) &&
			   !strings.contains(lower_n, "leg") && !strings.contains(lower_n, "thigh") &&
			   !strings.contains(lower_n, "arm") && !strings.contains(lower_n, "shoulder") {
				is_trunk_bone[j] = true
			}
		}
	}

	cut_mat_override: engine.Asset_GUID = {}
	for j in 0 ..< min(total_joints, len(adm.joints)) {
		jh := adm.joints[j]
		if jh == {} || !engine.pool_valid(&w.transforms, engine.Handle(jh)) do continue
		_, vol := engine.transform_get_comp(jh, cad_csg.CSGVolume)
		if vol == nil || !vol.enabled do continue
		if !vol.compiled {
			cad_csg.csg_volume_rebuild(vol)
		}

		// Gather surviving local hulls from `vol.chunks` (or fallback to `vol.runtime_hulls`)
		local_hulls := make([dynamic]cad_csg.CSG_Convex, 0, 8, context.temp_allocator)
		for _, ch in vol.chunks {
			if ch == nil do continue
			for h in ch.destructible_hulls {
				if len(h.planes) >= 4 do append(&local_hulls, h)
			}
			for h in ch.indestructible_hulls {
				if len(h.planes) >= 4 do append(&local_hulls, h)
			}
		}
		if len(local_hulls) == 0 && len(vol.runtime_hulls) > 0 && len(vol.chunks) == 0 {
			for h in vol.runtime_hulls {
				if len(h.planes) >= 4 do append(&local_hulls, h)
			}
		}

		is_cut := len(vol.recorded_blasts) > 0 || len(vol.brushes) > 0 || len(local_hulls) != 1
		ghoul_sig = (ghoul_sig ~ u64(j * 131 + len(local_hulls) * 17 + len(vol.recorded_blasts) * 31)) * 1099511628211
		for lh, hi in local_hulls {
			ghoul_sig = (ghoul_sig ~ u64(len(lh.planes) + hi * 7)) * 1099511628211
			ghoul_sig ~= u64(transmute(u32)lh.aabb_min.x) ~ (u64(transmute(u32)lh.aabb_max.y) << 16)
			for p in lh.planes {
				if p.mat_slot >= 1 || !p.uv_lock_brush {
					is_cut = true
				}
			}
		}
		if !is_cut do continue

		if !engine.asset_guid_is_empty(vol.faker_cut_material_guid) {
			cut_mat_override = vol.faker_cut_material_guid
			raw_cm := transmute([2]u64)vol.faker_cut_material_guid
			ghoul_sig = (ghoul_sig ~ raw_cm[0] ~ raw_cm[1]) * 1099511628211
		}
		joint_damaged[j]  = true
		any_joint_damaged = true

		// Proximal Joint `{0, 0, 0}` Connectivity Filter (for appendicular limbs only):
		// Keep ONLY the convex hulls of limb bone `j` that remain connected (directly or via `convex_touches`)
		// to bone `j`'s proximal joint origin `{0, 0, 0}` (where bone `j` attaches to its parent bone!).
		// Trunk bones (`Hips`, `Pelvis`, `Spine`, `Chest`) are exempt so slicing the pelvis never deletes the torso!
		if !is_trunk_bone[j] && len(local_hulls) > 1 {
			n_lh := len(local_hulls)
			keep_lh := make([]bool, n_lh, context.temp_allocator)
			bfs_q   := make([dynamic]int, 0, n_lh, context.temp_allocator)

			for lh, hi in local_hulls {
				in_root := true
				for p in lh.planes {
					tol_r: f32 = 0.035 if (!p.uv_lock_brush || p.mat_slot >= 1) else 0.095
					// Distance from origin `{0,0,0}` to plane: `dot(n, 0) - d = -p.dist`
					if -p.dist > tol_r {
						in_root = false
						break
					}
				}
				if in_root {
					keep_lh[hi] = true
					append(&bfs_q, hi)
				}
			}

			if len(bfs_q) > 0 {
				head := 0
				for head < len(bfs_q) {
					curr := bfs_q[head]
					head += 1
					for nj in 0 ..< n_lh {
						if keep_lh[nj] do continue
						if cad_csg.convex_touches(local_hulls[curr], local_hulls[nj], 0.025) {
							keep_lh[nj] = true
							append(&bfs_q, nj)
						}
					}
				}

				pruned_hulls := make([dynamic]cad_csg.CSG_Convex, 0, len(bfs_q), context.temp_allocator)
				pruned_any   := false
				for lh, hi in local_hulls {
					if keep_lh[hi] {
						append(&pruned_hulls, lh)
					} else {
						pruned_any = true
					}
				}
				local_hulls = pruned_hulls

				// Also purge disconnected distal hulls from `vol.chunks` so their Jolt colliders are removed!
				if pruned_any {
					for _, ch in vol.chunks {
						if ch == nil do continue
						for hi := len(ch.destructible_hulls) - 1; hi >= 0; hi -= 1 {
							dh := ch.destructible_hulls[hi]
							still_kept := false
							for kh in local_hulls {
								if linalg.length2(dh.centroid - kh.centroid) < 1e-4 {
									still_kept = true
									break
								}
							}
							if !still_kept {
								cad_csg.convex_destroy(&ch.destructible_hulls[hi])
								ordered_remove(&ch.destructible_hulls, hi)
								ch.dirty_physics = true
								ch.dirty_gpu     = true
							}
						}
					}
					cad_csg.csg_volume_sync_colliders_only(vol)
				}
			}
		}

		if len(local_hulls) == 0 {
			joint_severed[j] = true
			continue
		}

		// Transform `local_hulls` of bone `j` into World Space so skin triangles & child joints can be clipped directly!
		jtw := engine.transform_world(jh)
		sc := jtw.scale
		for ax in 0 ..< 3 do if abs(sc[ax]) < 1e-4 do sc[ax] = 1.0
		j_model := engine.trs_matrix(jtw.position, jtw.rotation, sc)
		j_inv_t := linalg.transpose(linalg.inverse(j_model))

		w_hulls := make([dynamic]cad_csg.CSG_Convex, 0, len(local_hulls), context.temp_allocator)
		for lh in local_hulls {
			wh := cad_csg.CSG_Convex{
				planes   = make([dynamic]cad_csg.CSG_Plane, 0, len(lh.planes), context.temp_allocator),
				anchored = lh.anchored,
				brush_id = lh.brush_id,
			}
			for p in lh.planes {
				pt_l := p.normal * p.dist
				pt_w := (j_model * [4]f32{pt_l.x, pt_l.y, pt_l.z, 1.0}).xyz
				n_w  := linalg.normalize0((j_inv_t * [4]f32{p.normal.x, p.normal.y, p.normal.z, 0.0}).xyz)
				if linalg.length2(n_w) < 0.25 do n_w = p.normal
				wp := p
				wp.normal = n_w
				wp.dist   = linalg.dot(n_w, pt_w)
				append(&wh.planes, wp)
			}
			if cad_csg.convex_rebuild_bounds_and_prune(&wh, prune_redundant = false, min_extent = 0.003) {
				append(&w_hulls, wh)
			}
		}
		bone_world_hulls[j] = w_hulls
		if len(w_hulls) == 0 {
			joint_severed[j] = true
		}
	}

	// Propagate limb dismemberment down the bone hierarchy:
	// 1) If ancestor bone `p_idx` is severed, child limb bone `j` is severed.
	// 2) If ancestor bone `p_idx` was sliced/blasted (`joint_damaged[p_idx]`) such that child limb bone `j`'s joint origin
	//    now lies on the cut-away side of `p_idx`'s active cut planes (`!p.uv_lock_brush || p.mat_slot == 1`),
	//    then child limb bone `j` was severed off by the cut on `p_idx`!
	//    Note: We NEVER test uncut outer skin wrapper planes (`p.uv_lock_brush && p.mat_slot == 0`) here, and we
	//    never auto-sever core trunk bones (`Hips`, `Spine`, `Chest`) so slicing the pelvis never deletes the upper body!
	if any_joint_damaged {
		for pass in 0 ..< 8 {
			changed_sev := false
			for j in 0 ..< min(total_joints, len(adm.joints)) {
				if joint_severed[j] || is_trunk_bone[j] do continue
				jh := adm.joints[j]
				if jh == {} || !engine.pool_valid(&w.transforms, engine.Handle(jh)) do continue

				// Walk up `jt.parent` up to 4 ancestor steps to find the closest parent joint in `adm.joints`
				curr_h := jh
				p_idx  := -1
				for _ in 0 ..< 4 {
					ct := engine.pool_get(&w.transforms, engine.Handle(curr_h))
					if ct == nil || ct.parent.handle == {} do break
					parent_h := engine.Transform_Handle(ct.parent.handle)
					for cand_i in 0 ..< min(total_joints, len(adm.joints)) {
						if adm.joints[cand_i] == parent_h {
							p_idx = cand_i
							break
						}
					}
					if p_idx >= 0 do break
					curr_h = parent_h
				}
				if p_idx < 0 do continue

				if joint_severed[p_idx] {
					joint_severed[j] = true
					changed_sev      = true
					continue
				}
				if joint_damaged[p_idx] && !is_trunk_bone[p_idx] {
					j_pos := engine.transform_world(jh).position
					inside_any := false
					for wh in bone_world_hulls[p_idx] {
						in_h := true
						for p in wh.planes {
							if p.uv_lock_brush && p.mat_slot == 0 do continue
							if linalg.dot(p.normal, j_pos) - p.dist > 0.025 {
								in_h = false
								break
							}
						}
						if in_h {
							inside_any = true
							break
						}
					}
					if !inside_any {
						joint_severed[j] = true
						changed_sev      = true
					}
				}
			}
			if !changed_sev do break
			_ = pass
		}

		// Retire Jolt colliders & primitive wireframe colliders on all completely severed child bones
		// so zero floating green/orange colliders remain in mid-air after dismemberment!
		for j in 0 ..< min(total_joints, len(adm.joints)) {
			if !joint_severed[j] do continue
			jh := adm.joints[j]
			if jh == {} || !engine.pool_valid(&w.transforms, engine.Handle(jh)) do continue
			ghoul_sig = (ghoul_sig ~ u64(j * 997 + 0x5E7E)) * 1099511628211
			if _, vol_s := engine.transform_get_comp(jh, cad_csg.CSGVolume); vol_s != nil {
				for _, ch_s in vol_s.chunks {
					if ch_s == nil do continue
					if len(ch_s.destructible_hulls) > 0 || len(ch_s.indices) > 0 {
						for &dh in ch_s.destructible_hulls do cad_csg.convex_destroy(&dh)
						clear(&ch_s.destructible_hulls)
						clear(&ch_s.verts)
						clear(&ch_s.indices)
						ch_s.dirty_physics = true
						ch_s.dirty_gpu     = true
						cad_csg.csg_volume_sync_colliders_only(vol_s)
					}
				}
			}
			if _, cap_s := engine.transform_get_comp(jh, physics3d.CapsuleCollider); cap_s != nil do cap_s.enabled = false
			if _, box_s := engine.transform_get_comp(jh, physics3d.BoxCollider);     box_s != nil do box_s.enabled = false
			if _, sph_s := engine.transform_get_comp(jh, physics3d.SphereCollider);  sph_s != nil do sph_s.enabled = false
		}
	}

	is_heatmap_active := (show_bone_weights_heatmap || weight_painting_active) && active_heatmap_joint_idx >= 0
	heatmap_changed := (adm.last_heatmap_idx != active_heatmap_joint_idx) || (adm.last_heatmap_show != is_heatmap_active)
	skin_changed := (len(adm.custom_skin) != adm.last_skin_count)
	ghoul_changed := (ghoul_sig != adm.last_ghoul_blast_sig)
	force_recompute := (adm.posed_frame == 0)

	if !palette_changed && !heatmap_changed && !skin_changed && !ghoul_changed && !force_recompute {
		return
	}

	// Update cached state
	if len(adm.last_palette) != total_joints {
		if adm.last_palette == nil do adm.last_palette = make([dynamic]matrix[4, 4]f32)
		resize(&adm.last_palette, total_joints)
	}
	copy(adm.last_palette[:], palette)
	adm.last_heatmap_idx     = active_heatmap_joint_idx
	adm.last_heatmap_show    = is_heatmap_active
	adm.last_skin_count      = len(adm.custom_skin)
	adm.last_ghoul_blast_sig = ghoul_sig

	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}

	use_custom_skin := len(adm.custom_skin) == len(mesh.bind_vertices)
	num_palette := len(palette)
	vert_dom_j := make([]int, len(mesh.bind_vertices), context.temp_allocator)

	#no_bounds_check for i in 0 ..< len(mesh.bind_vertices) {
		v := mesh.bind_vertices[i]
		sv := use_custom_skin ? adm.custom_skin[i] : mesh.skin[i]

		c0, c1, c2, c3: [3]f32
		total: f32
		dom_j := -1
		dom_w: f32 = 0.0

		for k in 0 ..< 4 {
			wgt := sv.weights[k]
			if wgt <= 0 do continue
			ji := int(sv.joints[k])
			if ji >= num_palette do continue
			if wgt > dom_w {
				dom_w = wgt
				dom_j = ji
			}
			pm := palette[ji]
			c0 += pm[0].xyz * wgt
			c1 += pm[1].xyz * wgt
			c2 += pm[2].xyz * wgt
			c3 += pm[3].xyz * wgt
			total += wgt
		}
		vert_dom_j[i] = dom_j

		if total > 0 {
			inv_total := 1.0 / total
			v.position = (c0 * v.position.x + c1 * v.position.y + c2 * v.position.z + c3) * inv_total
			nrm := c0 * v.normal.x + c1 * v.normal.y + c2 * v.normal.z
			v.normal = linalg.normalize0(nrm)
		} else if adm.anchor_to_actor {
			// Vertices without bone weight anchor to the actor's level transform!
			p4 := actor_m * [4]f32{v.position.x, v.position.y, v.position.z, 1}
			v.position = p4.xyz
		}

		// Weight Heatmap overlay
		if is_heatmap_active {
			wgt: f32 = 0.0
			for k in 0 ..< 4 {
				if int(sv.joints[k]) == active_heatmap_joint_idx {
					wgt = sv.weights[k]
					break
				}
			}
			v.color = bone_weight_to_color(wgt)
		} else {
			v.color = {255, 255, 255, 255}
		}

		adm.posed[i] = v
		lo = {min(lo.x, v.position.x), min(lo.y, v.position.y), min(lo.z, v.position.z)}
		hi = {max(hi.x, v.position.x), max(hi.y, v.position.y), max(hi.z, v.position.z)}
	}

	if len(mesh.bind_vertices) > 0 {
		adm.posed_min = lo
		adm.posed_max = hi
	}
	gfx.dynamic_mesh_update(&adm.gpu, adm.posed[:])

	// Build exact Ghoul CSG boolean-clipped & wound-capped procedural mesh when any bone is sliced/blasted/cut!
	if !any_joint_damaged || is_heatmap_active || len(mesh.bind_indices) < 3 {
		adm.ghoul_active = false
		return
	}

	if engine.asset_guid_is_empty(adm.ghoul_clipped_guid) {
		adm.ghoul_clipped_guid = _make_adm_ghoul_guid(owner)
	}

	out_verts := make([dynamic]gfx.Vertex, 0, len(adm.posed) + 256, context.temp_allocator)
	out_inds  := make([dynamic]u32, 0, len(mesh.bind_indices) + 512, context.temp_allocator)
	buf_a     := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)
	buf_b     := make([dynamic]gfx.Vertex, 0, 16, context.temp_allocator)

	// Sutherland-Hodgman 3D vertex polygon clipper against a single half-space plane `(n, d)`
	// Preserves original vertex colors so multi-material white stripes / decals never turn red!
	clip_vert_poly :: proc(in_v: []gfx.Vertex, n: [3]f32, d: f32, out_v: ^[dynamic]gfx.Vertex) {
		clear(out_v)
		m := len(in_v)
		if m < 3 do return
		EPS :: f32(1e-5)
		prev := in_v[m - 1]
		prev_s := linalg.dot(n, prev.position) - d
		for curr in in_v {
			curr_s := linalg.dot(n, curr.position) - d
			if curr_s <= EPS {
				if prev_s > EPS {
					t := clamp(prev_s / (prev_s - curr_s), 0.0, 1.0)
					append(out_v, gfx.Vertex{
						position = linalg.lerp(prev.position, curr.position, t),
						normal   = linalg.normalize0(linalg.lerp(prev.normal, curr.normal, t)),
						uv       = linalg.lerp(prev.uv, curr.uv, t),
						color    = {
							u8(clamp(linalg.lerp(f32(prev.color.r), f32(curr.color.r), t), 0, 255)),
							u8(clamp(linalg.lerp(f32(prev.color.g), f32(curr.color.g), t), 0, 255)),
							u8(clamp(linalg.lerp(f32(prev.color.b), f32(curr.color.b), t), 0, 255)),
							prev.color.a,
						},
					})
				}
				append(out_v, curr)
			} else if prev_s <= EPS {
				t := clamp(prev_s / (prev_s - curr_s), 0.0, 1.0)
				append(out_v, gfx.Vertex{
					position = linalg.lerp(prev.position, curr.position, t),
					normal   = linalg.normalize0(linalg.lerp(prev.normal, curr.normal, t)),
					uv       = linalg.lerp(prev.uv, curr.uv, t),
					color    = {
						u8(clamp(linalg.lerp(f32(prev.color.r), f32(curr.color.r), t), 0, 255)),
						u8(clamp(linalg.lerp(f32(prev.color.g), f32(curr.color.g), t), 0, 255)),
						u8(clamp(linalg.lerp(f32(prev.color.b), f32(curr.color.b), t), 0, 255)),
						prev.color.a,
					},
				})
			}
			prev   = curr
			prev_s = curr_s
		}
	}

	bone_skin_pts := make([][dynamic][3]f32, total_joints, context.temp_allocator)
	for j in 0 ..< total_joints {
		if joint_damaged[j] && !joint_severed[j] {
			bone_skin_pts[j] = make([dynamic][3]f32, 0, 64, context.temp_allocator)
		}
	}

	// Preserve multi-material `mesh.submeshes` 1:1 so `adm.materials[0]` (e.g. red body),
	// `adm.materials[1]` (e.g. white hip stripes/traces), etc. map to their exact original submeshes!
	fallback_sub := [1]engine.Mesh_Submesh{{first_index = 0, index_count = u32(len(mesh.bind_indices))}}
	src_subs := mesh.submeshes[:] if len(mesh.submeshes) > 0 else fallback_sub[:]
	sub_inds := make([][dynamic]u32, len(src_subs), context.temp_allocator)
	for s_i in 0 ..< len(src_subs) {
		sub_inds[s_i] = make([dynamic]u32, 0, int(src_subs[s_i].index_count) + 128, context.temp_allocator)
	}

	for sub, sub_idx in src_subs {
		t_start := int(sub.first_index) / 3
		t_end   := min(int(sub.first_index + sub.index_count) / 3, len(mesh.bind_indices) / 3)
		cur_sub_inds := &sub_inds[sub_idx]

		for t in t_start ..< t_end {
			i0 := mesh.bind_indices[t * 3 + 0]
			i1 := mesh.bind_indices[t * 3 + 1]
			i2 := mesh.bind_indices[t * 3 + 2]
			if int(i0) >= len(adm.posed) || int(i1) >= len(adm.posed) || int(i2) >= len(adm.posed) do continue

			j0 := vert_dom_j[i0]
			j1 := vert_dom_j[i1]
			j2 := vert_dom_j[i2]

			sev0 := j0 >= 0 && j0 < total_joints && joint_severed[j0]
			sev1 := j1 >= 0 && j1 < total_joints && joint_severed[j1]
			sev2 := j2 >= 0 && j2 < total_joints && joint_severed[j2]

			// Discard triangle if all dominant joints are completely severed
			if sev0 && sev1 && sev2 {
				continue
			}

			// Determine if this triangle is influenced by any damaged bone (`dmg_j`)
			dmg_j := -1
			if !sev0 && j0 >= 0 && j0 < total_joints && joint_damaged[j0] do dmg_j = j0
			else if !sev1 && j1 >= 0 && j1 < total_joints && joint_damaged[j1] do dmg_j = j1
			else if !sev2 && j2 >= 0 && j2 < total_joints && joint_damaged[j2] do dmg_j = j2

			if dmg_j < 0 {
				// Check secondary skin weights (`w >= 0.12`) across the 3 vertices so triangles near elbow/knee joints clip cleanly!
				verts_idx := [3]u32{i0, i1, i2}
				outer_w: for vi in verts_idx {
					sv := use_custom_skin ? adm.custom_skin[vi] : mesh.skin[vi]
					for k in 0 ..< 4 {
						if sv.weights[k] < 0.12 do continue
						ji := int(sv.joints[k])
						if ji >= 0 && ji < total_joints && joint_damaged[ji] && !joint_severed[ji] {
							dmg_j = ji
							break outer_w
						}
					}
				}
			}

			if (sev0 || sev1 || sev2) && dmg_j < 0 {
				continue
			}

			v0 := adm.posed[i0]
			v1 := adm.posed[i1]
			v2 := adm.posed[i2]

			if dmg_j < 0 {
				base := u32(len(out_verts))
				append(&out_verts, v0, v1, v2)
				append(cur_sub_inds, base + 0, base + 1, base + 2)
				continue
			}

			// Fast O(1) Unsplit Path: if all 3 vertices `(v0, v1, v2)` lie inside the same surviving hull of `bone_world_hulls[dmg_j]`
			// (with respect to cut planes), emit the original triangle unsplit so multi-material seams stay 100% crisp!
			t_min := linalg.min(v0.position, linalg.min(v1.position, v2.position))
			t_max := linalg.max(v0.position, linalg.max(v1.position, v2.position))

			fully_inside_single_hull := false
			for wh in bone_world_hulls[dmg_j] {
				if !cad_csg.aabb_overlaps(t_min, t_max, wh.aabb_min, wh.aabb_max, 0.08) do continue
				in_wh := true
				for p in wh.planes {
					if p.uv_lock_brush && p.mat_slot == 0 do continue
					if linalg.dot(p.normal, v0.position) - p.dist > 1e-4 ||
					   linalg.dot(p.normal, v1.position) - p.dist > 1e-4 ||
					   linalg.dot(p.normal, v2.position) - p.dist > 1e-4 {
						in_wh = false
						break
					}
				}
				if in_wh {
					fully_inside_single_hull = true
					break
				}
			}

			if fully_inside_single_hull {
				base := u32(len(out_verts))
				append(&out_verts, v0, v1, v2)
				append(cur_sub_inds, base + 0, base + 1, base + 2)
				append(&bone_skin_pts[dmg_j], v0.position, v1.position, v2.position)
				continue
			}

			// Clip triangle `(v0, v1, v2)` against the surviving convex hulls of `bone_world_hulls[dmg_j]`
			// (only clipping against newly created cut/partition planes `!p.uv_lock_brush` so uncut outer skin is 100% preserved!)
			for wh in bone_world_hulls[dmg_j] {
				if !cad_csg.aabb_overlaps(t_min, t_max, wh.aabb_min, wh.aabb_max, 0.08) do continue
				clear(&buf_a)
				append(&buf_a, v0, v1, v2)
				for p in wh.planes {
					if p.uv_lock_brush && p.mat_slot == 0 do continue
					clip_vert_poly(buf_a[:], p.normal, p.dist, &buf_b)
					buf_a, buf_b = buf_b, buf_a
					if len(buf_a) < 3 do break
				}
				if len(buf_a) >= 3 {
					base := u32(len(out_verts))
					for cv in buf_a {
						append(&out_verts, cv)
						append(&bone_skin_pts[dmg_j], cv.position)
					}
					for k in 1 ..< u32(len(buf_a) - 1) {
						append(cur_sub_inds, base, base + k, base + k + 1)
					}
				}
			}
		}
	}

	// Emit interior wound cross-section caps / crater walls (`f.mat_slot == 1`) from each damaged bone's surviving hulls,
	// clipped tightly against the 12-direction 2D support polygon of `bone_skin_pts[j]` near the cut plane (just like `.fmesh`!)
	has_custom_cut_mat := !engine.asset_guid_is_empty(cut_mat_override)
	adm.ghoul_cut_material_guid = cut_mat_override
	cap_sub_inds := make([dynamic]u32, 0, 128, context.temp_allocator)
	cap_col := [4]u8{255, 255, 255, 255} if has_custom_cut_mat else [4]u8{148, 22, 22, 255}

	cap_faces := make([dynamic]cad_csg.CSG_Face_Poly, 0, 32, context.temp_allocator)
	cap_poly_a := make([dynamic][3]f32, 0, 16, context.temp_allocator)
	cap_poly_b := make([dynamic][3]f32, 0, 16, context.temp_allocator)

	for j in 0 ..< total_joints {
		if !joint_damaged[j] || joint_severed[j] || len(bone_world_hulls[j]) == 0 do continue
		clear(&cap_faces)
		cad_csg.csg_extract_clean_polygons_from_hulls(bone_world_hulls[j][:], &cap_faces, context.temp_allocator)
		skin_pts_j := bone_skin_pts[j][:]

		for f in cap_faces {
			if f.mat_slot == 0 || len(f.verts) < 3 do continue
			u_ax, v_ax := cad_csg.plane_tangent_basis(f.normal)

			clear(&cap_poly_a)
			append(&cap_poly_a, ..f.verts[:])

			// Clip `cap_poly_a` against the 12-direction 2D support contour of `skin_pts_j` near `f`
			// so the crimson wound cap never protrudes outside the limb's actual skin mesh!
			if len(skin_pts_j) >= 3 {
				f_d := linalg.dot(f.normal, f.verts[0])
				near_cnt := 0
				for sp in skin_pts_j {
					if abs(linalg.dot(f.normal, sp) - f_d) <= 0.085 {
						near_cnt += 1
					}
				}
				use_near := near_cnt >= 3
				for d_i in 0 ..< 12 {
					ang := f32(d_i) * (2.0 * math.PI / 12.0)
					dir_w := linalg.normalize0(u_ax * math.cos(ang) + v_ax * math.sin(ang))
					max_sup: f32 = -1e9
					for sp in skin_pts_j {
						if use_near && abs(linalg.dot(f.normal, sp) - f_d) > 0.085 do continue
						pr := linalg.dot(dir_w, sp)
						if pr > max_sup do max_sup = pr
					}
					if max_sup > -1e8 {
						cad_csg.clip_polygon_by_plane(cap_poly_a[:], cad_csg.CSG_Plane{normal = dir_w, dist = max_sup + 0.004}, &cap_poly_b)
						cap_poly_a, cap_poly_b = cap_poly_b, cap_poly_a
						if len(cap_poly_a) < 3 do break
					}
				}
			}
			if len(cap_poly_a) < 3 do continue

			base := u32(len(out_verts))
			for pt in cap_poly_a {
				append(&out_verts, gfx.Vertex{
					position = pt,
					normal   = f.normal,
					uv       = {linalg.dot(pt, u_ax), linalg.dot(pt, v_ax)},
					color    = cap_col,
				})
			}
			for k in 1 ..< u32(len(cap_poly_a) - 1) {
				if has_custom_cut_mat {
					append(&cap_sub_inds, base, base + k, base + k + 1)
				} else {
					append(&sub_inds[0], base, base + k, base + k + 1)
				}
			}
		}
	}

	out_subs := make([dynamic]engine.Mesh_Submesh, 0, len(src_subs) + 1, context.temp_allocator)
	for s_i in 0 ..< len(src_subs) {
		first_i := u32(len(out_inds))
		cnt_i   := u32(len(sub_inds[s_i]))
		if cnt_i > 0 {
			append(&out_inds, ..sub_inds[s_i][:])
		}
		append(&out_subs, engine.Mesh_Submesh{
			first_index = first_i,
			index_count = cnt_i,
		})
	}
	if has_custom_cut_mat && len(cap_sub_inds) > 0 {
		first_cap := u32(len(out_inds))
		append(&out_inds, ..cap_sub_inds[:])
		append(&out_subs, engine.Mesh_Submesh{
			first_index = first_cap,
			index_count = u32(len(cap_sub_inds)),
		})
	}

	if len(out_verts) >= 3 && len(out_inds) >= 3 {
		engine.mesh_upsert_procedural(adm.ghoul_clipped_guid, out_verts[:], out_inds[:], out_subs[:], keep_cpu_buffers = false)
		adm.ghoul_active = true
	} else {
		adm.ghoul_active = false
	}
}

// --- BONE WEIGHT HEATMAP & RIG EXPANSION AUTHORING ---

show_bone_weights_heatmap: bool
active_heatmap_joint_idx:  int = -1
active_heatmap_bone_h:     engine.Transform_Handle
show_mesh_wireframe:       bool = true
wireframe_overlay_color:   [4]f32 = {0.08, 0.08, 0.12, 0.28} // Refined, non-obscuring topological wireframe (Blender style)
heatmap_shading_unlit:     bool = true                       // 100% emissive flat shading prevents lighting/textures from darkening heatmap colors
weight_painting_active:    bool

bone_weight_to_color :: proc(w: f32) -> [4]u8 {
	if w <= 0.001 {
		return {45, 48, 58, 255} // Slate dark tint for uninfluenced mesh
	}
	t := clamp(w, 0.0, 1.0)
	r, g, b: f32
	if t < 0.25 {
		// Dark blue -> Cyan
		f := t / 0.25
		r = 0.0
		g = f * 0.8
		b = 0.8 + f * 0.2
	} else if t < 0.50 {
		// Cyan -> Green
		f := (t - 0.25) / 0.25
		r = 0.0
		g = 0.8 + f * 0.2
		b = 1.0 - f
	} else if t < 0.75 {
		// Green -> Yellow
		f := (t - 0.50) / 0.25
		r = f
		g = 1.0
		b = 0.0
	} else {
		// Yellow -> Bright Red
		f := (t - 0.75) / 0.25
		r = 1.0
		g = 1.0 - f
		b = 0.0
	}
	return {u8(clamp(r * 255.0, 0.0, 255.0)), u8(clamp(g * 255.0, 0.0, 255.0)), u8(clamp(b * 255.0, 0.0, 255.0)), 255}
}

armature_get_bone_joint_index :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle) -> int {
	if adm == nil || bone_h == {} do return -1
	for j in 0 ..< len(adm.joints) {
		if adm.joints[j] == bone_h do return j
	}
	return -1
}

armature_get_bone_weight_stats :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle) -> (count: int, max_w: f32, avg_w: f32) {
	if adm == nil || bone_h == {} do return 0, 0, 0
	j_idx := armature_get_bone_joint_index(adm, bone_h)
	if j_idx < 0 do return 0, 0, 0

	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	if !mok || mesh == nil do return 0, 0, 0

	use_custom := len(adm.custom_skin) == len(mesh.bind_vertices)
	total_sum: f32 = 0

	for i in 0 ..< len(mesh.bind_vertices) {
		sv := use_custom ? adm.custom_skin[i] : mesh.skin[i]
		for k in 0 ..< 4 {
			if int(sv.joints[k]) == j_idx && sv.weights[k] > 0.001 {
				count += 1
				if sv.weights[k] > max_w do max_w = sv.weights[k]
				total_sum += sv.weights[k]
				break
			}
		}
	}
	if count > 0 do avg_w = total_sum / f32(count)
	return count, max_w, avg_w
}

// Synchronizes adm.custom_inverse_binds to match adm.custom_joint_names.
// Recomputes any missing or identity bind matrices from the bone's current world transform.
armature_sync_custom_inverse_binds :: proc(adm: ^ArmatureDeformedMesh) {
	if adm == nil do return
	w := engine.ctx_world()
	if w == nil do return

	num_custom := len(adm.custom_joint_names)
	if num_custom == 0 {
		clear(&adm.custom_inverse_binds)
		return
	}

	if adm.custom_inverse_binds == nil {
		adm.custom_inverse_binds = make([dynamic]matrix[4, 4]f32)
	}

	for len(adm.custom_inverse_binds) < num_custom {
		append(&adm.custom_inverse_binds, linalg.MATRIX4F32_IDENTITY)
	}
	if len(adm.custom_inverse_binds) > num_custom {
		resize(&adm.custom_inverse_binds, num_custom)
	}

	owner_h := engine.Transform_Handle(adm.owner)
	actor_tw := engine.transform_world(owner_h)
	actor_m := engine.trs_matrix(actor_tw.position, actor_tw.rotation, actor_tw.scale)
	inv_actor_m := linalg.inverse(actor_m)

	search_root := engine.Transform_Handle(adm.root_bone.handle)
	if search_root == {} do search_root = owner_h

	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	base_joints := mok && mesh != nil ? len(mesh.joint_names) : 0

	for i in 0 ..< num_custom {
		name := adm.custom_joint_names[i]
		joint_idx := base_joints + i
		bone_h: engine.Transform_Handle
		found := false

		// Fast path O(1): check already-bound handle in adm.joints first!
		if joint_idx < len(adm.joints) {
			cand_h := adm.joints[joint_idx]
			if cand_h != {} && engine.pool_valid(&w.transforms, engine.Handle(cand_h)) {
				bone_h = cand_h
				found = true
			}
		}

		if !found {
			bone_h, found = _adm_find_bone_recursive(search_root, name)
			if !found && search_root != owner_h {
				bone_h, found = _adm_find_bone_recursive(owner_h, name)
			}
		}

		if found && bone_h != {} && engine.pool_valid(&w.transforms, engine.Handle(bone_h)) {
			// Also sync name if transform.name was edited
			cbt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
			if cbt != nil && cbt.name != adm.custom_joint_names[i] {
				delete(adm.custom_joint_names[i])
				adm.custom_joint_names[i] = strings.clone(cbt.name)
			}
			if joint_idx < len(adm.joints) {
				adm.joints[joint_idx] = bone_h
			}

			// If this slot is uninitialized (identity matrix):
			if adm.custom_inverse_binds[i] == linalg.MATRIX4F32_IDENTITY {
				bone_tw := engine.transform_world(bone_h)
				bone_m := engine.trs_matrix(bone_tw.position, bone_tw.rotation, bone_tw.scale)
				local_bone_m := inv_actor_m * bone_m
				adm.custom_inverse_binds[i] = linalg.inverse(local_bone_m)
			}
		}
	}
}

// Explicitly establishes the bone's current position & orientation as its authentic rest / bind pose.
// Recomputes M_inv = (M_actor^-1 * M_bone)^-1 = M_bone^-1 * M_actor.
// This immediately eliminates polygon jumping/popping for all vertices weighted to this bone.
armature_set_bone_rest_pose :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle) -> bool {
	if adm == nil || bone_h == {} do return false
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(bone_h)) do return false

	bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bt == nil do return false

	custom_idx := -1
	for name, idx in adm.custom_joint_names {
		if strings.equal_fold(name, bt.name) {
			custom_idx = idx
			break
		}
	}

	// Fallback: match via adm.joints if bone was renamed
	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	base_joints := mok && mesh != nil ? len(mesh.joint_names) : 0
	if custom_idx < 0 {
		for j in 0 ..< len(adm.joints) {
			if adm.joints[j] == bone_h && j >= base_joints {
				c_idx := j - base_joints
				if c_idx < len(adm.custom_joint_names) {
					custom_idx = c_idx
					delete(adm.custom_joint_names[c_idx])
					adm.custom_joint_names[c_idx] = strings.clone(bt.name)
				}
				break
			}
		}
	}
	if custom_idx < 0 do return false

	if adm.custom_inverse_binds == nil {
		adm.custom_inverse_binds = make([dynamic]matrix[4, 4]f32)
	}
	for len(adm.custom_inverse_binds) <= custom_idx {
		append(&adm.custom_inverse_binds, linalg.MATRIX4F32_IDENTITY)
	}

	owner_h := engine.Transform_Handle(adm.owner)
	actor_tw := engine.transform_world(owner_h)
	bone_tw := engine.transform_world(bone_h)

	actor_m := engine.trs_matrix(actor_tw.position, actor_tw.rotation, actor_tw.scale)
	bone_m := engine.trs_matrix(bone_tw.position, bone_tw.rotation, bone_tw.scale)

	local_bone_m := linalg.inverse(actor_m) * bone_m
	adm.custom_inverse_binds[custom_idx] = linalg.inverse(local_bone_m)

	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Recomputes rest pose / inverse bind matrices for all custom bones on this mesh.
armature_set_all_custom_bones_rest_pose :: proc(adm: ^ArmatureDeformedMesh) -> int {
	if adm == nil do return 0
	w := engine.ctx_world()
	if w == nil do return 0

	owner_h := engine.Transform_Handle(adm.owner)
	search_root := engine.Transform_Handle(adm.root_bone.handle)
	if search_root == {} do search_root = owner_h

	count := 0
	for name in adm.custom_joint_names {
		bone_h, found := _adm_find_bone_recursive(search_root, name)
		if !found && search_root != owner_h {
			bone_h, found = _adm_find_bone_recursive(owner_h, name)
		}
		if found && bone_h != {} {
			if armature_set_bone_rest_pose(adm, bone_h) do count += 1
		}
	}
	return count
}

armature_add_child_bone :: proc(adm: ^ArmatureDeformedMesh, parent_bone_h: engine.Transform_Handle, bone_name: string, local_pos: [3]f32) -> (new_bone_h: engine.Transform_Handle, ok: bool) {
	if adm == nil || parent_bone_h == {} do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false

	// 1. Spawn new transform parented under parent_bone_h
	new_bone_h = engine.transform_new(bone_name, parent_bone_h)
	engine.transform_set_local_position(new_bone_h, local_pos)

	// 2. Compute authentic Inverse Bind Matrix
	// In rest pose: M_inv = (M_actor^-1 * M_bone)^-1 = M_bone^-1 * M_actor
	owner_h := engine.Transform_Handle(adm.owner)
	actor_tw := engine.transform_world(owner_h)
	bone_tw := engine.transform_world(new_bone_h)

	actor_m := engine.trs_matrix(actor_tw.position, actor_tw.rotation, actor_tw.scale)
	bone_m := engine.trs_matrix(bone_tw.position, bone_tw.rotation, bone_tw.scale)

	local_bone_m := linalg.inverse(actor_m) * bone_m
	inv_bind := linalg.inverse(local_bone_m)

	// 3. Register in custom_joint_names and custom_inverse_binds
	append(&adm.custom_joint_names, strings.clone(bone_name))
	append(&adm.custom_inverse_binds, inv_bind)
	append(&adm.joints, new_bone_h)

	// Invalidate frame pose to force re-evaluation
	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return new_bone_h, true
}

armature_apply_spherical_weight_falloff :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle, radius: f32, max_weight: f32) -> int {
	if adm == nil || bone_h == {} || radius <= 0.001 do return 0
	w := engine.ctx_world()
	if w == nil do return 0

	new_j_idx := armature_get_bone_joint_index(adm, bone_h)
	if new_j_idx < 0 do return 0

	bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bt == nil || bt.parent.handle == {} do return 0
	parent_h := engine.Transform_Handle(bt.parent.handle)
	parent_j_idx := armature_get_bone_joint_index(adm, parent_h)

	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	if !mok || mesh == nil do return 0

	// Lazy initialize custom_skin copy if empty
	if len(adm.custom_skin) != len(mesh.bind_vertices) {
		if adm.custom_skin == nil do adm.custom_skin = make([dynamic]engine.Mesh_Skin_Vertex)
		resize(&adm.custom_skin, len(mesh.bind_vertices))
		copy(adm.custom_skin[:], mesh.skin)
	}

	// Bone position in actor local mesh space
	owner_h := engine.Transform_Handle(adm.owner)
	actor_tw := engine.transform_world(owner_h)
	bone_tw := engine.transform_world(bone_h)

	inv_actor_rot := linalg.quaternion_inverse(engine.quat_to_native(actor_tw.rotation))
	bone_local_pos := linalg.quaternion128_mul_vector3(inv_actor_rot, bone_tw.position - actor_tw.position)

	affected_count := 0
	clamp_max := clamp(max_weight, 0.05, 1.0)

	for i in 0 ..< len(mesh.bind_vertices) {
		v_pos := mesh.bind_vertices[i].position
		dist := linalg.distance(v_pos, bone_local_pos)
		if dist >= radius do continue

		// Smooth cubic polynomial falloff: (1 - (d/R)^2)^2
		t := dist / radius
		falloff := (1.0 - t * t) * (1.0 - t * t)
		desired_w := falloff * clamp_max

		sv := &adm.custom_skin[i]

		// 1. Check if new bone is already an influence
		new_slot := -1
		for k in 0 ..< 4 {
			if int(sv.joints[k]) == new_j_idx {
				new_slot = k
				break
			}
		}

		// 2. Check if parent bone is an influence (to steal weight from)
		parent_slot := -1
		if parent_j_idx >= 0 {
			for k in 0 ..< 4 {
				if int(sv.joints[k]) == parent_j_idx {
					parent_slot = k
					break
				}
			}
		}

		if new_slot >= 0 {
			// Already influenced: adjust weight towards desired_w
			cur_w := sv.weights[new_slot]
			diff := desired_w - cur_w
			if diff > 0 && parent_slot >= 0 {
				stolen := min(diff, sv.weights[parent_slot])
				sv.weights[parent_slot] -= stolen
				sv.weights[new_slot] += stolen
			} else if diff < 0 && parent_slot >= 0 {
				sv.weights[new_slot] += diff
				sv.weights[parent_slot] -= diff
			}
		} else {
			// New influence: find slot
			// If parent exists, steal directly from parent!
			if parent_slot >= 0 && sv.weights[parent_slot] > 0.05 {
				// Find an empty slot (weight == 0) or replace minimum slot
				target_slot := -1
				min_k := 0
				min_val: f32 = 999.0
				for k in 0 ..< 4 {
					if sv.weights[k] <= 0.001 {
						target_slot = k
						break
					}
					if k != parent_slot && sv.weights[k] < min_val {
						min_val = sv.weights[k]
						min_k = k
					}
				}
				if target_slot < 0 do target_slot = min_k

				stolen := min(desired_w, sv.weights[parent_slot] * 0.90)
				sv.weights[parent_slot] -= stolen

				sv.joints[target_slot] = u16(new_j_idx)
				sv.weights[target_slot] = stolen
			}
		}

		// Enforce strict normalization: sum(weights) == 1.0
		sum: f32 = 0
		for k in 0 ..< 4 do sum += sv.weights[k]
		if sum > 0.0001 {
			for k in 0 ..< 4 do sv.weights[k] /= sum
		}
		affected_count += 1
	}

	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return affected_count
}

armature_add_bilateral_chest_bones :: proc(adm: ^ArmatureDeformedMesh) -> (left_h, right_h: engine.Transform_Handle, ok: bool) {
	if adm == nil do return {}, {}, false
	l_h, r_h, _, traced_ok := smart_auto_rig_breasts_via_line_traces(adm, attach_colliders = true)
	if traced_ok do return l_h, r_h, true

	w := engine.ctx_world()
	if w == nil do return {}, {}, false

	owner_h := engine.Transform_Handle(adm.owner)
	bones: Humanoid_Bones
	if !skeleton_bind_humanoid(&bones, owner_h) {
		// Fallback: look for chest or spine bone directly
		chest_h, found := _adm_find_bone_recursive(owner_h, "chest")
		if !found do chest_h, found = _adm_find_bone_recursive(owner_h, "spine_02")
		if !found do chest_h, found = _adm_find_bone_recursive(owner_h, "spine")
		if !found do return {}, {}, false
		bones.chest = chest_h
	}

	chest_bone := bones.chest != {} ? bones.chest : bones.spine
	if chest_bone == {} do return {}, {}, false

	// Clean out existing breast bones if they already exist
	existing_l, has_l := _adm_find_bone_recursive(chest_bone, "breast_l")
	if has_l && existing_l != {} do armature_remove_custom_bone(adm, existing_l)
	existing_r, has_r := _adm_find_bone_recursive(chest_bone, "breast_r")
	if has_r && existing_r != {} do armature_remove_custom_bone(adm, existing_r)

	// Anatomical pectoral placement relative to chest bone
	left_pos  := [3]f32{ 0.075, -0.04, 0.11}
	right_pos := [3]f32{-0.075, -0.04, 0.11}

	ok_l, ok_r: bool
	left_h, ok_l = armature_add_child_bone(adm, chest_bone, "breast_l", left_pos)
	right_h, ok_r = armature_add_child_bone(adm, chest_bone, "breast_r", right_pos)
	if !ok_l || !ok_r do return left_h, right_h, false

	// Apply smooth spherical weight falloff
	armature_apply_spherical_weight_falloff(adm, left_h, radius = 0.11, max_weight = 0.75)
	armature_apply_spherical_weight_falloff(adm, right_h, radius = 0.11, max_weight = 0.75)

	// Attach SpringBone component to both with tailored soft-tissue dynamics
	_, l_raw := engine.transform_add_comp(left_h, .SpringBone)
	if l_raw != nil {
		sb := cast(^SpringBone)l_raw
		sb.stiffness     = 42.0
		sb.damping       = 0.68
		sb.gravity       = {0, -0.8, 0}
		sb.drag          = 0.06
		sb.max_angle_deg = 28.0
		sb.bone_length   = 0.08
		sb.forward_axis  = {0, 0, 1}
	}

	_, r_raw := engine.transform_add_comp(right_h, .SpringBone)
	if r_raw != nil {
		sb := cast(^SpringBone)r_raw
		sb.stiffness     = 42.0
		sb.damping       = 0.68
		sb.gravity       = {0, -0.8, 0}
		sb.drag          = 0.06
		sb.max_angle_deg = 28.0
		sb.bone_length   = 0.08
		sb.forward_axis  = {0, 0, 1}
	}

	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return left_h, right_h, true
}

armature_remove_custom_bone :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle) -> bool {
	if adm == nil || bone_h == {} do return false
	w := engine.ctx_world()
	if w == nil do return false

	bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bt == nil do return false
	bone_name := bt.name

	// Find in custom_joint_names
	custom_idx := -1
	for i in 0 ..< len(adm.custom_joint_names) {
		if strings.equal_fold(adm.custom_joint_names[i], bone_name) {
			custom_idx = i
			break
		}
	}

	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	base_joints := mok && mesh != nil ? len(mesh.joint_names) : 0

	// Fallback: match via adm.joints handle if bone was renamed
	if custom_idx < 0 {
		for j in 0 ..< len(adm.joints) {
			if adm.joints[j] == bone_h && j >= base_joints {
				c_idx := j - base_joints
				if c_idx < len(adm.custom_joint_names) {
					custom_idx = c_idx
				}
				break
			}
		}
	}
	if custom_idx < 0 do return false

	full_j_idx := base_joints + custom_idx

	// If custom skin exists, transfer any weight back to parent bone
	parent_j_idx := -1
	if bt.parent.handle != {} {
		parent_j_idx = armature_get_bone_joint_index(adm, engine.Transform_Handle(bt.parent.handle))
	}

	if len(adm.custom_skin) > 0 {
		for i in 0 ..< len(adm.custom_skin) {
			sv := &adm.custom_skin[i]
			for k in 0 ..< 4 {
				if int(sv.joints[k]) == full_j_idx {
					wgt := sv.weights[k]
					sv.weights[k] = 0
					sv.joints[k]  = 0
					if parent_j_idx >= 0 && wgt > 0.0 {
						added_to_existing := false
						for pk in 0 ..< 4 {
							if pk != k && int(sv.joints[pk]) == parent_j_idx && sv.weights[pk] > 0.0 {
								sv.weights[pk] += wgt
								added_to_existing = true
								break
							}
						}
						if !added_to_existing {
							sv.joints[k]  = u16(parent_j_idx)
							sv.weights[k] = wgt
						}
					}
				}
			}
			// Shift down any custom joint indices above `full_j_idx` to match `ordered_remove` below
			tot_w: f32 = 0.0
			for pk in 0 ..< 4 {
				if int(sv.joints[pk]) > full_j_idx {
					sv.joints[pk] -= 1
				}
				tot_w += sv.weights[pk]
			}
			if tot_w > 0.0001 {
				for pk in 0 ..< 4 do sv.weights[pk] /= tot_w
			}
		}
	}

	// Remove from custom arrays
	delete(adm.custom_joint_names[custom_idx])
	ordered_remove(&adm.custom_joint_names, custom_idx)
	ordered_remove(&adm.custom_inverse_binds, custom_idx)

	// Remove from joints array
	for j in 0 ..< len(adm.joints) {
		if adm.joints[j] == bone_h {
			ordered_remove(&adm.joints, j)
			break
		}
	}

	// Destroy transform entity
	engine.transform_destroy(bone_h)

	adm.bound_ready = false
	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Renames a skeleton bone (both transform entity and custom_joint_names registration).
// Prevents phantom / ghost bones from emerging after renaming.
armature_rename_bone :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle, new_name: string) -> bool {
	if adm == nil || bone_h == {} do return false
	cleaned := strings.trim_space(new_name)
	if len(cleaned) == 0 do return false
	w := engine.ctx_world()
	if w == nil do return false

	bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bt == nil do return false

	old_name := bt.name

	// 1. Rename the transform entity
	delete(bt.name)
	bt.name = strings.clone(cleaned)

	// 2. Synchronize adm.custom_joint_names by old name
	renamed_custom := false
	for i in 0 ..< len(adm.custom_joint_names) {
		if strings.equal_fold(adm.custom_joint_names[i], old_name) {
			delete(adm.custom_joint_names[i])
			adm.custom_joint_names[i] = strings.clone(cleaned)
			renamed_custom = true
			break
		}
	}

	// 3. Fallback: match by joint index in adm.joints
	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	base_joints := mok && mesh != nil ? len(mesh.joint_names) : 0
	if !renamed_custom {
		for j in 0 ..< len(adm.joints) {
			if adm.joints[j] == bone_h && j >= base_joints {
				c_idx := j - base_joints
				if c_idx < len(adm.custom_joint_names) {
					delete(adm.custom_joint_names[c_idx])
					adm.custom_joint_names[c_idx] = strings.clone(cleaned)
				}
				break
			}
		}
	}

	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Scans and cleans any orphan ghost bones that have no corresponding transform entity in the scene.
armature_clean_ghost_bones :: proc(adm: ^ArmatureDeformedMesh) -> int {
	if adm == nil do return 0
	w := engine.ctx_world()
	if w == nil do return 0

	owner_h := engine.Transform_Handle(adm.owner)
	search_root := engine.Transform_Handle(adm.root_bone.handle)
	if search_root == {} do search_root = owner_h

	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	base_joints := mok && mesh != nil ? len(mesh.joint_names) : 0

	removed := 0
	i := 0
	for i < len(adm.custom_joint_names) {
		name := adm.custom_joint_names[i]
		bone_h, found := _adm_find_bone_recursive(search_root, name)
		if !found && search_root != owner_h {
			bone_h, found = _adm_find_bone_recursive(owner_h, name)
		}

		joint_idx := base_joints + i
		has_live_handle := false
		if joint_idx < len(adm.joints) {
			jh := adm.joints[joint_idx]
			if jh != {} && engine.pool_valid(&w.transforms, engine.Handle(jh)) {
				has_live_handle = true
				if !found {
					// Bone was renamed! Update name instead of removing
					cbt := engine.pool_get(&w.transforms, engine.Handle(jh))
					if cbt != nil {
						delete(adm.custom_joint_names[i])
						adm.custom_joint_names[i] = strings.clone(cbt.name)
						found = true
					}
				}
			}
		}

		if !found && !has_live_handle {
			// Truly a ghost bone! Purge it
			delete(adm.custom_joint_names[i])
			ordered_remove(&adm.custom_joint_names, i)
			if i < len(adm.custom_inverse_binds) {
				ordered_remove(&adm.custom_inverse_binds, i)
			}
			if joint_idx < len(adm.joints) {
				ordered_remove(&adm.joints, joint_idx)
			}
			removed += 1
		} else {
			i += 1
		}
	}

	if removed > 0 {
		adm.posed_frame = 0
		if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	}
	return removed
}

armature_get_mirrored_bone_name :: proc(src_name: string) -> (opp_name: string, ok: bool) {
	// Suffixes: _l / _r, _L / _R, .l / .r, .L / .R
	if strings.ends_with(src_name, "_l")  do return fmt.tprintf("%s_r", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, "_L")  do return fmt.tprintf("%s_R", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, "_r")  do return fmt.tprintf("%s_l", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, "_R")  do return fmt.tprintf("%s_L", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, ".l")  do return fmt.tprintf("%s.r", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, ".L")  do return fmt.tprintf("%s.R", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, ".r")  do return fmt.tprintf("%s.l", src_name[:len(src_name)-2]), true
	if strings.ends_with(src_name, ".R")  do return fmt.tprintf("%s.L", src_name[:len(src_name)-2]), true

	// Prefixes: l_ / r_, L_ / R_, left_ / right_, Left_ / Right_
	if strings.starts_with(src_name, "l_")     do return fmt.tprintf("r_%s", src_name[2:]), true
	if strings.starts_with(src_name, "L_")     do return fmt.tprintf("R_%s", src_name[2:]), true
	if strings.starts_with(src_name, "r_")     do return fmt.tprintf("l_%s", src_name[2:]), true
	if strings.starts_with(src_name, "R_")     do return fmt.tprintf("L_%s", src_name[2:]), true
	if strings.starts_with(src_name, "left_")  do return fmt.tprintf("right_%s", src_name[5:]), true
	if strings.starts_with(src_name, "Left_")  do return fmt.tprintf("Right_%s", src_name[5:]), true
	if strings.starts_with(src_name, "right_") do return fmt.tprintf("left_%s", src_name[6:]), true
	if strings.starts_with(src_name, "Right_") do return fmt.tprintf("Left_%s", src_name[6:]), true

	return "", false
}

armature_mirror_bone_and_weights :: proc(adm: ^ArmatureDeformedMesh, bone_h: engine.Transform_Handle) -> bool {
	if adm == nil || bone_h == {} do return false
	w := engine.ctx_world()
	if w == nil do return false

	bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
	if bt == nil || bt.parent.handle == {} do return false

	opp_name, name_ok := armature_get_mirrored_bone_name(bt.name)
	if !name_ok do return false

	parent_h := engine.Transform_Handle(bt.parent.handle)
	mirrored_pos := [3]f32{-bt.position.x, bt.position.y, bt.position.z}

	opp_h, found := _adm_find_bone_recursive(parent_h, opp_name)
	if !found || opp_h == {} {
		h, ok := armature_add_child_bone(adm, parent_h, opp_name, mirrored_pos)
		if !ok do return false
		opp_h = h
	} else {
		engine.transform_set_local_position(opp_h, mirrored_pos)
		armature_set_bone_rest_pose(adm, opp_h)
	}

	// Copy SpringBone if present
	_, src_sb := engine.transform_get_comp(bone_h, SpringBone)
	if src_sb != nil {
		_, opp_raw := engine.transform_add_comp(opp_h, .SpringBone)
		if opp_raw != nil {
			opp_sb := cast(^SpringBone)opp_raw
			opp_sb.stiffness     = src_sb.stiffness
			opp_sb.damping       = src_sb.damping
			opp_sb.gravity       = src_sb.gravity
			opp_sb.drag          = src_sb.drag
			opp_sb.max_angle_deg = src_sb.max_angle_deg
			opp_sb.bone_length   = src_sb.bone_length
			opp_sb.forward_axis  = src_sb.forward_axis
		}
	}

	// Authentic 1:1 Symmetrical Vertex Weight Mirroring across X=0
	mesh_guid := adm.mesh
	mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
	if !mok || mesh == nil || len(mesh.bind_vertices) == 0 do return true

	// Ensure custom_skin is allocated
	if len(adm.custom_skin) != len(mesh.bind_vertices) {
		if adm.custom_skin == nil do adm.custom_skin = make([dynamic]engine.Mesh_Skin_Vertex)
		resize(&adm.custom_skin, len(mesh.bind_vertices))
		copy(adm.custom_skin[:], mesh.skin)
	}

	src_j_idx := armature_get_bone_joint_index(adm, bone_h)
	opp_j_idx := armature_get_bone_joint_index(adm, opp_h)
	if src_j_idx < 0 || opp_j_idx < 0 do return true

	// 1. Clear any existing weights for opp_j_idx on target side
	for i in 0 ..< len(adm.custom_skin) {
		sv := &adm.custom_skin[i]
		for k in 0 ..< 4 {
			if int(sv.joints[k]) == opp_j_idx {
				sv.weights[k] = 0.0
				break
			}
		}
	}

	// 2. Map every vertex weighted on src_j_idx to its geometric mirror across X=0
	for i in 0 ..< len(mesh.bind_vertices) {
		src_w: f32 = 0.0
		sv_src := adm.custom_skin[i]
		for k in 0 ..< 4 {
			if int(sv_src.joints[k]) == src_j_idx {
				src_w = sv_src.weights[k]
				break
			}
		}
		if src_w <= 0.001 do continue

		// Mirrored point across sagittal plane
		p_src := mesh.bind_vertices[i].position
		p_target := [3]f32{-p_src.x, p_src.y, p_src.z}

		// Find closest vertex in bind vertices
		best_j := -1
		best_d2: f32 = 1e20

		// Fast windowed check
		eps := f32(0.015) // 15mm tolerance window
		for j in 0 ..< len(mesh.bind_vertices) {
			pj := mesh.bind_vertices[j].position
			if abs(pj.y - p_target.y) > eps do continue
			if abs(pj.z - p_target.z) > eps do continue
			if abs(pj.x - p_target.x) > eps do continue

			d2 := linalg.length2(pj - p_target)
			if d2 < best_d2 {
				best_d2 = d2
				best_j = j
			}
		}

		// Fallback check across all vertices
		if best_j < 0 {
			for j in 0 ..< len(mesh.bind_vertices) {
				pj := mesh.bind_vertices[j].position
				d2 := linalg.length2(pj - p_target)
				if d2 < best_d2 {
					best_d2 = d2
					best_j = j
				}
			}
		}

		if best_j >= 0 && best_d2 < 0.0025 { // within 5 cm threshold
			sv_opp := &adm.custom_skin[best_j]

			// Assign slot for opp_j_idx
			slot := -1
			for k in 0 ..< 4 {
				if int(sv_opp.joints[k]) == opp_j_idx {
					slot = k
					break
				}
			}
			if slot < 0 {
				min_k := 0
				min_val: f32 = 999.0
				for k in 0 ..< 4 {
					if sv_opp.weights[k] < 0.001 {
						min_k = k
						break
					}
					if sv_opp.weights[k] < min_val {
						min_val = sv_opp.weights[k]
						min_k = k
					}
				}
				slot = min_k
				sv_opp.joints[slot] = u16(opp_j_idx)
			}

			sv_opp.weights[slot] = src_w

			// Scale other slots to sum to 1.0 - src_w
			rem := max(0.0, 1.0 - src_w)
			other_sum: f32 = 0.0
			for k in 0 ..< 4 {
				if k != slot do other_sum += sv_opp.weights[k]
			}
			if other_sum > 0.001 {
				for k in 0 ..< 4 {
					if k != slot {
						sv_opp.weights[k] = (sv_opp.weights[k] / other_sum) * rem
					}
				}
			} else {
				p_slot := (slot + 1) % 4
				sv_opp.weights[p_slot] = rem
			}

			// Enforce partition of unity
			tot: f32 = 0.0
			for k in 0 ..< 4 do tot += sv_opp.weights[k]
			if tot > 0.001 {
				for k in 0 ..< 4 do sv_opp.weights[k] /= tot
			}
		}
	}

	adm.posed_frame = 0
	if s := engine.sm_scene_get_active(); s != nil do s.dirty = true
	return true
}

// Automatically detects whether a `.glb` / `.gltf` asset (`mesh_guid`) is a Skeletal Mesh (has skin/joints)
// or a Static Mesh:
// - If Skeletal Mesh: spawns a Control Rig character (`ArmatureDeformedMesh` + `ControlRig` + `HumanoidIkSolver` + full Bone Tree)!
// - If Static Mesh:   spawns a standard 3D Mesh entity (`MeshFilter` + `MeshRenderer`)!
instantiate_gltf_model_auto :: proc(
	mesh_guid:     engine.Asset_GUID,
	model_name:    string,
	parent_tH:     engine.Transform_Handle,
	spawn_pos:     [3]f32 = {},
	has_spawn_pos: bool   = false,
) -> (new_tH: engine.Transform_Handle, is_skeletal: bool) {
	w := engine.ctx_world()
	scene := engine.sm_scene_get_active()
	if w == nil || scene == nil || engine.asset_guid_is_empty(mesh_guid) {
		return {}, false
	}

	parent := parent_tH if (parent_tH != {} && engine.pool_valid(&w.transforms, engine.Handle(parent_tH))) else engine.Transform_Handle(scene.root.handle)
	safe_name := model_name if len(model_name) > 0 else "GLTF_Model"

	mesh, mok := engine.mesh_load(mesh_guid, 0)
	is_skeletal = mok && mesh != nil && engine.mesh_is_skinned(mesh)
	if !is_skeletal {
		if source_path, pok := engine.asset_db_get_path(uuid.Identifier(mesh_guid)); pok && len(source_path) > 0 {
			path_c := strings.clone_to_cstring(source_path, context.temp_allocator)
			opts := cgltf.options{}
			if data, parse_res := cgltf.parse_file(opts, path_c); parse_res == .success {
				is_skeletal = len(data.skins) > 0
				cgltf.free(data)
			}
		}
	}

	new_tH = engine.transform_new(safe_name, parent)
	if new_tH == {} do return {}, false
	engine.transform_ensure_unique_name(new_tH)
	if has_spawn_pos {
		engine.transform_set_world_position(new_tH, spawn_pos)
	}

	if is_skeletal {
		_, adm_ptr := engine.transform_add_comp(new_tH, .ArmatureDeformedMesh)
		if adm := cast(^ArmatureDeformedMesh)adm_ptr; adm != nil {
			reset_ArmatureDeformedMesh(adm)
			adm.mesh                   = mesh_guid
			adm.anchor_to_actor        = true
			adm.auto_resolve_materials = true
			adm.cast_shadows           = true
			armature_deformed_mesh_spawn_skeleton(adm)
			armature_deformed_mesh_reset_bind_pose(adm)
		}
		_, rig_ptr := engine.transform_add_comp(new_tH, .ControlRig)
		if rig := cast(^ControlRig)rig_ptr; rig != nil {
			reset_ControlRig(rig)
			skeleton_bind_humanoid(&rig.bones, new_tH)
			control_rig_sync_from_skeleton(rig)
		}
		_, ik_ptr := engine.transform_add_comp(new_tH, .HumanoidIkSolver)
		if ik := cast(^HumanoidIkSolver)ik_ptr; ik != nil {
			reset_HumanoidIkSolver(ik)
		}
	} else {
		_, mf_ptr := engine.transform_add_comp(new_tH, .MeshFilter)
		if mf := cast(^engine.MeshFilter)mf_ptr; mf != nil {
			mf.mesh = engine.PPtr{guid = mesh_guid, local_id = 0}
		}
		_, mr_ptr := engine.transform_add_comp(new_tH, .MeshRenderer)
		if mr := cast(^engine.MeshRenderer)mr_ptr; mr != nil {
			mr.cast_shadows = true
		}
	}

	scene.dirty = true
	return new_tH, is_skeletal
}

// Extracts the current posed vertices & triangle indices of an `ArmatureDeformedMesh` in the entity's local space
// so a posed skeletal mesh / humanoid statue can be wrapped directly into a static `CSGVolume` or `Faker CSG`!
armature_extract_posed_local_geometry :: proc(
	target_h:  engine.Transform_Handle,
	allocator := context.temp_allocator,
) -> (verts: []gfx.Vertex, indices: []u32, mesh_guid: engine.Asset_GUID, ok: bool) {
	w := engine.ctx_world()
	if w == nil || target_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(target_h)) {
		return nil, nil, {}, false
	}
	_, adm := engine.transform_get_comp(target_h, ArmatureDeformedMesh)
	if adm == nil || !adm.enabled || engine.asset_guid_is_empty(adm.mesh) {
		return nil, nil, {}, false
	}
	mesh, mok := engine.mesh_load(adm.mesh, adm.bound_part)
	if !mok || mesh == nil || len(mesh.bind_vertices) < 3 || len(mesh.bind_indices) < 3 {
		return nil, nil, {}, false
	}
	if engine.mesh_is_skinned(mesh) {
		if !adm.bound_ready || !_adm_joints_alive(adm) {
			_ = _adm_bind(adm, mesh, adm.mesh, adm.bound_part, target_h)
		}
		if adm.bound_ready {
			_adm_skin_pose(adm, mesh, target_h)
		}
	}

	tw := engine.transform_world(target_h)
	inv_model := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))

	src_v := adm.posed[:] if (len(adm.posed) == len(mesh.bind_vertices) && engine.mesh_is_skinned(mesh)) else mesh.bind_vertices
	out_v := make([]gfx.Vertex, len(src_v), allocator)
	for v, i in src_v {
		out_v[i] = v
		if len(adm.posed) == len(mesh.bind_vertices) && engine.mesh_is_skinned(mesh) {
			// `adm.posed` vertices are in world space; transform back to `target_h` local space!
			lp4 := inv_model * [4]f32{v.position.x, v.position.y, v.position.z, 1.0}
			ln4 := inv_model * [4]f32{v.normal.x, v.normal.y, v.normal.z, 0.0}
			out_v[i].position = lp4.xyz
			out_v[i].normal   = linalg.normalize0(ln4.xyz)
		}
	}
	out_i := make([]u32, len(mesh.bind_indices), allocator)
	copy(out_i, mesh.bind_indices)
	return out_v, out_i, adm.mesh, true
}

// Ensures `adm.posed` is bound and evaluated for the current bone transforms, returning world-space posed vertices,
// triangle indices, and the underlying `^engine.Mesh` for ray-traced anatomical collider fitting and auto-rigging.
armature_ensure_posed_world_geometry :: proc(
	adm: ^ArmatureDeformedMesh,
) -> (world_verts: []gfx.Vertex, indices: []u32, mesh: ^engine.Mesh, ok: bool) {
	if adm == nil || engine.asset_guid_is_empty(adm.mesh) do return nil, nil, nil, false
	w := engine.ctx_world()
	if w == nil do return nil, nil, nil, false
	owner_h := engine.Transform_Handle(adm.owner)
	if owner_h == {} || !engine.pool_valid(&w.transforms, engine.Handle(owner_h)) do return nil, nil, nil, false

	m, mok := engine.mesh_load(adm.mesh, adm.bound_part)
	if !mok || m == nil || len(m.bind_vertices) < 3 || len(m.bind_indices) < 3 {
		return nil, nil, nil, false
	}
	if engine.mesh_is_skinned(m) {
		if !adm.bound_ready || !_adm_joints_alive(adm) {
			_ = _adm_bind(adm, m, adm.mesh, adm.bound_part, owner_h)
		}
		if adm.bound_ready {
			adm.posed_frame = 0
			_adm_skin_pose(adm, m, owner_h)
		}
	}
	if len(adm.posed) == len(m.bind_vertices) {
		return adm.posed[:], m.bind_indices, m, true
	}
	return m.bind_vertices, m.bind_indices, m, true
}

