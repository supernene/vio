#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ $(uname -s) == MSYS* ]]; then
    tmp=$(cygpath -m "$tmp")  # Native sing-box reads the certificate paths from JSON.
fi
CFG="$tmp/config"
DB_FILE="$CFG/db.json"
SINGBOX_PROTOCOLS='anytls hy2 tuic'
binary=$(command -v sing-box)

for fn in init_db db_get db_exists db_list_ports register_protocol _singbox_db_nodes _build_singbox_inbound \
    generate_singbox_config _apply_singbox_config _change_singbox_nodes _merge_singbox_manual_routes _singbox_advertised_host \
    check_singbox_runtime_consistency \
    _singbox_stat_key_for_user _valid_trusted_cert_pair _valid_self_cert_pair _existing_acme_variant; do
    awk -v fn="$fn" '$0 ~ ("^" fn "\\(\\) \\{") {on=1} on {print} on && $0 == "}" {exit}' \
        "$root/vless-server.sh" >> "$tmp/functions.sh"
done
source "$tmp/functions.sh"
_err() { echo "$*" >&2; }
_info() { :; }
_ok() { :; }
check_cmd() { command -v "$1" >/dev/null; }
_listen_addr() { echo '::'; }
db_get_warp_mode() { echo disabled; }
db_get_balancer_groups() { echo '[]'; }
db_get_routing_rules() { echo '[]'; }
gen_singbox_routing_rules() { echo '[]'; }
_get_singbox_stat_user_mappings() { :; }
create_singbox_service() { :; }
create_server_scripts() { :; }
running=true
fail_restart=false
fail_stop=false
fail_check=false
svc() {
    [[ "$2" == vless-singbox ]]
    if [[ "$1" != status ]]; then printf '%s\n' "$1" >> "$tmp/service-events"; fi
    case "$1" in
        status) "$running" ;;
        restart|start)
            if $fail_restart; then fail_restart=false; running=false; return 1; fi
            running=true
            ;;
        stop) if $fail_stop; then return 1; fi; running=false ;;
        enable|disable) : ;;
    esac
}
_singbox_service_ready() { "$running"; }
sing-box() {
    if [[ "$1" == check ]]; then
        if [[ "$3" == "$CFG/singbox.json" ]]; then
            "$binary" "$@"
            return
        fi
        printf '%s\n' check >> "$tmp/service-events"
        if $fail_check; then return 1; fi
    fi
    "$binary" "$@"
}

mkdir -p "$CFG/certs/hy2" "$CFG/certs/tuic"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.test' \
    -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" 2>/dev/null
for proto in hy2 tuic; do cp "$CFG/certs/server."{crt,key} "$CFG/certs/$proto/"; done
A='{"server":"proxy-a.example.test","port":24443,"listen_addr":"127.0.0.1","listen_port":31443,"password":"fixture-a","sni":"example.test","users":[{"name":"alice","uuid":"fixture-alice","routing":"direct"}]}'
B='{"server":"proxy-b.example.test","port":25443,"password":"fixture-b","sni":"example.test","users":[{"name":"bob","uuid":"fixture-bob","routing":"direct"}]}'
jq -n --argjson a "$A" '{singbox:{anytls:$a},xray:{vless:{port:16000}}}' > "$DB_FILE"
printf '{"unrelated":true}\n' > "$CFG/config.json"
_apply_singbox_config active
jq -ce '.inbounds[0] | select(.tag=="anytls-in-24443" and .listen=="127.0.0.1" and .listen_port==31443 and
    .users==[{name:"anytls-default",password:"fixture-a"},{name:"anytls-alice",password:"fixture-alice"}])' \
    "$CFG/singbox.json" > "$tmp/inbound-a"

register_protocol anytls "$B"
jq -e '.singbox.anytls | type=="array" and length==2' "$DB_FILE" >/dev/null
jq -ce '.inbounds[] | select(.tag=="anytls-in-24443")' "$CFG/singbox.json" | cmp - "$tmp/inbound-a"
jq -e '(.inbounds | length)==2 and any(.inbounds[]; .tag=="anytls-in-25443" and .listen=="::" and .listen_port==25443 and
    .users==[{name:"anytls-default",password:"fixture-b"},{name:"anytls-bob",password:"fixture-bob"}]) and
    any(.route.rules[]; .inbound==["anytls-in-25443"] and .auth_user==["anytls-bob"])' "$CFG/singbox.json" >/dev/null

# An older config can be valid with another protocol present but missing AnyTLS.
check_singbox_runtime_consistency
cp "$CFG/singbox.json" "$tmp/complete.json"
jq '.inbounds = [{tag:"legacy-direct",type:"direct",listen:"::",listen_port:22443}] |
    del(.route.rules[] | select(.inbound != null))' "$CFG/singbox.json" > "$tmp/partial.json"
"$binary" check -c "$tmp/partial.json"
cp "$tmp/partial.json" "$CFG/singbox.json"
: > "$tmp/service-events"
if check_singbox_runtime_consistency; then exit 1; fi
cmp "$CFG/singbox.json" "$tmp/partial.json"
[[ ! -s "$tmp/service-events" ]]

# Legacy records may omit the actual listener used behind a reverse proxy.
cp "$DB_FILE" "$tmp/db-explicit"
jq 'del(.singbox.anytls[0].listen_addr, .singbox.anytls[0].listen_port)' "$tmp/db-explicit" > "$DB_FILE"
cp "$tmp/complete.json" "$CFG/singbox.json"
if check_singbox_runtime_consistency; then exit 1; fi
cmp "$CFG/singbox.json" "$tmp/complete.json"
[[ ! -s "$tmp/service-events" ]]
cp "$tmp/db-explicit" "$DB_FILE"

_apply_singbox_config active
jq -ce '.inbounds[] | select(.tag=="anytls-in-24443")' "$CFG/singbox.json" | cmp - "$tmp/inbound-a"

cp "$DB_FILE" "$tmp/db-two"
cp "$CFG/singbox.json" "$tmp/config-two"
cp "$CFG/singbox-managed-rules.json" "$tmp/rules-two"
assert_unchanged() {
    cmp "$DB_FILE" "$tmp/db-two"
    cmp "$CFG/singbox.json" "$tmp/config-two"
    cmp "$CFG/singbox-managed-rules.json" "$tmp/rules-two"
    $running
}

# One bad node must not publish a partial config containing only the good nodes.
: > "$tmp/service-events"
if register_protocol anytls '{"port":25444}'; then exit 1; fi
assert_unchanged
[[ ! -s "$tmp/service-events" ]]

fail_check=true
if _change_singbox_nodes delete anytls 25443; then exit 1; fi
fail_check=false
assert_unchanged
[[ $(cat "$tmp/service-events") == check ]]

: > "$tmp/service-events"
fail_restart=true
if _change_singbox_nodes delete anytls 25443; then exit 1; fi
assert_unchanged
[[ $(cat "$tmp/service-events") == $'check\nrestart\nrestart' ]]

_change_singbox_nodes delete anytls 25443
jq -e --argjson a "$A" '.singbox.anytls==[$a]' "$DB_FILE" >/dev/null
jq -ce '.inbounds | select(length==1) | .[0]' "$CFG/singbox.json" | cmp - "$tmp/inbound-a"
[[ $(_singbox_advertised_host anytls "$A") == proxy-a.example.test ]]

# Exercise both other multi-node protocols and ensure this change leaves Xray alone.
register_protocol hy2 '{"port":26443,"password":"fixture-hy-a"}'
register_protocol hy2 '{"port":27443,"password":"fixture-hy-b","listen":"127.0.0.1","listen_port":32443}'
register_protocol tuic '{"port":28443,"password":"fixture-tu-a","uuid":"00000000-0000-4000-8000-000000000001"}'
register_protocol tuic '{"port":29443,"password":"fixture-tu-b","uuid":"00000000-0000-4000-8000-000000000002"}'
jq -e '([.inbounds[] | select(.type=="hysteria2")] | length)==2 and
    ([.inbounds[] | select(.type=="tuic")] | length)==2 and
    any(.inbounds[]; .tag=="hy2-in-27443" and .listen_port==32443)' "$CFG/singbox.json" >/dev/null
_change_singbox_nodes delete hy2 all
_change_singbox_nodes delete tuic all

cp "$DB_FILE" "$tmp/db-last"
cp "$CFG/singbox.json" "$tmp/config-last"
fail_stop=true
if _change_singbox_nodes delete anytls 24443; then exit 1; fi
fail_stop=false
cmp "$DB_FILE" "$tmp/db-last"
cmp "$CFG/singbox.json" "$tmp/config-last"
$running

: > "$tmp/service-events"
_change_singbox_nodes delete anytls 24443
[[ $(cat "$tmp/service-events") == $'stop\ndisable' ]]
[[ ! -e "$CFG/singbox.json" && ! -e "$CFG/singbox-managed-rules.json" ]]
jq -e '.singbox=={} and .xray.vless.port==16000' "$DB_FILE" >/dev/null
jq -e '.unrelated' "$CFG/config.json" >/dev/null
echo 'Sing-box node lifecycle tests passed'
