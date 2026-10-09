#!/bin/bash
# Create (once) a self-signed code-signing identity for the native driver.
#
# Why: an ad-hoc signed app has no stable "designated requirement" — macOS keys
# the TCC grant (Input Monitoring, Accessibility) on the code hash, so every
# rebuild looks like a brand-new app and the permissions are silently lost.
# Signing with a fixed certificate makes the requirement
#   identifier "com.local.inkdriver" and certificate leaf = H"..."
# which survives rebuilds, so the grants stick.
#
# Idempotent: does nothing if the identity already exists.
#
# Usage: Support/make-signing-identity.sh [NAME]     (default "InkDriver Dev")

set -euo pipefail

NAME="${1:-InkDriver Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "identity '$NAME' already exists"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > openssl.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = PLACEHOLDER
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
sed -i '' "s/PLACEHOLDER/$NAME/" openssl.cnf

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config openssl.cnf -keyout key.pem -out cert.pem >/dev/null 2>&1

# Empty passphrase on the PKCS#12 so `security import` does not prompt.
openssl pkcs12 -export -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:inkdriver -legacy >/dev/null 2>&1 || \
    openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem -passout pass:inkdriver >/dev/null 2>&1

echo "importing identity into the login keychain…"
security import identity.p12 -k "$KEYCHAIN" -P inkdriver -T /usr/bin/codesign >/dev/null

echo "trusting it for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

echo
echo "done. identities now available:"
security find-identity -v -p codesigning | sed 's/^/  /'
