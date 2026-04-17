// This is set during the build so it also has to be set
// during import time to get the right types. Without this
// you get stack size mismatches on some structs.
#define IMGUI_USE_WCHAR32 1

#define IMGUI_HAS_DOCK 1
#include "dcimgui.h"
