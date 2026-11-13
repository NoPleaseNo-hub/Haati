package mh

// Built-in GLSL shaders to the per-backend binaries SDL_GPU consumes: SPIR-V
// (Vulkan) via glslc, MSL (Metal) via spirv-cross. DXIL is added when Windows
// rendering support lands.
//
// Output under compiled/ is COMMITTED, so contributors do not need this
// toolchain unless they change a shader — builds skip the step when it is
// missing. Toolchain: brew install shaderc spirv-cross
//
// The .glsl ASSET importer runs the same two tools with different flags
// (moonhug/engine_editor/asset_pipeline/importer_shader.odin adds --reflect
// for binding indices). They stay separate: same tools, different output
// contracts.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SHADER_DIR :: "haati/engine/gfx/shaders"

// Stage comes from the second extension: "world.vert" -> vert.
SHADERS := []string{"world.vert", "world.frag", "lit.frag", "depth.frag", "skin.comp"}

cmd_shaders :: proc(args: []string) -> int {
	missing := false
	for tool in ([]string{"glslc", "spirv-cross"}) {
		if !have(tool) {
			fmt.eprintfln("mh: %s is not on PATH or MH_SHADER_TOOLS_DIR", tool)
			missing = true
		}
	}
	if missing {
		fmt.eprintln("mh: shader authoring needs glslc and spirv-cross on PATH or set MH_SHADER_TOOLS_DIR")
		return 1
	}
	return 0 if shaders_compile(force = true) else 1
}

// force compiles every shader. Otherwise a shader whose outputs are both newer
// than its source is skipped — builds call this on every run, and recompiling
// unchanged shaders each time is pure latency.
shaders_compile :: proc(force := false) -> bool {
	glslc_bin, ok_g := resolve_shader_tool("glslc")
	spirv_bin, ok_s := resolve_shader_tool("spirv-cross")
	if !ok_g || !ok_s do return false

	out_dir, _ := filepath.join({SHADER_DIR, "compiled"}, context.temp_allocator)
	os.make_directory_all(out_dir)

	common_src, _ := filepath.join({SHADER_DIR, "lighting_common.glsl"}, context.temp_allocator)
	for name in SHADERS {
		stage := name[strings.last_index(name, ".") + 1:]
		src, _ := filepath.join({SHADER_DIR, fmt.tprintf("%s.glsl", name)}, context.temp_allocator)
		spv, _ := filepath.join({out_dir, fmt.tprintf("%s.spv", name)}, context.temp_allocator)
		msl, _ := filepath.join({out_dir, fmt.tprintf("%s.msl", name)}, context.temp_allocator)

		if !force && newer_than(spv, src) && newer_than(msl, src) &&
		   newer_than(spv, common_src) && newer_than(msl, common_src) {
			continue
		}

		if !step(fmt.tprintf("glslc %s", name), glslc_bin, fmt.tprintf("-fshader-stage=%s", stage), "-I", SHADER_DIR, src, "-o", spv) {
			return false
		}
		// MSL entry point becomes main0 (spirv-cross convention, matches shadercross).
		// --msl-decoration-binding preserves sparse GLSL bindings (e.g. shadow atlas at slot 7).
		if !step(fmt.tprintf("spirv-cross %s", name), spirv_bin, spv, "--msl", "--msl-decoration-binding", "--output", msl) {
			return false
		}
		fmt.printfln("compiled %s", name)
	}
	return true
}
