#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DB_FILE="$tmp/db.json" CFG="$tmp/config"
mkdir -p "$CFG/ruleset" "$CFG/ruleset-src"

for fn in db_get_routing_rules db_add_routing_rule gen_singbox_routing_rules \
    _singbox_ruleset_path _singbox_ruleset_source_path _list_missing_singbox_rulesets_from_routing_rules \
    _ensure_singbox_rulesets_from_routing_rules _build_singbox_ruleset_defs \
    _merge_singbox_manual_routes _regenerate_proxy_configs generate_singbox_config; do
    awk -v fn="$fn" '$0 == fn "() {" {on=1} on {print} on && $0 == "}" {exit}' \
        "$root/vless-server.sh" >> "$tmp/functions.sh"
done
source "$tmp/functions.sh"
_info() { :; }
_warn() { :; }
_err() { echo "$*" >&2; }

cat > "$DB_FILE" <<'EOF'
{"routing_rules":[
  {"id":"custom_1793890568","type":"custom","outbound":"block","domains":"geosite:tracker","ip_version":"as_is"},
  {"id":"custom_1793890568","type":"custom","outbound":"block","domains":"geoip:cn","ip_version":"as_is"},
  {"id":"custom_1793890568","type":"custom","outbound":"block","domains":"geosite:cn","ip_version":"as_is"},
  {"id":"allow-cn","type":"custom","outbound":"direct","domains":"allow.example","ip_version":"as_is"}
]}
EOF
rules=$(gen_singbox_routing_rules)
[[ $(echo "$rules" | jq '[.[] | select(.rule_set)] | length') == 3 ]]
[[ $(echo "$rules" | jq -r '.[0].domain_suffix[0]') == allow.example ]]
[[ $(echo "$rules" | jq -r '[.[] | .rule_set[]?] | unique | length') == 3 ]]
[[ $(echo "$rules" | jq '[.[] | select(.action=="reject")] | length') == 3 ]]
[[ $(echo "$rules" | jq '[.[] | select(.outbound=="block")] | length') == 0 ]]
for tag in geosite-cn geoip-cn geosite-tracker; do
    printf 'SRS' > "$CFG/ruleset/$tag.srs"
done
_ensure_singbox_rulesets_from_routing_rules "$rules"
defs=$(_build_singbox_ruleset_defs "$rules")
[[ $(echo "$defs" | jq length) == 3 ]]
[[ $(echo "$defs" | jq '[.[] | select(.type=="local" and .format=="binary")] | length') == 3 ]]

# If sing-box is available, check the generated route shape against its parser.
binary="${SING_BOX_TEST_BIN:-}"
[[ -z "$binary" ]] && binary=$(command -v sing-box || true)
if [[ -n "$binary" ]]; then
    for tag in geosite-cn geoip-cn geosite-tracker; do
        if [[ "$tag" == geoip-cn ]]; then
            printf '%s\n' '{"version":3,"rules":[{"ip_cidr":["1.1.1.0/24"]}]}' > "$tmp/source.json"
        else
            printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["example.com"]}]}' > "$tmp/source.json"
        fi
        "$binary" rule-set compile "$tmp/source.json" -o "$CFG/ruleset/$tag.srs"
    done
    defs=$(_build_singbox_ruleset_defs "$rules")
    case "$(uname -s)" in
        MSYS*|MINGW*|CYGWIN*)
            native_dir=$(cd "$CFG/ruleset" && pwd -W)
            defs=$(echo "$defs" | jq --arg dir "$native_dir" 'map(.path = ($dir + "/" + .tag + ".srs"))')
            ;;
    esac
    jq -n --argjson rules "$rules" --argjson defs "$defs" '{
        log:{level:"warn"},
        dns:{servers:[{type:"local",tag:"local"}]},
        inbounds:[{type:"mixed",tag:"test-in",listen:"127.0.0.1",listen_port:20001}],
        outbounds:[{type:"direct",tag:"direct"},{type:"direct",tag:"direct-asis"},
            {type:"direct",tag:"direct-prefer-ipv4",domain_resolver:{server:"local",strategy:"prefer_ipv4"}},
            {type:"block",tag:"block"}],
        route:{rules:([{action:"sniff"}] + $rules),rule_set:$defs,final:"direct"}
    }' > "$tmp/compat.json"
    "$binary" check -c "$tmp/compat.json"
fi

cat > "$CFG/singbox.json" <<'EOF'
{"outbounds":[{"type":"socks","tag":"custom-proxy","server":"127.0.0.1","server_port":1080}],
"route":{"rules":[
  {"action":"sniff"},
  {"domain_suffix":["quark.cn"],"action":"reject"},
  {"domain_suffix":["apple.com"],"outbound":"custom-proxy"},
  {"rule_set":["geosite-cn","geoip-cn"],"action":"reject"}
],"rule_set":[{"type":"local","tag":"custom-local","format":"binary","path":"/custom.srs"}]}}
EOF
next=$(jq -n --argjson rules "$rules" --argjson defs "$defs" '{route:{rules:$rules,rule_set:$defs,final:"direct"}}')
merged=$(_merge_singbox_manual_routes "$next")
[[ $(echo "$merged" | jq -r '.route.rules[0].action') == sniff ]]
[[ $(echo "$merged" | jq '[.route.rules[] | select(.domain_suffix==["quark.cn"])] | length') == 1 ]]
[[ $(echo "$merged" | jq '[.route.rules[] | select(.rule_set==["geosite-cn","geoip-cn"])] | length') == 0 ]]
[[ $(echo "$merged" | jq '[.route.rule_set[] | select(.tag=="custom-local")] | length') == 1 ]]
[[ $(echo "$merged" | jq '[.outbounds[] | select(.tag=="custom-proxy")] | length') == 1 ]]
printf '%s\n' "$merged" > "$CFG/singbox.json"
printf '%s\n' "$(jq -n --argjson rules "$rules" --argjson defs "$defs" '{rules:$rules,rule_set:$defs}')" > "$CFG/singbox-managed-rules.json"
merged=$(_merge_singbox_manual_routes "$next")
expected=$(($(echo "$next" | jq '.route.rules | length') + 3))
[[ $(echo "$merged" | jq '.route.rules | length') -eq $expected ]]

rm "$CFG/ruleset/geoip-cn.srs"
_build_singbox_ruleset() { return 1; }
! _ensure_singbox_rulesets_from_routing_rules "$rules"
printf 'cached' > "$CFG/ruleset/geoip-cn.srs"
printf '{}' > "$CFG/ruleset-src/geoip-cn.json"
touch "$CFG/ruleset/.managed-geoip-cn"
_get_file_mtime() { echo 1; }
_ensure_singbox_rulesets_from_routing_rules "$rules"
[[ -s "$CFG/ruleset/geoip-cn.srs" ]]

db_add_routing_rule custom block one.example as_is
db_add_routing_rule custom block two.example as_is
[[ $(jq '[.routing_rules[] | select(.domains=="one.example" or .domains=="two.example") | .id] | unique | length' "$DB_FILE") == 2 ]]
db_add_routing_rule custom block geosite:cn as_is restrict-cn-geosite
[[ $(jq -r '.routing_rules[] | select(.domains=="geosite:cn") | .id' "$DB_FILE" | grep -c '^restrict-cn-geosite$') == 1 ]]
db_add_routing_rule custom block geosite:cn,geoip:cn as_is
mixed=$(gen_singbox_routing_rules)
[[ $(echo "$mixed" | jq '[.[] | select(.rule_set==["geosite-cn","geoip-cn"])] | length') == 1 ]]
[[ $(echo "$mixed" | jq '[.[] | select(.rule_set==["geosite-cn"])] | length') == 1 ]]
db_add_routing_rule all direct '' as_is
mixed=$(gen_singbox_routing_rules)
[[ $(echo "$mixed" | jq -r '.[0].domain_suffix[0]') == allow.example ]]
[[ $(echo "$mixed" | jq -r '.[-1].outbound') == direct-asis ]]

# Exercise the complete config generator with two protocols and user changes.
(
    p=ss2022
    _ok() { :; }
    _ensure_singbox_default_users() { :; }
    _listen_addr() { echo 127.0.0.1; }
    db_list_protocols() { printf '%s\n' anytls ss2022; }
    db_get() { jq -c --arg p "$2" '.singbox[$p]' "$DB_FILE"; }
    db_get_warp_mode() { echo disabled; }
    db_get_balancer_groups() { echo '[]'; }
    _valid_trusted_cert_pair() { return 0; }
    _get_singbox_stat_user_mappings() { :; }
    sing-box() { [[ "$1" == check ]]; }
    jq '.singbox = {
        anytls:{port:443,password:"keep-password",sni:"test.example",users:[]},
        ss2022:{port:8443,password:"keep-ss",method:"2022-blake3-aes-128-gcm",users:[]}
    }' "$DB_FILE" > "$tmp/db-next"
    mv "$tmp/db-next" "$DB_FILE"
    generate_singbox_config || exit 1
    [[ $(jq '.route.rules | map(select(.rule_set)) | length' "$CFG/singbox.json") -gt 0 ]]
    jq -e '.inbounds[] | select(.type=="anytls" and .listen_port==443) | .users[] | select(.name=="anytls-default" and .password=="keep-password")' "$CFG/singbox.json" >/dev/null
    jq '.singbox.anytls.users=[{name:"added",uuid:"new-user-password"}]' "$DB_FILE" > "$tmp/db-next"
    mv "$tmp/db-next" "$DB_FILE"
    generate_singbox_config || exit 1
    jq -e '.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="anytls-added")' "$CFG/singbox.json" >/dev/null
    jq '.singbox.ss2022.port=9443' "$DB_FILE" > "$tmp/db-next"
    mv "$tmp/db-next" "$DB_FILE"
    generate_singbox_config || exit 1
    jq -e '.inbounds[] | select(.type=="anytls" and .listen_port==443) | .users[] | select(.name=="anytls-default" and .password=="keep-password")' "$CFG/singbox.json" >/dev/null
)

# A failed rebuild must not restart stale config; restart failure restores it.
printf 'old-config' > "$CFG/singbox.json"
get_xray_protocols() { :; }
get_singbox_protocols() { echo anytls; }
generate_singbox_config() { return 1; }
svc() { printf '%s\n' restart >> "$tmp/service-calls"; }
! _regenerate_proxy_configs
[[ $(cat "$CFG/singbox.json") == old-config && ! -e "$tmp/service-calls" ]]
generate_singbox_config() { printf 'new-config' > "$CFG/singbox.json"; }
svc() { return 1; }
! _regenerate_proxy_configs
[[ $(cat "$CFG/singbox.json") == old-config ]]
echo 'Sing-box route tests passed'
