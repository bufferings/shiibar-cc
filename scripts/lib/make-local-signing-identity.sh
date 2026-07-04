#!/usr/bin/env bash
# Create (once) a local, self-signed code-signing identity in the login
# keychain, trusted for code signing (DESIGN.md §4.5: "install スクリプトが
# 安定した署名 ID を使う"). Plain ad-hoc signing (`codesign --sign -`) gives
# the app a *new* identity derived from the binary's own hash on every
# rebuild; several TCC-gated permissions (notifications among them) are
# reset when that identity changes. A locally-trusted self-signed
# certificate gives `codesign` a stable identity across rebuilds instead,
# by signing with the same certificate every time regardless of the binary
# contents.
#
# NOT independently verified end-to-end against live Apple documentation or
# a real run in this environment (no network access during development, and
# this is a real user machine — running this for real, including granting
# codesign trust, was left to the human `scripts/install.sh` run rather than
# exercised here). Verify after a real install: Keychain Access should show
# the certificate under "My Certificates" trusted for code signing, and a
# rebuild + reinstall should NOT reset the app's notification permission.

set -euo pipefail

COMMON_NAME="${1:?usage: make-local-signing-identity.sh <common-name>}"
KEYCHAIN="${SHIIBAR_CC_SIGNING_KEYCHAIN:-login.keychain-db}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CERT_PEM="$WORKDIR/cert.pem"
KEY_PEM="$WORKDIR/key.pem"
P12="$WORKDIR/identity.p12"
P12_PASSWORD="$(openssl rand -base64 24)"

echo "Generating a self-signed code-signing certificate ($COMMON_NAME)..."
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
  -days 3650 -nodes -subj "/CN=$COMMON_NAME" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

openssl pkcs12 -export -out "$P12" -inkey "$KEY_PEM" -in "$CERT_PEM" \
  -passout "pass:$P12_PASSWORD"

echo "Importing into $KEYCHAIN..."
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security

echo "Trusting it for code signing (may prompt for keychain access)..."
if ! security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT_PEM"; then
  echo "warning: could not add code-signing trust automatically." >&2
  echo "  Open Keychain Access, find the '$COMMON_NAME' certificate, and under" >&2
  echo "  'Trust' set 'Code Signing' to 'Always Trust'." >&2
fi

echo "Done. Verify with: security find-identity -v -p codesigning | grep '$COMMON_NAME'"
