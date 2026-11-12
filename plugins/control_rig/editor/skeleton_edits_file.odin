package control_rig_editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import engine "moonhug:engine"
import crig "moonhug:packages/control_rig"

SKELETON_EDITS_DIR :: "assets/skeleton_edits"
SKEL_EDITS_EXT     :: ".mhskel"
SKEL_BINARY_MAGIC  :: [4]u8{'M', 'H', 'S', 'K'}
SKEL_BINARY_VER    :: u32(1)

// Flat binary header for .mhskel files (84 bytes, #packed, zero reflection overhead).
Skeleton_Edits_Bin_Header :: struct #packed {
	magic:                [4]u8,
	version:              u32,
	mesh_name_len:        u8,
	mesh_name_buf:        [63]u8,
	custom_bone_count:    u32,
	bone_transform_count: u32,
	skin_vertex_count:    u32,
}

// Flat binary record for a custom hierarchy bone and its optional SpringBone parameters.
Skeleton_Custom_Bone_Bin :: struct #packed {
	name_len:         u8,
	name_buf:         [63]u8,
	parent_name_len:  u8,
	parent_name_buf:  [63]u8,
	local_pos:        [3]f32,
	local_rot:        [4]f32,
	local_scale:      [3]f32,
	has_spring_bone:  u8,
	_pad:             [3]u8,
	spring_stiffness: f32,
	spring_damping:   f32,
	spring_gravity:   [3]f32,
	spring_drag:      f32,
	spring_max_angle: f32,
	spring_bone_len:  f32,
	spring_axis:      [3]f32,
}

// Flat binary record for a joint local transform override.
Skeleton_Bone_Transform_Bin :: struct #packed {
	name_len:        u8,
	name_buf:        [63]u8,
	parent_name_len: u8,
	parent_name_buf: [63]u8,
	local_pos:       [3]f32,
	local_rot:       [4]f32,
	local_scale:     [3]f32,
}

// Flat binary record for a sparse vertex skinning override (28 bytes).
Skeleton_Skin_Vertex_Bin :: struct #packed {
	idx:     u32,
	joints:  [4]u16,
	weights: [4]f32,
}

@(private = "file")
_pack_fixed_name :: proc(dst_buf: ^[63]u8, src: string) -> u8 {
	n := min(len(src), 63)
	dst_buf^ = {}
	if n > 0 {
		copy(dst_buf[:n], transmute([]u8)src[:n])
	}
	return u8(n)
}

@(private = "file")
_unpack_fixed_name :: proc(src_buf: ^[63]u8, n: u8) -> string {
	clamped := min(int(n), 63)
	if clamped <= 0 do return ""
	return string(src_buf[:clamped])
}

// Ensures the assets/skeleton_edits directory exists.
ensure_skeleton_edits_dir :: proc() -> bool {
	if !os.is_dir(SKELETON_EDITS_DIR) {
		if err := os.make_directory(SKELETON_EDITS_DIR); err != nil {
			return false
		}
	}
	return true
}

// Returns a list of all saved .mhskel file basenames in assets/skeleton_edits.
skeleton_edits_list_files :: proc(allocator := context.temp_allocator) -> [dynamic]string {
	res := make([dynamic]string, allocator)
	if !os.is_dir(SKELETON_EDITS_DIR) do return res

	handle, err := os.open(SKELETON_EDITS_DIR)
	if err != nil do return res
	defer os.close(handle)

	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return res
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for entry in entries {
		if strings.has_suffix(entry.name, SKEL_EDITS_EXT) {
			name := entry.name[:len(entry.name) - len(SKEL_EDITS_EXT)]
			append(&res, strings.clone(name, allocator))
		}
	}
	return res
}

// Saves all current bone transforms, custom bones, and skin weights to assets/skeleton_edits/<preset_name>.mhskel
skeleton_edits_save_to_file :: proc(adm: ^crig.ArmatureDeformedMesh, preset_name: string) -> (path: string, count: int, ok: bool) {
	if adm == nil do return "", 0, false
	w := engine.ctx_world()
	if w == nil do return "", 0, false

	cleaned := strings.trim_space(preset_name)
	if len(cleaned) == 0 do return "", 0, false

	ensure_skeleton_edits_dir()

	owner_h := engine.Transform_Handle(adm.owner)
	mesh_name := "Mesh"
	if bt := engine.pool_get(&w.transforms, engine.Handle(owner_h)); bt != nil {
		mesh_name = bt.name
	}

	custom_bones    := make([dynamic]Skeleton_Custom_Bone_Bin, context.temp_allocator)
	bone_transforms := make([dynamic]Skeleton_Bone_Transform_Bin, context.temp_allocator)
	custom_weights  := make([dynamic]Skeleton_Skin_Vertex_Bin, context.temp_allocator)

	search_root := engine.Transform_Handle(adm.root_bone.handle)
	if search_root == {} do search_root = owner_h

	// 1. Record Custom Bones
	for cname in adm.custom_joint_names {
		bone_h, found := _find_bone_in_adm_hierarchy(search_root, owner_h, cname)
		if found && bone_h != {} && engine.pool_valid(&w.transforms, engine.Handle(bone_h)) {
			bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
			parent_name := ""
			if bt.parent.handle != {} {
				if pt := engine.pool_get(&w.transforms, bt.parent.handle); pt != nil {
					parent_name = pt.name
				}
			}
			cbd: Skeleton_Custom_Bone_Bin
			cbd.name_len        = _pack_fixed_name(&cbd.name_buf, cname)
			cbd.parent_name_len = _pack_fixed_name(&cbd.parent_name_buf, parent_name)
			cbd.local_pos       = bt.position
			cbd.local_rot       = bt.rotation
			cbd.local_scale     = bt.scale

			_, sb := engine.transform_get_comp(bone_h, crig.SpringBone)
			if sb != nil {
				cbd.has_spring_bone  = 1
				cbd.spring_stiffness = sb.stiffness
				cbd.spring_damping   = sb.damping
				cbd.spring_gravity   = sb.gravity
				cbd.spring_drag      = sb.drag
				cbd.spring_max_angle = sb.max_angle_deg
				cbd.spring_bone_len  = sb.bone_length
				cbd.spring_axis      = sb.forward_axis
			}
			append(&custom_bones, cbd)
		}
	}

	// 2. Record All Bone Transforms
	for j in adm.joints {
		if j != {} && engine.pool_valid(&w.transforms, engine.Handle(j)) {
			bt := engine.pool_get(&w.transforms, engine.Handle(j))
			parent_name := ""
			if bt.parent.handle != {} {
				if pt := engine.pool_get(&w.transforms, bt.parent.handle); pt != nil {
					parent_name = pt.name
				}
			}
			btd: Skeleton_Bone_Transform_Bin
			btd.name_len        = _pack_fixed_name(&btd.name_buf, bt.name)
			btd.parent_name_len = _pack_fixed_name(&btd.parent_name_buf, parent_name)
			btd.local_pos       = bt.position
			btd.local_rot       = bt.rotation
			btd.local_scale     = bt.scale
			append(&bone_transforms, btd)
		}
	}

	// 3. Record Custom Weights (if any)
	mesh_guid := adm.mesh
	if !engine.asset_guid_is_empty(mesh_guid) {
		mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
		if mok && mesh != nil && len(adm.custom_skin) == len(mesh.bind_vertices) {
			for i in 0 ..< len(adm.custom_skin) {
				c_sv := adm.custom_skin[i]
				m_sv := mesh.skin[i]
				if c_sv.joints != m_sv.joints || c_sv.weights != m_sv.weights {
					append(&custom_weights, Skeleton_Skin_Vertex_Bin{
						idx     = u32(i),
						joints  = c_sv.joints,
						weights = c_sv.weights,
					})
				}
			}
		}
	}

	// 4. Write contiguous flat binary buffer directly to disk
	hdr: Skeleton_Edits_Bin_Header
	hdr.magic                = SKEL_BINARY_MAGIC
	hdr.version              = SKEL_BINARY_VER
	hdr.mesh_name_len        = _pack_fixed_name(&hdr.mesh_name_buf, mesh_name)
	hdr.custom_bone_count    = u32(len(custom_bones))
	hdr.bone_transform_count = u32(len(bone_transforms))
	hdr.skin_vertex_count    = u32(len(custom_weights))

	hdr_bytes  := mem.ptr_to_bytes(&hdr)
	cb_bytes   := mem.slice_to_bytes(custom_bones[:])
	bt_bytes   := mem.slice_to_bytes(bone_transforms[:])
	sv_bytes   := mem.slice_to_bytes(custom_weights[:])
	total_size := len(hdr_bytes) + len(cb_bytes) + len(bt_bytes) + len(sv_bytes)

	buf := make([]u8, total_size, context.temp_allocator)
	offset := 0
	copy(buf[offset:], hdr_bytes); offset += len(hdr_bytes)
	copy(buf[offset:], cb_bytes);  offset += len(cb_bytes)
	copy(buf[offset:], bt_bytes);  offset += len(bt_bytes)
	copy(buf[offset:], sv_bytes)

	out_path := fmt.tprintf("%s/%s%s", SKELETON_EDITS_DIR, cleaned, SKEL_EDITS_EXT)
	if werr := os.write_entire_file(out_path, buf); werr != nil {
		return "", 0, false
	}

	return out_path, len(bone_transforms), true
}

// Loads bone transforms, custom bones, and weights from assets/skeleton_edits/<preset_name>.mhskel
skeleton_edits_load_from_file :: proc(adm: ^crig.ArmatureDeformedMesh, preset_name: string) -> (bone_count: int, custom_count: int, ok: bool) {
	if adm == nil do return 0, 0, false
	w := engine.ctx_world()
	if w == nil do return 0, 0, false

	cleaned := strings.trim_space(preset_name)
	if len(cleaned) == 0 do return 0, 0, false

	in_path := fmt.tprintf("%s/%s%s", SKELETON_EDITS_DIR, cleaned, SKEL_EDITS_EXT)
	data, rerr := os.read_entire_file(in_path, context.temp_allocator)
	if rerr != nil || len(data) < size_of(Skeleton_Edits_Bin_Header) {
		return 0, 0, false
	}

	hdr := (^Skeleton_Edits_Bin_Header)(raw_data(data))
	if hdr.magic != SKEL_BINARY_MAGIC || hdr.version != SKEL_BINARY_VER {
		return 0, 0, false
	}

	cb_size := int(hdr.custom_bone_count) * size_of(Skeleton_Custom_Bone_Bin)
	bt_size := int(hdr.bone_transform_count) * size_of(Skeleton_Bone_Transform_Bin)
	sv_size := int(hdr.skin_vertex_count) * size_of(Skeleton_Skin_Vertex_Bin)
	expected_size := size_of(Skeleton_Edits_Bin_Header) + cb_size + bt_size + sv_size
	if len(data) < expected_size {
		return 0, 0, false
	}

	offset := size_of(Skeleton_Edits_Bin_Header)
	custom_bones := slice.from_ptr((^Skeleton_Custom_Bone_Bin)(raw_data(data[offset:])), int(hdr.custom_bone_count)) if hdr.custom_bone_count > 0 else nil
	offset += cb_size
	bone_transforms := slice.from_ptr((^Skeleton_Bone_Transform_Bin)(raw_data(data[offset:])), int(hdr.bone_transform_count)) if hdr.bone_transform_count > 0 else nil
	offset += bt_size
	custom_weights := slice.from_ptr((^Skeleton_Skin_Vertex_Bin)(raw_data(data[offset:])), int(hdr.skin_vertex_count)) if hdr.skin_vertex_count > 0 else nil

	owner_h := engine.Transform_Handle(adm.owner)
	search_root := engine.Transform_Handle(adm.root_bone.handle)
	if search_root == {} do search_root = owner_h

	// 1. Restore / Spawn Custom Bones
	loaded_custom := 0
	for &cbd in custom_bones {
		cname := _unpack_fixed_name(&cbd.name_buf, cbd.name_len)
		pname := _unpack_fixed_name(&cbd.parent_name_buf, cbd.parent_name_len)
		bone_h, found := _find_bone_in_adm_hierarchy(search_root, owner_h, cname)
		if !found || bone_h == {} {
			parent_h, p_found := _find_bone_in_adm_hierarchy(search_root, owner_h, pname)
			if !p_found || parent_h == {} do parent_h = search_root
			new_h, sok := crig.armature_add_child_bone(adm, parent_h, cname, cbd.local_pos)
			if sok {
				bone_h = new_h
				loaded_custom += 1
			}
		} else {
			loaded_custom += 1
		}

		if bone_h != {} && engine.pool_valid(&w.transforms, engine.Handle(bone_h)) {
			bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
			if bt != nil {
				bt.position = cbd.local_pos
				bt.rotation = cbd.local_rot
				bt.scale    = cbd.local_scale
			}
			if cbd.has_spring_bone != 0 {
				_, sb := engine.transform_get_comp(bone_h, crig.SpringBone)
				if sb == nil {
					_, raw := engine.transform_add_comp(bone_h, .SpringBone)
					sb = cast(^crig.SpringBone)raw
				}
				if sb != nil {
					sb.stiffness     = cbd.spring_stiffness
					sb.damping       = cbd.spring_damping
					sb.gravity       = cbd.spring_gravity
					sb.drag          = cbd.spring_drag
					sb.max_angle_deg = cbd.spring_max_angle
					sb.bone_length   = cbd.spring_bone_len
					sb.forward_axis  = cbd.spring_axis
				}
			}
		}
	}

	// 2. Restore Bone Transforms
	loaded_bones := 0
	for &btd in bone_transforms {
		bname := _unpack_fixed_name(&btd.name_buf, btd.name_len)
		bone_h, found := _find_bone_in_adm_hierarchy(search_root, owner_h, bname)
		if found && bone_h != {} && engine.pool_valid(&w.transforms, engine.Handle(bone_h)) {
			bt := engine.pool_get(&w.transforms, engine.Handle(bone_h))
			if bt != nil {
				bt.position = btd.local_pos
				bt.rotation = btd.local_rot
				bt.scale    = btd.local_scale
				loaded_bones += 1
			}
		}
	}

	// 3. Restore Custom Weights
	mesh_guid := adm.mesh
	if len(custom_weights) > 0 && !engine.asset_guid_is_empty(mesh_guid) {
		mesh, mok := engine.mesh_load(mesh_guid, adm.bound_part)
		if mok && mesh != nil {
			if len(adm.custom_skin) != len(mesh.bind_vertices) {
				if adm.custom_skin == nil do adm.custom_skin = make([dynamic]engine.Mesh_Skin_Vertex)
				resize(&adm.custom_skin, len(mesh.bind_vertices))
				copy(adm.custom_skin[:], mesh.skin)
			}
			for &wd in custom_weights {
				idx := int(wd.idx)
				if idx >= 0 && idx < len(adm.custom_skin) {
					adm.custom_skin[idx].joints  = wd.joints
					adm.custom_skin[idx].weights = wd.weights
				}
			}
		}
	}

	// 4. Update rest poses for all custom bones so no polygon jumping occurs!
	crig.armature_set_all_custom_bones_rest_pose(adm)
	adm.posed_frame = 0
	if sc := engine.sm_scene_get_active(); sc != nil do sc.dirty = true

	return loaded_bones, loaded_custom, true
}

// Deletes a save file from assets/skeleton_edits/<preset_name>.mhskel
skeleton_edits_delete_file :: proc(preset_name: string) -> bool {
	cleaned := strings.trim_space(preset_name)
	if len(cleaned) == 0 do return false

	path := fmt.tprintf("%s/%s%s", SKELETON_EDITS_DIR, cleaned, SKEL_EDITS_EXT)
	if !os.exists(path) do return false

	_ = os.remove(path)
	meta := fmt.tprintf("%s.meta", path)
	if os.exists(meta) do _ = os.remove(meta)
	return true
}

@(private = "file")
_find_bone_in_adm_hierarchy :: proc(search_root, owner_h: engine.Transform_Handle, name: string) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	if w == nil do return {}, false

	_find_recursive :: proc(h: engine.Transform_Handle, target: string, w: ^engine.World) -> (engine.Transform_Handle, bool) {
		if h == {} || !engine.pool_valid(&w.transforms, engine.Handle(h)) do return {}, false
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do return {}, false
		if strings.equal_fold(t.name, target) do return h, true
		for c in t.children {
			if pool_c := engine.Transform_Handle(c.handle); pool_c != {} {
				if res, ok := _find_recursive(pool_c, target, w); ok do return res, true
			}
		}
		return {}, false
	}

	if h, ok := _find_recursive(search_root, name, w); ok do return h, true
	if search_root != owner_h {
		if h, ok := _find_recursive(owner_h, name, w); ok do return h, true
	}
	return {}, false
}
