#!/bin/zsh
#
# Builds Ice in the Release configuration, signs it with the local code
# signing identity, and installs it to /Applications.
#
# Signing every build with the same identity keeps the app's code signing
# requirement stable, so macOS retains the Accessibility and Screen Recording
# permissions across rebuilds.
#
# Usage: Scripts/install_local_build.sh

set -euo pipefail

readonly SIGNING_IDENTITY="${ICE_SIGNING_IDENTITY:-Ice Local Code Signing}"
readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly WORK_ROOT="${REPOSITORY_ROOT:h}"
readonly DERIVED_DATA="${WORK_ROOT}/build"
readonly PACKAGE_DIRECTORY="${WORK_ROOT}/spm"
readonly BUILD_LOG="${WORK_ROOT}/build.log"
readonly PRODUCT="${DERIVED_DATA}/Build/Products/Release/Ice.app"
readonly DESTINATION="/Applications/Ice.app"

if ! security find-identity -p codesigning | grep -q "\"${SIGNING_IDENTITY}\""; then
    print -u2 "Signing identity \"${SIGNING_IDENTITY}\" was not found in the keychain."
    exit 1
fi

print "Building (log: ${BUILD_LOG})"
xcodebuild \
    -project "${REPOSITORY_ROOT}/Ice.xcodeproj" \
    -scheme Ice \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${PACKAGE_DIRECTORY}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    ENABLE_HARDENED_RUNTIME=NO \
    build > "${BUILD_LOG}" 2>&1 || {
        grep -E "error:" "${BUILD_LOG}" | sort -u >&2
        print -u2 "Build failed."
        exit 1
    }

print "Signing with \"${SIGNING_IDENTITY}\""
# Sign nested code first, deepest paths first, then the app itself.
nested_code=("${(@f)$(find "${PRODUCT}/Contents" \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)}")
for item in "${nested_code[@]}"; do
    [[ -n "${item}" ]] || continue
    codesign --force --sign "${SIGNING_IDENTITY}" --preserve-metadata=identifier,entitlements,flags "${item}"
done
codesign --force --sign "${SIGNING_IDENTITY}" --preserve-metadata=identifier,entitlements,flags "${PRODUCT}"
codesign --verify --deep --strict "${PRODUCT}"

print "Installing to ${DESTINATION}"
pkill -x Ice 2>/dev/null || true
pkill -x MenuBarItemService 2>/dev/null || true
sleep 1
rm -rf "${DESTINATION}"
ditto "${PRODUCT}" "${DESTINATION}"
open "${DESTINATION}"
print "Done."
