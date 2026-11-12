#!/bin/bash
# Creates a self-signed code-signing certificate in signing/lumen.keychain-db (a project-local
# keychain, not your login keychain). A stable signature lets macOS remember Lumen's permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p signing
cd signing
[[ -f lumen.keychain-db ]] && { echo "signing/lumen.keychain-db already exists"; exit 0; }
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Lumen Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
created=""
cleanup() {
    local status=$?
    rm -f key.pem id.p12 # never leave the private key lying around
    # A half-made keychain would make every later run stop at "already exists".
    if [[ $status -ne 0 && -n "$created" ]]; then security delete-keychain "$PWD/lumen.keychain-db" || true; fi
}
trap cleanup EXIT
# OpenSSL 3+ encrypts PKCS#12 with algorithms the macOS keychain can't import unless told -legacy.
# LibreSSL (/usr/bin/openssl) has no -legacy flag and already uses the old algorithms.
legacy=()
openssl version | grep -q LibreSSL || legacy=(-legacy)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem
openssl pkcs12 -export ${legacy[@]+"${legacy[@]}"} -inkey key.pem -in cert.pem -out id.p12 -passout pass:lumen
security create-keychain -p lumen "$PWD/lumen.keychain-db"
created=1
security set-keychain-settings "$PWD/lumen.keychain-db"
security unlock-keychain -p lumen "$PWD/lumen.keychain-db"
security import id.p12 -k "$PWD/lumen.keychain-db" -P lumen -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k lumen "$PWD/lumen.keychain-db" >/dev/null
echo "created signing/lumen.keychain-db"
