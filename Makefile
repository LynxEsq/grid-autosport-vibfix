# GRID Autosport Vibration Fix — Build
# IMPORTANT: Must be x86_64 (game runs under Rosetta 2)
ARCH = x86_64
MIN_MACOS = 13.0
CFLAGS = -arch $(ARCH) -mmacosx-version-min=$(MIN_MACOS) -Wno-deprecated-declarations

.PHONY: all clean

all: grid_vibfix.dylib stop_rumble

grid_vibfix.dylib: grid_vibfix.m
	clang -dynamiclib -o $@ grid_vibfix.m -framework Foundation -framework IOKit $(CFLAGS)
	codesign -fs - $@

stop_rumble: stop_rumble.m
	clang -o $@ stop_rumble.m -framework Foundation -framework IOKit $(CFLAGS)
	codesign -fs - $@

clean:
	rm -f grid_vibfix.dylib stop_rumble
