//
//  OfficialBuildMarker.h
//  Zerro
//
//  The official-build marker, declared ONLY when the C preprocessor macro
//  OFFICIAL_BUILD is set. SmartScale's release workflows pass it as
//  GCC_PREPROCESSOR_DEFINITIONS=OFFICIAL_BUILD=1 alongside the Swift condition
//  SWIFT_ACTIVE_COMPILATION_CONDITIONS=OFFICIAL_BUILD; no checked-in
//  configuration sets either, so a plain checkout never sees this declaration
//  and never links the symbol. See OfficialBuildMarker.c and
//  BuildEnvironment.swift for how the two conditions are paired.
//

#ifndef ZERRO_OFFICIAL_BUILD_MARKER_H
#define ZERRO_OFFICIAL_BUILD_MARKER_H

#include <stdint.h>

#if defined(OFFICIAL_BUILD) && OFFICIAL_BUILD
/// Returns 1 in an official build. Exported as the weak global Mach-O symbol
/// `_zerroOfficialBuildMarker`, which is what the release workflows require
/// in the exported, stripped app binary.
int32_t zerroOfficialBuildMarker(void);
#endif

#endif /* ZERRO_OFFICIAL_BUILD_MARKER_H */
