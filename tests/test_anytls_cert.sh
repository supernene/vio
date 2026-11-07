#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.acme.sh" "$tmp/config/certs"
export HOME="$tmp/home" CFG="$tmp/config" CERT_CA_BUNDLE="$tmp/root.crt"
export MOCK_ACTIVE=0 MOCK_RELOADCMD="$tmp/reloadcmd" MOCK_FAIL_ONCE="$tmp/fail-once"
export PATH="$tmp/bin:$PATH"

for fn in _valid_trusted_cert_pair _valid_self_cert_pair _reload_cert_services \
    deploy_acme_certificate _install_acme_cert _existing_acme_variant \
    gen_self_cert gen_anytls_link; do
    awk -v fn="$fn" '$0 == fn "() {" {on=1} on {print} on && $0 == "}" {exit}' \
        "$root/vless-server.sh" >> "$tmp/functions.sh"
done
source "$tmp/functions.sh"
_ok() { :; }
_err() { echo "$*" >&2; }
_warn() { echo "$*" >&2; }
get_ip_suffix() { :; }

cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env sh
case "$1" in
    is-active) [ "$MOCK_ACTIVE" = 1 ] && [ "$3" = vless-singbox ] ;;
    restart)
        if [ -e "$MOCK_FAIL_ONCE" ]; then rm -f "$MOCK_FAIL_ONCE"; exit 1; fi
        printf '%s\n' "$2" >> "$CFG/restarts"
        ;;
esac
EOF
cat > "$HOME/.acme.sh/acme.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --install-cert ] || exit 1
shift
domain= variant=rsa cert= key= reload=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) domain="$2"; shift 2 ;;
        --ecc) variant=ecc; shift ;;
        --key-file) key="$2"; shift 2 ;;
        --fullchain-file) cert="$2"; shift 2 ;;
        --reloadcmd) reload="$2"; shift 2 ;;
        *) exit 1 ;;
    esac
done
if [ "$variant" = ecc ]; then source_dir="$HOME/.acme.sh/${domain}_ecc"; else source_dir="$HOME/.acme.sh/$domain"; fi
cp "$source_dir/fullchain.cer" "$cert"
cp "$source_dir/$domain.key" "$key"
printf '%s\n' "$reload" > "$MOCK_RELOADCMD"
EOF
chmod +x "$tmp/bin/systemctl" "$HOME/.acme.sh/acme.sh"

openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
    -subj '/CN=Local Test Root' -keyout "$tmp/root.key" -out "$tmp/root.crt" >/dev/null 2>&1
printf '%s\n' 'subjectAltName=DNS:test.example' > "$tmp/extensions"
issue_leaf() {
    local suffix="$1"
    local key_args=(-newkey rsa:2048)
    [[ "$suffix" == first ]] && key_args=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1)
    openssl req "${key_args[@]}" -nodes -subj '/CN=test.example' \
        -keyout "$tmp/$suffix.key" -out "$tmp/$suffix.csr" >/dev/null 2>&1
    openssl x509 -req -in "$tmp/$suffix.csr" -CA "$tmp/root.crt" -CAkey "$tmp/root.key" \
        -CAcreateserial -days 3 -extfile "$tmp/extensions" -out "$tmp/$suffix.leaf" >/dev/null 2>&1
    cat "$tmp/$suffix.leaf" "$tmp/root.crt" > "$tmp/$suffix.fullchain"
}
issue_leaf first
issue_leaf second

_valid_trusted_cert_pair "$tmp/first.fullchain" "$tmp/first.key" test.example
! _valid_trusted_cert_pair "$tmp/first.fullchain" "$tmp/first.key" wrong.example
! _valid_trusted_cert_pair "$tmp/first.fullchain" "$tmp/second.key" test.example
! _valid_trusted_cert_pair "$tmp/first.leaf" "$tmp/first.key" test.example
openssl x509 -req -in "$tmp/first.csr" -CA "$tmp/root.crt" -CAkey "$tmp/root.key" \
    -days 0 -extfile "$tmp/extensions" -out "$tmp/expired.leaf" >/dev/null 2>&1
cat "$tmp/expired.leaf" "$tmp/root.crt" > "$tmp/expired.fullchain"
! _valid_trusted_cert_pair "$tmp/expired.fullchain" "$tmp/first.key" test.example

# First install without an ACME cert: explicit self-signed mode stays stable.
gen_self_cert test.example
_valid_self_cert_pair "$CFG/certs/server.crt" "$CFG/certs/server.key"
[[ $(gen_anytls_link 127.0.0.1 443 pw test.example) == *'allowInsecure=1'* ]]
before=$(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint)
gen_self_cert different.example
[[ $(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint) == "$before" ]]

mkdir -p "$HOME/.acme.sh/test.example_ecc" "$HOME/.acme.sh/test.example"
for variant_dir in test.example_ecc test.example; do
    cp "$tmp/first.fullchain" "$HOME/.acme.sh/$variant_dir/fullchain.cer"
    cp "$tmp/first.key" "$HOME/.acme.sh/$variant_dir/test.example.key"
done
[[ $(_existing_acme_variant test.example) == ecc ]]
mv "$HOME/.acme.sh/test.example_ecc" "$HOME/.acme.sh/ecc.saved"
[[ $(_existing_acme_variant test.example) == rsa ]]
mv "$HOME/.acme.sh/ecc.saved" "$HOME/.acme.sh/test.example_ecc"
(deploy_acme_certificate() { :; }; _install_acme_cert test.example "$HOME/.acme.sh/acme.sh" ecc)
[[ -s "$CFG/certs/.acme-test.example.crt" && -s "$CFG/certs/.acme-test.example.key" ]]
grep -q -- 'cert-deploy.sh' "$MOCK_RELOADCMD"
[[ -s "$CFG/cert-deploy.sh" ]]

# Some Windows shells copy links instead of creating them; report that explicitly.
if [[ ! -L "$CFG/certs/current" ]]; then
    echo 'Certificate validation passed; deployment tests require symlink support'
    exit 0
fi

# An existing ECC ACME cert replaces the self-signed pair and retains a backup.
mkdir -p "$HOME/.acme.sh/test.example_ecc"
cp "$tmp/first.fullchain" "$HOME/.acme.sh/test.example_ecc/fullchain.cer"
cp "$tmp/first.key" "$HOME/.acme.sh/test.example_ecc/test.example.key"
[[ $(_existing_acme_variant test.example) == ecc ]]
_install_acme_cert test.example "$HOME/.acme.sh/acme.sh" ecc
_valid_trusted_cert_pair "$CFG/certs/server.crt" "$CFG/certs/server.key" test.example
[[ $(gen_anytls_link 127.0.0.1 443 pw test.example) == *'allowInsecure=0'* ]]
[[ -s "$MOCK_RELOADCMD" && -d "$CFG/certs/backups" ]]
[[ $(find "$CFG/certs/backups" -name server.crt | wc -l) -ge 1 ]]
before=$(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint)
gen_self_cert support.apple.com
[[ $(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint) == "$before" ]]

# Renewal loads a new matched pair; a restart failure restores the old pair.
cp "$tmp/second.fullchain" "$HOME/.acme.sh/test.example_ecc/fullchain.cer"
cp "$tmp/second.key" "$HOME/.acme.sh/test.example_ecc/test.example.key"
export MOCK_ACTIVE=1
touch "$MOCK_FAIL_ONCE"
! _install_acme_cert test.example "$HOME/.acme.sh/acme.sh" ecc
[[ $(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint) == "$before" ]]
_install_acme_cert test.example "$HOME/.acme.sh/acme.sh" ecc
_valid_trusted_cert_pair "$CFG/certs/server.crt" "$CFG/certs/server.key" test.example
[[ $(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint) != "$before" ]]
[[ -s "$CFG/restarts" ]]

# A process interrupted after staging only one file cannot change the active pair.
before=$(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint)
cp "$tmp/first.key" "$CFG/certs/.acme-test.example.key"
! deploy_acme_certificate test.example
[[ $(openssl x509 -in "$CFG/certs/server.crt" -noout -fingerprint) == "$before" ]]
cp "$tmp/second.key" "$CFG/certs/.acme-test.example.key"
# The persisted hook works independently of the installed main script.
"$BASH" "$CFG/cert-deploy.sh" test.example

# RSA ACME storage is recognized without an ECC directory.
mkdir -p "$HOME/.acme.sh/rsa.example"
cp "$tmp/first.fullchain" "$HOME/.acme.sh/rsa.example/fullchain.cer"
cp "$tmp/first.key" "$HOME/.acme.sh/rsa.example/rsa.example.key"
# The wrong SAN must be rejected even when the path is valid.
! _existing_acme_variant rsa.example
mv "$HOME/.acme.sh/test.example_ecc" "$HOME/.acme.sh/test.example"
[[ $(_existing_acme_variant test.example) == rsa ]]

# Existing deployed files and user-supplied symlinks both migrate safely.
cp "$tmp/second.fullchain" "$HOME/.acme.sh/test.example/fullchain.cer"
cp "$tmp/second.key" "$HOME/.acme.sh/test.example/test.example.key"
migration_modes="regular symlink"
case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) migration_modes=""; echo 'Legacy file/link migration requires native Linux rename semantics' ;;
esac
for mode in $migration_modes; do
    (
        export CFG="$tmp/$mode" MOCK_ACTIVE=0
        mkdir -p "$CFG/certs" "$CFG/original"
        cp "$tmp/first.fullchain" "$CFG/original/server.crt"
        cp "$tmp/first.key" "$CFG/original/server.key"
        if [[ "$mode" == regular ]]; then
            cp "$CFG/original/"* "$CFG/certs/"
        else
            ln -s ../original/server.crt "$CFG/certs/server.crt"
            ln -s ../original/server.key "$CFG/certs/server.key"
        fi
        _install_acme_cert test.example "$HOME/.acme.sh/acme.sh" rsa
        [[ $(readlink "$CFG/certs/server.crt") == current/server.crt ]]
        _valid_trusted_cert_pair "$CFG/certs/server.crt" "$CFG/certs/server.key" test.example
    )
done

echo 'AnyTLS certificate tests passed'
