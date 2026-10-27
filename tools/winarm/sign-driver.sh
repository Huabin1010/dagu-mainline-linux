#!/usr/bin/env bash
# Test-sign Windows kernel drivers (.sys) for the dagu WOA port, on Linux.
#
# Windows ARM64 enforces kernel-mode code signing. With the image booted
# testsigning=on (set by the WinPE deploy), a driver loads if it carries a
# valid Authenticode signature whose chain ends in a root the machine trusts.
# We mint our own 2-tier test PKI (root CA + code-signing leaf), embed-sign the
# .sys with the leaf (osslsigncode), and emit the root CA + a registry blob so
# the offline image can trust it (added to ROOT + TrustedPublisher in WinPE).
#
#   tools/winarm/sign-driver.sh path/to/driver.sys [more.sys ...]
#
# Artifacts land in tools/winarm/signing/ (the private keys are gitignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/signing"
mkdir -p "$S"
ROOT_KEY="$S/dagu-test-root.key"  ROOT_CRT="$S/dagu-test-root.crt"
LEAF_KEY="$S/dagu-test-codesign.key"  LEAF_CRT="$S/dagu-test-codesign.crt"
CHAIN="$S/dagu-test-chain.pem"  ROOT_DER="$S/dagu-test-root.cer"

if [ ! -f "$ROOT_CRT" ]; then
	echo "== minting test root CA =="
	openssl req -x509 -newkey rsa:4096 -sha256 -days 7300 -nodes \
		-keyout "$ROOT_KEY" -out "$ROOT_CRT" \
		-subj "/CN=dagu WOA Test Root CA/O=dagu-woa" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign"
fi
if [ ! -f "$LEAF_CRT" ]; then
	echo "== minting code-signing leaf =="
	openssl req -newkey rsa:2048 -sha256 -nodes \
		-keyout "$LEAF_KEY" -out "$S/leaf.csr" \
		-subj "/CN=dagu WOA Test Code Signing/O=dagu-woa"
	openssl x509 -req -in "$S/leaf.csr" -CA "$ROOT_CRT" -CAkey "$ROOT_KEY" \
		-CAcreateserial -days 3650 -sha256 -out "$LEAF_CRT" \
		-extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
	rm -f "$S/leaf.csr"
fi
cat "$LEAF_CRT" "$ROOT_CRT" > "$CHAIN"
openssl x509 -in "$ROOT_CRT" -outform DER -out "$ROOT_DER"

for sys in "$@"; do
	[ -f "$sys" ] || { echo "no such .sys: $sys" >&2; exit 1; }
	tmp="$(mktemp -u)"
	osslsigncode sign -certs "$CHAIN" -key "$LEAF_KEY" -h sha256 \
		-n "dagu WOA driver" -in "$sys" -out "$tmp" >/dev/null
	mv "$tmp" "$sys"
	osslsigncode verify -in "$sys" 2>&1 | grep -iE "Signature verification|Message digest" | head -2 || true
	echo "signed: $sys"
done

# SHA1 thumbprint (registry store key name) + serialized-cert registry blob.
# A registry cert store element is: DWORD propID, DWORD flags(=1), DWORD cb,
# then cb bytes. propID 0x20 (CERT_CERT_PROP_ID) carries the DER certificate.
TP="$(openssl x509 -in "$ROOT_CRT" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
python3 - "$ROOT_DER" "$S/root-blob.hex" <<'PY'
import sys, struct
der = open(sys.argv[1], "rb").read()
open(sys.argv[2], "w").write((struct.pack("<III", 0x20, 1, len(der)) + der).hex())
PY
printf '%s' "$TP" > "$S/root-thumbprint.txt"
echo "root CA thumbprint: $TP"
echo "root blob: $S/root-blob.hex"
