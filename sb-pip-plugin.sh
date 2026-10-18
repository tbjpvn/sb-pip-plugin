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
wrapper_marker="# proxyip-plugin wrapper"
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }

[ -z "$SB_WORK_DIR" ] && [ "$EUID" -ne 0 ] && { red "请在root用户下运行脚本"; exit 1; }

write_payload() {
cat > "${plugin_dir}/proxyip.sh" <<'PIP_PAYLOAD_EOF'
# ---- 公共 ProxyIP 分流 ----
# 取 Cloudflare trace 里的 ip= / colo= ；$1=host(可空则直连) $2=ProxyIP $3=IP族参数(-4/-6)
_pip_trace() {
    local host=${1:-www.cloudflare.com} pip=$2 fam=$3
    local args=(-s -m 8 $fam)
    if [ -n "$pip" ]; then
        [[ "$pip" == *:* ]] && pip="[${pip}]"
        args+=(--connect-to "${host}:443:${pip}:443")
    fi
    curl "${args[@]}" "https://${host}/cdn-cgi/trace" 2>/dev/null | grep -E '^(ip|colo)=' | tr '\n' ' '
}

# 列出已添加的 ProxyIP 分流规则: 输出 "规则名<TAB>ProxyIP<TAB>域名列表"
_pip_list_rules() {
    jq -r '
      . as $root
      | .route.rules[]?
      | select(.override_address != null and (.rule_set | type) == "array")
      | .rule_set[0] as $t
      | (first($root.route.rule_set[]? | select(.tag == $t) | .rules[0].domain_suffix | join(" ")) // "") as $d
      | "\($t)\t\(.override_address)\t\($d)"
    ' "$route_file" 2>/dev/null
}

proxyip_menu() {
    route_file="${conf_dir}/route.json"
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
    fi
    echo ""
    green "1. 添加 ProxyIP 分流"
    red   "2. 删除 ProxyIP 分流"
    purple "0. 返回上级菜单"
    reading "请输入选择: " pip_menu_choice
    case "$pip_menu_choice" in
        1) add_proxyip_route ;;
        2) delete_proxyip_route ;;
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
    sleep 2; proxyip_menu
}

add_proxyip_route() {
    clear
    green "=== 添加公共 ProxyIP 分流 ===\n"
    yellow "说明：ProxyIP 只是一个能中转TCP的CF相关地址，不是代理协议："
    yellow " - 仅对 Cloudflare 托管的网站有效 (443端口/TLS)，其余站点会直接打不开"
    yellow " - 对方服务器能看到你访问的域名，稳定性取决于对方\n"

    local sb_ver
    sb_ver=$("${work_dir}/sing-box" version 2>/dev/null | awk 'NR==1{print $3}')
    if [ -n "$sb_ver" ] && [ "$(printf '%s\n1.11.0\n' "$sb_ver" | sort -V | head -n1)" != "1.11.0" ]; then
        red "当前 sing-box 内核版本 ${sb_ver} 过低，ProxyIP 分流需要 1.11.0 及以上，请先在主菜单更新内核。"
        sleep 3; warp_manage; return
    fi

    reading "请输入 ProxyIP 域名或IP (回车返回): " pip_addr
    [ -z "$pip_addr" ] && { warp_manage; return; }
    pip_addr=$(echo "$pip_addr" | xargs)
    local pip_re_dom='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    local pip_re_v4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if ! [[ "$pip_addr" =~ $pip_re_dom || "$pip_addr" =~ $pip_re_v4 || "$pip_addr" == *:* ]]; then
        red "地址格式无效"; sleep 2; warp_manage; return
    fi

    local fam="-4" direct_info pip_info
    direct_info=$(_pip_trace "" "" "$fam")
    [ -z "$direct_info" ] && { fam="-6"; direct_info=$(_pip_trace "" "" "$fam"); }
    if [ -z "$direct_info" ]; then
        red "无法访问 cloudflare.com，请检查服务器网络"; sleep 2; warp_manage; return
    fi
    pip_info=$(_pip_trace "" "$pip_addr" "$fam")
    echo ""
    green "服务器直连:   ${direct_info}"
    if [ -z "$pip_info" ]; then
        red "经 ${pip_addr} 访问失败：该 ProxyIP 不可用，已取消"; sleep 3; warp_manage; return
    fi
    green "经 ProxyIP:   ${pip_info}"
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
        r=$(_pip_trace "$d" "$pip_addr" "$fam")
        if [ -n "$r" ]; then
            green "  ✔ ${d}  ${r}"; ok_domains+=("$d")
        else
            yellow "  ✘ ${d}  (非CF托管或不可达，已跳过)"
        fi
    done
    [ ${#ok_domains[@]} -eq 0 ] && { red "没有可用域名，已取消"; sleep 3; warp_manage; return; }

    local domains_json
    domains_json=$(printf '%s\n' "${ok_domains[@]}" | jq -R . | jq -s .)

    cp -f "$route_file" "${route_file}.bak"
    jq_write "$route_file" --arg tag "$tag" --argjson domains "$domains_json" --arg addr "$pip_addr" '
      .route.rule_set = ((.route.rule_set // []) + [{"tag":$tag,"type":"inline","rules":[{"domain_suffix":$domains}]}])
      | .route.rules = (
          [{"action":"sniff"}]
          + [ .route.rules[]? | select(.action != "sniff") ]
          + [
              {"rule_set":[$tag],"network":"udp","port":443,"action":"reject"},
              {"rule_set":[$tag],"network":"tcp","port":443,"action":"route","outbound":"direct","override_address":$addr,"override_port":443}
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
    green "\n已添加 ProxyIP 分流 '${tag}' -> ${pip_addr}，域名: ${ok_domains[*]}"
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

bash -n "$out" 2>/dev/null || passthrough
cat "$out"
PIP_INJECT_EOF
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
    chmod +x "${plugin_dir}/proxyip-inject.sh"
    if ! bash -n "${plugin_dir}/proxyip.sh" || ! bash -n "${plugin_dir}/proxyip-inject.sh"; then
        red "插件文件语法检查失败，已中止（未修改 sb 快捷指令）"; exit 1
    fi
    echo "$url" > "${plugin_dir}/main_url"
    write_wrapper "$url"
    [ -e /usr/bin/sb ] || { [ -z "$SB_WORK_DIR" ] && ln -sf "$wrapper" /usr/bin/sb; }

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
    rm -f "${plugin_dir}/proxyip.sh" "${plugin_dir}/proxyip-inject.sh" "${plugin_dir}/main_url"
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
