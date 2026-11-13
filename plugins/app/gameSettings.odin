package app

@(typ_guid={guid = "f47ac10b-58cc-4372-a567-0e02b2c3d479", menu_assets_create = {menu_name = "Game Settings", order = 0}})
GameSettings :: struct {
    playerSpeed: f32 `inspect:""
        decor:min(0.5)`,
    maxHealth: int `
        decor:min(5)
        `,

    isDebugMode: bool,

    test: bool `
        decor:readonly()
        `,

    gameNames:[dynamic]string `
        decor:header(text="Test Header")
        decor:tooltip(desc="Tooltip message")`,

    dynamicInt:[dynamic]int `
        decor:separator()`,
    int3:[3]int,
}

cleanup_GameSettings :: proc(g: ^GameSettings) {
    for n in g.gameNames do delete(n)
    delete(g.gameNames)
    delete(g.dynamicInt)
    g^ = {}
}
