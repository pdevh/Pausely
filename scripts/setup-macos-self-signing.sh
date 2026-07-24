#!/bin/bash

set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR="${PAUSELY_SIGNING_BACKUP_DIR:-$HOME/.config/pausely/release-signing}"
GH_REPO="${GH_REPO:-pdevh/Pausely}"
PUBLIC_CERTIFICATE="$REPO_ROOT/.github/signing/Pausely-Release-Certificate.pem"
SET_GITHUB_SECRETS=true

for argument in "$@"; do
    case "$argument" in
        --no-github) SET_GITHUB_SECRETS=false ;;
        *)
            echo "usage: $0 [--no-github]" >&2
            exit 2
            ;;
    esac
done

for command in openssl base64 install; do
    command -v "$command" >/dev/null || {
        echo "error: required command '$command' is unavailable" >&2
        exit 1
    }
done

if [[ "$SET_GITHUB_SECRETS" == "true" ]]; then
    command -v gh >/dev/null || {
        echo "error: GitHub CLI is required unless --no-github is used" >&2
        exit 1
    }
    gh auth status >/dev/null
fi

PRIVATE_KEY="$OUTPUT_DIR/Pausely-Release-Certificate.key.pem"
PRIVATE_KEY_PASSWORD_FILE="$OUTPUT_DIR/Pausely-Release-Certificate.key.password"
CERTIFICATE_BACKUP="$OUTPUT_DIR/Pausely-Release-Certificate.pem"
P12_BACKUP="$OUTPUT_DIR/Pausely-GitHub-Release.p12"
P12_PASSWORD_FILE="$OUTPUT_DIR/Pausely-GitHub-Release.password"

mkdir -p "$OUTPUT_DIR" "$(dirname "$PUBLIC_CERTIFICATE")"

if [[ -f "$PRIVATE_KEY" || -f "$CERTIFICATE_BACKUP" || -f "$PUBLIC_CERTIFICATE" ]]; then
    for required_file in "$PRIVATE_KEY" "$PRIVATE_KEY_PASSWORD_FILE" "$CERTIFICATE_BACKUP" "$PUBLIC_CERTIFICATE"; do
        [[ -f "$required_file" ]] || {
            echo "error: incomplete release identity; missing $required_file" >&2
            exit 1
        }
    done

    PUBLIC_FINGERPRINT=$(openssl x509 -in "$PUBLIC_CERTIFICATE" -noout -fingerprint -sha256)
    BACKUP_FINGERPRINT=$(openssl x509 -in "$CERTIFICATE_BACKUP" -noout -fingerprint -sha256)
    [[ "$PUBLIC_FINGERPRINT" == "$BACKUP_FINGERPRINT" ]] || {
        echo "error: committed and backed-up release certificates do not match" >&2
        exit 1
    }
else
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pausely-release-signing.XXXXXX")
    trap 'rm -rf "$TEMP_DIR"' EXIT

    PRIVATE_KEY_PASSWORD=$(openssl rand -hex 32)
    TEMP_PRIVATE_KEY="$TEMP_DIR/release-key.pem"
    TEMP_CERTIFICATE="$TEMP_DIR/release-certificate.pem"

    openssl genpkey \
        -algorithm RSA \
        -pkeyopt rsa_keygen_bits:3072 \
        -aes-256-cbc \
        -pass "pass:$PRIVATE_KEY_PASSWORD" \
        -out "$TEMP_PRIVATE_KEY" >/dev/null 2>&1

    openssl req \
        -x509 \
        -new \
        -sha256 \
        -days 7300 \
        -key "$TEMP_PRIVATE_KEY" \
        -passin "pass:$PRIVATE_KEY_PASSWORD" \
        -subj "/CN=Pausely GitHub Release Signing/O=Pausely" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" \
        -out "$TEMP_CERTIFICATE" >/dev/null 2>&1

    install -m 600 "$TEMP_PRIVATE_KEY" "$PRIVATE_KEY"
    printf '%s\n' "$PRIVATE_KEY_PASSWORD" > "$PRIVATE_KEY_PASSWORD_FILE"
    chmod 600 "$PRIVATE_KEY_PASSWORD_FILE"
    install -m 644 "$TEMP_CERTIFICATE" "$CERTIFICATE_BACKUP"
    install -m 644 "$TEMP_CERTIFICATE" "$PUBLIC_CERTIFICATE"
fi

PRIVATE_KEY_PASSWORD=$(tr -d '\r\n' < "$PRIVATE_KEY_PASSWORD_FILE")
P12_PASSWORD=$(openssl rand -hex 32)
TEMP_P12=$(mktemp "${TMPDIR:-/tmp}/Pausely-GitHub-Release.XXXXXX.p12")
trap 'rm -f "$TEMP_P12"' EXIT

openssl pkcs12 \
    -export \
    -out "$TEMP_P12" \
    -inkey "$PRIVATE_KEY" \
    -passin "pass:$PRIVATE_KEY_PASSWORD" \
    -in "$CERTIFICATE_BACKUP" \
    -name "Pausely GitHub Release Signing" \
    -passout "pass:$P12_PASSWORD"

install -m 600 "$TEMP_P12" "$P12_BACKUP"
printf '%s\n' "$P12_PASSWORD" > "$P12_PASSWORD_FILE"
chmod 600 "$P12_PASSWORD_FILE"

if [[ "$SET_GITHUB_SECRETS" == "true" ]]; then
    base64 < "$TEMP_P12" | tr -d '\n' | gh secret set MACOS_SIGNING_CERTIFICATE --repo "$GH_REPO"
    printf '%s' "$P12_PASSWORD" | gh secret set MACOS_SIGNING_CERTIFICATE_PASSWORD --repo "$GH_REPO"
fi

CERTIFICATE_FINGERPRINT=$(openssl x509 -in "$CERTIFICATE_BACKUP" -noout -fingerprint -sha256 | cut -d= -f2)
CERTIFICATE_EXPIRY=$(openssl x509 -in "$CERTIFICATE_BACKUP" -noout -enddate | cut -d= -f2)

echo "Prepared Pausely's persistent self-signed release identity."
echo "Public certificate: $PUBLIC_CERTIFICATE"
echo "Encrypted private key: $PRIVATE_KEY"
echo "Private-key password: $PRIVATE_KEY_PASSWORD_FILE"
echo "CI certificate backup: $P12_BACKUP"
echo "CI certificate password: $P12_PASSWORD_FILE"
echo "Certificate SHA-256 fingerprint: $CERTIFICATE_FINGERPRINT"
echo "Certificate expires: $CERTIFICATE_EXPIRY"
if [[ "$SET_GITHUB_SECRETS" == "true" ]]; then
    echo "Updated MACOS_SIGNING_CERTIFICATE and MACOS_SIGNING_CERTIFICATE_PASSWORD for $GH_REPO."
fi
echo "Back up the private key and passwords securely. Never upload the private key itself to GitHub."
