#!/bin/bash
# ssb-youtube-v6-patch — маршрутизация трафика YouTube через IPv6-выход OUT-сервера
# (по аналогии с ssb-gemini-v6-patch / ssb-openai-v6-patch / ssb-claude-v6-patch).
#
# Зачем: выводит трафик YouTube (видеопотоки googlevideo, сайт, API, превью) в интернет
# по IPv6-адресу сервера. Может улучшить качество видео, если IPv4-маршрут к Google
# загружен/ограничен, а IPv6 идёт через более чистый пиринг (Google отдаёт другой edge).
#
# Использование (на OUT-сервере):
#   ssb-youtube-v6-patch.sh apply [IPv6]   — применить (IPv6 определится сам, если не указан)
#   ssb-youtube-v6-patch.sh remove         — откат (полный)
#   ssb-youtube-v6-patch.sh status         — состояние
#   ssb-youtube-v6-patch.sh test           — проверка связности YouTube по IPv6
#
# Что делает apply:
#   1) бэкап /etc/sing-box/config.json -> /root/bak-singbox/config.json.bak-<дата>;
#   2) добавляет outbound "youtube-v6" (direct с inet6_bind_address=<IPv6>);
#   3) добавляет route-правило (домены YouTube -> youtube-v6) перед catch-all;
#   4) sing-box check + reload;
#   5) тесты связности; при провале — АВТО-ОТКАТ из бэкапа.
#
# Покрываемые домены (суффиксы покрывают ВСЕ поддомены, включая динамические
# хосты googlevideo вида rr*.---sn-*.googlevideo.com):
#   googlevideo.com (видеопотоки/манифесты/live), youtube.com, youtu.be,
#   youtube-nocookie.com, youtubekids.com, ytimg.com, ggpht.com,
#   youtubei.googleapis.com, jnn-pa.googleapis.com, youtube.googleapis.com,
#   yt3.googleusercontent.com, lh3.googleusercontent.com
#
# Безопасно: трогает только трафик YouTube, остальной трафик не меняется.

set -uo pipefail

CONFIG="/etc/sing-box/config.json"
BAKDIR="/root/bak-singbox"

# Домены YouTube: суффиксы (все поддомены) + точечные
DOMAIN_SUFFIX_JSON='["googlevideo.com","youtube.com","youtu.be","youtube-nocookie.com","youtubekids.com","ytimg.com","ggpht.com"]'
DOMAIN_JSON='["youtubei.googleapis.com","jnn-pa.googleapis.com","youtube.googleapis.com","yt3.googleusercontent.com","lh3.googleusercontent.com"]'

die()  { echo "ОШИБКА: $*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "нужен root"; }

detect_ipv6() {
    local v6
    v6=$(ip -6 route get 2a00:1450:4001:80f::200e 2>/dev/null | grep -oE 'src [0-9a-f:]+' | awk '{print $2}' | head -1)
    [[ -z $v6 ]] && v6=$(ip -6 addr show scope global 2>/dev/null | grep -oE 'inet6 [0-9a-f:]+' | awk '{print $2}' | head -1)
    echo "$v6"
}

is_applied() {
    jq -e 'any(.outbounds[]; .tag == "youtube-v6")' "$CONFIG" >/dev/null 2>&1
}

# --- тесты связности YouTube по IPv6 (host-level) ---
run_tests() {
    local v6="$1" ok=0 fail=0 code
    echo "=== connectivity tests to YouTube (source IPv6: ${v6}) ==="
    if [[ -n $(ip -6 addr show scope global 2>/dev/null | grep -F "$v6") ]]; then
        echo "  [OK]   IPv6 ${v6} is assigned on this server"; ok=$((ok+1))
    else
        echo "  [FAIL] IPv6 ${v6} не найден на сервере"; fail=$((fail+1))
    fi
    if getent ahosts www.youtube.com 2>/dev/null | grep -q ':'; then
        echo "  [OK]   DNS: www.youtube.com resolves to IPv6 (AAAA)"; ok=$((ok+1))
    else
        echo "  [SKIP] DNS: AAAA для www.youtube.com не получен"; fail=$((fail+1))
    fi
    code=$(curl -6 --interface "$v6" -s -o /dev/null -m 15 -w '%{http_code}' https://www.youtube.com/generate_204 2>/dev/null)
    if [[ $code == 204 || $code == 200 ]]; then
        echo "  [OK]   www.youtube.com/generate_204 via IPv6 -> HTTP ${code} (reachable)"; ok=$((ok+1))
    else
        echo "  [FAIL] www.youtube.com/generate_204 via IPv6 -> HTTP ${code:-000}"; fail=$((fail+1))
    fi
    code=$(curl -6 --interface "$v6" -s -o /dev/null -m 15 -w '%{http_code}' https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg 2>/dev/null)
    if [[ $code == 200 ]]; then
        echo "  [OK]   i.ytimg.com (превью) via IPv6 -> HTTP 200 (reachable)"; ok=$((ok+1))
    else
        echo "  [FAIL] i.ytimg.com via IPv6 -> HTTP ${code:-000}"; fail=$((fail+1))
    fi
    code=$(curl -6 --interface "$v6" -s -o /dev/null -m 15 -w '%{http_code}' https://redirector.gvt1.com/ 2>/dev/null)
    if [[ $code != 000 && -n $code ]]; then
        echo "  [OK]   redirector.gvt1.com via IPv6 -> HTTP ${code} (reachable)"; ok=$((ok+1))
    else
        echo "  [FAIL] redirector.gvt1.com via IPv6 -> HTTP ${code:-000}"; fail=$((fail+1))
    fi
    echo "--- tests: OK=${ok} FAIL=${fail} SKIP=0"
    return $fail
}

cmd_apply() {
    need_root
    [[ -f $CONFIG ]] || die "нет ${CONFIG}"
    local v6="${1:-}"
    [[ -z $v6 ]] && v6=$(detect_ipv6)
    [[ -z $v6 ]] && die "не удалось определить исходящий IPv6 (укажите аргументом)"
    [[ $v6 == *:* ]] || die "аргумент должен быть IPv6-адресом, получено: $v6"

    if is_applied; then
        echo "youtube-v6 уже применён (для смены IPv6: remove && apply)"
        cmd_status
        return 0
    fi

    mkdir -p "$BAKDIR"
    local bak="$BAKDIR/config.json.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG" "$bak"
    echo "backup: $bak"

    echo "[youtube-v6-patch] IPv6: $v6"

    # outbound youtube-v6
    jq --arg v6 "$v6" \
       '.outbounds += [{"type":"direct","tag":"youtube-v6","inet6_bind_address":$v6}]' \
       "$CONFIG" > /tmp/ytv6-$$.json || die "jq outbound"
    mv /tmp/ytv6-$$.json "$CONFIG"

    # route-правило: вставляем на позицию 3 (как у AI-патчей), перед catch-all
    local rule
    rule=$(jq -c -n --argjson s "$DOMAIN_SUFFIX_JSON" --argjson d "$DOMAIN_JSON" \
        '{domain_suffix:$s, domain:$d, outbound:"youtube-v6"}')
    jq --argjson r "$rule" \
       '(.route.rules // []) as $rs | .route.rules = ($rs[0:3] + [$r] + $rs[3:])' \
       "$CONFIG" > /tmp/ytv6-$$.json || die "jq rules"
    mv /tmp/ytv6-$$.json "$CONFIG"

    echo "[youtube-v6-patch] outbound added: youtube-v6 inet6_bind_address=${v6}"
    echo "[youtube-v6-patch] rules added at 3: ${rule}"

    sing-box check -c "$CONFIG" || { echo "[youtube-v6-patch] sing-box check FAILED — откат"; cp -a "$bak" "$CONFIG"; die "конфиг откатён из бэкапа"; }
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    echo "[youtube-v6-patch] service sing-box reloaded"

    # тесты; при провале — авто-откат
    if ! run_tests "$v6"; then
        echo "[youtube-v6-patch] tests FAILED — авто-откат"
        cp -a "$bak" "$CONFIG"
        sing-box check -c "$CONFIG" && systemctl reload sing-box 2>/dev/null
        die "конфиг откатён из бэкапа (${bak})"
    fi
    echo "[youtube-v6-patch] done: youtube traffic -> youtube-v6 -> IPv6"
}

cmd_remove() {
    need_root
    [[ -f $CONFIG ]] || die "нет ${CONFIG}"
    is_applied || { echo "youtube-v6 не применён — делать нечего"; return 0; }
    mkdir -p "$BAKDIR"
    local bak="$BAKDIR/config.json.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG" "$bak"
    jq '(.outbounds |= map(select(.tag != "youtube-v6")))
        | (.route.rules |= (map(select((.outbound // "") != "youtube-v6"))))' \
       "$CONFIG" > /tmp/ytv6-$$.json || die "jq"
    mv /tmp/ytv6-$$.json "$CONFIG"
    sing-box check -c "$CONFIG" || { cp -a "$bak" "$CONFIG"; die "sing-box check failed — откат"; }
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    echo "[youtube-v6-patch] removed: youtube-v6 outbound + rules (backup: $bak)"
}

cmd_status() {
    echo "=== ssb-youtube-v6-patch status ==="
    if is_applied; then
        echo "  outbound youtube-v6: ЕСТЬ"
        jq -r '.outbounds[]|select(.tag=="youtube-v6")|"  inet6_bind_address: " + (.inet6_bind_address // "-")' "$CONFIG"
        local n
        n=$(jq '[.route.rules[]|select((.outbound // "") == "youtube-v6")]|length' "$CONFIG")
        echo "  route-правил youtube: ${n}"
    else
        echo "  outbound youtube-v6: НЕ применён"
    fi
    local v6
    v6=$(detect_ipv6)
    echo "  исходящий IPv6 сервера: ${v6:-не найден}"
    systemctl is-active sing-box >/dev/null 2>&1 && echo "  sing-box: active" || echo "  sing-box: НЕ active"
}

case "${1:-}" in
    apply)  shift; cmd_apply "${1:-}" ;;
    remove) cmd_remove ;;
    status) cmd_status ;;
    test)   v6="${2:-}"; [[ -z $v6 ]] && v6=$(detect_ipv6); [[ -z $v6 ]] && die "нет IPv6"; run_tests "$v6" ;;
    *)
        echo "Использование: ssb-youtube-v6-patch.sh {apply [IPv6]|remove|status|test}"
        exit 1 ;;
esac
