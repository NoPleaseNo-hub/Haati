package editor

import "core:fmt"
import im "haati:external/odin-imgui"
import "menu"
import "widgets"

ABOUT_POPUP_ID :: "About"

draw_about_popup :: proc() {
    if menu.show_about {
        menu.show_about = false
        im.OpenPopup(ABOUT_POPUP_ID, {})
    }

    widgets.center_next_window_on_active_monitor(.Appearing)

    if im.BeginPopupModal(ABOUT_POPUP_ID, nil, {.AlwaysAutoResize}) {
        im.Text("%s", fmt.ctprintf("Haati Engine v%s", VERSION))
        im.Spacing()
        im.Text("Purpose-built multicore CAD-CSG, Control Rig & Data-Oriented Odin Studio.")
        im.Text("Built on the MoonHug game engine (zlib License).")
        im.Spacing()
        im.TextDisabled("Icons & Fonts: Material Symbols (Apache-2.0)  |  Phosphor Icons (MIT)  |  Watch-Wolf by Lorc / game-icons.net (CC-BY 3.0)")
        im.TextDisabled("Fonts: Roboto & JetBrains Mono")
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
