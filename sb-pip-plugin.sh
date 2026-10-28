#!/bin/bash
# =========================================================
# sing-box.sh 插件：公共 ProxyIP 分流（单文件，用链接安装）
#
# 安装/更新: bash <(curl -Ls https://raw.githubusercontent.com/你的用户名/你的仓库/main/proxyip.sh)
# 卸载:      bash <(curl -Ls https://raw.githubusercontent.com/你的用户名/你的仓库/main/proxyip.sh) -u
#
# 原理：sb 快捷指令每次都会从 GitHub 拉取最新主脚本运行，本机没有主脚本文件可改。
#       安装时把 /etc/sing-box/sb.sh 换成带插件的版本：拉取主脚本 -> 自动在
#       「WARP分流管理」菜单末尾追加本插件入口(序号=现有最大序号+1) -> 再运行。
#       主脚本本身不被修改；插入失败时自动回退为原样运行。
# 注意：只对 sb 命令生效；直接用链接运行主脚本时没有此菜单。
# =========================================================
export LANG=en_US.UTF-8
work_dir="${SB_WORK_DIR:-/etc/sing-box}"
plugin_dir="${work_dir}/plugins"
wrapper="${work_dir}/sb.sh"
wrapper_marker="plugin wrapper"   # 子串匹配: 兼容旧标记 "# proxyip-plugin wrapper" 与多插件共用的 "# sb-plugin wrapper"
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }

[ -z "$SB_WORK_DIR" ] && [ "$EUID" -ne 0 ] && { red "请在root用户下运行脚本"; exit 1; }

write_payload() {
cat > "${plugin_dir}/proxyip.sh" <<'PIP_PAYLOAD_EOF'
# ---- 公共 ProxyIP 分流 ----
# 取 Cloudflare trace 里的 ip= / colo= ；$1=host(可空) $2=ProxyIP(空则直连) $3=IP族参数(-4/-6) $4=ProxyIP端口(默认443)
_pip_trace() {
    local host=${1:-www.cloudflare.com} pip=$2 fam=$3 port=${4:-443}
    local args=(-s --connect-timeout 5 -m 8 $fam)
    if [ -n "$pip" ]; then
        [[ "$pip" == *:* ]] && pip="[${pip}]"
        args+=(--connect-to "${host}:443:${pip}:${port}")
    fi
    curl "${args[@]}" "https://${host}/cdn-cgi/trace" 2>/dev/null | grep -E '^(ip|colo)=' | tr '\n' ' '
}

# 插件状态文件 (主/备 ProxyIP、当前使用哪个)，简单的 KEY=VALUE
_pip_cf() { echo "${work_dir}/plugins/proxyip.conf"; }
_pip_conf_get() { local cf; cf=$(_pip_cf); [ -f "$cf" ] && sed -n "s/^$1=//p" "$cf" | head -1; }
_pip_conf_set() {
    local cf k=$1 v=$2; cf=$(_pip_cf)
    mkdir -p "$(dirname "$cf")"; touch "$cf"
    if grep -q "^${k}=" "$cf"; then sed -i "s|^${k}=.*|${k}=${v}|" "$cf"; else echo "${k}=${v}" >> "$cf"; fi
}
_pip_conf_del() { local cf; cf=$(_pip_cf); [ -f "$cf" ] && sed -i "/^$1=/d" "$cf"; return 0; }

# 列出已添加的 ProxyIP 分流规则: 输出 "规则名<TAB>地址:端口<TAB>域名列表"
_pip_list_rules() {
    jq -r '
      . as $root
      | .route.rules[]?
      | select(.override_address != null and (.rule_set | type) == "array")
      | .rule_set[0] as $t
      | (first($root.route.rule_set[]? | select(.tag == $t) | .rules[0].domain_suffix | join(" ")) // "") as $d
      | "\($t)\t\(.override_address):\(.override_port // 443)\t\($d)"
    ' "$route_file" 2>/dev/null
}

# 槽位 / 首选 / 当前使用 的状态：
#   proxyip.slots 每行 "序号 地址 端口" (序号 1-5，空槽位不写)
#   proxyip.conf  PREF=首选槽位序号(没有=不设首选) CUR_ADDR/CUR_PORT=当前正在使用的 ProxyIP
# 旧版(主 + 备用列表)自动迁移：原来的主 -> 槽位1 并设为首选，备用依次放到 2-5
_pip_sync_conf() {
    local sf la=() lp=() a p row has_pri=0 ob_a ob_p ca cp i k pf
    sf=$(_pip_sf)
    if [ ! -s "$sf" ]; then
        a=$(_pip_conf_get P_ADDR); p=$(_pip_conf_get P_PORT)
        if [ -z "$a" ] && [ -f "$route_file" ]; then
            row=$(jq -r '.route.rules[]? | select(.override_address != null) | "\(.override_address)\t\(.override_port // 443)"' "$route_file" 2>/dev/null | head -1)
            [ -n "$row" ] && { a=${row%%$'\t'*}; p=${row##*$'\t'}; }
        fi
        if [ -n "$a" ]; then la+=("$a"); lp+=("${p:-443}"); has_pri=1; fi
        ob_a=$(_pip_conf_get B_ADDR); ob_p=$(_pip_conf_get B_PORT)
        if [ -f "$(_pip_bkf)" ]; then
            while read -r a p; do
                [ -n "$a" ] && { la+=("$a"); lp+=("${p:-443}"); }
            done < "$(_pip_bkf)"
        elif [ -n "$ob_a" ]; then
            la+=("$ob_a"); lp+=("${ob_p:-443}")
            if [ "$(_pip_conf_get CURRENT)" = backup ] && [ -z "$(_pip_conf_get CUR_ADDR)" ]; then
                _pip_conf_set CUR_ADDR "$ob_a"; _pip_conf_set CUR_PORT "${ob_p:-443}"
            fi
        fi
        if [ "${#la[@]}" -gt 0 ]; then
            ca=$(_pip_conf_get CUR_ADDR); cp=$(_pip_conf_get CUR_PORT); cp=${cp:-443}
            if [ "${#la[@]}" -gt 5 ]; then
                # 超过 5 个：保留前 5 个；正在用的若排在后面，顶替第 5 个
                for ((i=5; i<${#la[@]}; i++)); do
                    if [ "${la[$i]}" = "$ca" ] && [ "${lp[$i]}" = "$cp" ]; then la[4]=${la[$i]}; lp[4]=${lp[$i]}; break; fi
                done
                la=("${la[@]:0:5}"); lp=("${lp[@]:0:5}")
                yellow "ProxyIP 槽位最多 5 个，旧配置里超出的备用已忽略。"; sleep 3
            fi
            mkdir -p "$(dirname "$sf")"; : > "$sf"
            for ((i=0; i<${#la[@]}; i++)); do echo "$((i+1)) ${la[$i]} ${lp[$i]}" >> "$sf"; done
            [ "$has_pri" = 1 ] && _pip_conf_set PREF 1
        fi
        for k in P_ADDR P_PORT B_ADDR B_PORT CURRENT; do _pip_conf_del "$k"; done
        rm -f "$(_pip_bkf)"
    fi
    # 首选必须指向已配置的槽位
    pf=$(_pip_conf_get PREF)
    if [ -n "$pf" ] && [ -z "$(_pip_slot_get "$pf")" ]; then _pip_conf_del PREF; fi
    # 状态里没有当前使用的地址时，取路由规则里正在用的
    if [ -z "$(_pip_conf_get CUR_ADDR)" ] && [ -f "$route_file" ]; then
        row=$(jq -r '.route.rules[]? | select(.override_address != null) | "\(.override_address)\t\(.override_port // 443)"' "$route_file" 2>/dev/null | head -1)
        if [ -n "$row" ]; then
            _pip_conf_set CUR_ADDR "${row%%$'\t'*}"; _pip_conf_set CUR_PORT "${row##*$'\t'}"
        fi
    fi
    return 0
}

# 解析 "地址[:端口]" -> 设置 pip_addr / pip_port(端口可为空，默认443)；格式无效返回1
_pip_parse_addr() {
    local in=$1
    local r_v6p='^\[([^]]+)\]:([0-9]+)$' r_v6='^\[([^]]+)\]$' r_hp='^([^:]+):([0-9]+)$'
    local r_dom='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' r_v4='^([0-9]{1,3}\.){3}[0-9]{1,3}$' r_v6b='^[0-9a-fA-F:]*:[0-9a-fA-F:]*:[0-9a-fA-F:]*$'
    pip_addr=""; pip_port=""
    if [[ "$in" =~ $r_v6p ]]; then pip_addr=${BASH_REMATCH[1]}; pip_port=${BASH_REMATCH[2]}
    elif [[ "$in" =~ $r_v6 ]]; then pip_addr=${BASH_REMATCH[1]}
    elif [[ "$in" =~ $r_hp ]]; then pip_addr=${BASH_REMATCH[1]}; pip_port=${BASH_REMATCH[2]}
    else pip_addr=$in
    fi
    [[ "$pip_addr" =~ $r_dom || "$pip_addr" =~ $r_v4 || "$pip_addr" =~ $r_v6b ]] || return 1
    if [ -n "$pip_port" ]; then
        [ "$pip_port" -ge 1 ] && [ "$pip_port" -le 65535 ] || return 1
    fi
    return 0
}

# 检测 ProxyIP 是否可用(端口缺省443)；读取 pip_addr/pip_port，设置 fam direct_info pip_info
# 返回 0=可用 1=该 ProxyIP 不可用 2=服务器自身访问不了 cloudflare.com
# 公共 NAT64 前缀 (nat64.net / Kasper Dupont，均为 /96，来源 nat64.xyz)
_pip_nat64_prefixes() { echo "2a00:1098:2b:: 2a00:1098:2c:1:: 2a01:4f8:c2c:123f:64:: 2a01:4f9:c010:3f02:64::"; }

# 取 ProxyIP 的 IPv4：本身是 IPv4 就直接用；域名则解析 A 记录
_pip_v4_of() {
    local h=$1 v
    local r_v4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    [[ "$h" =~ $r_v4 ]] && { echo "$h"; return 0; }
    v=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')
    [[ "$v" =~ $r_v4 ]] || v=$(dig +short A "$h" 2>/dev/null | grep -E "$r_v4" | head -1)
    [[ "$v" =~ $r_v4 ]] || v=$(host -t A "$h" 2>/dev/null | awk '/has address/{print $4; exit}')
    [[ "$v" =~ $r_v4 ]] && echo "$v"
    return 0
}

# 前缀($1) + IPv4($2) -> 合成的 IPv6 地址
_pip_synth() {
    local a b c d
    IFS=. read -r a b c d <<< "$2"
    printf '%s%02x%02x:%02x%02x' "$1" "$a" "$b" "$c" "$d"
}

# 依次用公共 NAT64 前缀测试：$1=地址(域名或IPv4) $2=端口 $3=IP族；成功则输出可用的合成地址
_pip_nat64_find() {
    local v4 pfx cand
    v4=$(_pip_v4_of "$1"); [ -z "$v4" ] && return 1
    for pfx in $(_pip_nat64_prefixes); do
        cand=$(_pip_synth "$pfx" "$v4")
        if [ -n "$(_pip_trace "" "$cand" "$3" "${2:-443}")" ]; then echo "$cand"; return 0; fi
    done
    return 1
}

# 合成地址 <-> 原域名 对照 (仅用于显示，方便知道这个 IPv6 地址是谁)
_pip_nf() { echo "${work_dir}/plugins/proxyip.nat64"; }
_pip_nat64_save() {   # $1=合成地址 $2=原域名/IPv4
    local f; f=$(_pip_nf)
    mkdir -p "$(dirname "$f")"
    { awk -F'\t' -v a="$1" '$1!=a' "$f" 2>/dev/null; printf '%s\t%s\n' "$1" "$2"; } > "${f}.tmp" && mv -f "${f}.tmp" "$f"
}
_pip_src_note() {     # $1=地址；若是合成地址则输出 "  (NAT64，原 xxx)"
    local f s; f=$(_pip_nf)
    [ -f "$f" ] || return 0
    s=$(awk -F'\t' -v a="$1" '$1==a{print $2; exit}' "$f")
    [ -n "$s" ] && echo "  (NAT64，原 ${s})"
    return 0
}

# 检测 ProxyIP 是否可用(端口缺省443)；读取 pip_addr/pip_port，设置 fam direct_info pip_info
# 纯 IPv6 机器连不上只有 IPv4 的 ProxyIP 时，自动改用公共 NAT64 合成地址：此时 pip_addr 变为合成的 IPv6 地址，
# 原地址记在 pip_nat64_src。返回 0=可用 1=该 ProxyIP 不可用 2=服务器自身访问不了 cloudflare.com
_pip_probe() {
    [ -z "$pip_port" ] && pip_port=443
    pip_nat64_src=""
    fam="-4"
    direct_info=$(_pip_trace "" "" "$fam")
    [ -z "$direct_info" ] && { fam="-6"; direct_info=$(_pip_trace "" "" "$fam"); }
    if [ -z "$direct_info" ]; then
        red "无法访问 cloudflare.com，请检查服务器网络"; return 2
    fi
    echo ""
    green "服务器直连:   ${direct_info}"
    pip_info=$(_pip_trace "" "$pip_addr" "$fam" "$pip_port")
    if [ -z "$pip_info" ] && [ "$fam" = "-6" ] && [[ "$pip_addr" != *:* ]]; then
        yellow "本机是纯 IPv6 环境，该 ProxyIP 无法直接连接，正在尝试通过公共 NAT64 (nat64.net) 连接..."
        local lit
        lit=$(_pip_nat64_find "$pip_addr" "$pip_port" "$fam")
        if [ -n "$lit" ]; then
            pip_nat64_src=$pip_addr; pip_addr=$lit
            pip_info=$(_pip_trace "" "$pip_addr" "$fam" "$pip_port")
            green "已通过公共 NAT64 连通，改用合成地址: ${pip_addr}"
        fi
    fi
    [ -n "$pip_info" ] || return 1
    return 0
}

# 测延迟：$1=地址 $2=端口 $3=IP族 $4=次数(默认5)
# 结果：pip_lat_avg(毫秒) pip_lat_max pip_lat_fail(超时次数) pip_lat_n
_pip_latency() {
    local h=$1 port=${2:-443} fam=$3 n=${4:-5} i out t ms sum=0 ok=0
    [[ "$h" == *:* ]] && h="[${h}]"
    pip_lat_n=$n; pip_lat_max=0; pip_lat_fail=0; pip_lat_avg=0
    for ((i=1; i<=n; i++)); do
        out=$(curl -s -o /dev/null $fam --connect-timeout 5 -m 8 --connect-to "www.cloudflare.com:443:${h}:${port}" \
              -w '%{http_code} %{time_starttransfer}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        if [ "${out%% *}" = "200" ]; then
            ms=$(awk -v t="${out#* }" 'BEGIN{printf "%d", t*1000}')
            sum=$((sum+ms)); ok=$((ok+1))
            [ "$ms" -gt "$pip_lat_max" ] && pip_lat_max=$ms
        else
            pip_lat_fail=$((pip_lat_fail+1))
        fi
    done
    [ "$ok" -gt 0 ] && pip_lat_avg=$((sum/ok))
    return 0
}

# 按 pip_lat_* 评级：pip_rate_lv 0良好 1一般 2较差 3不可用
_pip_rate() {
    if [ "$pip_lat_fail" -ge $(( (pip_lat_n+1)/2 )) ]; then pip_rate_lv=3; pip_rate_txt="不可用 (超时过多)"
    elif [ "$pip_lat_fail" -gt 0 ] || [ "$pip_lat_avg" -gt 1500 ]; then pip_rate_lv=2; pip_rate_txt="较差"
    elif [ "$pip_lat_avg" -gt 600 ]; then pip_rate_lv=1; pip_rate_txt="一般"
    else pip_rate_lv=0; pip_rate_txt="良好"; fi
}

_pip_show_latency() {
    _pip_rate
    local msg="延迟 平均 ${pip_lat_avg}ms  最高 ${pip_lat_max}ms  超时 ${pip_lat_fail}/${pip_lat_n}  评级: ${pip_rate_txt}"
    [ "$pip_lat_fail" -ge "$pip_lat_n" ] && msg="延迟 全部超时 (${pip_lat_n}/${pip_lat_n})  评级: ${pip_rate_txt}"
    case "$pip_rate_lv" in
        0) green "  ${msg}" ;;
        1) yellow "  ${msg}" ;;
        *) red "  ${msg}" ;;
    esac
}

# 测下载速度(约25MB，最多15秒)：$1=地址 $2=端口 $3=IP族 -> pip_dl_mbps (失败为空)
_pip_download() {
    local h=$1 port=${2:-443} fam=$3 sp
    [[ "$h" == *:* ]] && h="[${h}]"
    sp=$(curl -s -o /dev/null $fam --connect-timeout 5 -m 15 --connect-to "speed.cloudflare.com:443:${h}:${port}" \
         -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000' 2>/dev/null)
    pip_dl_mbps=$(awk -v s="$sp" 'BEGIN{ if (s+0 > 0) printf "%.1f", s*8/1000000 }')
}

# 添加/更换前的质量检查：测5次延迟并显示；较差/不可用时询问是否仍要使用。0=继续 1=取消
_pip_quality_gate() {
    echo ""
    yellow "正在测试延迟 (5次)..."
    _pip_latency "$1" "$2" "$3" 5
    _pip_show_latency
    [ "$pip_rate_lv" -le 1 ] && return 0
    reading "质量较差，仍要使用？(y/N): " q_go
    [[ "$q_go" == "y" || "$q_go" == "Y" ]]
}

# 把所有 ProxyIP 规则改指向 $1(地址) $2(端口)：备份 -> 写入 -> 校验(失败回滚) -> 重载
_pip_apply() {
    cp -f "$route_file" "${route_file}.bak"
    jq_write "$route_file" --arg addr "$1" --argjson pport "$2" '
      .route.rules |= map(if .override_address != null then .override_address = $addr | .override_port = $pport else . end)
    '
    local check_output
    check_output=$(validate_singbox_config)
    if [ $? -ne 0 ]; then
        cp -f "${route_file}.bak" "$route_file"
        red "\n配置校验未通过，已自动回滚：\n"
        echo "$check_output"
        return 1
    fi
    rm -f "${route_file}.bak"
    reload_singbox
    return 0
}

# 把规则切到指定 ProxyIP 并记为当前使用
_pip_switch_addr() {   # $1=地址 $2=端口
    _pip_apply "$1" "${2:-443}" || return 1
    _pip_conf_set CUR_ADDR "$1"; _pip_conf_set CUR_PORT "${2:-443}"
    _pip_conf_set FAILS 0; _pip_conf_set OKS 0
    return 0
}

# ---- 槽位 (ProxyIP 1-5) ----
_pip_sf() { echo "${work_dir}/plugins/proxyip.slots"; }
_pip_bkf() { echo "${work_dir}/plugins/proxyip.backups"; }   # 旧版备用列表，仅用于迁移

# $1=序号 -> 输出 "地址 端口"，空槽位无输出
_pip_slot_get() { awk -v n="$1" '$1==n && NF>=2 {print $2, ($3==""?443:$3); exit}' "$(_pip_sf)" 2>/dev/null; }
_pip_slot_set() {   # $1=序号 $2=地址 $3=端口
    local f; f=$(_pip_sf)
    mkdir -p "$(dirname "$f")"
    { awk -v n="$1" '$1!=n' "$f" 2>/dev/null; printf '%s %s %s\n' "$1" "$2" "${3:-443}"; } | sort -n > "${f}.tmp" && mv -f "${f}.tmp" "$f"
}
_pip_slot_clear() {   # $1=序号
    local f; f=$(_pip_sf)
    [ -f "$f" ] || return 0
    awk -v n="$1" '$1!=n' "$f" > "${f}.tmp" && mv -f "${f}.tmp" "$f"
    return 0
}
_pip_slot_count() { awk 'NF>=2' "$(_pip_sf)" 2>/dev/null | wc -l; }
_pip_slot_first_empty() {
    local n
    for n in 1 2 3 4 5; do
        [ -z "$(_pip_slot_get "$n")" ] && { echo "$n"; return 0; }
    done
    return 0
}
# 首选槽位序号(没设或指向空槽位则无输出)
_pip_pref() {
    local v; v=$(_pip_conf_get PREF)
    [ -n "$v" ] && [ -n "$(_pip_slot_get "$v")" ] && echo "$v"
    return 0
}
# 当前使用的槽位序号(当前地址不在任何槽位里则无输出)
_pip_cur_slot() {
    local ca cp; ca=$(_pip_conf_get CUR_ADDR); cp=$(_pip_conf_get CUR_PORT)
    [ -z "$ca" ] && return 0
    awk -v a="$ca" -v p="${cp:-443}" '$2==a && ($3==""?443:$3)==p {print $1; exit}' "$(_pip_sf)" 2>/dev/null
    return 0
}
# 当前使用的 ProxyIP 显示名：ProxyIP N
_pip_cur_label() {
    local s ca cp; s=$(_pip_cur_slot)
    if [ -n "$s" ]; then echo "ProxyIP ${s}"; return; fi
    ca=$(_pip_conf_get CUR_ADDR); cp=$(_pip_conf_get CUR_PORT)
    if [ -n "$ca" ]; then _pip_hostport "$ca" "${cp:-443}"; else echo "未使用"; fi
}
# 槽位标记：★首选 ▶当前使用   $1=槽位序号
_pip_slot_tags() {
    [ "$1" = "$(_pip_pref)" ] && printf '  %s★首选%s' "$green" "$re"
    [ "$1" = "$(_pip_cur_slot)" ] && printf '  %s▶当前使用%s' "$skyblue" "$re"
    return 0
}
# 自动切换的过慢阈值(毫秒)，默认3000
_pip_slow_ms() { local v; v=$(_pip_conf_get SLOW_MS); echo "${v:-3000}"; }
# 服务器可用的 IP 族：优先 IPv4
_pip_fam() { if [ -n "$(_pip_trace "" "" "-4")" ]; then echo -4; else echo -6; fi; }

# ---- 自动切换服务 (sb-proxyip)：守护脚本由插件安装时写入 plugins/proxyip-watch.sh ----
_pip_watch_state() { service_is_running sb-proxyip && echo "运行中" || echo "未开启"; }

_pip_watch_start() {
    local bin="${work_dir}/plugins/proxyip-watch.sh"
    [ -f "$bin" ] || { red "缺少 ${bin}，请重新运行插件安装链接"; return 1; }
    if command_exists systemctl; then
        cat > /etc/systemd/system/sb-proxyip.service << EOF
[Unit]
Description=sing-box ProxyIP failover watcher
After=sing-box.service

[Service]
Type=simple
ExecStart=/bin/bash ${bin} daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sb-proxyip >/dev/null 2>&1
        systemctl restart sb-proxyip >/dev/null 2>&1
    elif command_exists rc-service; then
        cat > /etc/init.d/sb-proxyip << EOF
#!/sbin/openrc-run
description="sing-box ProxyIP failover watcher"
command="/bin/bash"
command_args="${bin} daemon"
command_background=true
pidfile="/var/run/sb-proxyip.pid"

depend() {
    need net
    after sing-box
}
EOF
        chmod +x /etc/init.d/sb-proxyip
        rc-update add sb-proxyip default >/dev/null 2>&1
        rc-service sb-proxyip restart >/dev/null 2>&1
    else
        red "未检测到 systemd/openrc，无法开启自动切换"; return 1
    fi
    return 0
}

_pip_watch_stop() {
    if command_exists systemctl && [ -f /etc/systemd/system/sb-proxyip.service ]; then
        systemctl disable --now sb-proxyip >/dev/null 2>&1
        rm -f /etc/systemd/system/sb-proxyip.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    if command_exists rc-service && [ -f /etc/init.d/sb-proxyip ]; then
        rc-service sb-proxyip stop >/dev/null 2>&1
        rc-update del sb-proxyip default >/dev/null 2>&1
        rm -f /etc/init.d/sb-proxyip
    fi
    return 0
}

# 测速记录：最近5条，proxyip.history，每行 地址<TAB>端口<TAB>平均ms<TAB>最高ms<TAB>超时<TAB>次数<TAB>下载Mbps(未测为-)<TAB>时间
_pip_hf() { echo "${work_dir}/plugins/proxyip.history"; }

# $1=地址 $2=端口 $3=平均ms $4=最高ms $5=超时 $6=次数 $7=下载Mbps(可空)；同一地址端口只保留最新一条
_pip_hist_add() {
    local hf; hf=$(_pip_hf)
    mkdir -p "$(dirname "$hf")"
    {
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:--}" "$(date '+%m-%d %H:%M')"
        [ -f "$hf" ] && awk -F'\t' -v a="$1" -v p="$2" '!($1==a && $2==p)' "$hf"
    } | head -n 10 > "${hf}.tmp" && mv -f "${hf}.tmp" "$hf"   # 存10条(5个槽位的数据不容易被挤掉)，列表只显示最近5条
}

_pip_hist_show() {
    local i=0 a p avg mx f n dl t addr_s lat_s dl_s
    while IFS=$'\t' read -r a p avg mx f n dl t; do
        [ -z "$a" ] && continue
        i=$((i+1))
        addr_s="$a"; [[ "$a" == *:* ]] && addr_s="[${a}]"
        if [ "$f" -ge "$n" ] 2>/dev/null; then lat_s="全部超时(${f}/${n})"; else lat_s="平均${avg}ms 最高${mx}ms 超时${f}/${n}"; fi
        if [ -z "$dl" ] || [ "$dl" = "-" ]; then dl_s="下载 未测"; else dl_s="下载 ${dl}Mbps"; fi
        echo -e " ${skyblue}${i}.${re} ${yellow}${addr_s}:${p}${re}$(_pip_src_note "$a")  ${skyblue}${lat_s}  ${dl_s}  ${t}${re}"
    done < <(head -n 5 "$(_pip_hf)")
}

# 按 地址+端口 取最近一次测速记录(一行，tab分隔)；纯IPv6机器经 NAT64 测的，记录用的是合成地址，这里也一并找
_pip_hist_find() {
    local hf nf row s; hf=$(_pip_hf); nf=$(_pip_nf)
    [ -f "$hf" ] || return 0
    row=$(awk -F'\t' -v a="$1" -v p="$2" '$1==a && $2==p {print; exit}' "$hf")
    if [ -z "$row" ] && [ -f "$nf" ]; then
        while read -r s; do
            [ -z "$s" ] && continue
            row=$(awk -F'\t' -v a="$s" -v p="$2" '$1==a && $2==p {print; exit}' "$hf")
            [ -n "$row" ] && break
        done < <(awk -F'\t' -v a="$1" '$2==a {print $1}' "$nf")
    fi
    [ -n "$row" ] && printf '%s' "$row"
    return 0
}

# 把一条测速记录格式化成显示文本；$1=记录行(没有则显示"未测速")
_pip_hist_fmt() {
    local a p avg mx f n dl t lat_s dl_s
    [ -z "$1" ] && { printf '未测速'; return 0; }
    IFS=$'\t' read -r a p avg mx f n dl t <<< "$1"
    if [ "$f" -ge "$n" ] 2>/dev/null; then lat_s="全部超时(${f}/${n})"; else lat_s="平均${avg}ms 最高${mx}ms 超时${f}/${n}"; fi
    if [ -z "$dl" ] || [ "$dl" = "-" ]; then dl_s="下载 未测"; else dl_s="下载 ${dl}Mbps"; fi
    printf '%s  %s  %s' "$lat_s" "$dl_s" "$t"
}

# 显示当前配置(槽位)：标题后面跟 ★首选 N ▶当前使用 N，每个槽位后面跟最近一次测速数据
# $1=1 时标题带"(输入槽位序号可单独测试)"；没有任何槽位返回 1
_pip_cfg_show() {
    local n a p pf cs tags="" cnt=0 title="当前配置"
    pf=$(_pip_pref); cs=$(_pip_cur_slot)
    [ -n "$pf" ] && tags+="  ${yellow}★首选${re} ${green}${pf}${re}"
    [ -n "$cs" ] && tags+="  ${yellow}▶当前使用${re} ${green}${cs}${re}"
    [ "$1" = 1 ] && title+=" (输入槽位序号可单独测试)"
    for n in 1 2 3 4 5; do
        read -r a p <<< "$(_pip_slot_get "$n")"
        [ -z "$a" ] && continue
        if [ "$cnt" -eq 0 ]; then echo -e "${green}${title}:${re}${tags}"; fi
        cnt=$((cnt+1))
        echo -e " ${green}${n}.${re} ${yellow}$(_pip_hostport "$a" "$p")${re}$(_pip_src_note "$a")  ${skyblue}$(_pip_hist_fmt "$(_pip_hist_find "$a" "$p")")${re}"
    done
    [ "$cnt" -eq 0 ] && { yellow "还没有配置 ProxyIP"; return 1; }
    return 0
}

# $1=序号(1-5) -> 输出 "地址:端口"(IPv6 带方括号)，没有则无输出
_pip_hist_get() {
    local a p
    IFS=$'\t' read -r a p _ < <(sed -n "${1}p" "$(_pip_hf)" 2>/dev/null)
    [ -z "$a" ] && return 0
    [[ "$a" == *:* ]] && a="[${a}]"
    echo "${a}:${p}"
}

# 读取 ProxyIP 输入；有测速记录时先列出，可输入序号 1-5 直接选用。结果写入变量名 $2
_pip_read_addr() {
    local prompt=$1 pip_rd_v pip_rd_rec
    if [ -s "$(_pip_hf)" ]; then
        echo ""
        green "最近测速记录 (输入序号 1-5 可直接选用):"
        _pip_hist_show
        echo ""
    fi
    reading "$prompt" pip_rd_v
    if [[ "$pip_rd_v" =~ ^([1-5])$ ]]; then
        pip_rd_rec=$(_pip_hist_get "${BASH_REMATCH[1]}")
        if [ -z "$pip_rd_rec" ]; then red "没有这条测速记录"; pip_rd_v=""
        else pip_rd_v=$pip_rd_rec; green "已选用 ${pip_rd_v}"; fi
    fi
    printf -v "$2" '%s' "$pip_rd_v"
}

# 显示用 地址:端口 (IPv6 加方括号)
_pip_hostport() { if [[ "$1" == *:* ]]; then echo "[$1]:$2"; else echo "$1:$2"; fi; }

speedtest_proxyip_menu() {
    clear
    green "=== ProxyIP 测速 ===\n"
    _pip_sync_conf
    local names=() addrs=() ports=() nums=() a p j n
    for n in 1 2 3 4 5; do
        read -r a p <<< "$(_pip_slot_get "$n")"
        [ -z "$a" ] && continue
        names+=("ProxyIP ${n}"); addrs+=("$a"); ports+=("${p:-443}"); nums+=("$n")
    done
    _pip_cfg_show 0
    if [ -s "$(_pip_hf)" ]; then
        echo ""
        green "最近测速记录 (最多5条，仅供查看；设置 ProxyIP 槽位时输入对应序号可直接选用):"
        _pip_hist_show
    fi
    echo ""
    echo -e " ${green}1. 测试当前配置${re}"
    echo -e " ${green}2. 批量测试其他地址 (域名/IP[:端口]，空格分隔，不写端口默认443，写一个就是单个测试)${re}"
    echo -e " ${green}x. 清空测速记录${re}"
    echo -e " ${purple}0. 返回上级菜单${re}"
    reading "请输入选择: " sp_choice
    local ta=() tp=() tn=() fam pip_addr pip_port rec tok k=0
    case "$sp_choice" in
        0) proxyip_menu; return ;;
        "") speedtest_proxyip_menu; return ;;
        1)
            [ ${#names[@]} -eq 0 ] && { yellow "还没有配置 ProxyIP"; sleep 2; speedtest_proxyip_menu; return; }
            echo ""
            _pip_cfg_show 1
            echo -e " ${green}8. 测试全部配置${re}"
            echo -e " ${purple}0. 返回${re}"
            reading "请输入槽位序号 (回车返回): " sp_sub
            case "$sp_sub" in
                ""|0) speedtest_proxyip_menu; return ;;
                8) tn=("${names[@]}"); ta=("${addrs[@]}"); tp=("${ports[@]}") ;;
                *)
                    if ! [[ "$sp_sub" =~ ^[1-5]$ ]]; then
                        red "无效的选择"; sleep 1; speedtest_proxyip_menu; return
                    fi
                    local si=-1
                    for j in "${!nums[@]}"; do [ "${nums[$j]}" = "$sp_sub" ] && si=$j; done
                    if [ "$si" -lt 0 ]; then
                        red "ProxyIP ${sp_sub} 还没有设置"; sleep 1; speedtest_proxyip_menu; return
                    fi
                    tn=("${names[$si]}"); ta=("${addrs[$si]}"); tp=("${ports[$si]}") ;;
            esac ;;
        2)
            reading "请输入多个地址，空格分隔，不写端口默认443 (如: a.com b.com:8443 1.2.3.4，回车返回本页): " sp_in
            [ -z "$sp_in" ] && { speedtest_proxyip_menu; return; }
            for tok in $sp_in; do
                if _pip_parse_addr "$tok"; then
                    if [ "$k" -ge 10 ]; then yellow "一次最多测10个，多出的已忽略"; break; fi
                    k=$((k+1)); tn+=("批量${k}"); ta+=("$pip_addr"); tp+=("${pip_port:-443}")
                else
                    yellow "跳过无效地址: $tok"
                fi
            done
            [ ${#ta[@]} -eq 0 ] && { red "没有有效地址"; sleep 2; speedtest_proxyip_menu; return; } ;;
        x|X)
            rm -f "$(_pip_hf)"; green "已清空测速记录"; sleep 1; speedtest_proxyip_menu; return ;;
        *)
            red "无效的选择"; sleep 1; speedtest_proxyip_menu; return ;;
    esac
    reading "是否同时测下载速度？(每个约15秒) (y/N): " sp_dl
    fam=$(_pip_fam)
    echo ""
    local dl_rec key hp nlit sum_lines=()
    for j in "${!tn[@]}"; do
        hp=$(_pip_hostport "${ta[$j]}" "${tp[$j]}")
        echo -e "${green}${tn[$j]}${re}  ${yellow}${hp}${re}"
        _pip_latency "${ta[$j]}" "${tp[$j]}" "$fam" 8
        if [ "$pip_lat_fail" -ge "$pip_lat_n" ] && [ "$fam" = "-6" ] && [[ "${ta[$j]}" != *:* ]]; then
            nlit=$(_pip_nat64_find "${ta[$j]}" "${tp[$j]}" "$fam")
            if [ -n "$nlit" ]; then
                yellow "  纯 IPv6 环境，已改用公共 NAT64 合成地址测试: ${nlit}"
                _pip_nat64_save "$nlit" "${ta[$j]}"
                ta[$j]=$nlit; hp=$(_pip_hostport "${ta[$j]}" "${tp[$j]}")
                _pip_latency "${ta[$j]}" "${tp[$j]}" "$fam" 8
            fi
        fi
        _pip_show_latency
        dl_rec=""
        if [[ "$sp_dl" == "y" || "$sp_dl" == "Y" ]]; then
            pip_dl_mbps=""
            _pip_download "${ta[$j]}" "${tp[$j]}" "$fam"
            if [ -n "$pip_dl_mbps" ]; then echo "  下载速度 约 ${pip_dl_mbps} Mbps"; dl_rec=$pip_dl_mbps; else yellow "  下载测速失败"; fi
        fi
        _pip_hist_add "${ta[$j]}" "${tp[$j]}" "$pip_lat_avg" "$pip_lat_max" "$pip_lat_fail" "$pip_lat_n" "$dl_rec"
        key=$pip_lat_avg; [ "$pip_lat_fail" -ge "$pip_lat_n" ] && key=999999
        sum_lines+=("${key}"$'\t'"${green}${tn[$j]}${re} ${yellow}${hp}${re}  $(_pip_rate; echo "${pip_rate_txt}")  平均${pip_lat_avg}ms 超时${pip_lat_fail}/${pip_lat_n}  下载 ${dl_rec:-未测}")
        echo ""
    done
    if [ ${#ta[@]} -ge 2 ]; then
        green "汇总 (按平均延迟从小到大，全部超时的排最后):"
        printf '%s\n' "${sum_lines[@]}" | sort -t$'\t' -k1,1n | cut -f2- | while IFS= read -r sl; do echo -e " ${sl}"; done
        echo ""
    fi
    yellow "参考：聊天类(ChatGPT/Claude)主要看延迟，平均<600ms且无超时为良好；看视频才需要较高的下载速度。"
    reading "按回车返回测速页面" sp_any
    speedtest_proxyip_menu
}

proxyip_menu() {
    route_file="${conf_dir}/route.json"
    _pip_sync_conf
    clear
    green "=== 公共 ProxyIP 分流 ===\n"
    green "当前已添加的 ProxyIP 分流:"
    local rows
    rows=$(_pip_list_rules)
    if [ -z "$rows" ]; then
        echo "  无"
    else
        local t a d
        while IFS=$'\t' read -r t a d; do
            echo -e " - ${skyblue}${t}${re} ${purple}->${re} ${yellow}${a}${re}  ${green}${d}${re}"
        done <<< "$rows"
    fi
    local ns pf
    ns=$(_pip_slot_count); pf=$(_pip_pref)
    if [ "$ns" -gt 0 ]; then
        echo ""
        yellow " ProxyIP 槽位: ${ns}/5 已设置"
        yellow " 首选: $([ -n "$pf" ] && echo "ProxyIP ${pf}" || echo 未设置)"
        yellow " 当前使用: $(_pip_cur_label)"
        yellow " 自动切换: $(_pip_watch_state)"
    fi
    echo ""
    green  "1. 添加 ProxyIP 分流"
    red    "2. 删除 ProxyIP 分流"
    green  "3. ProxyIP 槽位 / 首选 / 自动切换"
    green  "4. 测速 (延迟 / 下载速度)"
    purple "0. 返回上级菜单"
    reading "请输入选择: " pip_menu_choice
    case "$pip_menu_choice" in
        1) add_proxyip_route ;;
        2) delete_proxyip_route ;;
        3) proxyip_slot_menu ;;
        4) speedtest_proxyip_menu ;;
        0) warp_manage ;;
        *) red "无效选项"; sleep 1; proxyip_menu ;;
    esac
}

delete_proxyip_route() {
    clear
    green "=== 删除 ProxyIP 分流 ===\n"
    local tags=() addrs=() doms=() t a d i
    while IFS=$'\t' read -r t a d; do
        [ -z "$t" ] && continue
        tags+=("$t"); addrs+=("$a"); doms+=("$d")
    done < <(_pip_list_rules)
    if [ ${#tags[@]} -eq 0 ]; then
        yellow "当前没有 ProxyIP 分流规则"; sleep 2; proxyip_menu; return
    fi
    for i in "${!tags[@]}"; do
        printf '%b%2d.%b %b%s%b -> %s  %s\n' "$green" "$((i+1))" "$re" "$skyblue" "${tags[$i]}" "$re" "${addrs[$i]}" "${doms[$i]}"
    done
    echo -e "${purple} 0. 返回${re}"
    reading "\n输入要删除的序号: " pip_del
    [ -z "$pip_del" ] || [ "$pip_del" = "0" ] && { proxyip_menu; return; }
    if ! [[ "$pip_del" =~ ^[0-9]+$ ]] || [ "$pip_del" -lt 1 ] || [ "$pip_del" -gt "${#tags[@]}" ]; then
        red "无效的选择"; sleep 1; proxyip_menu; return
    fi
    local tag="${tags[$((pip_del-1))]}"

    cp -f "$route_file" "${route_file}.bak"
    jq_write "$route_file" --arg tag "$tag" '
      .route.rules = (
        [{"action":"sniff"}]
        + [
            .route.rules[]?
            | select(.action != "sniff")
            | if .rule_set != null then .rule_set = [.rule_set[] | select(. != $tag)] else . end
            | select((.rule_set | type) != "array" or (.rule_set | length) > 0)
          ]
      )
      | .route.rule_set = [(.route.rule_set // [])[] | select(.tag != $tag)]
    '

    local check_output
    check_output=$(validate_singbox_config)
    if [ $? -ne 0 ]; then
        cp -f "${route_file}.bak" "$route_file"
        red "\n配置校验未通过，已自动回滚：\n"
        echo "$check_output"
        sleep 3; proxyip_menu; return
    fi
    rm -f "${route_file}.bak"

    reload_singbox
    green "\n已删除 ProxyIP 分流 '${tag}'，相关域名恢复原有出站。"
    # 全部规则删完后，自动切换没有意义：停掉服务并清除"当前使用"状态(槽位和首选保留)
    if [ -z "$(_pip_list_rules)" ]; then
        _pip_watch_stop
        local k; for k in CUR_ADDR CUR_PORT FAILS OKS; do _pip_conf_del "$k"; done
    fi
    sleep 2; proxyip_menu
}

proxyip_slot_menu() {
    clear
    green "=== ProxyIP 槽位 / 自动切换 ===\n"
    _pip_sync_conf
    local n a p pf cs ns
    pf=$(_pip_pref); cs=$(_pip_cur_slot); ns=$(_pip_slot_count)
    for n in 1 2 3 4 5; do
        read -r a p <<< "$(_pip_slot_get "$n")"
        if [ -n "$a" ]; then
            echo -e " ${green}ProxyIP ${n}:${re} ${yellow}$(_pip_hostport "$a" "$p")${re}$(_pip_src_note "$a")$(_pip_slot_tags "$n")"
        else
            echo -e " ${green}ProxyIP ${n}:${re} ${yellow}(空)${re}"
        fi
    done
    echo ""
    yellow " 当前使用: $(_pip_cur_label)"
    yellow " 首选:     $([ -n "$pf" ] && echo "ProxyIP ${pf} (恢复正常后自动切回)" || echo "未设置 (只在当前失效时按 1→2→…→5→1 顺延，不切回)")"
    yellow " 自动切换: $(_pip_watch_state)"
    echo ""
    green  "1. 设置 / 替换槽位"
    red    "2. 清空槽位"
    green  "3. 设置 / 取消首选"
    green  "4. 手动切换"
    green  "5. 开启自动切换 (当前连续不通/过慢时，切到下一个可用的槽位)"
    red    "6. 关闭自动切换"
    skyblue "7. 查看切换日志"
    green  "8. 设置过慢阈值 (当前 $(_pip_slow_ms)ms：当前 ProxyIP 持续慢于此值也视为故障)"
    purple "0. 返回"
    reading "请输入选择: " sl_choice
    local pip_addr pip_port fam direct_info pip_info pip_in
    case "$sl_choice" in
        1)
            reading "输入槽位序号 (1-5，回车=第一个空槽位，0=返回): " sl_n
            [ "$sl_n" = "0" ] && { proxyip_slot_menu; return; }
            if [ -z "$sl_n" ]; then
                sl_n=$(_pip_slot_first_empty)
                [ -z "$sl_n" ] && { red "5 个槽位都已占用，请输入要替换的槽位序号"; sleep 2; proxyip_slot_menu; return; }
            fi
            if ! [[ "$sl_n" =~ ^[1-5]$ ]]; then red "槽位序号只能是 1-5"; sleep 2; proxyip_slot_menu; return; fi
            local old_a old_p j oa op
            read -r old_a old_p <<< "$(_pip_slot_get "$sl_n")"
            [ -n "$old_a" ] && yellow "ProxyIP ${sl_n} 当前是 $(_pip_hostport "$old_a" "$old_p")，将被替换。"
            _pip_read_addr "请输入 ProxyIP，可带端口 (不写端口默认443，回车返回): " pip_in
            [ -z "$pip_in" ] && { proxyip_slot_menu; return; }
            pip_in=$(echo "$pip_in" | xargs)
            if ! _pip_parse_addr "$pip_in"; then
                red "地址或端口格式无效"; sleep 2; proxyip_slot_menu; return
            fi
            [ -z "$pip_port" ] && pip_port=443
            for j in 1 2 3 4 5; do
                [ "$j" = "$sl_n" ] && continue
                read -r oa op <<< "$(_pip_slot_get "$j")"
                if [ "$oa" = "$pip_addr" ] && [ "$op" = "$pip_port" ]; then
                    red "该 ProxyIP 已在 ProxyIP ${j} 里"; sleep 2; proxyip_slot_menu; return
                fi
            done
            _pip_probe
            case $? in
                0) green "经 ProxyIP:   $(_pip_hostport "$pip_addr" "$pip_port")  ${pip_info}" ;;
                2) sleep 2; proxyip_slot_menu; return ;;
                *) red "该 ProxyIP ($(_pip_hostport "$pip_addr" "$pip_port")) 不可用，已取消"; sleep 3; proxyip_slot_menu; return ;;
            esac
            # 防呆：出口 IP 和其它槽位相同就是同一个源，它挂了另一个也会一起挂，没有备份意义
            local new_ip o_ip dup=""
            new_ip=$(echo "$pip_info" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
            for j in 1 2 3 4 5; do
                [ "$j" = "$sl_n" ] && continue
                read -r oa op <<< "$(_pip_slot_get "$j")"
                [ -z "$oa" ] && continue
                o_ip=$(_pip_trace "" "$oa" "$fam" "$op" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
                if [ -n "$o_ip" ] && [ "$o_ip" = "$new_ip" ]; then dup="ProxyIP ${j}"; break; fi
            done
            if [ -n "$dup" ]; then
                red "该 ProxyIP 的出口 IP (${new_ip}) 和 ${dup} 相同，属于同一个源，不能放进不同槽位。"
                sleep 4; proxyip_slot_menu; return
            fi
            _pip_quality_gate "$pip_addr" "$pip_port" "$fam" || { proxyip_slot_menu; return; }
            # 替换的是正在使用的槽位：规则要同步改指向新地址
            if [ -n "$old_a" ] && [ "$sl_n" = "$cs" ]; then
                _pip_switch_addr "$pip_addr" "$pip_port" || { sleep 3; proxyip_slot_menu; return; }
            fi
            _pip_slot_set "$sl_n" "$pip_addr" "$pip_port"
            [ -n "$pip_nat64_src" ] && _pip_nat64_save "$pip_addr" "$pip_nat64_src"
            green "\n已设置 ProxyIP ${sl_n}: $(_pip_hostport "$pip_addr" "$pip_port")"
            if [ "$(_pip_slot_count)" -ge 2 ] && [ -n "$(_pip_list_rules)" ] && [ "$(_pip_watch_state)" != "运行中" ]; then
                reading "是否开启自动切换？(Y/n): " sl_auto
                if [[ "$sl_auto" != "n" && "$sl_auto" != "N" ]]; then
                    _pip_watch_start && green "自动切换已开启" || red "自动切换开启失败"
                fi
            fi
            sleep 2; proxyip_slot_menu ;;
        2)
            [ "$ns" -eq 0 ] && { yellow "没有可清空的槽位"; sleep 2; proxyip_slot_menu; return; }
            reading "输入要清空的槽位序号 (回车返回): " sl_n
            [ -z "$sl_n" ] && { proxyip_slot_menu; return; }
            if ! [[ "$sl_n" =~ ^[1-5]$ ]] || [ -z "$(_pip_slot_get "$sl_n")" ]; then
                red "无效的槽位序号，或该槽位本来就是空的"; sleep 2; proxyip_slot_menu; return
            fi
            # 正在使用的槽位：先切到别的槽位
            if [ "$sl_n" = "$cs" ]; then
                local tgt="" c oa op
                if [ -n "$pf" ] && [ "$pf" != "$sl_n" ]; then tgt=$pf; fi
                if [ -z "$tgt" ]; then
                    for ((j=1; j<=4; j++)); do
                        c=$(( (sl_n - 1 + j) % 5 + 1 ))
                        if [ -n "$(_pip_slot_get "$c")" ]; then tgt=$c; break; fi
                    done
                fi
                if [ -z "$tgt" ]; then
                    red "这是唯一的槽位，且正在使用。要清空它，请先在「2. 删除 ProxyIP 分流」里删掉所有分流规则。"
                    sleep 4; proxyip_slot_menu; return
                fi
                read -r oa op <<< "$(_pip_slot_get "$tgt")"
                yellow "ProxyIP ${sl_n} 正在使用，清空前需先切换到 ProxyIP ${tgt}。"
                fam=$(_pip_fam)
                if [ -z "$(_pip_trace "" "$oa" "$fam" "$op")" ]; then
                    yellow "ProxyIP ${tgt} 当前检测不通，切过去后这些域名会暂时打不开。"
                    reading "仍要切换并清空？(y/N): " sl_force
                    [[ "$sl_force" == "y" || "$sl_force" == "Y" ]] || { proxyip_slot_menu; return; }
                fi
                _pip_switch_addr "$oa" "$op" || { sleep 3; proxyip_slot_menu; return; }
            fi
            _pip_slot_clear "$sl_n"
            [ "$pf" = "$sl_n" ] && _pip_conf_del PREF
            green "已清空 ProxyIP ${sl_n}"
            if [ "$(_pip_slot_count)" -lt 2 ] && [ "$(_pip_watch_state)" = "运行中" ]; then
                _pip_watch_stop; yellow "槽位不足 2 个，自动切换已关闭。"
            fi
            sleep 2; proxyip_slot_menu ;;
        3)
            [ "$ns" -eq 0 ] && { yellow "请先设置 ProxyIP 槽位"; sleep 2; proxyip_slot_menu; return; }
            reading "输入要设为首选的槽位序号 (0=取消首选，回车返回): " sl_n
            [ -z "$sl_n" ] && { proxyip_slot_menu; return; }
            if [ "$sl_n" = "0" ]; then
                _pip_conf_del PREF
                green "已取消首选：现在只在当前失效时顺延，不再切回。"
            elif [[ "$sl_n" =~ ^[1-5]$ ]] && [ -n "$(_pip_slot_get "$sl_n")" ]; then
                _pip_conf_set PREF "$sl_n"; _pip_conf_set OKS 0
                green "已将 ProxyIP ${sl_n} 设为首选"
                [ "$sl_n" != "$cs" ] && yellow "当前用的不是它：开启自动切换后，它恢复正常会自动切回；也可以用「4. 手动切换」立即切过去。"
            else
                red "无效的槽位序号，或该槽位是空的"
            fi
            sleep 3; proxyip_slot_menu ;;
        4)
            [ -z "$(_pip_list_rules)" ] && { yellow "还没有 ProxyIP 分流规则，请先添加"; sleep 2; proxyip_slot_menu; return; }
            [ "$ns" -eq 0 ] && { yellow "请先设置 ProxyIP 槽位"; sleep 2; proxyip_slot_menu; return; }
            reading "输入要切换到的槽位序号 (回车返回): " sl_n
            [ -z "$sl_n" ] && { proxyip_slot_menu; return; }
            if ! [[ "$sl_n" =~ ^[1-5]$ ]] || [ -z "$(_pip_slot_get "$sl_n")" ]; then
                red "无效的槽位序号，或该槽位是空的"; sleep 2; proxyip_slot_menu; return
            fi
            if [ "$sl_n" = "$cs" ]; then yellow "已经在使用 ProxyIP ${sl_n}"; sleep 2; proxyip_slot_menu; return; fi
            local sa sp
            read -r sa sp <<< "$(_pip_slot_get "$sl_n")"
            fam=$(_pip_fam)
            if [ -z "$(_pip_trace "" "$sa" "$fam" "$sp")" ]; then
                yellow "$(_pip_hostport "$sa" "$sp") 当前检测不通。"
                reading "仍要切换？(y/N): " sl_force
                [[ "$sl_force" == "y" || "$sl_force" == "Y" ]] || { proxyip_slot_menu; return; }
            fi
            if _pip_switch_addr "$sa" "$sp"; then
                green "已切换到 ProxyIP ${sl_n}: $(_pip_hostport "$sa" "$sp")"
                if [ "$(_pip_watch_state)" = "运行中" ] && [ -n "$pf" ] && [ "$pf" != "$sl_n" ]; then
                    yellow "提示：自动切换已开启且首选是 ProxyIP ${pf}，它恢复正常后会自动切回。"
                fi
            fi
            sleep 3; proxyip_slot_menu ;;
        5)
            [ "$ns" -lt 2 ] && { red "至少设置 2 个槽位才能自动切换"; sleep 2; proxyip_slot_menu; return; }
            [ -z "$(_pip_list_rules)" ] && { red "请先添加 ProxyIP 分流规则"; sleep 2; proxyip_slot_menu; return; }
            _pip_watch_start && green "自动切换已开启 (每2分钟检测一次)" || red "自动切换开启失败"
            sleep 2; proxyip_slot_menu ;;
        6)
            _pip_watch_stop; green "自动切换已关闭"
            sleep 2; proxyip_slot_menu ;;
        7)
            local lg="${work_dir}/plugins/proxyip-watch.log"
            echo ""
            if [ -s "$lg" ]; then tail -n 20 "$lg"; else echo "暂无切换记录"; fi
            echo ""
            reading "按回车返回" sl_any
            proxyip_slot_menu ;;
        8)
            reading "请输入阈值，毫秒 (500-20000，默认3000，回车返回): " sl_slow
            [ -z "$sl_slow" ] && { proxyip_slot_menu; return; }
            if ! [[ "$sl_slow" =~ ^[0-9]+$ ]] || [ "$sl_slow" -lt 500 ] || [ "$sl_slow" -gt 20000 ]; then
                red "请输入 500-20000 之间的整数"; sleep 2; proxyip_slot_menu; return
            fi
            _pip_conf_set SLOW_MS "$sl_slow"
            green "已设置：首字节延迟持续超过 ${sl_slow}ms 视为过慢"
            sleep 2; proxyip_slot_menu ;;
        *) proxyip_menu ;;
    esac
}

add_proxyip_route() {
    clear
    green "=== 添加公共 ProxyIP 分流 ===\n"
    yellow "说明：ProxyIP 只是一个能中转TCP的CF相关地址，不是代理协议："
    yellow " - 仅对 Cloudflare 托管的网站有效 (TLS/HTTPS)，其余站点会直接打不开"
    yellow " - 对方服务器能看到你访问的域名，稳定性取决于对方\n"

    local sb_ver
    sb_ver=$("${work_dir}/sing-box" version 2>/dev/null | awk 'NR==1{print $3}')
    if [ -n "$sb_ver" ] && [ "$(printf '%s\n1.11.0\n' "$sb_ver" | sort -V | head -n1)" != "1.11.0" ]; then
        red "当前 sing-box 内核版本 ${sb_ver} 过低，ProxyIP 分流需要 1.11.0 及以上，请先在主菜单更新内核。"
        sleep 3; proxyip_menu; return
    fi

    _pip_sync_conf
    local pip_addr pip_port fam direct_info pip_info pip_in reuse=0 from_slot=""
    local pip_re_dom='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    if [ -n "$(_pip_list_rules)" ] && [ -n "$(_pip_conf_get CUR_ADDR)" ]; then
        # 已有规则：所有规则共用同一个 ProxyIP，新规则沿用当前正在使用的那个
        reuse=1
        pip_addr=$(_pip_conf_get CUR_ADDR); pip_port=$(_pip_conf_get CUR_PORT)
        yellow "已有 ProxyIP 分流，新规则沿用当前 ProxyIP: $(_pip_hostport "$pip_addr" "${pip_port:-443}")"
    elif [ "$(_pip_slot_count)" -gt 0 ]; then
        # 还没有规则但已设置过槽位：用首选，没有首选就用编号最小的槽位
        from_slot=$(_pip_pref)
        [ -z "$from_slot" ] && from_slot=$(awk 'NF>=2{print $1; exit}' "$(_pip_sf)")
        read -r pip_addr pip_port <<< "$(_pip_slot_get "$from_slot")"
        yellow "使用 ProxyIP ${from_slot}: $(_pip_hostport "$pip_addr" "${pip_port:-443}")"
    else
        _pip_read_addr "请输入 ProxyIP，可带端口，如 tw.william.us.ci 或 tw.william.us.ci:8443 (不写端口默认443，回车返回): " pip_in
        [ -z "$pip_in" ] && { proxyip_menu; return; }
        pip_in=$(echo "$pip_in" | xargs)
        if ! _pip_parse_addr "$pip_in"; then
            red "地址或端口格式无效"; sleep 2; proxyip_menu; return
        fi
    fi
    _pip_probe
    case $? in
        0) ;;
        2) sleep 2; proxyip_menu; return ;;
        *) red "该 ProxyIP ($(_pip_hostport "$pip_addr" "$pip_port")) 不可用，已取消 (若它用的不是443端口，请写成 域名:端口)"; sleep 3; proxyip_menu; return ;;
    esac
    green "经 ProxyIP:   $(_pip_hostport "$pip_addr" "$pip_port")  ${pip_info}"
    local d_ip p_ip
    d_ip=$(echo "$direct_info" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
    p_ip=$(echo "$pip_info" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
    if [ "$d_ip" = "$p_ip" ]; then
        yellow "\n两者出口IP相同：该 ProxyIP 没有改变出口，分流没有意义。"
        reading "仍要继续？(y/N): " go_on
        [[ "$go_on" == "y" || "$go_on" == "Y" ]] || { proxyip_menu; return; }
    fi

    if [ "$reuse" -eq 0 ] && [ -z "$from_slot" ]; then
        _pip_quality_gate "$pip_addr" "$pip_port" "$fam" || { proxyip_menu; return; }
    fi

    echo ""
    green "选择要走该 ProxyIP 的站点:"
    green "1. OpenAI/ChatGPT  (chatgpt.com openai.com oaistatic.com oaiusercontent.com)"
    green "2. Claude          (claude.ai claude.com anthropic.com)"
    green "3. 自定义域名 (仅限CF托管站点，添加时会自动逐个检测)"
    purple "0. 返回"
    reading "请输入选择: " pip_choice
    local pip_name pip_domains=()
    case "$pip_choice" in
        1) pip_name="openai";  pip_domains=(chatgpt.com openai.com oaistatic.com oaiusercontent.com) ;;
        2) pip_name="claude";  pip_domains=(claude.ai claude.com anthropic.com) ;;
        3)
            reading "规则名称(字母/数字/下划线/中横线): " pip_name
            pip_name=$(echo "$pip_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')
            [ -z "$pip_name" ] && { red "名称不能为空"; sleep 1; proxyip_menu; return; }
            reading "域名列表(空格或逗号分隔，含下级域名): " pip_dom_in
            pip_dom_in="${pip_dom_in//,/ }"
            local d
            for d in $pip_dom_in; do
                [[ "$d" =~ $pip_re_dom ]] && pip_domains+=("$d") || yellow "跳过无效域名: $d"
            done
            ;;
        *) proxyip_menu; return ;;
    esac
    [ ${#pip_domains[@]} -eq 0 ] && { red "没有有效域名"; sleep 1; proxyip_menu; return; }

    local tag="pip-${pip_name}"
    if jq -e --arg t "$tag" '.route.rule_set[]? | select(.tag == $t)' "$route_file" >/dev/null 2>&1; then
        yellow "规则 '${tag}' 已存在，请先在本菜单「2. 删除 ProxyIP 分流」中删除后再添加"
        sleep 2; proxyip_menu; return
    fi
    if jq -e --arg t "$pip_name" '.route.rules[]? | select(.rule_set != null) | .rule_set[]? | select(. == $t)' "$route_file" >/dev/null 2>&1; then
        yellow "注意：同名的 '${pip_name}' 分流规则已在使用其他出站，先匹配的规则优先，建议先在 WARP分流管理 的「2. 删除分流服务」中删除它，否则 ProxyIP 可能不生效。"
    fi

    # 逐个域名检测：必须能经 ProxyIP 返回 CF trace，否则跳过，避免整个域名打不开
    echo ""
    yellow "正在检测各域名能否经 ProxyIP 访问..."
    local ok_domains=() d r
    for d in "${pip_domains[@]}"; do
        r=$(_pip_trace "$d" "$pip_addr" "$fam" "$pip_port")
        if [ -n "$r" ]; then
            green "  ✔ ${d}  ${r}"; ok_domains+=("$d")
        else
            yellow "  ✘ ${d}  (非CF托管或不可达，已跳过)"
        fi
    done
    [ ${#ok_domains[@]} -eq 0 ] && { red "没有可用域名，已取消"; sleep 3; proxyip_menu; return; }

    local domains_json="[" dd
    for dd in "${ok_domains[@]}"; do domains_json+="\"${dd}\","; done
    domains_json="${domains_json%,}]"

    cp -f "$route_file" "${route_file}.bak"
    jq_write "$route_file" --arg tag "$tag" --argjson domains "$domains_json" --arg addr "$pip_addr" --argjson pport "$pip_port" '
      .route.rule_set = ((.route.rule_set // []) + [{"tag":$tag,"type":"inline","rules":[{"domain_suffix":$domains}]}])
      | .route.rules = (
          [{"action":"sniff"}]
          + [ .route.rules[]? | select(.action != "sniff") ]
          + [
              {"rule_set":[$tag],"network":"udp","port":443,"action":"reject"},
              {"rule_set":[$tag],"network":"tcp","port":443,"action":"route","outbound":"direct","override_address":$addr,"override_port":$pport}
            ]
        )'

    local check_output
    check_output=$(validate_singbox_config)
    if [ $? -ne 0 ]; then
        cp -f "${route_file}.bak" "$route_file"
        red "\n配置校验未通过，已自动回滚：\n"
        echo "$check_output"
        sleep 3; proxyip_menu; return
    fi
    rm -f "${route_file}.bak"

    reload_singbox
    # 第一条规则：记录当前使用的 ProxyIP；若是刚输入的新地址，同时存为 ProxyIP 1 (之后添加的规则沿用当前使用的)
    if [ "$reuse" -eq 0 ]; then
        if [ -z "$from_slot" ]; then
            _pip_slot_set 1 "$pip_addr" "$pip_port"
            [ -n "$pip_nat64_src" ] && _pip_nat64_save "$pip_addr" "$pip_nat64_src"
        fi
        _pip_conf_set CUR_ADDR "$pip_addr"; _pip_conf_set CUR_PORT "$pip_port"
        _pip_conf_set FAILS 0; _pip_conf_set OKS 0
    fi
    green "\n已添加 ProxyIP 分流 '${tag}' -> $(_pip_hostport "$pip_addr" "$pip_port")，域名: ${ok_domains[*]}"
    [ "$(_pip_slot_count)" -lt 2 ] && yellow "提示：在「3. ProxyIP 槽位」里最多可再设置 4 个 ProxyIP，开启自动切换后，当前这个不通时会按顺序切到下一个。"
    yellow "提示：已同时拦截这些域名的 UDP/443(QUIC)，让浏览器回退到 TCP，否则 QUIC 会绕过 ProxyIP。"
    yellow "验证：客户端连上节点后访问 https://chatgpt.com/cdn-cgi/trace 之类 (对应站点的 /cdn-cgi/trace)，查看 ip= 是否为 ProxyIP 的出口。"
    sleep 3; proxyip_menu
}

PIP_PAYLOAD_EOF
}

write_inject() {
cat > "${plugin_dir}/proxyip-inject.sh" <<'PIP_INJECT_EOF'
#!/bin/bash
# 从 stdin 读取 sing-box 主脚本，插入 ProxyIP 插件菜单后输出到 stdout。
# 任何一步不满足(锚点缺失/语法检查失败等)都原样输出主脚本，保证 sb 不受影响。
payload="$(cd "$(dirname "$0")" && pwd)/proxyip.sh"
tmp=$(mktemp) || exit 1
cat > "$tmp"
out=$(mktemp) || { cat "$tmp"; rm -f "$tmp"; exit 0; }
trap 'rm -f "$tmp" "$out"' EXIT
passthrough() { cat "$tmp"; exit 0; }

[ -s "$payload" ] || passthrough
grep -q 'proxyip_menu' "$tmp" && passthrough
grep -q '^warp_manage() {' "$tmp" || passthrough

# 序号 = 「WARP分流管理」菜单里现有最大序号 + 1
n=$(awk '/^warp_manage\(\) \{/{f=1;next} f&&/^\}/{f=0} f&&match($0,/^[[:space:]]+[0-9]+\)/){s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); if(s+0>m)m=s+0} END{print m+0}' "$tmp")
[ "${n:-0}" -ge 1 ] || passthrough
n=$((n+1))

awk -v N="$n" -v payload="$payload" '
/^warp_manage\(\) \{/ { inw=1 }
inw && /^\}/ { inw=0 }
inw && !m && /purple "0\. 返回主菜单"/ {
    print "    green \"" N ". 公共ProxyIP分流 (插件，添加/删除，仅限CF托管站点)\""
    print "    skyblue \"----------------------\""
    m=1
}
inw && !c && /^[[:space:]]+0\)[[:space:]]+menu ;;/ {
    print "        " N ")  proxyip_menu ;;"
    c=1
}
!t && /^trap / {
    while ((getline line < payload) > 0) print line
    close(payload)
    t=1
}
{ print }
END { if (!(m && c && t)) exit 3 }
' "$tmp" > "$out" || passthrough

# 菜单2的删除列表去重(ProxyIP 每个规则名对应两条路由规则)；匹配不到则不改动
sed -i 's/map(select(\. != "telegram-ip")) | \.\[\]/map(select(. != "telegram-ip")) | unique | .[]/' "$out" 2>/dev/null

# 「已启用的分流规则集」列表：ProxyIP 规则显示 规则名 -> ProxyIP:地址，而不是 direct；匹配不到则不改动
sed -i 's/\\(\$r\.outbound)"/\\(if $r.override_address != null then "ProxyIP:" + $r.override_address + ":" + ($r.override_port | tostring) else $r.outbound end)"/' "$out" 2>/dev/null

bash -n "$out" 2>/dev/null || passthrough
cat "$out"
PIP_INJECT_EOF
}

write_watch() {
cat > "${plugin_dir}/proxyip-watch.sh.tmp" <<'PIP_WATCH_EOF'
#!/bin/bash
# sing-box ProxyIP 槽位自动切换守护进程（由 sb-proxyip 服务运行：bash proxyip-watch.sh daemon）
# 槽位 ProxyIP 1-5：当前使用的连续不通/过慢 -> 先看首选(如有)，再按 1→2→…→5→1 环形顺延，切到第一个可用的槽位；
# 设了首选且当前用的不是它：首选恢复并连续正常 -> 切回首选。不设首选就不切回。
# 本机网络自身异常(直连 cloudflare.com 都不通)时不做任何判定，避免误切换。
work_dir="$(cd "$(dirname "$0")/.." && pwd)"
conf_dir="${work_dir}/conf"
route_file="${conf_dir}/route.json"
cf="${work_dir}/plugins/proxyip.conf"
sf="${work_dir}/plugins/proxyip.slots"
logf="${work_dir}/plugins/proxyip-watch.log"
INTERVAL=${PIP_INTERVAL:-120}       # 检测间隔(秒)
FAIL_LIMIT=${PIP_FAIL_LIMIT:-2}     # 当前 ProxyIP 连续几轮不通/过慢才切走
BACK_LIMIT=${PIP_BACK_LIMIT:-2}     # 首选恢复后连续几轮正常才切回

log() {
    echo "$(date '+%F %T') $*" >> "$logf"
    if [ "$(wc -l < "$logf" 2>/dev/null || echo 0)" -gt 300 ]; then
        tail -n 150 "$logf" > "${logf}.tmp" && mv "${logf}.tmp" "$logf"
    fi
}
get() { sed -n "s/^$1=//p" "$cf" 2>/dev/null | head -1; }
put() {
    if grep -q "^$1=" "$cf" 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" "$cf"; else echo "$1=$2" >> "$cf"; fi
}

fam=""
net_ok() {
    local f
    for f in -4 -6; do
        if curl -s $f --connect-timeout 5 -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^ip='; then
            fam=$f; return 0
        fi
    done
    return 1
}
# probe 地址 端口：2 次尝试，任意一次拿到 HTTP 200 即视为可通；probe_ms 记下首字节耗时(毫秒)，失败为0
probe_ms=0
probe() {
    local host=$1 port=$2 i out t
    [[ "$host" == *:* ]] && host="[${host}]"
    for i in 1 2; do
        out=$(curl -s $fam --connect-timeout 5 -m 8 --connect-to "www.cloudflare.com:443:${host}:${port}" \
              -w '\n%{http_code} %{time_starttransfer}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        t=${out##*$'\n'}
        if [ "${t%% *}" = "200" ]; then
            probe_ms=$(awk -v t="${t#* }" 'BEGIN{printf "%d", t*1000}'); return 0
        fi
        [ "$i" -eq 1 ] && sleep 3
    done
    probe_ms=0; return 1
}
# 健康 = 可通 且 首字节延迟不超过阈值(SLOW_MS)
SLOW_MS=3000
good() { probe "$1" "$2" && [ "$probe_ms" -le "$SLOW_MS" ]; }
ms_txt() { if [ "$probe_ms" -gt 0 ]; then echo "过慢 ${probe_ms}ms"; else echo "不通"; fi; }
has_rules() {
    jq -e '[.route.rules[]? | select(.override_address != null)] | length > 0' "$route_file" >/dev/null 2>&1
}
reload_sb() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    else
        rc-service sing-box restart
    fi
}
# 把所有 ProxyIP 规则改指向 $1:$2；配置校验失败则回滚
apply() {
    cp -f "$route_file" "${route_file}.bak" || return 1
    if jq --arg addr "$1" --argjson pport "$2" \
        '.route.rules |= map(if .override_address != null then .override_address = $addr | .override_port = $pport else . end)' \
        "${route_file}.bak" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"; then
        if [ -x "${work_dir}/sing-box" ] && ! "${work_dir}/sing-box" check -C "$conf_dir" >/dev/null 2>&1; then
            cp -f "${route_file}.bak" "$route_file"; rm -f "${route_file}.bak"
            log "配置校验失败，已回滚，未切换"; return 1
        fi
        rm -f "${route_file}.bak"; reload_sb; return 0
    fi
    cp -f "${route_file}.bak" "$route_file"; rm -f "${route_file}.bak" "${route_file}.tmp"
    return 1
}

# 槽位：sn=序号 sa=地址 sp=端口 (按序号升序)
sn=(); sa=(); sp=()
load_slots() {
    sn=(); sa=(); sp=()
    local n a p
    while read -r n a p; do
        [ -z "$a" ] && continue
        sn+=("$n"); sa+=("$a"); sp+=("${p:-443}")
    done < <(sort -n "$sf" 2>/dev/null)
}
idx_of_slot() {   # $1=槽位序号 -> 数组下标，没有输出 -1
    local i
    for i in "${!sn[@]}"; do [ "${sn[$i]}" = "$1" ] && { echo "$i"; return 0; }; done
    echo -1
}
idx_of_addr() {   # $1=地址 $2=端口 -> 数组下标，没有输出 -1
    local i
    for i in "${!sa[@]}"; do [ "${sa[$i]}" = "$1" ] && [ "${sp[$i]}" = "$2" ] && { echo "$i"; return 0; }; done
    echo -1
}
# 切换到 $1:$2 并记为当前使用；$3=日志说明
switch_to() {
    if apply "$1" "$2"; then
        put CUR_ADDR "$1"; put CUR_PORT "$2"; put FAILS 0; put OKS 0
        log "$3 ${1}:${2}"
        return 0
    fi
    return 1
}

tick() {
    local ca cp fails oks pref pi ci n k i
    SLOW_MS=$(get SLOW_MS); SLOW_MS=${SLOW_MS:-${PIP_SLOW_MS:-3000}}
    load_slots
    n=${#sa[@]}
    [ "$n" -ge 2 ] || return 0
    has_rules || return 0
    net_ok || return 0
    ca=$(get CUR_ADDR); cp=$(get CUR_PORT)
    if [ -z "$ca" ]; then
        # 状态里没有当前使用的地址：取路由规则里正在用的
        ca=$(jq -r '[.route.rules[]? | select(.override_address != null)][0].override_address // empty' "$route_file" 2>/dev/null)
        cp=$(jq -r '[.route.rules[]? | select(.override_address != null)][0].override_port // 443' "$route_file" 2>/dev/null)
        [ -n "$ca" ] || return 0
        put CUR_ADDR "$ca"; put CUR_PORT "$cp"
    fi
    cp=${cp:-443}
    fails=$(get FAILS); oks=$(get OKS); fails=${fails:-0}; oks=${oks:-0}
    ci=$(idx_of_addr "$ca" "$cp")
    pref=$(get PREF); pi=-1
    [ -n "$pref" ] && pi=$(idx_of_slot "$pref")

    if good "$ca" "$cp"; then
        put FAILS 0
        if [ "$pi" -ge 0 ] && [ "$pi" != "$ci" ]; then
            # 设了首选且当前用的不是它：看首选是否恢复
            if good "${sa[$pi]}" "${sp[$pi]}"; then
                oks=$((oks+1)); put OKS "$oks"
                if [ "$oks" -ge "$BACK_LIMIT" ]; then
                    switch_to "${sa[$pi]}" "${sp[$pi]}" "首选 ProxyIP ${pref} 已恢复，切回"
                fi
            else
                put OKS 0
            fi
        elif [ "$oks" -ne 0 ]; then
            put OKS 0
        fi
        return 0
    fi

    # 当前 ProxyIP 不通/过慢：连续 FAIL_LIMIT 轮才切走
    fails=$((fails+1)); put FAILS "$fails"
    log "当前 ProxyIP ${ca}:${cp} $(ms_txt) (${fails}/${FAIL_LIMIT})"
    [ "$fails" -ge "$FAIL_LIMIT" ] || return 0
    put OKS 0
    # 先看首选能不能用
    if [ "$pi" -ge 0 ] && [ "$pi" != "$ci" ] && good "${sa[$pi]}" "${sp[$pi]}"; then
        switch_to "${sa[$pi]}" "${sp[$pi]}" "当前不通或过慢，已切到首选 ProxyIP ${pref}" && return 0
    fi
    # 再按 1→2→…→5→1 从当前的下一个开始环形找第一个可用的
    for ((k=1; k<=n; k++)); do
        if [ "$ci" -ge 0 ]; then i=$(( (ci+k) % n )); else i=$((k-1)); fi
        [ "$i" = "$ci" ] && continue
        [ "$i" = "$pi" ] && continue      # 首选上面已经测过
        if good "${sa[$i]}" "${sp[$i]}"; then
            switch_to "${sa[$i]}" "${sp[$i]}" "当前不通或过慢，已切换到 ProxyIP ${sn[$i]}" && return 0
        fi
    done
    log "所有槽位的 ProxyIP 都不通或过慢，保持不变"
}

case "$1" in
    daemon) while true; do tick; sleep "$INTERVAL"; done ;;
    once)   tick ;;
    *)      echo "usage: $0 daemon|once"; exit 1 ;;
esac
PIP_WATCH_EOF
    mv -f "${plugin_dir}/proxyip-watch.sh.tmp" "${plugin_dir}/proxyip-watch.sh"
}

write_wrapper() {
    local url=$1 stages="" f
    # 与其它插件(如 quota)共用: 按文件名顺序串联 plugins/*-inject.sh，谁先装都一样
    for f in "${plugin_dir}"/*-inject.sh; do
        [ -f "$f" ] && stages="${stages} | bash ${f}"
    done
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# sb-plugin wrapper
bash <(curl -Ls ${url}${stages}) "\$@"
EOF
    chmod +x "$wrapper"
}

# 预览：用线上主脚本演练一遍，告诉用户生成的菜单序号
preview_menu_no() {
    local url=$1 res
    res=$(curl -Ls -m 20 "$url" 2>/dev/null | bash "${plugin_dir}/proxyip-inject.sh" 2>/dev/null | grep -E '^[[:space:]]+[0-9]+\)[[:space:]]+proxyip_menu ;;' | head -1 | grep -oE '[0-9]+' | head -1)
    echo "$res"
}

install_plugin() {
    if [ ! -x "${work_dir}/sing-box" ] || [ ! -f "$wrapper" ]; then
        red "未检测到已安装的 sing-box / sb 快捷指令，请先用主脚本安装 sing-box。"
        exit 1
    fi
    command -v jq >/dev/null 2>&1 || { red "缺少 jq，请先用主脚本安装依赖。"; exit 1; }

    local url
    if grep -q "$wrapper_marker" "$wrapper"; then
        url=$(cat "${plugin_dir}/main_url" 2>/dev/null)
        [ -z "$url" ] && url=$(grep -oE 'https://[^ )"]+' "$wrapper" | head -1)
    else
        cp -f "$wrapper" "${wrapper}.orig"
        url=$(grep -oE 'https://[^ )"]+' "$wrapper" | head -1)
    fi
    url="${MAIN_URL:-$url}"
    if [ -z "$url" ]; then
        red "未能识别主脚本地址，请指定后重试: MAIN_URL=主脚本raw链接 bash <(curl -Ls 本插件链接)"
        exit 1
    fi

    mkdir -p "$plugin_dir"
    write_payload
    write_inject
    write_watch
    chmod +x "${plugin_dir}/proxyip-inject.sh"
    if ! bash -n "${plugin_dir}/proxyip.sh" || ! bash -n "${plugin_dir}/proxyip-inject.sh" || ! bash -n "${plugin_dir}/proxyip-watch.sh"; then
        red "插件文件语法检查失败，已中止（未修改 sb 快捷指令）"; exit 1
    fi
    echo "$url" > "${plugin_dir}/main_url"
    write_wrapper "$url"
    if [ ! -e /usr/bin/sb ] && [ -z "$SB_WORK_DIR" ]; then
        ln -sf "$wrapper" /usr/bin/sb && touch "${plugin_dir}/sb_link_created"
    fi

    # 旧版(主 + 备用)状态迁移为槽位：在重启自动切换服务前完成，新守护进程才能读到槽位
    (
        route_file="${work_dir}/conf/route.json"
        source "${plugin_dir}/proxyip.sh"
        _pip_sync_conf
    ) 2>/dev/null
    # 更新插件时，自动切换服务若在运行则重启以使用新脚本
    if [ -z "$SB_WORK_DIR" ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sb-proxyip 2>/dev/null; then
        systemctl restart sb-proxyip >/dev/null 2>&1
    elif [ -z "$SB_WORK_DIR" ] && command -v rc-service >/dev/null 2>&1 && rc-service sb-proxyip status 2>/dev/null | grep -q started; then
        rc-service sb-proxyip restart >/dev/null 2>&1
    fi

    green "\nProxyIP 分流插件安装完成。"
    local no
    no=$(preview_menu_no "$url")
    if [ -n "$no" ]; then
        green "运行 sb -> 10(WARP分流管理) -> ${no}(公共ProxyIP分流) 即可使用。"
    else
        yellow "未能联网演练主脚本，请直接运行 sb 进入 WARP分流管理 查看新增菜单；"
        yellow "若没有出现，说明主脚本菜单结构有变，插入已自动跳过，主脚本仍可正常使用。"
    fi
    yellow "提示：主脚本重新安装/卸载会重置 sb 快捷指令，届时重新运行本安装链接即可。"
}

# 清理本插件添加的 ProxyIP 分流规则(pip- 开头的规则集及其路由规则)；先备份，sing-box 校验失败则回滚
remove_pip_rules() {
    local rf="${work_dir}/conf/route.json"
    [ -f "$rf" ] || return 0
    command -v jq >/dev/null 2>&1 || { yellow "缺少 jq，无法自动清理 pip- 开头的分流规则，请手动检查 ${rf}"; return 0; }
    if ! jq -e '([.route.rule_set[]? | select((.tag // "") | startswith("pip-"))] | length > 0) or ([.route.rules[]? | select(.override_address != null)] | length > 0)' "$rf" >/dev/null 2>&1; then
        return 0
    fi
    cp -f "$rf" "${rf}.pipbak"
    if ! jq '
        .route.rules = [ .route.rules[]? | select((.override_address == null) and (((.rule_set // []) | map(select(startswith("pip-"))) | length) == 0)) ]
        | if .route.rule_set then .route.rule_set = [ .route.rule_set[] | select(((.tag // "") | startswith("pip-")) | not) ] else . end
      ' "${rf}.pipbak" > "${rf}.piptmp"; then
        rm -f "${rf}.piptmp" "${rf}.pipbak"; red "清理 ProxyIP 规则失败，已保持原配置不变"; return 1
    fi
    mv -f "${rf}.piptmp" "$rf"
    if [ -x "${work_dir}/sing-box" ] && ! "${work_dir}/sing-box" check -C "${work_dir}/conf" >/dev/null 2>&1; then
        mv -f "${rf}.pipbak" "$rf"; red "清理后配置校验未通过，已回滚，请手动处理 pip- 开头的分流规则"; return 1
    fi
    rm -f "${rf}.pipbak"
    if [ -z "$SB_WORK_DIR" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service sing-box restart >/dev/null 2>&1
        fi
    fi
    green "已清理 ProxyIP 分流规则并重载 sing-box"
}

uninstall_plugin() {
    local url others=0
    url=$(cat "${plugin_dir}/main_url" 2>/dev/null)

    # 1) 停止并删除自动切换服务
    if [ -z "$SB_WORK_DIR" ]; then
        if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sb-proxyip.service ]; then
            systemctl disable --now sb-proxyip >/dev/null 2>&1
            rm -f /etc/systemd/system/sb-proxyip.service
            systemctl daemon-reload >/dev/null 2>&1
            systemctl reset-failed sb-proxyip >/dev/null 2>&1
        fi
        if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/sb-proxyip ]; then
            rc-service sb-proxyip stop >/dev/null 2>&1
            rc-update del sb-proxyip default >/dev/null 2>&1
            rm -f /etc/init.d/sb-proxyip /var/run/sb-proxyip.pid
        fi
    fi

    # 2) 清理本插件添加的 ProxyIP 分流规则
    remove_pip_rules

    # 3) 还原 sb 快捷指令 (只处理带本插件标记的 sb.sh；主脚本重装后重建的 sb.sh 不动)
    if [ -f "$wrapper" ] && grep -q "$wrapper_marker" "$wrapper"; then
        rm -f "${plugin_dir}/proxyip-inject.sh"
        if ls "${plugin_dir}"/*-inject.sh >/dev/null 2>&1; then
            others=1      # 还有其它插件(如 quota)在用 sb.sh: 只摘掉本插件, 保留它们的注入器
            write_wrapper "$url"
        elif [ -f "${wrapper}.orig" ]; then
            mv -f "${wrapper}.orig" "$wrapper"
        elif [ -n "$url" ]; then
            printf '#!/usr/bin/env bash\nbash <(curl -Ls %s) $1\n' "$url" > "$wrapper"
        else
            red "无法还原 sb.sh (缺少备份和主脚本地址)，请用主脚本重新安装以重建 sb 快捷指令"
        fi
        chmod +x "$wrapper"
    else
        rm -f "${wrapper}.orig"
    fi
    # 本插件创建过 /usr/bin/sb 链接才删除；原来就有的不动
    if [ "$others" = 0 ] && [ -z "$SB_WORK_DIR" ] && [ -f "${plugin_dir}/sb_link_created" ] && [ -L /usr/bin/sb ]; then
        rm -f /usr/bin/sb
    fi

    # 4) 删除插件文件
    rm -f "${plugin_dir}/proxyip.sh" "${plugin_dir}/proxyip-inject.sh" "${plugin_dir}/proxyip-watch.sh" "${plugin_dir}/proxyip-watch.sh.tmp" \
          "${plugin_dir}/proxyip.conf" "${plugin_dir}/proxyip.backups" "${plugin_dir}/proxyip.slots" "${plugin_dir}/proxyip.slots.tmp" "${plugin_dir}/proxyip.history" "${plugin_dir}/proxyip.nat64" "${plugin_dir}/proxyip.nat64.tmp" "${plugin_dir}/proxyip-watch.log" \
          "${plugin_dir}/proxyip-watch.log.tmp"
    # main_url / sb 链接标记为各插件共用, 其它插件还在就保留
    [ "$others" = 0 ] && rm -f "${plugin_dir}/main_url" "${plugin_dir}/sb_link_created"
    rmdir "$plugin_dir" 2>/dev/null

    # 5) 残留检查
    local left=""
    [ "$others" = 0 ] && [ -f "${wrapper}.orig" ] && left+=" ${wrapper}.orig"
    [ -d "$plugin_dir" ] && ls "$plugin_dir" 2>/dev/null | grep -q 'proxyip' && left+=" ${plugin_dir}/proxyip*"
    [ -z "$SB_WORK_DIR" ] && { [ -f /etc/systemd/system/sb-proxyip.service ] || [ -f /etc/init.d/sb-proxyip ]; } && left+=" sb-proxyip 服务文件"
    [ -f "${work_dir}/conf/route.json" ] && grep -q '"pip-' "${work_dir}/conf/route.json" 2>/dev/null && left+=" route.json 中的 pip- 规则"
    if [ -z "$left" ]; then
        green "已卸载 ProxyIP 分流插件，所有相关文件、服务和分流规则都已清理，sb 快捷指令已还原。"
    else
        yellow "已卸载，但仍有残留需要手动处理:${left}"
    fi
}

case "$1" in
    -u | --uninstall) uninstall_plugin ;;
    "" | -i | --install) install_plugin ;;
    *) echo "用法: 不带参数=安装/更新, -u=卸载"; exit 1 ;;
esac
