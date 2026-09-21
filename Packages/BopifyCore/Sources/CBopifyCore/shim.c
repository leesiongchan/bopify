/* This target carries the module map and the linker settings a binaryTarget
   cannot. SwiftPM skips a target with no source file, so this one compiles
   the header out of the xcframework, beside the archive it describes, and
   defines nothing. */
#include "../../../../artifacts/BopifyCoreFFI.xcframework/macos-arm64/Headers/bopify_core.h"
