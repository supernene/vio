#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ $(uname -s) == MSYS* ]]; then tmp=$(cygpath -m "$tmp"); fi
CFG="$tmp/cfg"
DB_FILE="$CFG/db.json"
XRAY_LOG_DIR="$tmp/log"
XRAY_PROTOCOLS='vless vless-xhttp vless-xhttp-cdn vless-ws vless-ws-notls vmess-ws vless-vision trojan trojan-ws socks ss2022 ss-legacy'
SINGBOX_PROTOCOLS='anytls'
binary=$(command -v xray)
for fn in init_db _xray_db_nodes _xray_node_accounts _xray_master_node _has_master_protocol _get_master_port generate_xray_config add_xray_inbound_v2 \
    register_protocol _apply_xray_config _change_xray_nodes; do
    awk -v fn="$fn" '$0 ~ ("^" fn "\\(\\) \\{") {on=1} on {print} on && $0 == "}" {exit}' \
        "$root/vless-server.sh" >> "$tmp/functions.sh"
done
source "$tmp/functions.sh"
_err() { echo "$*" >&2; }
_listen_addr() { echo '0.0.0.0'; }
db_get_routing_rules() { echo '[]'; }
gen_xray_user_routing_rules() { echo '[]'; }
gen_xray_ip_routing_outbounds() { echo '[]'; }
db_ip_routing_enabled() { return 1; }
_sync_tunnel_config() { :; }
create_server_scripts() { :; }
create_service() { :; }
service_running=false
fail_restart=false
fail_stop=false
events="$tmp/events"
svc() {
    [[ "$2" == vless-reality ]] || return 1
    [[ "$1" == status ]] || echo "$1" >> "$events"
    case "$1" in
        status) "$service_running" ;;
        start|restart)
            if $fail_restart; then fail_restart=false; service_running=false; return 1; fi
            service_running=true ;;
        stop) if $fail_stop; then return 1; fi; service_running=false ;;
        enable|disable) : ;;
        *) return 1 ;;
    esac
}
_xray_service_ready() { "$service_running"; }
xray() {
    [[ "$1 $2 $3" == 'run -test -c' && "$4" == "$CFG/".xray.*/config.json ]] || return 1
    echo check >> "$events"
    "$binary" "$@"
}

mkdir -p "$CFG/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.test' \
    -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" 2>/dev/null
A='{"port":"24443","listen_addr":"127.0.0.1","listen_port":"31443","sni":"a.example.test","path":"/a","uuid":"00000000-0000-4000-8000-000000000001","users":[{"name":"default","uuid":"00000000-0000-4000-8000-000000000001"},{"name":"alice","uuid":"00000000-0000-4000-8000-000000000003"},{"name":"disabled","uuid":"00000000-0000-4000-8000-000000000004","enabled":false}]}'
B='{"port":25443,"sni":"b.example.test","path":"/b","uuid":"00000000-0000-4000-8000-000000000002"}'
register_protocol vmess-ws "$A"
[[ $(cat "$events") == $'check\nstart\nenable' ]]
jq -ce '.inbounds[] | select(.tag=="vmess-ws-24443" and .listen=="127.0.0.1" and .port==31443 and
    [.settings.clients[].id]==["00000000-0000-4000-8000-000000000001","00000000-0000-4000-8000-000000000003"])' "$CFG/config.json" > "$tmp/inbound-a"
jq '.singbox = {anytls:{port:21443}}' "$DB_FILE" > "$tmp/db"
mv "$tmp/db" "$DB_FILE"
printf 'unrelated\n' > "$CFG/singbox.json"
register_protocol vmess-ws "$B"
jq -e '.xray["vmess-ws"] | type=="array" and length==2' "$DB_FILE" >/dev/null
jq -ce '.inbounds[] | select(.tag=="vmess-ws-24443")' "$CFG/config.json" | cmp - "$tmp/inbound-a"
jq -e 'any(.inbounds[]; .tag=="vmess-ws-25443" and .port==25443 and .listen=="0.0.0.0" and
    [.settings.clients[].id]==["00000000-0000-4000-8000-000000000002"])' "$CFG/config.json" >/dev/null
cp "$DB_FILE" "$tmp/db-two"
cp "$CFG/config.json" "$tmp/config-two"
assert_unchanged() { cmp "$DB_FILE" "$tmp/db-two"; cmp "$CFG/config.json" "$tmp/config-two"; $service_running; }

: > "$events"
if register_protocol vmess-ws '{"port":26443}'; then exit 1; fi
assert_unchanged
[[ ! -s "$events" ]]

if register_protocol ss-legacy '{"port":26443,"method":"invalid-test-method","password":"fixture"}'; then exit 1; fi
assert_unchanged
[[ $(cat "$events") == check ]]

: > "$events"
fail_restart=true
if _change_xray_nodes delete vmess-ws 25443; then exit 1; fi
assert_unchanged
[[ $(cat "$events") == $'check\nrestart\nrestart' ]]

_change_xray_nodes delete vmess-ws 25443
jq -e --argjson a "$A" '.xray["vmess-ws"]==[$a]' "$DB_FILE" >/dev/null
jq -ce '.inbounds[] | select(.tag=="vmess-ws-24443")' "$CFG/config.json" | cmp - "$tmp/inbound-a"

# Register a second master port and 2 WS paths with different real listeners.
register_protocol trojan '{"port":27443,"password":"fixture-alt"}'
register_protocol trojan '{"port":8443,"password":"fixture-master","users":[{"name":"default","uuid":"fixture-master"},{"name":"eve","uuid":"fixture-eve"}]}'
[[ $(_get_master_port 25443) == 8443 ]]
register_protocol vmess-ws "$B"
jq -e 'any(.inbounds[]; .tag=="trojan-8443" and
        [.settings.clients[].password]==["fixture-master","fixture-eve"] and
        any(.settings.fallbacks[]; .path=="/a" and .dest==31443) and
        any(.settings.fallbacks[]; .path=="/b" and .dest==25443)) and
    any(.inbounds[]; .tag=="trojan-27443" and [.settings.clients[].password]==["fixture-alt"])' "$CFG/config.json" >/dev/null
cp "$DB_FILE" "$tmp/db-two"
cp "$CFG/config.json" "$tmp/config-two"
: > "$events"
duplicate=$(jq -c '.port = 26443 | .path = "/a"' <<< "$B")
if register_protocol vmess-ws "$duplicate"; then exit 1; fi
assert_unchanged
[[ ! -s "$events" ]]
register_protocol vless-ws-notls '{"port":28443,"host":"a.example.test","path":"/a","uuid":"00000000-0000-4000-8000-000000000005"}'
register_protocol vless-ws-notls '{"port":29443,"host":"b.example.test","path":"/b","uuid":"00000000-0000-4000-8000-000000000006"}'
register_protocol socks '{"port":30443,"username":"fixture-owner","password":"fixture-owner-pass","users":[{"name":"default","uuid":"fixture-owner-pass"},{"name":"fixture-user","uuid":"fixture-user-pass"}]}'
jq -e 'any(.inbounds[]; .tag=="vless-ws-notls-29443" and .streamSettings.wsSettings.headers.Host=="b.example.test") and
    any(.inbounds[]; .tag=="socks-30443" and [.settings.accounts[].user]==["fixture-owner","fixture-user"])' "$CFG/config.json" >/dev/null
_change_xray_nodes delete trojan all
_change_xray_nodes delete vless-ws-notls all
_change_xray_nodes delete socks 30443
_change_xray_nodes delete vmess-ws 25443
cp "$DB_FILE" "$tmp/db-last"
cp "$CFG/config.json" "$tmp/config-last"
fail_stop=true
if _change_xray_nodes delete vmess-ws 24443; then exit 1; fi
fail_stop=false
cmp "$DB_FILE" "$tmp/db-last"
cmp "$CFG/config.json" "$tmp/config-last"
$service_running
: > "$events"
_change_xray_nodes delete vmess-ws 24443
[[ $(cat "$events") == $'stop\ndisable' && ! -e "$CFG/config.json" ]]
jq -e '.xray=={} and .singbox.anytls.port==21443' "$DB_FILE" >/dev/null
[[ $(cat "$CFG/singbox.json") == unrelated ]]
echo 'Xray node lifecycle tests passed'
