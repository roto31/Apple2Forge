#!/bin/bash
# Universal (Apple silicon + Intel) build helpers. Source after gates.sh.
# Bash 3.2 compatible (macOS /bin/bash).

# CMake list syntax; SwiftPM takes the same names as repeated --arch flags.
readonly UNIVERSAL_ARCHS="arm64;x86_64"
readonly UNIVERSAL_SWIFT_ARCH_FLAGS=(--arch arm64 --arch x86_64)

# is_universal BINARY → 0 when BINARY has both an arm64 and an x86_64 slice.
is_universal() {
  local archs
  archs=" $(lipo -archs "$1" 2>/dev/null) "
  [[ "${archs}" == *" arm64 "* && "${archs}" == *" x86_64 "* ]]
}

# describe_archs BINARY → the slices lipo reports, or "unreadable".
describe_archs() {
  lipo -archs "$1" 2>/dev/null || echo "unreadable"
}

# rosetta_available → 0 when x86_64 code can run here (Intel, or Rosetta 2).
rosetta_available() {
  arch -x86_64 /usr/bin/true >/dev/null 2>&1
}
