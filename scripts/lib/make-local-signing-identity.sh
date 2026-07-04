#!/usr/bin/env bash
# Create (once) a local, self-signed code-signing identity in the login
# keychain, trusted for code signing (DESIGN.md §4.5: the install script
# must use a stable signing identity). Plain ad-hoc signing (`codesign
# --sign -`) gives the app a *new* identity derived from the binary's own
# hash on every rebuild; several TCC-gated permissions (notifications among
# them) are reset when that identity changes. A locally-trusted self-signed
# certificate gives `codesign` a stable identity across rebuilds instead.
#
# Robustness notes (each of these bit a real install run):
#   - Pinned to /usr/bin/openssl (the system LibreSSL). A Homebrew OpenSSL 3
#     earlier on PATH generates PKCS#12 files with PBES2/PBKDF2/AES-256
#     encryption that macOS `security import` cannot read, which made the
#     original p12-based version of this script fail and the install fall
#     back to ad-hoc signing. We now avoid PKCS#12 entirely (see next).
#   - The certificate and private key are imported as two plain PEM files
#     instead of a bundled .p12 — `security import` matches them into one
#     identity by public-key hash, and PEM import has no encryption-format
#     compatibility problem in the first place.
#   - Certificate extensions come from a -config file, not -addext, so the
#     script also works on older LibreSSL versions that lack -addext.
#   - The script VERIFIES at the end that a *valid* codesigning identity
#     actually exists, and fails loudly with instructions if not (an
#     imported-but-untrusted certificate shows up as 0 valid identities).
#
# Interactive prompts to expect (both are one-time, both must be approved):
#   1. `security add-trusted-cert` opens a system dialog asking for your
#      login password to change certificate trust settings.
#   2. The first `codesign` that uses the new key may ask to allow codesign
#      access to it — choose "Always Allow".

set -euo pipefail

COMMON_NAME="${1:?usage: make-local-signing-identity.sh <common-name>}"
OPENSSL=/usr/bin/openssl   # system LibreSSL, deliberately not PATH openssl

# Default to the user's actual default keychain (normally
# ~/Library/Keychains/login.keychain-db) rather than a hardcoded name.
KEYCHAIN="${SHIIBAR_CC_SIGNING_KEYCHAIN:-$(security default-keychain | tr -d ' "')}"
if [ -z "$KEYCHAIN" ]; then
  echo "error: could not determine the default keychain (security default-keychain)." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CERT_PEM="$WORKDIR/cert.pem"
KEY_PEM="$WORKDIR/key.pem"

cat > "$WORKDIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no
[dn]
CN = $COMMON_NAME
[v3_codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "Generating a self-signed code-signing certificate ($COMMON_NAME)..."
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
  -days 3650 -nodes -config "$WORKDIR/openssl.cnf"

echo "Importing certificate + key into $KEYCHAIN..."
security import "$CERT_PEM" -k "$KEYCHAIN"
security import "$KEY_PEM" -k "$KEYCHAIN" -t priv -f openssl \
  -T /usr/bin/codesign -T /usr/bin/security

echo "Trusting it for code signing (a system dialog will ask for your login password)..."
if ! security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT_PEM"; then
  echo "warning: could not add code-signing trust automatically." >&2
  echo "  Open Keychain Access, find the '$COMMON_NAME' certificate, expand" >&2
  echo "  'Trust', and set 'Code Signing' to 'Always Trust'. Then re-run install.sh." >&2
fi

# Loud verification: an identity that exists but isn't trusted for code
# signing is NOT listed as valid, and codesign would refuse it — failing
# here (with instructions) beats a silent ad-hoc fallback that resets the
# notification permission on every rebuild (DESIGN.md §4.5).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$COMMON_NAME"; then
  echo "OK: '$COMMON_NAME' is a valid codesigning identity."
else
  echo "error: '$COMMON_NAME' was imported but is NOT a valid codesigning identity." >&2
  echo "  Most likely the trust step above was cancelled or failed. Fix it manually:" >&2
  echo "    1. Open Keychain Access (login keychain, My Certificates)." >&2
  echo "    2. Double-click '$COMMON_NAME', expand 'Trust'," >&2
  echo "       set 'Code Signing' to 'Always Trust', close (enter password)." >&2
  echo "    3. Verify: security find-identity -v -p codesigning | grep '$COMMON_NAME'" >&2
  echo "    4. Re-run scripts/install.sh." >&2
  exit 1
fi
