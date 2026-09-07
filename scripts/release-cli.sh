#!/usr/bin/env bash
# release-cli.sh — build, package, and (optionally) release the `ainkrad` CLI
# via a Homebrew tap. Real Developer-ID notarization is blocked on Apple
# enrollment (AIN-135); the --notarize step is wired but no-ops until
# AINKRAD_NOTARY_PROFILE (or equivalent Developer-ID creds) is present.
#
# Usage:
#   scripts/release-cli.sh <version> [--dry-run] [--notarize] [--formula-path PATH]
#
# Run from the AinkradKit repo root.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GITHUB_REPO="AinkradHQ/AinkradKit"
BIN_NAME="ainkrad"

VERSION=""
DRY_RUN=0
NOTARIZE=0
FORMULA_PATH="${REPO_ROOT}/../homebrew-ainkrad/Formula/ainkrad.rb"

usage() {
  echo "usage: $(basename "$0") <version> [--dry-run] [--notarize] [--formula-path PATH]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --formula-path)
      [[ $# -ge 2 ]] || usage
      FORMULA_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "unknown flag: $1" >&2
      usage
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "unexpected argument: $1" >&2
        usage
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "error: version argument is required (e.g. v0.1.0)" >&2
  usage
fi

echo "== release-cli: ${BIN_NAME} ${VERSION} =="

# 1. Build a universal (arm64 + x86_64) release binary.
echo "-- building release binary (universal) --"
swift build -c release --arch arm64 --arch x86_64

BUILT_BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${BIN_NAME}"
if [[ ! -f "$BUILT_BIN" ]]; then
  echo "error: expected built binary at $BUILT_BIN" >&2
  exit 1
fi
echo "built: $BUILT_BIN"
file "$BUILT_BIN" || true

# AinkradAppKit is a dynamic library (ABI lockstep: host + plugins share one
# copy), so the CLI links it via @rpath. The binary already carries an
# @loader_path rpath, so shipping the dylib as a sibling of the executable is
# all that's needed — no install_name_tool surgery.
DYLIB_NAME="libAinkradAppKit.dylib"
BUILT_DYLIB="$(dirname "$BUILT_BIN")/${DYLIB_NAME}"
if [[ ! -f "$BUILT_DYLIB" ]]; then
  echo "error: expected AinkradAppKit dylib at $BUILT_DYLIB" >&2
  exit 1
fi
echo "dylib: $BUILT_DYLIB"

# 2. Package as a zip in dist/.
DIST_DIR="${REPO_ROOT}/dist"
mkdir -p "$DIST_DIR"
ZIP_NAME="${BIN_NAME}-${VERSION}-macos.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
rm -f "$ZIP_PATH"

echo "-- packaging $ZIP_PATH --"
STAGE_DIR="$(mktemp -d)"
cp "$BUILT_BIN" "$STAGE_DIR/${BIN_NAME}"
cp "$BUILT_DYLIB" "$STAGE_DIR/${DYLIB_NAME}"
(cd "$STAGE_DIR" && zip -q "$ZIP_PATH" "$BIN_NAME" "$DYLIB_NAME")
rm -rf "$STAGE_DIR"

# 3. Compute sha256 of the zip.
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "sha256: $SHA256"

# 4. Gated notarization (guarded — no-op without Developer-ID creds).
if [[ "$NOTARIZE" -eq 1 ]]; then
  if [[ -z "${AINKRAD_NOTARY_PROFILE:-}" ]]; then
    echo "notarization: Developer-ID not enrolled (AIN-135) — shipping unsigned"
  else
    echo "-- notarizing $ZIP_PATH --"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$AINKRAD_NOTARY_PROFILE" --wait
    xcrun stapler staple "$ZIP_PATH"
  fi
fi

# 5. Rewrite the Homebrew formula with the real version/url/sha256.
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${ZIP_NAME}"

mkdir -p "$(dirname "$FORMULA_PATH")"
cat > "$FORMULA_PATH" <<RUBY
class Ainkrad < Formula
  desc "Ainkrad agentic OS CLI"
  homepage "https://github.com/${GITHUB_REPO}"
  version "${VERSION#v}"
  url "${ASSET_URL}"
  sha256 "${SHA256}"
  license "UNLICENSED"

  def install
    # ainkrad links libAinkradAppKit.dylib via @loader_path, so the two must
    # stay siblings. Install both into libexec and symlink the CLI into bin.
    libexec.install "ainkrad", "libAinkradAppKit.dylib"
    bin.install_symlink libexec/"ainkrad"
  end

  test do
    system "#{bin}/ainkrad", "--help"
  end
end
RUBY

echo "-- formula written: $FORMULA_PATH --"

# 6. Print the resulting stanza and zip path for inspection.
echo "== zip =="
echo "$ZIP_PATH"
echo "== formula =="
cat "$FORMULA_PATH"

# 7. Non-dry-run: create the GitHub release (the only networked step).
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: skipping gh release create =="
else
  echo "-- creating GitHub release $VERSION --"
  gh release create "$VERSION" "$ZIP_PATH" \
    --title "ainkrad $VERSION" --notes "ainkrad $VERSION"
  echo "Released $VERSION (sha256 $SHA256)"
fi
