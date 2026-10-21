#!/usr/bin/env bash
# Regenerate DIL Root CA -> Intermediate CA -> pi4b server cert
# with full Subject DN and subjectAltName on every certificate.
set -euo pipefail

SUBJ_BASE="/C=IN/ST=TN/L=Chennai/O=Deep Inter Link Ltd"
EMAIL="rajesh@deepinter.link"

# ---- Server SANs: edit to match how clients reach the Pi ----
SERVER_SAN="DNS:pi4b,DNS:pi4b.local,IP:192.168.1.50,email:${EMAIL}"

# ---------- Extension definitions ----------
cat > v3_ext.cnf <<EOF
[ v3_root ]
basicConstraints       = critical, CA:true
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
subjectAltName         = email:${EMAIL}

[ v3_inter ]
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always, issuer
subjectAltName         = email:${EMAIL}

[ v3_server ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid, issuer
subjectAltName         = ${SERVER_SAN}
EOF

# ---------- Root CA ----------
openssl genrsa -aes256 -out ca.key 4096

openssl req -x509 -new -key ca.key -sha256 -days 3650 -out ca.crt \
  -subj "${SUBJ_BASE}/CN=DIL Root CA/emailAddress=${EMAIL}" \
  -config <(printf "[req]\ndistinguished_name=dn\n[dn]\n"; cat v3_ext.cnf) \
  -extensions v3_root

# ---------- Intermediate CA ----------
openssl genrsa -aes256 -out interca.key 4096

openssl req -new -key interca.key -out interca.csr \
  -subj "${SUBJ_BASE}/CN=DIL Intermediate CA/emailAddress=${EMAIL}"

openssl x509 -req -in interca.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out interca.crt -sha384 -days 1825 \
  -extfile v3_ext.cnf -extensions v3_inter

# ---------- Apache2 server (pi4b) ----------
openssl genrsa -out pi4b.key 4096   # no passphrase so Apache starts unattended
chmod 600 pi4b.key

openssl req -new -key pi4b.key -out pi4b.csr \
  -subj "${SUBJ_BASE}/CN=pi4b/emailAddress=${EMAIL}"

openssl x509 -req -in pi4b.csr -CA interca.crt -CAkey interca.key -CAcreateserial \
  -out pi4b.crt -sha384 -days 365 \
  -extfile v3_ext.cnf -extensions v3_server

# ---------- Chain files ----------
cat interca.crt ca.crt > ca-chain.crt           # for SSLCACertificateFile / clients
cat pi4b.crt interca.crt > pi4b-fullchain.crt   # for SSLCertificateFile

# ---------- Verify ----------
openssl verify -CAfile ca.crt ca.crt
openssl verify -CAfile ca.crt interca.crt
openssl verify -CAfile ca.crt -untrusted interca.crt pi4b.crt

for c in ca.crt interca.crt pi4b.crt; do
  echo "=== $c ==="
  openssl x509 -in "$c" -noout -subject -issuer -ext subjectAltName,basicConstraints,keyUsage
done
