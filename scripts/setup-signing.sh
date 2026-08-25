#!/bin/bash
# One-time setup: create a stable self-signed code-signing identity in a
# dedicated keychain. Signing every build with the SAME identity keeps the
# app's code-signing identity constant across rebuilds, so macOS doesn't treat
# each rebuild as a new app and reset the helper's approval (SMAppService /
# Background Task Management keys approval off the signing identity, not the
# per-build code hash).
#
# Safe to re-run: it recreates the keychain from scratch.
set -euo pipefail

IDENTITY_CN="StudyBlock Self-Signed"
KEYCHAIN="studyblock-signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN"
KEYCHAIN_PASS="studyblock"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "→ Generating self-signed code-signing certificate…"
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_CN
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
# A non-empty export password avoids macOS's "MAC verification failed" on
# import of LibreSSL-generated PKCS12 bundles.
P12_PASS="studyblock"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$P12_PASS" -name "$IDENTITY_CN"

echo "→ Creating dedicated signing keychain…"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN_PATH"          # no auto-lock
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

echo "→ Importing identity and allowing codesign to use it…"
security import "$WORK/id.p12" -k "$KEYCHAIN_PATH" -P "$P12_PASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null 2>&1

# Trust the cert for code signing (user domain — no admin prompt) so it counts
# as a valid signing identity.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN_PATH" "$WORK/cert.pem" 2>/dev/null || \
    echo "  (trust step skipped — signing usually still works)"

# Make sure codesign searches this keychain, keeping the ones already listed.
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g')
security list-keychains -d user -s $EXISTING "$KEYCHAIN_PATH"

echo
echo "→ Code-signing identities now available:"
security find-identity -v -p codesigning | sed 's/^/   /'
