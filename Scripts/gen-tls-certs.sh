#!/usr/bin/env bash
# Generates a throwaway CA, a server certificate (localhost / 127.0.0.1) and a client certificate
# for exercising Redi's TLS support. Output: .dev-redis/tls/
#
#   ca.crt / ca.key           certificate authority (use as "CA certificate" in Redi)
#   server.crt / server.key   used by `Scripts/dev-redis.sh tls start`
#   client.crt / client.key   client certificate (PEM)
#   client.p12                same client identity as PKCS#12, password "redi"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.dev-redis/tls"
mkdir -p "$OUT"
cd "$OUT"

openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days 825 -subj "/CN=Redi Dev CA" -out ca.crt

openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -subj "/CN=localhost" -out server.csr
cat > server.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -sha256 \
  -extfile server.ext -out server.crt 2>/dev/null

openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -subj "/CN=redi-client" -out client.csr
printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n" > client.ext
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -sha256 \
  -extfile client.ext -out client.crt 2>/dev/null
openssl pkcs12 -export -inkey client.key -in client.crt -certfile ca.crt -passout pass:redi -out client.p12

rm -f ./*.csr ./*.ext ./*.srl
chmod 600 ./*.key
echo "Certificates written to $OUT"
