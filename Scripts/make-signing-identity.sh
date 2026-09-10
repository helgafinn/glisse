#!/bin/bash
#
# Creates a self-signed code-signing identity so Glisse keeps its Accessibility
# permission across rebuilds.
#
# The problem this solves
# ----------------------
# Ad-hoc signing (`codesign --sign -`) gives the app no stable identity: its
# designated requirement is a cdhash, which changes every time the binary is
# rebuilt. macOS keys the Accessibility grant to that requirement, so every
# `make release` silently invalidates the permission and the app looks broken
# until it is granted again.
#
# A self-signed certificate fixes it: the requirement becomes
# `identifier "xyz.glisse.Glisse" and certificate leaf = H"<cert>"`, and a
# certificate hash does not change when the code does. Grant once, done.
#
# This is optional. If you rarely rebuild, just re-granting Accessibility is less
# hassle than setting this up.
#
# What it touches
# ---------------
#  * adds ONE certificate + private key to your login keychain
#  * marks that ONE certificate as trusted for code signing, in YOUR user trust
#    settings (not the system domain, so no sudo)
#
# macOS will ask for your password for the trust step. Nothing else is trusted and
# no system setting changes. Remove it at any time with:
#
#     Scripts/make-signing-identity.sh --remove
#
# Two macOS-specific details this script exists to get right:
#
#  1. `security import` rejects a PKCS#12 with an empty password
#     ("MAC verification failed"). A real password is required.
#  2. OpenSSL 3 writes PKCS#12 using AES-256-CBC/PBKDF2, which macOS's Security
#     framework cannot read — also surfacing as "MAC verification failed". The
#     `-legacy` flag is required. (Homebrew ships OpenSSL 3; /usr/bin/openssl may
#     be LibreSSL, which does not accept -legacy, so both are handled.)

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Glisse Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# ---------------------------------------------------------------- removal

if [ "${1:-}" = "--remove" ]; then
  echo "--> removing '$NAME'"
  security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  security delete-certificate -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    still present; remove it by hand in Keychain Access." >&2
    exit 1
  fi
  echo "    removed. Future builds fall back to ad-hoc signing."
  exit 0
fi

# ---------------------------------------------------------------- already there

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Identity already present:"
  security find-identity -p codesigning | grep "$NAME"
  echo ""
  echo "Run 'make release' and it will be used automatically."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- certificate

echo "--> generating a key and a self-signed code-signing certificate"

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = Glisse Local Signing

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -config "$WORK/openssl.cnf" 2>/dev/null

# A non-empty password is mandatory (see note 1 above).
P12_PASSWORD="glisse-$RANDOM$RANDOM"

# Prefer the legacy PKCS#12 encoding; fall back for LibreSSL, which produces a
# compatible file by default and does not understand -legacy.
if ! openssl pkcs12 -export -legacy \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD" \
        -name "$NAME" 2>/dev/null; then
  echo "    (-legacy unsupported, using the default encoding)"
  openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD" \
    -name "$NAME" 2>/dev/null
fi

# ---------------------------------------------------------------- import

echo "--> importing into the login keychain"
security import "$WORK/identity.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null

# Let codesign use the private key without a prompt on every build.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- note on trust
#
# No `security add-trusted-cert` step. It is not needed: verified on macOS 27
# that `codesign --sign "<name>"` accepts a self-signed code-signing certificate
# with no trust settings at all. `security find-identity -v` will not *list* it
# (that filters on trust), which is why `-v` is omitted when checking below.
#
# Skipping it also avoids the GUI authorisation prompt that step required.

# ---------------------------------------------------------------- verify

echo ""
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Created signing identity:"
  security find-identity -p codesigning | grep "$NAME"
  echo ""
  echo "Next steps:"
  echo "  make release"
  echo "  tccutil reset Accessibility xyz.glisse.Glisse"
  echo "  open dist/Glisse.app"
  echo "  grant Accessibility once — it now survives rebuilds"
else
  echo "Imported, but codesign cannot see the identity." >&2
  echo "Check Keychain Access for '$NAME', or run '$0 --remove' to undo." >&2
  exit 1
fi
