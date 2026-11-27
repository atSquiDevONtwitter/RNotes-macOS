#!/bin/bash
# RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
#
# Runs the 7 acceptance tests of RNotes-update-tool-spec.md against a built app.
#   bash test-rnotes-publish.sh /path/to/RNotes.app
# Uses a throwaway key and a temp folder; never touches ~/.rnotes-update-key.
# Set KEEP=1 to keep the temp folder for inspection.

set -u
APP="${1:?usage: $0 /path/to/RNotes.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
TOOL="$(cd "$(dirname "$0")" && pwd)/rnotes-publish.swift"
WORK="$(mktemp -d -t rnotes-publish-test)"
KEY="$WORK/test-key"
PASS=0
FAIL=0
OUT=""
CODE=0

cleanup() { if [ "${KEEP:-0}" = "1" ]; then echo "Kept $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT
cd "$WORK" || exit 3

tool() { OUT="$(swift "$TOOL" "$@" 2>&1)"; CODE=$?; }
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; echo "$OUT" | sed 's/^/        /'; FAIL=$((FAIL + 1)); }
want() { # want <exit code> <description> [text the output must contain]
    if [ "$CODE" = "$1" ] && { [ -z "${3:-}" ] || printf '%s' "$OUT" | grep -qF -- "$3"; }; then ok "$2"; else bad "$2 (exit $CODE, wanted $1)"; fi
}

printf '## What'"'"'s new\n- Test release\n' > notes.md
echo "Tool: $TOOL"
echo "App:  $APP"
echo "Work: $WORK"
echo

# 1. Key setup
tool genkey --key "$KEY";            want 0 "1a genkey creates a key"
PUB="$(printf '%s' "$OUT" | sed -n 's/.*static let publicKey = "\(.*\)".*/\1/p')"
PERM="$(stat -f %Lp "$KEY" 2>/dev/null)"
if [ "$PERM" = "600" ]; then ok "1b key file is 0600"; else OUT="mode $PERM"; bad "1b key file is 0600"; fi
tool genkey --key "$KEY";            want 2 "1c genkey again without --force fails" "already exists"
tool pubkey --key "$KEY"
if [ "$CODE" = 0 ] && [ -n "$PUB" ] && [ "$OUT" = "$PUB" ]; then ok "1d pubkey matches genkey"; else bad "1d pubkey matches genkey"; fi

# 2. Publish + verify
tool publish --app "$APP" --channel beta --notes notes.md --key "$KEY"; want 0 "2a publish exits 0"
N="$(ls publish/beta 2>/dev/null | wc -l | tr -d ' ')"
if [ "$N" = "3" ]; then ok "2b publish/beta has 3 files"; else OUT="$(ls -la publish/beta 2>&1)"; bad "2b publish/beta has 3 files"; fi
tool verify --dir publish/beta --key "$KEY";   want 0 "2c verify --key exits 0" "app bundle verified"
tool verify --dir publish/beta --pubkey "$PUB"; want 0 "2d verify --pubkey exits 0"

# 3. Tampered manifest
cp publish/beta/update.json "$WORK/update.json.orig"
perl -pi -e 's/minimumSystemVersion/minimumSystemVersioN/' publish/beta/update.json
tool verify --dir publish/beta --key "$KEY";   want 2 "3  tampered manifest rejected" "signature does not match"
cp "$WORK/update.json.orig" publish/beta/update.json

# 4. Tampered zip
ZIP="$(ls publish/beta/*.zip | head -1)"
cp "$ZIP" "$WORK/zip.orig"
printf 'x' >> "$ZIP"
tool verify --dir publish/beta --key "$KEY";   want 2 "4  tampered zip rejected" "bytes but update.json says"
cp "$WORK/zip.orig" "$ZIP"

# 5. Wrong app
ditto "$APP" "$WORK/Other.app"
tool publish --app "$WORK/Other.app" --channel beta --notes notes.md --key "$KEY" --out "$WORK/p-name"
want 2 "5a app not named RNotes.app rejected" "must be named"
mkdir -p "$WORK/wrongid" && ditto "$APP" "$WORK/wrongid/RNotes.app"
plutil -replace CFBundleIdentifier -string com.example.Other "$WORK/wrongid/RNotes.app/Contents/Info.plist"
tool publish --app "$WORK/wrongid/RNotes.app" --channel beta --notes notes.md --key "$KEY" --out "$WORK/p-id"
want 2 "5b different bundle ID rejected" "CFBundleIdentifier"

# 6. Redirect
tool redirect --channel beta --feed-url https://sr2downloads-rnotes.radiant-technologies.ca/files/binaries/beta --key "$KEY"
want 0 "6a redirect exits 0"
if grep -q '"feedURL" : "https://sr2downloads-rnotes.radiant-technologies.ca/files/binaries/beta/"' publish/redirect-beta/update.json 2>/dev/null; then
    ok "6b feedURL ends in /beta/"; else OUT="$(cat publish/redirect-beta/update.json 2>&1)"; bad "6b feedURL ends in /beta/"; fi
tool verify --dir publish/redirect-beta --key "$KEY"; want 0 "6c verify redirect folder exits 0"
tool redirect --channel beta --feed-url http://sr2downloads-rnotes.radiant-technologies.ca/files/binaries/beta/ --key "$KEY" --out "$WORK/r-http"
want 1 "6d http:// rejected" "https"
tool redirect --channel beta --feed-url https://sr2downloads-rnotes.radiant-technologies.ca/files/binaries/stable/ --key "$KEY" --out "$WORK/r-stable"
want 1 "6e /stable/ URL for beta rejected" "/beta/"

# 7. Bad options
tool frobnicate;                     want 1 "7a unknown command prints usage" "Usage:"
tool publish --bogus;                want 1 "7b unknown option prints usage" "Usage:"
tool help;                           want 0 "7c help exits 0" "Usage:"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
