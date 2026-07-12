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

# -legacy is required: OpenSSL 3's default PKCS#12 cipher can't be imported by
# macOS's Security framework.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
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
EXISTING=$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')
if ! echo "$EXISTING" | grep -q "$KEYCHAIN_NAME"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo "==> Done. Available code-signing identity:"
security find-identity -v -p codesigning | grep "$CERT_CN" || {
    echo "!! Identity not found — signing setup failed." >&2
    exit 1
}
echo
echo "Now run ./build.sh — it will sign with this identity automatically."
