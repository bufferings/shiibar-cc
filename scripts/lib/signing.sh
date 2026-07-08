# Shared local code-signing identity lookup, sourced by scripts/dev-install.sh
# and scripts/dev-reload.sh (DESIGN.md §4.5: a stable signing identity, not
# ad-hoc, so notification permission doesn't reset across rebuilds).
#
# SIGNING_IDENTITY_CN is the common name scripts/lib/make-local-signing-identity.sh
# creates the certificate under. find_signing_identity() resolves it to the
# identity's hex hash (not the CN itself) so every codesign call signs by
# hash — that stays unambiguous even if the keychain ever ends up with more
# than one identity sharing this CN.
SIGNING_IDENTITY_CN="shiibar-cc-local-signing"

find_signing_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "$SIGNING_IDENTITY_CN" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]+)[[:space:]].*$/\1/'
}
