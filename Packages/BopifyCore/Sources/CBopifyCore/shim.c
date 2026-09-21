/* This target exists to carry the module map and the linker settings a
   binaryTarget cannot. SwiftPM skips a target with no source file, so this
   one compiles the generated header and nothing else. */
#include "../../../../artifacts/include/bopify_core.h"
