#!/bin/bash
# =========================================================
# sb-pip-plugin
# =========================================================
export LANG=en_US.UTF-8
work_dir="${SB_WORK_DIR:-/etc/sing-box}"
plugin_dir="${work_dir}/plugins"
wrapper="${work_dir}/sb.sh"
wrapper_marker="# proxyip-plugin wrapper"
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

# 旧版本添加过规则但还没有状态文件时，从 route.json 补全主 ProxyIP
_pip_sync_conf() {
    # 旧版(单个备用)状态迁移到 备用列表 + CUR_ADDR/CUR_PORT
    local ob_a ob_p
    ob_a=$(_pip_conf_get B_ADDR)
    if [ -n "$ob_a" ] && [ ! -f "$(_pip_bkf)" ]; then
        ob_p=$(_pip_conf_get B_PORT); ob_p=${ob_p:-443}
        echo "${ob_a} ${ob_p}" > "$(_pip_bkf)"
        if [ "$(_pip_conf_get CURRENT)" = backup ]; then
            _pip_conf_set CUR_ADDR "$ob_a"; _pip_conf_set CUR_PORT "$ob_p"
        fi
    fi
    local k; for k in B_ADDR B_PORT CURRENT; do _pip_conf_del "$k"; done
    # 旧版本添加过规则但还没有状态文件时，从 route.json 补全主 ProxyIP
    if [ -z "$(_pip_conf_get P_ADDR)" ]; then
        local row
        row=$(jq -r '.route.rules[]? | select(.override_address != null) | "\(.override_address)\t\(.override_port // 443)"' "$route_file" 2>/dev/null | head -1)
        [ -z "$row" ] && return 0
        _pip_conf_set P_ADDR "${row%%$'\t'*}"
        _pip_conf_set P_PORT "${row##*$'\t'}"
    fi
    if [ -z "$(_pip_conf_get CUR_ADDR)" ]; then
        _pip_conf_set CUR_ADDR "$(_pip_conf_get P_ADDR)"
        _pip_conf_set CUR_PORT "$(_pip_conf_get P_PORT)"
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
_pip_probe() {
    [ -z "$pip_port" ] && pip_port=443
    fam="-4"
    direct_info=$(_pip_trace "" "" "$fam")
    [ -z "$direct_info" ] && { fam="-6"; direct_info=$(_pip_trace "" "" "$fam"); }
    if [ -z "$direct_info" ]; then
        red "无法访问 cloudflare.com，请检查服务器网络"; return 2
    fi
    echo ""
    green "服务器直连:   ${direct_info}"
    pip_info=$(_pip_trace "" "$pip_addr" "$fam" "$pip_port")
    [ -n "$pip_info" ] || return 1
    return 0
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

# 切换到 primary 或 backup
_pip_switch_addr() {   # $1=地址 $2=端口：把规则切到该 ProxyIP 并记为当前使用
    _pip_apply "$1" "${2:-443}" || return 1
    _pip_conf_set CUR_ADDR "$1"; _pip_conf_set CUR_PORT "${2:-443}"
    _pip_conf_set FAILS 0; _pip_conf_set OKS 0
    return 0
}

# 备用 ProxyIP 列表：proxyip.backups，每行 "地址 端口"，顺序即优先级
_pip_bkf() { echo "${work_dir}/plugins/proxyip.backups"; }
_pip_bk_list() { sed '/^[[:space:]]*$/d' "$(_pip_bkf)" 2>/dev/null; }
_pip_bk_count() { _pip_bk_list | wc -l; }

# 当前是否在用主 ProxyIP
_pip_on_primary() {
    local ca cp; ca=$(_pip_conf_get CUR_ADDR); cp=$(_pip_conf_get CUR_PORT)
    [ -z "$ca" ] && return 0
    [ "$ca" = "$(_pip_conf_get P_ADDR)" ] && [ "${cp:-443}" = "$(_pip_conf_get P_PORT)" ]
}
# 当前使用的 ProxyIP 显示名：主 / 备用N
_pip_cur_label() {
    if _pip_on_primary; then echo 主; return; fi
    local ca cp n=0 a p; ca=$(_pip_conf_get CUR_ADDR); cp=$(_pip_conf_get CUR_PORT)
    while read -r a p; do
        n=$((n+1))
        if [ "$a" = "$ca" ] && [ "$p" = "${cp:-443}" ]; then echo "备用${n}"; return; fi
    done < <(_pip_bk_list)
    echo "${ca}:${cp}"
}
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
            echo -e " - ${skyblue}${t}${re} ${purple}->${re} ${yellow}${a}${re}  ${d}"
        done <<< "$rows"
        local pa pp nb
        pa=$(_pip_conf_get P_ADDR); pp=$(_pip_conf_get P_PORT)
        nb=$(_pip_bk_count)
        echo ""
        echo -e " 主 ProxyIP: ${yellow}${pa}:${pp:-443}${re}   当前使用: $(_pip_cur_label)"
        if [ "$nb" -gt 0 ]; then
            echo -e " 备用 ProxyIP: ${nb} 个   自动切换: $(_pip_watch_state)"
        else
            echo " 备用 ProxyIP: 未设置"
        fi
    fi
    echo ""
    green "1. 添加 ProxyIP 分流"
    red   "2. 删除 ProxyIP 分流"
    yellow "3. 更换主 ProxyIP (保留规则，批量改地址/端口)"
    skyblue "4. 备用 ProxyIP / 自动切换"
    purple "0. 返回上级菜单"
    reading "请输入选择: " pip_menu_choice
    case "$pip_menu_choice" in
        1) add_proxyip_route ;;
        2) delete_proxyip_route ;;
        3) change_proxyip_route ;;
        4) backup_proxyip_menu ;;
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
    # 全部规则删完后，自动切换没有意义：停掉服务并清除主 ProxyIP 状态(备用列表保留)
    if [ -z "$(_pip_list_rules)" ]; then
        _pip_watch_stop
        local k; for k in P_ADDR P_PORT CUR_ADDR CUR_PORT FAILS OKS; do _pip_conf_del "$k"; done
    fi
    sleep 2; proxyip_menu
}

change_proxyip_route() {
    clear
    green "=== 更换主 ProxyIP ===\n"
    if [ -z "$(_pip_list_rules)" ]; then
        yellow "当前没有 ProxyIP 分流规则"; sleep 2; proxyip_menu; return
    fi
    yellow "把所有 ProxyIP 分流规则改指向新的 ProxyIP(域名列表不变)，并设为主 ProxyIP。"
    local pip_addr pip_port fam direct_info pip_info pip_in
    reading "请输入新的 ProxyIP，可带端口，如 tw.william.us.ci:8443 (不写端口默认443，回车返回): " pip_in
    [ -z "$pip_in" ] && { proxyip_menu; return; }
    pip_in=$(echo "$pip_in" | xargs)
    if ! _pip_parse_addr "$pip_in"; then
        red "地址或端口格式无效"; sleep 2; proxyip_menu; return
    fi
    _pip_probe
    case $? in
        0) green "经 ProxyIP:   ${pip_addr}:${pip_port}  ${pip_info}" ;;
        2) sleep 2; proxyip_menu; return ;;
        *) red "该 ProxyIP (${pip_addr}:${pip_port}) 不可用，已取消"; sleep 3; proxyip_menu; return ;;
    esac

    _pip_apply "$pip_addr" "$pip_port" || { sleep 3; proxyip_menu; return; }
    _pip_conf_set P_ADDR "$pip_addr"; _pip_conf_set P_PORT "$pip_port"
    _pip_conf_set CUR_ADDR "$pip_addr"; _pip_conf_set CUR_PORT "$pip_port"
    _pip_conf_set FAILS 0; _pip_conf_set OKS 0
    green "\n已将所有 ProxyIP 分流改为 ${pip_addr}:${pip_port}"
    sleep 2; proxyip_menu
}

backup_proxyip_menu() {
    clear
    green "=== 备用 ProxyIP / 自动切换 ===\n"
    _pip_sync_conf
    local pa pp
    pa=$(_pip_conf_get P_ADDR); pp=$(_pip_conf_get P_PORT)
    if [ -z "$pa" ]; then
        yellow "请先添加 ProxyIP 分流规则"; sleep 2; proxyip_menu; return
    fi
    local bka=() bkp=() n=0 a p i
    while read -r a p; do
        [ -z "$a" ] && continue
        n=$((n+1)); bka+=("$a"); bkp+=("${p:-443}")
    done < <(_pip_bk_list)
    local cur_label; cur_label=$(_pip_cur_label)
    echo -e " 主 ProxyIP:   ${yellow}${pa}:${pp:-443}${re}"
    if [ "$n" -eq 0 ]; then
        echo " 备用 ProxyIP: 未设置"
    else
        for i in "${!bka[@]}"; do echo -e " 备用 $((i+1)):     ${yellow}${bka[$i]}:${bkp[$i]}${re}"; done
    fi
    echo -e " 当前使用:     ${cur_label}"
    echo -e " 自动切换:     $(_pip_watch_state)"
    echo ""
    green "1. 添加备用 ProxyIP (最多5个，按添加顺序优先)"
    red   "2. 删除备用 ProxyIP"
    green "3. 开启自动切换 (主连续不通时切到可用备用，主恢复后自动切回)"
    red   "4. 关闭自动切换"
    yellow "5. 手动切换 (主 / 备用)"
    skyblue "6. 查看切换日志"
    purple "0. 返回"
    reading "请输入选择: " bk_choice
    local pip_addr pip_port fam direct_info pip_info pip_in
    case "$bk_choice" in
        1)
            if [ "$n" -ge 5 ]; then red "最多添加 5 个备用"; sleep 2; backup_proxyip_menu; return; fi
            reading "请输入备用 ProxyIP，可带端口 (不写端口默认443，回车返回): " pip_in
            [ -z "$pip_in" ] && { backup_proxyip_menu; return; }
            pip_in=$(echo "$pip_in" | xargs)
            if ! _pip_parse_addr "$pip_in"; then
                red "地址或端口格式无效"; sleep 2; backup_proxyip_menu; return
            fi
            [ -z "$pip_port" ] && pip_port=443
            if [ "$pip_addr" = "$pa" ] && [ "$pip_port" = "${pp:-443}" ]; then
                red "与主 ProxyIP 相同，不能当备用"; sleep 2; backup_proxyip_menu; return
            fi
            for i in "${!bka[@]}"; do
                if [ "${bka[$i]}" = "$pip_addr" ] && [ "${bkp[$i]}" = "$pip_port" ]; then
                    red "该备用已存在 (备用$((i+1)))"; sleep 2; backup_proxyip_menu; return
                fi
            done
            _pip_probe
            case $? in
                0) green "经 ProxyIP:   ${pip_addr}:${pip_port}  ${pip_info}" ;;
                2) sleep 2; backup_proxyip_menu; return ;;
                *) red "该 ProxyIP (${pip_addr}:${pip_port}) 不可用，已取消"; sleep 3; backup_proxyip_menu; return ;;
            esac
            # 防呆：出口 IP 和主 / 其他备用相同就是同一个源，主挂了它也会一起挂，不能当备用
            local new_ip o_ip dup=""
            new_ip=$(echo "$pip_info" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
            o_ip=$(_pip_trace "" "$pa" "$fam" "${pp:-443}" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
            [ -n "$o_ip" ] && [ "$o_ip" = "$new_ip" ] && dup="主 ProxyIP"
            if [ -z "$dup" ]; then
                for i in "${!bka[@]}"; do
                    o_ip=$(_pip_trace "" "${bka[$i]}" "$fam" "${bkp[$i]}" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
                    if [ -n "$o_ip" ] && [ "$o_ip" = "$new_ip" ]; then dup="备用$((i+1))"; break; fi
                done
            fi
            if [ -n "$dup" ]; then
                red "该 ProxyIP 的出口 IP (${new_ip}) 和 ${dup} 相同，属于同一个源，不能当备用。"
                sleep 4; backup_proxyip_menu; return
            fi
            echo "${pip_addr} ${pip_port}" >> "$(_pip_bkf)"
            green "\n已添加备用 ProxyIP: ${pip_addr}:${pip_port} (备用$((n+1)))"
            if [ "$(_pip_watch_state)" != "运行中" ]; then
                reading "是否开启自动切换？(Y/n): " bk_auto
                if [[ "$bk_auto" != "n" && "$bk_auto" != "N" ]]; then
                    _pip_watch_start && green "自动切换已开启" || red "自动切换开启失败"
                fi
            fi
            sleep 2; backup_proxyip_menu ;;
        2)
            [ "$n" -eq 0 ] && { yellow "没有备用可删除"; sleep 2; backup_proxyip_menu; return; }
            reading "输入要删除的备用序号 (回车返回): " bk_del
            [ -z "$bk_del" ] && { backup_proxyip_menu; return; }
            if ! [[ "$bk_del" =~ ^[0-9]+$ ]] || [ "$bk_del" -lt 1 ] || [ "$bk_del" -gt "$n" ]; then
                red "无效的序号"; sleep 1; backup_proxyip_menu; return
            fi
            local di=$((bk_del-1))
            # 要删除的备用正在使用：先切回主 ProxyIP
            if ! _pip_on_primary && [ "${bka[$di]}" = "$(_pip_conf_get CUR_ADDR)" ] && [ "${bkp[$di]}" = "$(_pip_conf_get CUR_PORT)" ]; then
                yellow "备用${bk_del} 正在使用，删除前需先切回主 ProxyIP。"
                fam=$(_pip_fam)
                if [ -z "$(_pip_trace "" "$pa" "$fam" "${pp:-443}")" ]; then
                    yellow "主 ProxyIP 当前检测不通，切回后这些域名会暂时打不开。"
                    reading "仍要切回主并删除？(y/N): " bk_force
                    [[ "$bk_force" == "y" || "$bk_force" == "Y" ]] || { backup_proxyip_menu; return; }
                fi
                _pip_switch_addr "$pa" "${pp:-443}" || { sleep 3; backup_proxyip_menu; return; }
            fi
            : > "$(_pip_bkf)"
            for i in "${!bka[@]}"; do
                [ "$i" -ne "$di" ] && echo "${bka[$i]} ${bkp[$i]}" >> "$(_pip_bkf)"
            done
            green "已删除备用${bk_del}: ${bka[$di]}:${bkp[$di]}"
            if [ "$n" -le 1 ]; then _pip_watch_stop; yellow "已无备用，自动切换已关闭。"; fi
            sleep 2; backup_proxyip_menu ;;
        3)
            [ "$n" -eq 0 ] && { red "请先添加备用 ProxyIP"; sleep 2; backup_proxyip_menu; return; }
            _pip_watch_start && green "自动切换已开启 (每2分钟检测一次)" || red "自动切换开启失败"
            sleep 2; backup_proxyip_menu ;;
        4)
            _pip_watch_stop; green "自动切换已关闭"
            sleep 2; backup_proxyip_menu ;;
        5)
            [ "$n" -eq 0 ] && { yellow "没有备用，无法切换"; sleep 2; backup_proxyip_menu; return; }
            local all_a=("$pa" "${bka[@]}") all_p=("${pp:-443}" "${bkp[@]}") nm j
            echo ""
            for j in "${!all_a[@]}"; do
                nm="主"; [ "$j" -gt 0 ] && nm="备用${j}"
                echo -e " $((j+1)). ${nm}  ${all_a[$j]}:${all_p[$j]}$([ "$nm" = "$cur_label" ] && echo '  (当前)')"
            done
            reading "输入要切换到的序号 (回车返回): " bk_sw
            [ -z "$bk_sw" ] && { backup_proxyip_menu; return; }
            if ! [[ "$bk_sw" =~ ^[0-9]+$ ]] || [ "$bk_sw" -lt 1 ] || [ "$bk_sw" -gt "${#all_a[@]}" ]; then
                red "无效的序号"; sleep 1; backup_proxyip_menu; return
            fi
            local si=$((bk_sw-1))
            fam=$(_pip_fam)
            if [ -z "$(_pip_trace "" "${all_a[$si]}" "$fam" "${all_p[$si]}")" ]; then
                yellow "${all_a[$si]}:${all_p[$si]} 当前检测不通。"
                reading "仍要切换？(y/N): " bk_force
                [[ "$bk_force" == "y" || "$bk_force" == "Y" ]] || { backup_proxyip_menu; return; }
            fi
            if _pip_switch_addr "${all_a[$si]}" "${all_p[$si]}"; then
                green "已切换到 ${all_a[$si]}:${all_p[$si]}"
                [ "$(_pip_watch_state)" = "运行中" ] && [ "$si" -gt 0 ] && yellow "提示：自动切换已开启，主 ProxyIP 恢复后会自动切回。"
            fi
            sleep 3; backup_proxyip_menu ;;
        6)
            local lg="${work_dir}/plugins/proxyip-watch.log"
            echo ""
            if [ -s "$lg" ]; then tail -n 20 "$lg"; else echo "暂无切换记录"; fi
            echo ""
            reading "按回车返回" bk_any
            backup_proxyip_menu ;;
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
        sleep 3; warp_manage; return
    fi

    _pip_sync_conf
    local pip_addr pip_port fam direct_info pip_info pip_in reuse=0
    local pip_re_dom='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    if [ -n "$(_pip_list_rules)" ] && [ -n "$(_pip_conf_get P_ADDR)" ]; then
        # 已有规则：所有规则共用同一个 ProxyIP，新规则沿用当前正在使用的那个
        reuse=1
        pip_addr=$(_pip_conf_get CUR_ADDR); pip_port=$(_pip_conf_get CUR_PORT)
        [ -z "$pip_addr" ] && { pip_addr=$(_pip_conf_get P_ADDR); pip_port=$(_pip_conf_get P_PORT); }
        yellow "已有 ProxyIP 分流，新规则沿用当前 ProxyIP: ${pip_addr}:${pip_port:-443}"
    else
        reading "请输入 ProxyIP，可带端口，如 tw.william.us.ci 或 tw.william.us.ci:8443 (不写端口默认443，回车返回): " pip_in
        [ -z "$pip_in" ] && { warp_manage; return; }
        pip_in=$(echo "$pip_in" | xargs)
        if ! _pip_parse_addr "$pip_in"; then
            red "地址或端口格式无效"; sleep 2; warp_manage; return
        fi
    fi
    _pip_probe
    case $? in
        0) ;;
        2) sleep 2; warp_manage; return ;;
        *) red "该 ProxyIP (${pip_addr}:${pip_port}) 不可用，已取消 (若它用的不是443端口，请写成 域名:端口)"; sleep 3; warp_manage; return ;;
    esac
    green "经 ProxyIP:   ${pip_addr}:${pip_port}  ${pip_info}"
    local d_ip p_ip
    d_ip=$(echo "$direct_info" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
    p_ip=$(echo "$pip_info" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
    if [ "$d_ip" = "$p_ip" ]; then
        yellow "\n两者出口IP相同：该 ProxyIP 没有改变出口，分流没有意义。"
        reading "仍要继续？(y/N): " go_on
        [[ "$go_on" == "y" || "$go_on" == "Y" ]] || { warp_manage; return; }
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
            [ -z "$pip_name" ] && { red "名称不能为空"; sleep 1; warp_manage; return; }
            reading "域名列表(空格或逗号分隔，含下级域名): " pip_dom_in
            pip_dom_in="${pip_dom_in//,/ }"
            local d
            for d in $pip_dom_in; do
                [[ "$d" =~ $pip_re_dom ]] && pip_domains+=("$d") || yellow "跳过无效域名: $d"
            done
            ;;
        *) warp_manage; return ;;
    esac
    [ ${#pip_domains[@]} -eq 0 ] && { red "没有有效域名"; sleep 1; warp_manage; return; }

    local tag="pip-${pip_name}"
    if jq -e --arg t "$tag" '.route.rule_set[]? | select(.tag == $t)' "$route_file" >/dev/null 2>&1; then
        yellow "规则 '${tag}' 已存在，请先在「2. 删除分流服务」中删除后再添加"
        sleep 2; warp_manage; return
    fi
    if jq -e --arg t "$pip_name" '.route.rules[]? | select(.rule_set != null) | .rule_set[]? | select(. == $t)' "$route_file" >/dev/null 2>&1; then
        yellow "注意：同名的 '${pip_name}' 分流规则已在使用其他出站，先匹配的规则优先，建议先在「2. 删除分流服务」中删除它，否则 ProxyIP 可能不生效。"
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
    [ ${#ok_domains[@]} -eq 0 ] && { red "没有可用域名，已取消"; sleep 3; warp_manage; return; }

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
        sleep 3; warp_manage; return
    fi
    rm -f "${route_file}.bak"

    reload_singbox
    # 第一条规则：把这个 ProxyIP 记为主 ProxyIP (之后添加的规则沿用当前使用的 ProxyIP)
    if [ "$reuse" -eq 0 ]; then
        _pip_conf_set P_ADDR "$pip_addr"; _pip_conf_set P_PORT "$pip_port"
        _pip_conf_set CUR_ADDR "$pip_addr"; _pip_conf_set CUR_PORT "$pip_port"
        _pip_conf_set FAILS 0; _pip_conf_set OKS 0
    fi
    green "\n已添加 ProxyIP 分流 '${tag}' -> ${pip_addr}:${pip_port}，域名: ${ok_domains[*]}"
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
# sing-box ProxyIP 主备自动切换守护进程（由 sb-proxyip 服务运行：bash proxyip-watch.sh daemon）
# 每轮检测当前使用的 ProxyIP；主连续不通 -> 按顺序切到第一个可用备用；主恢复并连续正常 -> 切回主；
# 正在用的备用也坏了 -> 优先切回可用的主，否则换下一个可用备用。
# 本机网络自身异常(直连 cloudflare.com 都不通)时不做任何判定，避免误切换。
work_dir="$(cd "$(dirname "$0")/.." && pwd)"
conf_dir="${work_dir}/conf"
route_file="${conf_dir}/route.json"
cf="${work_dir}/plugins/proxyip.conf"
bkf="${work_dir}/plugins/proxyip.backups"
logf="${work_dir}/plugins/proxyip-watch.log"
INTERVAL=${PIP_INTERVAL:-120}       # 检测间隔(秒)
FAIL_LIMIT=${PIP_FAIL_LIMIT:-2}     # 连续几轮不通才切到备用
BACK_LIMIT=${PIP_BACK_LIMIT:-2}     # 主恢复后连续几轮正常才切回

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
# probe 地址 端口：2 次尝试，任意一次拿到 CF trace 即视为可用
probe() {
    local host=$1 port=$2 i
    [[ "$host" == *:* ]] && host="[${host}]"
    for i in 1 2; do
        curl -s $fam --connect-timeout 5 -m 8 --connect-to "www.cloudflare.com:443:${host}:${port}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^ip=' && return 0
        [ "$i" -eq 1 ] && sleep 3
    done
    return 1
}
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

bka=(); bkp=()
load_backups() {
    bka=(); bkp=()
    local a p
    while read -r a p; do
        [ -z "$a" ] && continue
        bka+=("$a"); bkp+=("${p:-443}")
    done < "$bkf" 2>/dev/null
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
# 按顺序找第一个可用的备用并切换；$1/$2=要跳过的(当前使用的)地址/端口
try_backups() {
    local i
    for i in "${!bka[@]}"; do
        [ "${bka[$i]}" = "$1" ] && [ "${bkp[$i]}" = "$2" ] && continue
        if probe "${bka[$i]}" "${bkp[$i]}"; then
            switch_to "${bka[$i]}" "${bkp[$i]}" "已切换到备用$((i+1))" && return 0
        fi
    done
    return 1
}

tick() {
    local pa pp ca cp fails oks
    pa=$(get P_ADDR); pp=$(get P_PORT); ca=$(get CUR_ADDR); cp=$(get CUR_PORT)
    [ -n "$pa" ] || return 0
    pp=${pp:-443}; ca=${ca:-$pa}; cp=${cp:-$pp}
    load_backups
    [ ${#bka[@]} -gt 0 ] || return 0
    has_rules || return 0
    net_ok || return 0
    fails=$(get FAILS); oks=$(get OKS); fails=${fails:-0}; oks=${oks:-0}

    if [ "$ca" = "$pa" ] && [ "$cp" = "$pp" ]; then
        # 正在用主 ProxyIP
        if probe "$pa" "$pp"; then put FAILS 0; return 0; fi
        fails=$((fails+1)); put FAILS "$fails"
        log "主 ProxyIP ${pa}:${pp} 不通 (${fails}/${FAIL_LIMIT})"
        if [ "$fails" -ge "$FAIL_LIMIT" ]; then
            try_backups "" "" || log "所有备用 ProxyIP 都不通，保持不变"
        fi
    else
        # 正在用某个备用
        if ! probe "$ca" "$cp"; then
            # 当前备用坏了：主如果可用就切回，否则换下一个可用备用
            if probe "$pa" "$pp"; then
                switch_to "$pa" "$pp" "当前备用不通，主 ProxyIP 可用，已切回主"
            else
                try_backups "$ca" "$cp" || log "主、备 ProxyIP 均不通"
            fi
            return 0
        fi
        # 当前备用正常：看主是否恢复
        if probe "$pa" "$pp"; then
            oks=$((oks+1)); put OKS "$oks"
            if [ "$oks" -ge "$BACK_LIMIT" ]; then
                switch_to "$pa" "$pp" "主 ProxyIP 已恢复，切回主"
            fi
        else
            put OKS 0
        fi
    fi
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
    local url=$1
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
${wrapper_marker}
bash <(curl -Ls ${url} | bash ${plugin_dir}/proxyip-inject.sh) "\$@"
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
    [ -e /usr/bin/sb ] || { [ -z "$SB_WORK_DIR" ] && ln -sf "$wrapper" /usr/bin/sb; }

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

uninstall_plugin() {
    [ -f "$wrapper" ] || { yellow "未找到 sb 快捷指令，无需卸载"; exit 0; }
    local url
    url=$(cat "${plugin_dir}/main_url" 2>/dev/null)
    if [ -f "${wrapper}.orig" ]; then
        mv -f "${wrapper}.orig" "$wrapper"
    elif [ -n "$url" ]; then
        printf '#!/usr/bin/env bash\nbash <(curl -Ls %s) $1\n' "$url" > "$wrapper"
    fi
    chmod +x "$wrapper"
    if [ -z "$SB_WORK_DIR" ]; then
        if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sb-proxyip.service ]; then
            systemctl disable --now sb-proxyip >/dev/null 2>&1
            rm -f /etc/systemd/system/sb-proxyip.service
            systemctl daemon-reload >/dev/null 2>&1
        fi
        if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/sb-proxyip ]; then
            rc-service sb-proxyip stop >/dev/null 2>&1
            rc-update del sb-proxyip default >/dev/null 2>&1
            rm -f /etc/init.d/sb-proxyip
        fi
    fi
    rm -f "${plugin_dir}/proxyip.sh" "${plugin_dir}/proxyip-inject.sh" "${plugin_dir}/proxyip-watch.sh" "${plugin_dir}/proxyip.conf" "${plugin_dir}/proxyip.backups" "${plugin_dir}/proxyip-watch.log" "${plugin_dir}/main_url"
    rmdir "$plugin_dir" 2>/dev/null
    green "已卸载 ProxyIP 分流插件，sb 快捷指令已恢复。"
    yellow "已添加的 ProxyIP 分流规则(名称以 pip- 开头)仍保留在配置里继续生效，"
    yellow "如需删除，请到 sb -> 10 -> 2(删除分流服务) 中删除。"
}

case "$1" in
    -u | --uninstall) uninstall_plugin ;;
    "" | -i | --install) install_plugin ;;
    *) echo "用法: 不带参数=安装/更新, -u=卸载"; exit 1 ;;
esac
