package editor

import "core:fmt"
import im "haati:external/odin-imgui"
import "menu"

ABOUT_POPUP_ID :: "About"

draw_about_popup :: proc() {
    if menu.show_about {
        menu.show_about = false
        im.OpenPopup(ABOUT_POPUP_ID, {})
    }

    vp := im.GetMainViewport()
    center := im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}
    im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})

    if im.BeginPopupModal(ABOUT_POPUP_ID, nil, {.AlwaysAutoResize}) {
        im.Text("%s", fmt.ctprintf("Haati Engine v%s", VERSION))
        im.Spacing()
        im.Text("Purpose-built multicore CAD-CSG, Control Rig & Data-Oriented Odin Studio.")
        im.Text("Built on the MoonHug game engine (zlib License).")
        im.Spacing()
        im.TextDisabled("Platform: Windows x64 (.exe)")
        im.TextDisabled("Troubleshooting: \"It works on my machine.\"  |  Source: \"Trust me bro.\"")
        im.Spacing()
        im.Separator()
        im.Spacing()

        btn_width: f32 = 120
        avail := im.GetContentRegionAvail()
        im.SetCursorPosX(im.GetCursorPosX() + (avail.x - btn_width) * 0.5)
        if im.Button("OK", im.Vec2{btn_width, 0}) {
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}
