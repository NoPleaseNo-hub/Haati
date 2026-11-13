# Shortcuts for tools/mh (also callable via tools/haati). This file FORWARDS ONLY —
# every build decision lives in tools/mh so there is one definition of how Haati builds.
#
#   odin run tools/haati -- <command>
#   odin run tools/mh -- <command>

MH := odin run tools/mh --

.PHONY: help setup run debug build check hot overwatch app package test prebuild deps shaders mcp clean distclean

help:      ; @$(MH) help
setup:     ; @$(MH) setup
run:       ; @$(MH) run
debug:     ; @$(MH) debug
build:     ; @$(MH) build
check:     ; @$(MH) check
hot:       ; @$(MH) hot
overwatch: ; @$(MH) overwatch
app:       ; @$(MH) app
package:   ; @$(MH) package
prebuild:  ; @$(MH) prebuild
deps:      ; @$(MH) deps $(NAME)
shaders:   ; @$(MH) shaders
mcp:       ; @$(MH) mcp
clean:     ; @$(MH) clean
distclean: ; @$(MH) clean --all
test:      ; @$(MH) test $(if $(NAME),--name=$(NAME),)
