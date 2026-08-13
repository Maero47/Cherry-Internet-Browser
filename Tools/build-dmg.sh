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
# TWO PATHS, CHOSEN BY THE ENVIRONMENT
#
# With no environment set the script signs ad-hoc, exactly as it always has,
# and says plainly at the end that the result is not distributable. Clone this
# repository and run it and that is what you get: a working build, no secrets
# required, no broken script.
#
# Set both of these and it signs for distribution instead:
#
#     CHERRY_SIGN_IDENTITY   a Developer ID Application identity — the full
#                            "Developer ID Application: …" string, or (better
#                            here) the certificate's SHA-1 hash from
#                            `security find-identity -v -p codesigning`
#     CHERRY_NOTARY_PROFILE  the name of a notarytool keychain profile, made
#                            once with `xcrun notarytool store-credentials`
#
# Neither value is in this repository and neither belongs in it: one is a
# person's name and team, the other is the handle on a credential. The script
# never asks for a password, never accepts one, and never prints the identity
# it was handed — an app-specific password lives in the keychain profile and
# nowhere else. Set one variable but not the other and the script stops and
# tells you, rather than half-signing something that cannot be distributed.
#
# The distribution path signs inside out (nested Mach-O, then nested bundles
# deepest-first, then the app) with the hardened runtime and a secure
# timestamp, notarizes the app, staples it, builds the image around the
# stapled app, then signs, notarizes and staples the image too.
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
# hdiutil stamps a fresh UUID and creation date into every image it writes, and
# a secure timestamp and a notarization ticket are different on every pass. That
# is why the script prints a SHA-256 of the image at the end — so the artifact
# you hand someone can be checked against the one you built — rather than
# claiming a checksum that would hold across builds.
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
ENTITLEMENTS="${REPO_ROOT}/Internet Browser/Internet Browser/Internet_Browser.entitlements"

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
            sed -n '2,61p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'
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
[[ -f "${ENTITLEMENTS}" ]] || { echo "error: entitlements not found at ${ENTITLEMENTS}" >&2; exit 1; }

# ------------------------------------------------------------------ which path

SIGN_IDENTITY="${CHERRY_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${CHERRY_NOTARY_PROFILE:-}"

if [[ -n "${SIGN_IDENTITY}" && -z "${NOTARY_PROFILE}" ]]; then
    cat >&2 <<'ERR'
error: CHERRY_SIGN_IDENTITY is set but CHERRY_NOTARY_PROFILE is not.

    A Developer ID signature without notarization is no better to a downloader
    than no signature at all — Gatekeeper still refuses it — so this script will
    not produce one and call it distributable. Either set both:

        export CHERRY_NOTARY_PROFILE=<your notarytool keychain profile>

    (create it once with `xcrun notarytool store-credentials`), or unset
    CHERRY_SIGN_IDENTITY to get the ad-hoc build.
ERR
    exit 2
fi

if [[ -z "${SIGN_IDENTITY}" && -n "${NOTARY_PROFILE}" ]]; then
    cat >&2 <<'ERR'
error: CHERRY_NOTARY_PROFILE is set but CHERRY_SIGN_IDENTITY is not.

    There is nothing to notarize: Apple only accepts submissions signed with a
    Developer ID Application certificate. Set the identity too —

        security find-identity -v -p codesigning
        export CHERRY_SIGN_IDENTITY=<the identity string, or its SHA-1 hash>

    — or unset CHERRY_NOTARY_PROFILE to get the ad-hoc build.
ERR
    exit 2
fi

DISTRIBUTE=0
[[ -n "${SIGN_IDENTITY}" ]] && DISTRIBUTE=1

# Both checks below cost a second each and save a six-minute build: a typo in
# either variable would otherwise not surface until after the compile.
if [[ "${DISTRIBUTE}" -eq 1 ]]; then
    step "Checking the signing identity and the notary profile"

    if ! security find-identity -v -p codesigning | grep -qF -- "${SIGN_IDENTITY}"; then
        echo "error: CHERRY_SIGN_IDENTITY does not match any code-signing identity in this keychain." >&2
        echo "       \`security find-identity -v -p codesigning\` lists what is available." >&2
        exit 1
    fi
    note "CHERRY_SIGN_IDENTITY matches a valid code-signing identity (not printed here — it is your name)"

    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        echo "error: CHERRY_NOTARY_PROFILE (\"${NOTARY_PROFILE}\") did not authenticate with Apple." >&2
        echo "       Re-create it with \`xcrun notarytool store-credentials\`, or check the network." >&2
        exit 1
    fi
    note "CHERRY_NOTARY_PROFILE authenticates"
fi

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

# The build signs ad-hoc on both paths and the signature is thrown away either
# way: stripping (below) invalidates it, and the distribution path re-signs
# every piece by hand afterwards in an order xcodebuild does not guarantee.
# Keeping the build invocation identical also keeps the two paths compiling the
# same bits, so the only difference between them is the signature.
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

if [[ "${DISTRIBUTE}" -eq 0 ]]; then

    step "Signing ad-hoc"

    # The build already signs with "-", but stripping invalidated that signature,
    # so this is not belt-and-braces — it is the signature the image ships with.
    codesign --force --sign - --timestamp=none \
        --entitlements "${ENTITLEMENTS}" \
        "${APP_PATH}" 2>&1 | sed 's/^/    /'

    # Fatal, not advisory. An image whose app fails its own signature check would
    # fail on the downloader's Mac in a way that really does look like damage.
    if ! codesign --verify --deep --strict "${APP_PATH}" 2>&1 | sed 's/^/    /'; then
        echo "error: the signed app does not verify" >&2
        exit 1
    fi
    AUTHORITY="$(codesign -dv "${APP_PATH}" 2>&1 | grep -E '^(Signature|Authority)' || echo 'Signature=adhoc')"
    note "verified, ${AUTHORITY}"

else

    step "Signing with the Developer ID identity, inside out"

    # WHY INSIDE OUT
    #
    # A bundle's signature seals everything under it, so a nested framework has
    # to be signed before the app that contains it: sign the app first and the
    # next `codesign` on a framework invalidates the seal that was just made
    # over it. Notarization checks every Mach-O file separately, and an
    # unsigned or stale-signed nested one is the single most common rejection
    # for a Mac app. So: loose Mach-O first, then nested bundles deepest-first
    # (`find -depth` gives exactly that order), then the app last.
    #
    # WHAT EACH FLAG IS FOR
    #
    #   --options runtime   the hardened runtime. Notarization refuses any
    #                       submission without it.
    #   --timestamp         a secure timestamp from Apple's server. Without it
    #                       the signature dies with the certificate; with it,
    #                       the app keeps working after the certificate expires.
    #                       Needs the network, which is why it is not in the
    #                       ad-hoc path (--timestamp=none there).
    #   --entitlements      the app's own, and only the app's. Nested code
    #                       inherits what it needs; handing entitlements to a
    #                       framework is how you get a rejection that reads as
    #                       an "invalid entitlement".
    #   --force             re-sign over the ad-hoc signature the build left.
    #
    # The identity is never echoed. It is a person's name and team ID, and this
    # output has a way of ending up pasted into issues and READMEs.

    SIGNED_NESTED=0

    # Pass one: every Mach-O that is not the app's own executable — dylibs,
    # framework binaries, anything a package dropped in Resources.
    while IFS= read -r -d '' MACHO; do
        [[ "${MACHO}" == "${APP_PATH}/Contents/MacOS/${APP_NAME}" ]] && continue
        file "${MACHO}" | grep -q 'Mach-O' || continue
        codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "${MACHO}"
        SIGNED_NESTED=$((SIGNED_NESTED + 1))
    done < <(find "${APP_PATH}" -depth -type f -perm +111 -print0)

    # Pass two: nested bundles, innermost first.
    while IFS= read -r -d '' BUNDLE; do
        [[ "${BUNDLE}" == "${APP_PATH}" ]] && continue
        codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "${BUNDLE}"
        SIGNED_NESTED=$((SIGNED_NESTED + 1))
    done < <(find "${APP_PATH}" -depth \( \
                -name '*.framework' -o -name '*.bundle' -o -name '*.app' -o \
                -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' \
            \) -print0)

    note "signed ${SIGNED_NESTED} nested item(s) before the app"

    # Pass three: the app itself, last, and the only one with entitlements.
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        "${APP_PATH}" 2>&1 | sed 's/^/    /'

    if ! codesign --verify --deep --strict "${APP_PATH}" 2>&1 | sed 's/^/    /'; then
        echo "error: the signed app does not verify" >&2
        exit 1
    fi

    # Both of these are assertions, not decoration: a missing hardened runtime
    # is an automatic notarization rejection, and a missing timestamp is an app
    # that stops launching the day the certificate expires. Neither is visible
    # by eye and both are one flag away from being absent.
    SIG_INFO="$(codesign --display --verbose=4 "${APP_PATH}" 2>&1)"
    if ! grep -q 'flags=.*runtime' <<<"${SIG_INFO}"; then
        echo "error: the app is signed without the hardened runtime" >&2
        exit 1
    fi
    if ! grep -q '^Timestamp=' <<<"${SIG_INFO}"; then
        echo "error: the app is signed without a secure timestamp" >&2
        exit 1
    fi
    note "verified: hardened runtime on, secure timestamp $(grep '^Timestamp=' <<<"${SIG_INFO}" | cut -d= -f2-)"

fi

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

# ------------------------------------------------------------------ notarize 1

# Reads a field out of notarytool's JSON without a JSON parser in the loop:
# plutil speaks JSON on stdin and prints one raw value.
json_field() { printf '%s' "$1" | plutil -extract "$2" raw -o - -- - 2>/dev/null || true; }

# Submits one artifact, waits, and fails loudly with Apple's own log if the
# answer is anything but Accepted. There is no fallback here on purpose: a
# silent drop back to ad-hoc would produce an image that looks like the signed
# one and behaves like the unsigned one.
notarize() {
    local artifact="$1" label="$2" json id status
    json="$(xcrun notarytool submit "${artifact}" \
                --keychain-profile "${NOTARY_PROFILE}" \
                --wait --timeout 30m --output-format json)"
    id="$(json_field "${json}" id)"
    status="$(json_field "${json}" status)"

    if [[ "${status}" != "Accepted" ]]; then
        echo "error: notarization of the ${label} came back ${status:-<no status>} (id ${id:-unknown})" >&2
        if [[ -n "${id}" ]]; then
            echo "       Apple's log for that submission:" >&2
            xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
        fi
        exit 1
    fi

    # The submission id is this function's return value, so it is the only
    # thing that may go to stdout; the human-readable line goes to stderr.
    note "${label}: Accepted, submission ${id}" >&2
    printf '%s' "${id}"
}

if [[ "${DISTRIBUTE}" -eq 1 ]]; then
    step "Notarizing the app"

    # notarytool will not take a bundle, only an archive of one, and `ditto -c
    # -k --keepParent` is the only zip Apple documents as preserving the
    # symlinks and extended attributes a signed bundle depends on. The zip is
    # a courier: it is thrown away, and the ticket it earns is stapled to the
    # app itself below.
    APP_ZIP="${DERIVED_DATA}/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"
    APP_SUBMISSION="$(notarize "${APP_ZIP}" "app")"
    rm -f "${APP_ZIP}"

    step "Stapling the app"

    # Why the app needs its own ticket even though the DMG gets one too: the
    # DMG's ticket travels with the DMG, and the DMG is the thing people throw
    # away after dragging Cherry to Applications. Staple the app and the ticket
    # is inside the copy that stays, so the first launch is answered locally
    # instead of by a call to Apple that an offline Mac cannot make.
    xcrun stapler staple "${APP_PATH}" 2>&1 | sed 's/^/    /'
    xcrun stapler validate "${APP_PATH}" 2>&1 | sed 's/^/    /'

    # Stapling writes into the bundle, so prove the seal survived it.
    if ! codesign --verify --deep --strict "${APP_PATH}" 2>&1 | sed 's/^/    /'; then
        echo "error: the app no longer verifies after stapling" >&2
        exit 1
    fi
fi

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

# ------------------------------------------------------------------ notarize 2

if [[ "${DISTRIBUTE}" -eq 1 ]]; then
    step "Signing, notarizing and stapling the disk image"

    # The image is signed as well as the app inside it. Without this the DMG is
    # an unsigned container and Gatekeeper judges it on its own terms before it
    # ever mounts. No hardened runtime here — a disk image is not code, and the
    # flag means nothing on one — but the same secure timestamp.
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}" 2>&1 | sed 's/^/    /'

    # A second submission, not a formality: the ticket earned by the app covers
    # the app's cdhash, and the image has its own. Notarizing the image is what
    # lets the DMG itself pass `spctl --assess --type open`, i.e. what stops the
    # warning at the moment of mounting rather than at first launch.
    DMG_SUBMISSION="$(notarize "${DMG_PATH}" "disk image")"

    xcrun stapler staple "${DMG_PATH}" 2>&1 | sed 's/^/    /'
    xcrun stapler validate "${DMG_PATH}" 2>&1 | sed 's/^/    /'

    # The last word belongs to the thing that will actually judge the download.
    # `--context context:primary-signature` is what Gatekeeper uses for a disk
    # image; without it spctl assesses the DMG as if it were an installer.
    step "Asking Gatekeeper"
    SPCTL_DMG="$(spctl --assess --type open --context context:primary-signature -vv "${DMG_PATH}" 2>&1 || true)"
    SPCTL_APP="$(spctl --assess --type execute -vv "${APP_PATH}" 2>&1 || true)"

    # The source lines only. The origin line is the identity, and printing it
    # would put a name in every log this script's output ever lands in.
    grep '^.*source=' <<<"${SPCTL_DMG}" | sed 's/^/    disk image: /' || true
    grep '^.*source=' <<<"${SPCTL_APP}" | sed 's/^/    app:        /' || true

    if ! grep -q 'accepted' <<<"${SPCTL_DMG}" || ! grep -q 'accepted' <<<"${SPCTL_APP}"; then
        echo "error: Gatekeeper did not accept the signed, notarized artifacts" >&2
        echo "${SPCTL_DMG}" >&2
        exit 1
    fi
fi

DMG_SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
DMG_BYTES="$(stat -f%z "${DMG_PATH}")"
DMG_SHA="$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"

# ---------------------------------------------------------------------- report

if [[ "${DISTRIBUTE}" -eq 1 ]]; then

cat <<REPORT

$(printf '\033[1m')Built $(printf '\033[0m')${DMG_PATH}

    version    ${VERSION} (${BUILD_NUMBER})
    requires   macOS ${MINIMUM_OS} or later
    size       ${DMG_SIZE} (${DMG_BYTES} bytes)
    sha256     ${DMG_SHA}

$(printf '\033[1;32m')SIGNED WITH A DEVELOPER ID, NOTARIZED, AND STAPLED.$(printf '\033[0m')

    app        hardened runtime, secure timestamp, notarized (${APP_SUBMISSION})
               and stapled — the ticket is inside the bundle, so the first-launch
               check is answered locally rather than by a call to Apple
    disk image signed, notarized (${DMG_SUBMISSION}) and stapled
    Gatekeeper accepts both

    A downloader drags Cherry to Applications and opens it. macOS shows the
    ordinary "downloaded from the Internet, are you sure you want to open it"
    prompt once, on the first launch, and opens the app when they say yes.
    That prompt is not a rejection and there is no way to remove it; it is what
    every notarized app shows. No terminal, no xattr, no Move to Trash.

REPORT

else

cat <<REPORT

$(printf '\033[1m')Built $(printf '\033[0m')${DMG_PATH}

    version    ${VERSION} (${BUILD_NUMBER})
    requires   macOS ${MINIMUM_OS} or later
    size       ${DMG_SIZE} (${DMG_BYTES} bytes)
    sha256     ${DMG_SHA}

$(printf '\033[1;33m')THIS BUILD IS NOT NOTARIZED, AND NOT SIGNED WITH A DEVELOPER ID.$(printf '\033[0m')

    It is signed ad-hoc, because neither CHERRY_SIGN_IDENTITY nor
    CHERRY_NOTARY_PROFILE is set in this environment. Ad-hoc is enough for the
    app to run on this Mac. It is not enough for anyone else's:

      * a Mac that DOWNLOADED this DMG puts a quarantine flag on it. Gatekeeper
        then refuses the app — measured on macOS 26.5.2: amfid reports "adhoc
        signed or signed by an unknown certificate chain", syspolicyd reports
        -67018 "Code did not match any currently allowed policy", a security
        dialog goes up, and the process is terminated. macOS words that as the
        app being DAMAGED, or as Apple being unable to verify it is free of
        malware, beside a Move to Trash button. Neither is true of this app.
      * the way through it is \`xattr -d com.apple.quarantine\` on the installed
        app. Do not ship this image to anyone without that text beside it.

    To build a distributable image instead, set both variables and re-run:

        export CHERRY_SIGN_IDENTITY=<Developer ID Application identity>
        export CHERRY_NOTARY_PROFILE=<notarytool keychain profile>

    That path signs inside out with the hardened runtime and a secure
    timestamp, notarizes and staples the app and the image, and needs a paid
    Apple Developer account. No password goes into this script either way.

REPORT

fi
