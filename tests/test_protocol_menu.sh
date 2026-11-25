#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DB_FILE="$tmp/db.json"
XRAY_PROTOCOLS='ss-legacy'
SINGBOX_PROTOCOLS='anytls'
STANDALONE_PROTOCOLS=''

for fn in db_get db_list_ports db_get_all_protocols get_installed_protocols filter_installed \
    get_protocol_name show_all_protocols_info; do
    awk -v fn="$fn" '$0 ~ ("^" fn "\\(\\) \\{") {on=1} on {print} on && $0 == "}" {exit}' \
        "$root/vless-server.sh" >> "$tmp/functions.sh"
done
source "$tmp/functions.sh"
get_xray_protocols() { filter_installed "$XRAY_PROTOCOLS"; }
get_singbox_protocols() { filter_installed "$SINGBOX_PROTOCOLS"; }
get_standalone_protocols() { :; }
_header() { :; }
_line() { :; }
_item() { :; }
show_single_protocol_info() { printf 'selected: %s\n' "$1"; }
W='' NC='' Y='' G='' D=''

node_a='{"port":443,"listen_addr":"127.0.0.1","listen_port":34443}'
node_b='{"port":444,"listen_port":34444}'
for shape in "$node_a" "[$node_a,$node_b]" "[$node_a]"; do
    jq -n --argjson nodes "$shape" '{xray:{"ss-legacy":{port:46806}},singbox:{anytls:$nodes}}' > "$DB_FILE"
    cp "$DB_FILE" "$tmp/db-before"
    output=$(show_all_protocols_info <<< $'2\n0') || exit 1
    grep -Fxq '    1) ss-legacy - 端口: 46806' <<< "$output"
    ports=443
    [[ "$shape" != "[$node_a,$node_b]" ]] || ports=443,444
    grep -Fxq "    2) AnyTLS - 端口: $ports" <<< "$output"
    grep -Fxq 'selected: anytls' <<< "$output"
    cmp "$DB_FILE" "$tmp/db-before"
done
printf 'Protocol list supports single nodes and arrays\n'
