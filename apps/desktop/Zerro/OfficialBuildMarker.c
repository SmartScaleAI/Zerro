//
//  OfficialBuildMarker.c
//  Zerro
//
//  The official-build marker that survives the exported app's stripping.
//
//  Why C, and why weak: the archive/export post-processing runs `strip` on the
//  app executable with STRIP_STYLE=all, which removes every non-weak symbol,
//  exported or not. The only definitions that survive are WEAK definitions
//  (dyld needs them for coalescing). Swift cannot emit a weak definition for a
//  @_cdecl function, so the marker is defined here in C with
//  __attribute__((weak)) and default visibility. Its Mach-O symbol is
//  `_zerroOfficialBuildMarker` (C name plus the leading underscore), listed by
//  `nm -g --defined-only` on the exported binary. Community builds do not
//  compile this definition at all, so their binaries contain no such symbol.
//
//  Why it calls into Swift: the C macro OFFICIAL_BUILD and the Swift condition
//  OFFICIAL_BUILD are set by two separate build settings. The marker reports
//  official only through `zerroOfficialBuildSwiftMarker`, which
//  BuildEnvironment.swift defines ONLY under the Swift condition. A build with
//  the C macro but not the Swift condition therefore has an undefined symbol
//  and FAILS TO LINK, so no artifact can ever carry the marker while Swift
//  runs in community mode; a build with the Swift condition but not the C
//  macro fails to compile, because the header declares nothing. Only a build
//  with both produces the marker, and in that build `Build.isOfficialBuild`
//  is true.
//

#include "OfficialBuildMarker.h"

#if defined(OFFICIAL_BUILD) && OFFICIAL_BUILD

/// Defined in BuildEnvironment.swift (`@_cdecl`) only under the Swift
/// OFFICIAL_BUILD condition. Referenced here on purpose: see the header
/// comment for why the reference is the fail-closed pairing.
extern int32_t zerroOfficialBuildSwiftMarker(void);

__attribute__((weak, visibility("default")))
int32_t zerroOfficialBuildMarker(void) {
    return zerroOfficialBuildSwiftMarker();
}

#endif
