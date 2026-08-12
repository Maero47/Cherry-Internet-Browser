#!/bin/bash
#
# build-dmg.sh — build Cherry as a Release .app and wrap it in a .dmg.
#
# Run it from anywhere; it locates the project from its own path:
#
#     Tools/build-dmg.sh                  # -> dist/Cherry-<version>.dmg
#     Tools/build-dmg.sh --output ~/tmp   # somewhere else
#     Tools/build-dmg.sh --keep-derived-data
#
# WHAT IT PRODUCES, AND WHAT IT DOES NOT
#
# The app is signed ad-hoc (`codesign --sign -`). That is the only kind of
# signature this machine can make: there is no code-signing identity in the
# keychain, so there is no Developer ID certificate to sign with and no
# certificate means nothing to notarize. An ad-hoc signature is enough for the
# app to run on the Mac that built it. It is NOT enough for a Mac that
# downloaded it — see the Gatekeeper section of README.md, which documents
# exactly what the downloader sees and the one route through it that was tested.
#
# REPRODUCIBILITY, HONESTLY
#
# Everything this script controls is pinned: the scheme, the Release
# configuration, a clean throwaway derived-data directory (so no stale object
# files leak in), the staging layout, the filesystem and the compression
# format. Re-running it on the same commit with the same Xcode gives a DMG with
# the same contents, the same layout and the same size.
#
# It is not byte-for-byte identical run to run, and no flag makes it so:
# hdiutil stamps a fresh UUID and creation date into every image it writes.
# That is why the script prints a SHA-256 of the image at the end — so the
# artifact you hand someone can be checked against the one you built — rather
# than claiming a checksum that would hold across builds.
#
# WHY DERIVED DATA GOES TO /private/tmp
#
# A derived-data directory inside this repository breaks CodeSign: the folder
# lives under ~/Documents, macOS FileProvider attaches extended attributes to
# everything written there, and codesign refuses a bundle carrying them. The
# directory is created under /private/tmp and deleted on exit (any exit —
# success, failure, or Ctrl-C) unless --keep-derived-data is passed.
#

set -euo pipefail

SCHEME="Internet Browser"
CONFIGURATION="Release"
APP_NAME="Cherry"
VOLUME_NAME="Cherry"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/Internet Browser/Internet Browser.xcodeproj"

OUTPUT_DIR="${REPO_ROOT}/dist"
KEEP_DERIVED_DATA=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { echo "error: --output needs a directory" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --keep-derived-data)
            KEEP_DERIVED_DATA=1
            shift
            ;;
        -h|--help)
            sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[[ -d "${PROJECT}" ]] || { echo "error: project not found at ${PROJECT}" >&2; exit 1; }

# ---------------------------------------------------------------- derived data

DERIVED_DATA="$(mktemp -d /private/tmp/cherry-dmg-XXXXXXXX)"

cleanup() {
    local status=$?
    if [[ -n "${STAGING:-}" && -d "${STAGING}" ]]; then
        rm -rf "${STAGING}"
    fi
    if [[ "${KEEP_DERIVED_DATA}" -eq 1 ]]; then
        printf '\n    derived data kept at %s\n' "${DERIVED_DATA}"
    else
        rm -rf "${DERIVED_DATA}"
    fi
    exit "${status}"
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------- build

step "Building ${SCHEME} (${CONFIGURATION})"
note "derived data: ${DERIVED_DATA}"

BUILD_LOG="${DERIVED_DATA}/xcodebuild.log"

set +e
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    build > "${BUILD_LOG}" 2>&1
BUILD_STATUS=$?
set -e

if [[ ${BUILD_STATUS} -ne 0 ]]; then
    echo "error: build failed. Last 40 lines:" >&2
    tail -40 "${BUILD_LOG}" >&2
    exit "${BUILD_STATUS}"
fi

tail -3 "${BUILD_LOG}" | sed 's/^/    /'

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
[[ -d "${APP_PATH}" ]] || { echo "error: no ${APP_NAME}.app at ${APP_PATH}" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")"

note "built ${APP_NAME}.app ${VERSION} (${BUILD_NUMBER}), needs macOS ${MINIMUM_OS} or later"

# ----------------------------------------------------------------------- strip

step "Stripping debug symbols"

# Not a size optimisation — a privacy fix, and it has to happen before signing
# because it invalidates the signature.
#
# `xcodebuild build` (as opposed to `install`/archive) does not strip, so the
# linked Release binary keeps its debug map: the stabs that name every object
# file and source directory the linker saw. On a fresh build of this project
# that is 398 occurrences of the builder's absolute path — home directory,
# username, and the entire source tree layout — sitting in an app about to be
# handed to strangers. `-S` removes exactly those and nothing the app needs.
#
# The check further down is what proves it worked; this is what makes it pass.
while IFS= read -r -d '' MACHO; do
    if file "${MACHO}" | grep -q 'Mach-O'; then
        strip -S "${MACHO}"
    fi
done < <(find "${APP_PATH}" -type f -perm +111 -print0)

note "$(du -h "${APP_PATH}/Contents/MacOS/${APP_NAME}" | cut -f1 | tr -d ' ') executable after stripping"

# ------------------------------------------------------------------- signature

step "Signing ad-hoc"

# The build already signs with "-", but stripping invalidated that signature,
# so this is not belt-and-braces — it is the signature the image ships with.
codesign --force --sign - --timestamp=none \
    --entitlements "${REPO_ROOT}/Internet Browser/Internet Browser/Internet_Browser.entitlements" \
    "${APP_PATH}" 2>&1 | sed 's/^/    /'

# Fatal, not advisory. An image whose app fails its own signature check would
# fail on the downloader's Mac in a way that really does look like damage.
if ! codesign --verify --deep --strict "${APP_PATH}" 2>&1 | sed 's/^/    /'; then
    echo "error: the signed app does not verify" >&2
    exit 1
fi
AUTHORITY="$(codesign -dv "${APP_PATH}" 2>&1 | grep -E '^(Signature|Authority)' || echo 'Signature=adhoc')"
note "verified, ${AUTHORITY}"

# --------------------------------------------------------------- private data

step "Checking the bundle for anything private"

# The app must ship with no state belonging to whoever built it. Cherry keeps
# every piece of user state outside the bundle — Core Data, settings, the MCP
# bearer token, imported themes and extensions all live in Application Support
# or UserDefaults — so anything matching here is a regression, not a warning to
# be waved through.
#
# `token` is the MCP bearer token's exact filename (MCPTokenStore.tokenFileURL);
# it is matched exactly rather than as `*token*`, which hits the
# `gpt2_tokenizer_config.json` that swift-transformers legitimately bundles.
SUSPECT="$(find "${APP_PATH}" \( \
        -name '*.sqlite' -o -name '*.sqlite-wal' -o -name '*.sqlite-shm' -o \
        -name 'token' -o -name '*.pem' -o -name '*.p12' -o -name '*.key' -o \
        -name '.env*' -o -name '*.xcuserstate' -o -name '.DS_Store' -o \
        -name 'com.cherry.browser.plist' -o -name '*.mobileprovision' \
    \) 2>/dev/null || true)"

if [[ -n "${SUSPECT}" ]]; then
    echo "error: bundle contains files that look like private state:" >&2
    echo "${SUSPECT}" >&2
    exit 1
fi
note "no databases, tokens, keys, dotfiles, provisioning or user defaults"

# The other half: a build can leak the builder without shipping a file, by
# baking their home directory into a string in a binary. Cherry itself never
# does this, but a dependency's build script could, and it is one grep.
if grep -rlq "${HOME}" "${APP_PATH}" 2>/dev/null; then
    echo "error: bundle contains the builder's home directory path:" >&2
    grep -rl "${HOME}" "${APP_PATH}" 2>/dev/null >&2
    exit 1
fi
note "no reference to ${HOME} anywhere in the bundle"

# ------------------------------------------------------------------------- dmg

step "Building the disk image"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "${OUTPUT_DIR}" && pwd)"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION}.dmg"

STAGING="$(mktemp -d /private/tmp/cherry-stage-XXXXXXXX)"
cp -R "${APP_PATH}" "${STAGING}/${APP_NAME}.app"
ln -s /Applications "${STAGING}/Applications"

# Copying strips nothing, but it can pick things up: the Finder writes a
# .DS_Store into any directory it is asked to look at. Remove any that exist so
# the image carries the app and the alias and nothing else.
find "${STAGING}" -name '.DS_Store' -delete 2>/dev/null || true

rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "${DMG_PATH}"

DMG_SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
DMG_BYTES="$(stat -f%z "${DMG_PATH}")"
DMG_SHA="$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"

# ---------------------------------------------------------------------- report

cat <<REPORT

$(printf '\033[1m')Built $(printf '\033[0m')${DMG_PATH}

    version    ${VERSION} (${BUILD_NUMBER})
    requires   macOS ${MINIMUM_OS} or later
    size       ${DMG_SIZE} (${DMG_BYTES} bytes)
    sha256     ${DMG_SHA}

$(printf '\033[1;33m')THIS BUILD IS NOT NOTARIZED, AND NOT SIGNED WITH A DEVELOPER ID.$(printf '\033[0m')

    It is signed ad-hoc, because this machine has no code-signing identity
    (\`security find-identity -v -p codesigning\` finds none). Ad-hoc is enough
    for the app to run on this Mac. It is not enough for anyone else's:

      * a Mac that DOWNLOADED this DMG puts a quarantine flag on it. Gatekeeper
        then refuses the app — measured on macOS 26.5.2: amfid reports "adhoc
        signed or signed by an unknown certificate chain", syspolicyd reports
        -67018 "Code did not match any currently allowed policy", a security
        dialog goes up, and the process is terminated. macOS words that as the
        app being DAMAGED, or as Apple being unable to verify it is free of
        malware, beside a Move to Trash button. Neither is true of this app.
      * the way through it — \`xattr -d com.apple.quarantine\` on the installed
        app — is documented in README.md, under Gatekeeper, with the evidence.
        Do not ship this image to anyone without that text beside it.

    Notarizing instead would need a paid Apple Developer account, a Developer ID
    Application certificate in this keychain, and an \`xcrun notarytool submit\`
    pass. None of that exists here, so none of it is faked here.

REPORT
