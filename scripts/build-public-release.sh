#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${MACTUBE_DERIVED_DATA:-$ROOT/Build/DerivedData}"
PACKAGES="${MACTUBE_PACKAGE_CACHE:-$DERIVED/SourcePackages}"
cd "$ROOT"
exec xcodebuild build -workspace MacTube.xcworkspace -scheme MacTube \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$PACKAGES" \
  -disableAutomaticPackageResolution -jobs 3 ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= MARKETING_VERSION=6.0.1 CURRENT_PROJECT_VERSION=29 \
  DEBUG_INFORMATION_FORMAT=dwarf CLANG_ENABLE_CODE_COVERAGE=NO GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO GCC_GENERATE_TEST_COVERAGE_FILES=NO ENABLE_CODE_COVERAGE=NO SWIFT_ENABLE_CODE_COVERAGE=NO \
  "OTHER_SWIFT_FLAGS=\$(inherited) -debug-prefix-map $ROOT=/src/MacTube -file-prefix-map $ROOT=/src/MacTube -debug-prefix-map $HOME=/build/home -file-prefix-map $HOME=/build/home" \
  "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=/src/MacTube -ffile-prefix-map=$HOME=/build/home"
