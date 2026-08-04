#!/bin/bash
#
# One-time setup: creates a local, self-signed code-signing certificate in a
# dedicated keychain so WindowSwitcher gets a STABLE code identity.
#
# Why: with ad-hoc signing ("-"), every rebuild produces a new code identity, so
# macOS TCC forgets your Accessibility / Screen Recording grants each time. A
# fixed self-signed certificate gives the app a constant "designated
# requirement", so a grant you give once survives every future rebuild.
#
# The dedicated keychain only ever holds this throwaway self-signed cert, so the
# password below guards nothing sensitive and is intentionally hardcoded so the
# build can stay fully automatic. Run this once, then use ./build.sh as usual.
#
set -euo pipefail

CERT_CN="WindowSwitcher Self-Signed"
KEYCHAIN_NAME="windowswitcher-signing.keychain-db"
KEYCHAIN="$HOME/Library/Keychains/$KEYCHAIN_NAME"
KC_PASS="winswitch-local"       # guards only a self-signed dev cert; not secret

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate"
# A config file (rather than -addext) keeps this working on the LibreSSL that
# ships with macOS.
cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" >/dev/null 2>&1

# OpenSSL 3's default PKCS#12 cipher can't be imported by macOS's Security
# framework, so it needs -legacy to opt back into the old RC2-40/3DES scheme.
# The LibreSSL that ships as /usr/bin/openssl on macOS has no -legacy flag at
# all (and doesn't need one — its default is already that legacy scheme), so
# only pass the flag when the active `openssl` actually understands it.
PKCS12_LEGACY_FLAG=""
if openssl pkcs12 -help 2>&1 | grep -q -- -legacy; then
    PKCS12_LEGACY_FLAG="-legacy"
fi
# Deliberately unquoted: it's either empty or the single static token
# "-legacy", never a value that needs word-splitting protection — and macOS's
# stock bash 3.2 treats a referenced-but-empty array as an unbound variable
# under `set -u`, so an array isn't a safe alternative here.
openssl pkcs12 -export $PKCS12_LEGACY_FLAG -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:winswitch -name "$CERT_CN" >/dev/null 2>&1

echo "==> Creating dedicated signing keychain"
security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"                 # never auto-lock
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

echo "==> Importing identity"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P winswitch \
    -T /usr/bin/codesign -A >/dev/null 2>&1

# Let codesign use the private key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1

# Add the keychain to the user search list so codesign can find the identity.
# Read as an array (one path per element) rather than word-splitting an
# unquoted variable — the latter silently mangles any path containing a
# space (e.g. a macOS username with a space in it), collapsing entries
# together and dropping keychains (including the login keychain) from the
# search list.
EXISTING=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%\"}"; line="${line#\"}"       # strip surrounding quotes
    [ -n "$line" ] && EXISTING+=("$line")
done < <(security list-keychains -d user)

if [[ ! " ${EXISTING[*]} " == *"$KEYCHAIN_NAME"* ]]; then
    security list-keychains -d user -s "${EXISTING[@]}" "$KEYCHAIN"
fi

echo "==> Done. Available code-signing identity:"
# Deliberately NOT `-v`: that flag restricts the list to identities System
# Trust considers valid, and a self-signed cert never is (CSSMERR_TP_NOT_TRUSTED)
# — expected, since nothing issued it. `codesign` doesn't require system trust
# to sign with an identity, only that it exist with its private key, which the
# plain (non -v) listing confirms.
security find-identity -p codesigning | grep "$CERT_CN" || {
    echo "!! Identity not found — signing setup failed." >&2
    exit 1
}
echo
echo "Now run ./build.sh — it will sign with this identity automatically."
