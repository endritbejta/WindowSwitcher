#!/bin/bash
#
# Manages the code-signing identity WindowSwitcher is built with.
#
# Why this exists: macOS does not remember a privacy grant by app name. It stores
# it against the app's "designated requirement" — a code-signing predicate. Sign
# ad-hoc and that predicate is the binary's own hash, so every rebuild orphans
# the grant. Sign with a certificate and the predicate is that certificate's
# hash, which is stable for as long as the same certificate is used.
#
# The catch, and the bug this script fixes: a certificate generated separately on
# each Mac hashes differently on each Mac, so a grant given on one machine means
# nothing on the next. The identity has to be *the same* identity everywhere —
# hence `export` and `import`.
#
# Usage:
#   ./setup-signing.sh                 create an identity on this Mac (first run)
#   ./setup-signing.sh export <file>   write this Mac's identity to a .p12
#   ./setup-signing.sh import <file>   install that identity on another Mac
#   ./setup-signing.sh status          show the identity and its requirement
#
# The .p12 is not committed to the repository on purpose — it is a signing key,
# and anything signed with it inherits this app's Accessibility grant. Move it
# between your own machines directly (AirDrop, or a password manager).
#
set -euo pipefail

CERT_CN="WindowSwitcher Self-Signed"
KEYCHAIN_NAME="windowswitcher-signing.keychain-db"
KEYCHAIN="$HOME/Library/Keychains/$KEYCHAIN_NAME"
KC_PASS="winswitch-local"       # guards only a self-signed dev cert; not secret
P12_PASS="winswitch"            # transport password for export/import

COMMAND="${1:-create}"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Create the dedicated keychain and add it to the search list so codesign can
# find the identity. Safe to call when it already exists.
prepare_keychain() {
	if [ ! -f "$KEYCHAIN" ]; then
		security create-keychain -p "$KC_PASS" "$KEYCHAIN"
	fi
	security set-keychain-settings "$KEYCHAIN"                 # never auto-lock
	security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

	# Read the existing list as an array (one path per element) rather than
	# word-splitting an unquoted variable — the latter silently mangles any path
	# containing a space (e.g. a macOS username with a space in it), collapsing
	# entries together and dropping keychains (including login) from the list.
	local existing=() line
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
		line="${line%\"}"; line="${line#\"}"       # strip surrounding quotes
		[ -n "$line" ] && existing+=("$line")
	done < <(security list-keychains -d user)

	# `${existing[*]}` on an empty array is an "unbound variable" under `set -u`
	# in the bash 3.2 that macOS ships, so guard on the element count before
	# either expansion is evaluated.
	if [ "${#existing[@]}" -eq 0 ]; then
		security list-keychains -d user -s "$KEYCHAIN"
	elif [[ ! " ${existing[*]} " == *"$KEYCHAIN_NAME"* ]]; then
		security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"
	fi
}

# Import a .p12 into the dedicated keychain and let codesign use its private key
# without an interactive prompt.
import_p12() {
	local file="$1" password="$2"
	security import "$file" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign -A >/dev/null
	security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1
}

show_identity() {
	# Deliberately NOT `-v`: that flag restricts the list to identities System
	# Trust considers valid, and a self-signed cert never is
	# (CSSMERR_TP_NOT_TRUSTED) — expected, since nothing issued it. `codesign`
	# doesn't require system trust to sign, only that the identity exist with its
	# private key, which the plain listing confirms.
	security find-identity -p codesigning | grep "$CERT_CN" || return 1
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
if [[ "$COMMAND" == "status" ]]; then
	echo "==> Identity on this Mac"
	if show_identity; then
		HASH="$(security find-identity -p codesigning | grep "$CERT_CN" | awk '{print $2}' | head -1)"
		echo
		echo "    Builds will be pinned to this certificate, giving the"
		echo "    designated requirement:"
		echo
		echo "        identifier \"com.example.windowswitcher\" and certificate leaf = H\"$(echo "$HASH" | tr 'A-Z' 'a-z')\""
		echo
		echo "    Every Mac that should keep its permission grant needs this"
		echo "    same certificate — export it here, import it there."
	else
		echo "    (none — run ./setup-signing.sh to create one)"
	fi
	exit 0
fi

# ---------------------------------------------------------------------------
# export: hand this Mac's identity to another machine.
# ---------------------------------------------------------------------------
if [[ "$COMMAND" == "export" ]]; then
	OUT="${2:-}"
	if [ -z "$OUT" ]; then
		echo "Usage: ./setup-signing.sh export <path-to-write.p12>" >&2
		exit 1
	fi
	if ! show_identity >/dev/null; then
		echo "!! No '$CERT_CN' identity on this Mac to export." >&2
		echo "   Run ./setup-signing.sh first, or export from the Mac that already works." >&2
		exit 1
	fi
	security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
	# -P sets the transport password; the import side uses the same constant.
	security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$P12_PASS" -o "$OUT"
	echo "==> Wrote $OUT"
	echo
	echo "    Copy it to your other Mac (AirDrop is fine) and run there:"
	echo "        ./setup-signing.sh import <path-to-the-file>"
	echo "        ./build.sh install"
	echo
	echo "    Then delete the file — it is a signing key. Anything signed with"
	echo "    it inherits this app's Accessibility permission."
	exit 0
fi

# ---------------------------------------------------------------------------
# import: adopt the identity from the other machine, so both Macs build an app
# with the same designated requirement and the grant holds on both.
# ---------------------------------------------------------------------------
if [[ "$COMMAND" == "import" ]]; then
	IN="${2:-}"
	if [ -z "$IN" ] || [ ! -f "$IN" ]; then
		echo "Usage: ./setup-signing.sh import <path-to.p12>" >&2
		exit 1
	fi
	echo "==> Preparing signing keychain"
	prepare_keychain
	echo "==> Importing identity from $IN"
	if ! import_p12 "$IN" "$P12_PASS"; then
		echo "!! Import failed. If the .p12 came from somewhere other than" >&2
		echo "   './setup-signing.sh export', its password is not the expected one." >&2
		exit 1
	fi
	echo "==> Done. Identity now available:"
	show_identity || { echo "!! Identity not found after import." >&2; exit 1; }
	echo
	echo "    Now run ./build.sh install — the app it produces has the same code"
	echo "    identity as on your other Mac, so the Accessibility grant sticks."
	echo "    If macOS already holds an entry from an earlier build here, the app"
	echo "    will offer 'Reset Permissions & Restart' on launch."
	exit 0
fi

# ---------------------------------------------------------------------------
# create (default): generate a fresh identity on this Mac.
# ---------------------------------------------------------------------------
if [[ "$COMMAND" != "create" ]]; then
	echo "Unknown command: $COMMAND" >&2
	echo "Usage: ./setup-signing.sh [create|export <file>|import <file>|status]" >&2
	exit 1
fi

if show_identity >/dev/null 2>&1; then
	echo "==> An identity already exists on this Mac:"
	show_identity
	echo
	echo "    Keeping it — regenerating would change the app's code identity and"
	echo "    invalidate the permission you have already granted."
	echo "    To share it with another Mac:  ./setup-signing.sh export <file.p12>"
	exit 0
fi

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
    -out "$WORK/identity.p12" -passout pass:"$P12_PASS" -name "$CERT_CN" >/dev/null 2>&1

echo "==> Creating dedicated signing keychain"
prepare_keychain

echo "==> Importing identity"
import_p12 "$WORK/identity.p12" "$P12_PASS"

echo "==> Done. Available code-signing identity:"
show_identity || { echo "!! Identity not found — signing setup failed." >&2; exit 1; }
echo
echo "Next:"
echo "    ./build.sh install                                  build and install to /Applications"
echo "    ./setup-signing.sh export ~/Desktop/ws-identity.p12  to reuse this identity on another Mac"
