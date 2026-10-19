#!/bin/bash
#
# Build "Pixelmator Batch" via xcodebuild and launch it.
#
# Usage:
#   ./build.sh           # build app, launch it
#   ./build.sh build     # same, but don't launch
#   ./build.sh clean     # remove Xcode build output
#
# Environment:
#   CONFIG     Debug (default) or Release
#   ARCH       host architecture (default); set to x86_64 to cross-compile
#
# Cross-compiling for Intel
# -------------------------
#   ARCH=x86_64 CONFIG=Release ./build.sh build
#
# The app is pure Swift with no vendored C dependencies, so a non-native build
# only needs ARCHS pinned (ONLY_ACTIVE_ARCH would otherwise resolve to the
# host's). The two architectures get separate derived-data trees so a release
# can hold both at once; the host build keeps ./build so existing paths still
# work.
#
# Pixelmator Pro must be installed to *use* the app, but not to build it.

set -e
cd "$(dirname "$0")"

CONFIG="${CONFIG:-Debug}"
HOST_ARCH="$(uname -m)"
ARCH="${ARCH:-$HOST_ARCH}"
PROJECT="Pixelmator Batch.xcodeproj"
SCHEME="Pixelmator Batch"
if [ "$ARCH" = "$HOST_ARCH" ]; then
    DERIVED="./build"
else
    DERIVED="./build-$ARCH"
fi
APP_PATH="$DERIVED/Build/Products/$CONFIG/Pixelmator Batch.app"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step()  { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
fail()  { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

case "${1:-run}" in
    clean)
        step "Cleaning Xcode build output..."
        rm -rf ./build ./build-x86_64
        echo "Clean complete."
        exit 0
        ;;
    build|run)
        ;;
    *)
        fail "Unknown command: $1 (expected: build | run | clean)"
        ;;
esac

# Build the app. A non-native build pins ARCHS, since ONLY_ACTIVE_ARCH would
# otherwise resolve to the host's.
BUILD_SETTINGS=()
if [ "$ARCH" != "$HOST_ARCH" ]; then
    BUILD_SETTINGS=("ARCHS=$ARCH" "ONLY_ACTIVE_ARCH=NO")
fi

step "Building $SCHEME ($CONFIG / $ARCH) into $DERIVED ..."
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED" \
        "${BUILD_SETTINGS[@]}" \
        build | xcbeautify --quiet
else
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED" \
        "${BUILD_SETTINGS[@]}" \
        build
fi

if [ ! -d "$APP_PATH" ]; then
    fail "Build succeeded but app not found at: $APP_PATH"
fi

ACTUAL_ARCH="$(lipo -archs "$APP_PATH/Contents/MacOS/Pixelmator Batch" 2>/dev/null || echo unknown)"
case " $ACTUAL_ARCH " in
    *" $ARCH "*) ;;
    *) fail "Asked for $ARCH but the binary is [$ACTUAL_ARCH]." ;;
esac

step "Built: $APP_PATH [$ACTUAL_ARCH]"

# Launch (unless 'build' was passed). A cross-built app is left alone —
# on Apple Silicon it would launch under Rosetta, which is useful for a
# smoke test but not what someone running ./build.sh is asking for.
if [ "${1:-run}" = "run" ]; then
    if [ "$ARCH" != "$HOST_ARCH" ]; then
        warn "Not launching a $ARCH build on $HOST_ARCH. Run it manually to test under Rosetta:"
        printf "    open \"%s\"\n" "$APP_PATH"
    else
        step "Launching..."
        open "$APP_PATH"
    fi
fi
