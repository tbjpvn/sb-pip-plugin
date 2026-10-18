#!/bin/bash

# =========================
# 老王sing-box四合一安装脚本
# vless-reality|vmess-ws-tls(Argo)|hysteria2|tuic5|[可额外添加Anytls，socks5，ss2022等协议]
# =========================


# 定义颜色
export LANG=en_US.UTF-8
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -r -p "$(red "$1")" "$2"; }

# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
sys_warp_dir="/etc/wireguard"
quota_bin="${work_dir}/quota-monitor.sh"
quota_state="${work_dir}/quota.json"
quota_api_conf="${conf_dir}/clash_api.json"
export vless_port=${PORT:-$(shuf -i 10000-65000 -n 1)}
export CFIP=${CFIP:-'cdns.doon.eu.org'} 
export ARGO_PORT=${ARGO_PORT:-'8001'} 
export CFPORT=${CFPORT:-'443'} 

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本，可输入 sudo -i 回车切换到root用户" && exit 1

# 检查命令是否存在函数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_port_free() {
    local port=$1
    if command_exists ss; then
        ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[.:]${port}\$" && return 1
        return 0
    elif command_exists lsof; then
        lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 && return 1
        lsof -iUDP:"$port" -t >/dev/null 2>&1 && return 1
        return 0
    fi
    return 0
}

get_free_port() {
    local min=$1 max=$2 tries=0 port
    while [ "$tries" -lt 200 ]; do
        port=$(shuf -i "${min}-${max}" -n 1)
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
        tries=$((tries+1))
    done
    echo "$port"
    return 1
}

jq_write() {
    local file=$1
    shift
    jq "$@" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

prompt_port() {
    local prompt=$1
    local min=${2:-10000}
    local max=${3:-65000}
    local label=$4
    local check_free=${5:-1}
    local port

    while true; do
        reading "$prompt" port
        if [ -z "$port" ]; then
            if [ "$check_free" = "1" ]; then
                port=$(get_free_port "$min" "$max")
            else
                port=$(shuf -i "${min}-${max}" -n 1)
            fi
            [ -n "$label" ] && green "${label}：${purple}${port}${re}" >&2
            echo "$port"
            return 0
        fi
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -gt 65535 ] || [ "$port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！" >&2
            continue
        fi
        if [ "$check_free" = "1" ] && ! is_port_free "$port"; then
            red "端口 $port 已被占用" >&2
            continue
        fi
        [ -n "$label" ] && green "${label}：${purple}${port}${re}" >&2
        echo "$port"
        return 0
    done
}

update_subscription() {
    [ -f "$client_dir" ] || return 0
    if base64 -w0 "$client_dir" > "${work_dir}/sub.txt" 2>/dev/null; then
        :
    else
        base64 "$client_dir" | tr -d '\n\r' > "${work_dir}/sub.txt"
    fi
    chmod 644 "${work_dir}/sub.txt" 2>/dev/null || true
}

print_client_urls() {
    local f=${1:-$client_dir}
    [ -f "$f" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && yellow "$line"
    done < "$f"
}

# 检查服务状态通用函数
check_service() {
    local service_name=$1
    local service_file=$2

    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }

    if service_is_running "${service_name}"; then
        green "running"
    else
        yellow "not running"
    fi
    return 0
}

service_is_running() {
    local name=$1
    if command_exists rc-service && ! command_exists systemctl; then
        rc-service "$name" status 2>/dev/null | grep -q "started"
    else
        systemctl is-active --quiet "$name" 2>/dev/null
    fi
}

verify_udp_listening() {
    command_exists ss || return 0
    local max_wait=30
    local waited=0
    local tuic_seen=0
    local hy2_seen=0

    [ -z "$tuic_port" ] && tuic_seen=1
    [ -z "$hy2_port" ] && hy2_seen=1

    while [ "$waited" -lt "$max_wait" ]; do
        [ "$tuic_seen" -eq 0 ] && ss -H -uln 2>/dev/null | grep -q ":${tuic_port} " && tuic_seen=1
        [ "$hy2_seen" -eq 0 ] && ss -H -uln 2>/dev/null | grep -q ":${hy2_port} " && hy2_seen=1
        [ "$tuic_seen" -eq 1 ] && [ "$hy2_seen" -eq 1 ] && break
        sleep 1
        waited=$((waited+1))
    done

    local ok=1
    if [ "$tuic_seen" -eq 0 ]; then
        red "警告：等待 ${max_wait} 秒后，tuic端口 ${tuic_port}/udp 仍未监听，节点大概率不通，请到「6.修改节点配置->1.修改端口->3.修改tuic端口」重新分配。"
        ok=0
    fi
    if [ "$hy2_seen" -eq 0 ]; then
        red "警告：等待 ${max_wait} 秒后，hysteria2端口 ${hy2_port}/udp 仍未监听，节点大概率不通，请到「6.修改节点配置->1.修改端口->2.修改hysteria2端口」重新分配。"
        ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        if [ "$waited" -gt 0 ]; then
            green "hysteria2/tuic 的UDP端口均已正常监听（等待了约 ${waited} 秒，多为规则集下载耗时）。"
        else
            green "hysteria2/tuic 的UDP端口均已正常监听。"
        fi
    else
        yellow "提示：以上是本机端口监听状态，若显示已监听但客户端仍连不上，也可能是该端口被服务商网络侧过滤，可尝试更换端口。"
    fi
    return 0
}

# 检查sing-box状态
check_singbox() {
    check_service "sing-box" "${work_dir}/${server_name}"
}

check_congestion() {
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ -z "$cc" ]; then
        yellow "unknown"
        return 1
    fi
    if [ -n "$qdisc" ]; then
        green "${cc}+${qdisc}"
    else
        green "${cc}"
    fi
    return 0
}

# 检查argo状态
check_argo() {
    check_service "argo" "${work_dir}/argo"
}

_SB_IP_CACHE_DIR="${TMPDIR:-/tmp}/sb-ip-cache"
_SB_IP_CACHE_TTL=60

_sb_cache_get() {
    local key=$1
    local file="${_SB_IP_CACHE_DIR}/${key}"
    local now ts
    [ -f "$file" ] || return 1
    now=$(date +%s 2>/dev/null) || return 1
    ts=$(head -1 "$file" 2>/dev/null) || return 1
    case "$ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ $((now - ts)) -le "${_SB_IP_CACHE_TTL}" ] || return 1
    tail -n +2 "$file" 2>/dev/null
    return 0
}

_sb_cache_set() {
    local key=$1
    shift
    mkdir -p "${_SB_IP_CACHE_DIR}" 2>/dev/null || return 0
    {
        date +%s 2>/dev/null || echo 0
        local _a
        for _a in "$@"; do
            printf '%s\n' "$_a"
        done
    } > "${_SB_IP_CACHE_DIR}/${key}" 2>/dev/null || true
}

_sb_cache_clear() {
    rm -f "${_SB_IP_CACHE_DIR}/realip" "${_SB_IP_CACHE_DIR}/isp" "${_SB_IP_CACHE_DIR}/dualstack" 2>/dev/null || true
}

check_dualstack() {
    local ip4 ip6 tmp4 tmp6 cached
    if cached=$(_sb_cache_get dualstack); then
        ip4=$(echo "$cached" | sed -n '1p')
        ip6=$(echo "$cached" | sed -n '2p')
    else
        tmp4=$(mktemp); tmp6=$(mktemp)
        fetch_ip 4 1.5 > "$tmp4" &
        fetch_ip 6 1.5 > "$tmp6" &
        wait
        ip4=$(cat "$tmp4" 2>/dev/null); ip6=$(cat "$tmp6" 2>/dev/null)
        rm -f "$tmp4" "$tmp6"
        _sb_cache_set dualstack "${ip4}" "${ip6}"
    fi
    if [ -n "$ip4" ] && [ -n "$ip6" ]; then
        green "IPv4: ${ip4}  IPv6: ${ip6}"
    elif [ -n "$ip4" ]; then
        yellow "IPv4: ${ip4}  IPv6: 无"
    elif [ -n "$ip6" ]; then
        yellow "IPv4: 无  IPv6: ${ip6}"
    else
        red "无法获取"
    fi
}

pkg_installed() {
    local pkg=$1
    if command_exists dpkg-query; then
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
    elif command_exists rpm; then
        rpm -q "$pkg" >/dev/null 2>&1
    elif command_exists apk; then
        apk info -e "$pkg" >/dev/null 2>&1
    else
        command_exists "$pkg"
    fi
}

_SB_PKG_INDEX_READY=0

_ensure_pkg_index() {
    [ "${_SB_PKG_INDEX_READY}" = "1" ] && return 0
    if command_exists apt; then
        yellow "正在刷新软件源...\n"
        DEBIAN_FRONTEND=noninteractive apt-get update -y || return 1
    elif command_exists apk; then
        yellow "正在刷新软件源...\n"
        apk update || return 1
    fi
    _SB_PKG_INDEX_READY=1
    return 0
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    local action=$1
    shift
    local package need_index=0

    if [ "$action" == "install" ]; then
        for package in "$@"; do
            if ! pkg_installed "$package" && ! command_exists "$package"; then
                need_index=1
                break
            fi
        done
        if [ "$need_index" -eq 1 ]; then
            _ensure_pkg_index || { red "刷新软件源失败"; return 1; }
        fi
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if pkg_installed "$package" || command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" || return 1
            elif command_exists dnf; then
                dnf install -y "$package" || return 1
            elif command_exists yum; then
                yum install -y "$package" || return 1
            elif command_exists apk; then
                apk add "$package" || return 1
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! pkg_installed "$package" && ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt-get remove -y "$package" && apt-get autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

ensure_core_deps() {
    if [ "${_SB_CORE_DEPS_OK}" = "1" ]; then
        return 0
    fi
    yellow "检查并安装核心依赖...\n"
    local pkgs=(curl jq tar openssl ca-certificates)
    manage_packages install "${pkgs[@]}" || return 1
    manage_packages install lsof 2>/dev/null || true
    local req
    for req in curl jq tar openssl; do
        if ! command_exists "$req"; then
            red "核心依赖 ${req} 不可用，请手动安装后重试\n"
            return 1
        fi
    done
    _SB_CORE_DEPS_OK=1
    green "核心依赖已就绪\n"
    return 0
}

fetch_ip() {
    local flag=$1 timeout=${2:-2}
    curl -"${flag}" -sm "$timeout" ip.sb 2>/dev/null
}

is_warp_org() {
    local flag=$1 timeout=${2:-2}
    curl -"${flag}" -sm "$timeout" http://ipinfo.io/org 2>/dev/null | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'
}

# 获取ip
get_realip() {
    local cached ip v6
    if cached=$(_sb_cache_get realip); then
        echo "$cached"
        return 0
    fi
    ip=$(fetch_ip 4)
    _get_ipv6() { fetch_ip 6; }
    if [ -z "$ip" ]; then
        v6=$(_get_ipv6)
        cached="[$v6]"
    else
        if is_warp_org 4; then
            v6=$(_get_ipv6)
            cached="[$v6]"
        else
            if grep -qE '^\s*precedence\s+::ffff:0:0/96\s+100' "/etc/gai.conf" 2>/dev/null; then
                cached="$ip"
            else
                v6=$(_get_ipv6)
                if [ -n "$v6" ]; then
                    cached="[$v6]"
                else
                    cached="$ip"
                fi
            fi
        fi
    fi
    _sb_cache_set realip "$cached"
    echo "$cached"
}

gh_fetch_json() {
    local url=$1 out proxy
    out=$(curl -s -m 8 "$url" 2>/dev/null)
    if [ -n "$out" ] && echo "$out" | jq -e . >/dev/null 2>&1; then
        echo "$out"; return 0
    fi
    for proxy in "https://gh-proxy.com/" "https://ghfast.top/" "https://github.moeyy.xyz/"; do
        out=$(curl -s -m 8 "${proxy}${url}" 2>/dev/null)
        if [ -n "$out" ] && echo "$out" | jq -e . >/dev/null 2>&1; then
            echo "$out"; return 0
        fi
    done
    return 1
}

gh_download() {
    local url=$1 dest=$2 proxy
    if curl -sL --fail -m 60 -o "$dest" "$url" 2>/dev/null; then
        return 0
    fi
    for proxy in "https://gh-proxy.com/" "https://ghfast.top/" "https://github.moeyy.xyz/"; do
        if curl -sL --fail -m 60 -o "$dest" "${proxy}${url}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

gh_ipv6_hint() {
    yellow "提示：GitHub官方(github.com/api.github.com)长期未提供IPv6解析，纯IPv6 VPS在未配置NAT64或WARP出站时通常无法直连，脚本已自动尝试镜像代理但仍失败（可能是网络波动或镜像暂时不可用）。可到主菜单「单栈VPS加装WARP全局出站」加装IPv4 WARP出站后重试，或稍后再试。\n"
}

get_isp() {
    local addr flag result cached
    if cached=$(_sb_cache_get isp); then
        echo "$cached"
        return 0
    fi
    addr=$(get_realip)
    case "$addr" in
        \[*\]) flag="-6" ;;
        *) flag="-4" ;;
    esac
    result=$(curl "$flag" -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | tr -d '\n' | \
        awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | \
        sed 's/ /_/g')
    if [ -z "$result" ]; then
        result=$(curl "$flag" -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" 2>/dev/null | tr -d '\n' | \
            awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | \
            sed 's/ /_/g')
    fi
    if [ -z "$result" ] && [ "$flag" = "-4" ]; then
        result=$(curl -4 -sm 3 "http://ip-api.com/json/?fields=countryCode,isp" 2>/dev/null | \
            jq -r 'if (.countryCode!=null and .isp!=null) then (.countryCode+"-"+.isp) else empty end' 2>/dev/null | \
            sed 's/ /_/g')
    fi
    [ -z "$result" ] && return 1
    _sb_cache_set isp "$result"
    echo "$result"
    return 0
}

persist_iptables() {
    if command_exists rc-service && ! command_exists systemctl; then
        mkdir -p /etc/iptables
        command_exists iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        command_exists ip6tables && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    elif command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
    elif command_exists service; then
        service iptables save >/dev/null 2>&1
        service ip6tables save >/dev/null 2>&1
    fi
    return 0
}

# 处理防火墙
allow_port() {
    has_ufw=0
    has_firewalld=0
    has_iptables=0
    has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && {
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    [ "$has_ip6tables" -eq 1 ] && {
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    }

    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    if ! command_exists rc-service && ! command_exists netfilter-persistent && command_exists apt; then
        manage_packages install iptables-persistent || yellow "请手动安装netfilter-persistent或保存iptables规则"
    fi
    persist_iptables
}


deny_port() {
    local has_ufw=0 has_firewalld=0 has_iptables=0 has_ip6tables=0
    local rule port proto

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    for rule in "$@"; do
        [ -z "$rule" ] && continue
        port=${rule%/*}
        proto=${rule#*/}
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [ "$proto" = "tcp" ] || [ "$proto" = "udp" ] || continue

        if [ "$has_ufw" -eq 1 ]; then
            ufw delete allow in ${port}/${proto} >/dev/null 2>&1 || true
            ufw delete allow ${port}/${proto} >/dev/null 2>&1 || true
        fi
        if [ "$has_firewalld" -eq 1 ]; then
            firewall-cmd --permanent --remove-port=${port}/${proto} >/dev/null 2>&1 || true
        fi
        if [ "$has_iptables" -eq 1 ]; then
            while iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || break
            done
        fi
        if [ "$has_ip6tables" -eq 1 ]; then
            while ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null; do
                ip6tables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || break
            done
        fi
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1 || true

    persist_iptables
}

collect_node_ports() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local ports=() typ port

    [ -f "$inbounds_file" ] && command_exists jq || return 0
    while IFS=$'\t' read -r typ port; do
        [ -z "$port" ] || [ "$port" = "null" ] && continue
        case "$typ" in
            vless|vmess|anytls) ports+=("${port}/tcp") ;;
            hysteria2|tuic)     ports+=("${port}/udp") ;;
            socks|shadowsocks)  ports+=("${port}/tcp" "${port}/udp") ;;
            *)                  ports+=("${port}/tcp") ;;
        esac
    done < <(jq -r '.inbounds[]? | select(.listen_port != null) | "\(.type)\t\(.listen_port)"' "$inbounds_file" 2>/dev/null)

    if [ ${#ports[@]} -gt 0 ]; then
        printf '%s\n' "${ports[@]}" | awk 'NF && !seen[$0]++'
    fi
}

cleanup_port_hop_nat() {
    local mport listen_port min_port max_port
    [ -f "$client_dir" ] || return 0

    mport=$(grep -oE 'mport=[0-9]+,[0-9]+-[0-9]+' "$client_dir" 2>/dev/null | head -1 | sed 's/mport=//')
    [ -n "$mport" ] || return 0

    listen_port=${mport%%,*}
    min_port=${mport#*,}
    min_port=${min_port%-*}
    max_port=${mport##*-}

    [[ "$listen_port" =~ ^[0-9]+$ && "$min_port" =~ ^[0-9]+$ && "$max_port" =~ ^[0-9]+$ ]] || return 0

    if command_exists iptables; then
        while iptables -t nat -C PREROUTING -p udp --dport ${min_port}:${max_port} -j DNAT --to-destination :${listen_port} 2>/dev/null; do
            iptables -t nat -D PREROUTING -p udp --dport ${min_port}:${max_port} -j DNAT --to-destination :${listen_port} 2>/dev/null || break
        done
    fi
    if command_exists ip6tables; then
        while ip6tables -t nat -C PREROUTING -p udp --dport ${min_port}:${max_port} -j DNAT --to-destination :${listen_port} 2>/dev/null; do
            ip6tables -t nat -D PREROUTING -p udp --dport ${min_port}:${max_port} -j DNAT --to-destination :${listen_port} 2>/dev/null || break
        done
    fi

    persist_iptables
}

close_port80_if_unused() {
    [ -f "${work_dir}/cert_domain.txt" ] || [ -f "${work_dir}/port80-prehook.sh" ] || return 0
    if is_port_free 80; then
        deny_port 80/tcp >/dev/null 2>&1 || true
    else
        yellow "检测到80端口仍被其他服务占用，已保留防火墙放行规则\n"
    fi
}

close_node_firewall_ports() {
    local port_list
    port_list=$(collect_node_ports)
    if [ -z "$port_list" ]; then
        return 0
    fi
    deny_port $port_list
    cleanup_port_hop_nat
    green "已关闭本脚本添加的端口防火墙规则\n"
}

detect_warp_out_family() {
    if curl -4 -sm 5 -o /dev/null https://www.cloudflare.com 2>/dev/null; then
        echo 4
    elif curl -6 -sm 5 -o /dev/null https://www.cloudflare.com 2>/dev/null; then
        echo 6
    else
        echo 4
    fi
}

warp_probe_endpoint() {
    local port="$1" v4="$2" v6="$3" private_key="$4" peer_pub="$5" reserved_json="$6" peer_addr="$7"
    local iface="sbwprobe$$"
    local conf result=1 tries=0 hs

    if command_exists wg && command_exists ip; then
        ip link del "$iface" 2>/dev/null || true
        if ip link add dev "$iface" type wireguard 2>/dev/null; then
            local pkfile
            pkfile=$(mktemp /tmp/sb-wg-pk.XXXXXX)
            printf '%s\n' "$private_key" > "$pkfile"
            chmod 600 "$pkfile"
            if wg set "$iface" private-key "$pkfile" peer "$peer_pub" \
                endpoint "${peer_addr}:${port}" \
                allowed-ips "0.0.0.0/0,::/0" \
                persistent-keepalive 25 2>/dev/null; then
                local a4="${v4%/*}"
                ip -4 address add "${a4}/32" dev "$iface" 2>/dev/null || true
                if [ -n "$v6" ]; then
                    local a6="${v6%/*}"
                    ip -6 address add "${a6}/128" dev "$iface" 2>/dev/null || true
                fi
                ip link set "$iface" up 2>/dev/null || true
                ping -c 1 -W 1 -I "$iface" 1.1.1.1 >/dev/null 2>&1 || true
                while [ "$tries" -lt 5 ]; do
                    hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
                    if [ -n "$hs" ] && [ "$hs" != "0" ]; then
                        result=0
                        break
                    fi
                    local rx
                    rx=$(wg show "$iface" transfer 2>/dev/null | awk '{print $2; exit}')
                    if [ -n "$rx" ] && [ "$rx" != "0" ]; then
                        result=0
                        break
                    fi
                    sleep 1
                    tries=$((tries + 1))
                done
            fi
            rm -f "$pkfile"
            ip link del "$iface" 2>/dev/null || true
            return $result
        fi
    fi

    local sb_bin="${work_dir}/sing-box"
    local probe_dir probe_port pid
    [ -x "$sb_bin" ] || return 1
    probe_dir=$(mktemp -d /tmp/singbox-warpprobe.XXXXXX) || return 1
    probe_port=$((20000 + RANDOM % 10000))
    local addr_json="[\"$v4\"]"
    [ -n "$v6" ] && addr_json="[\"$v4\", \"$v6\"]"

    cat > "${probe_dir}/config.json" << EOF
{
  "log": {"disabled": true},
  "inbounds": [
    {"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": ${probe_port}}
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": ${addr_json},
      "private_key": "${private_key}",
      "peers": [
        {
          "address": "${peer_addr}",
          "port": ${port},
          "public_key": "${peer_pub}",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25,
          "reserved": ${reserved_json}
        }
      ]
    }
  ],
  "route": {"final": "wireguard-out"}
}
EOF

    "$sb_bin" run -c "${probe_dir}/config.json" >/dev/null 2>&1 &
    pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        if curl -x "socks5h://127.0.0.1:${probe_port}" -sm 4 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on'; then
            result=0
        fi
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$probe_dir"
    return $result
}

generate_warp_endpoint() {
    local quiet="${1:-}"
    local sb_bin="${work_dir}/sing-box"
    local endpoints_file="${conf_dir}/endpoints.json"
    local warp_info_file="${work_dir}/warp_account.json"

    [ ! -x "$sb_bin" ] && { [ -z "$quiet" ] && red "sing-box 二进制不存在，无法生成密钥"; return 1; }

    [ -z "$quiet" ] && yellow "正在生成独立 WARP WireGuard 密钥并注册到 Cloudflare...\n"

    local private_key public_key key_output
    key_output=$("$sb_bin" generate wg-keypair 2>/dev/null)
    private_key=$(echo "$key_output" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_output" | awk '/PublicKey:/ {print $2}')

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        key_output=$("$sb_bin" generate wireguard-keypair 2>/dev/null)
        private_key=$(echo "$key_output" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "$key_output" | awk '/PublicKey:/ {print $2}')
    fi

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        if command_exists openssl; then
            local tmp_key
            tmp_key=$(mktemp)
            if openssl genpkey -algorithm X25519 -out "$tmp_key" 2>/dev/null; then
                private_key=$(openssl pkey -in "$tmp_key" -outform DER 2>/dev/null | tail -c 32 | base64 -w0 2>/dev/null || openssl pkey -in "$tmp_key" -outform DER 2>/dev/null | tail -c 32 | base64)
                public_key=$(openssl pkey -in "$tmp_key" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 2>/dev/null || openssl pkey -in "$tmp_key" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
                rm -f "$tmp_key"
            else
                rm -f "$tmp_key"
            fi
        fi
    fi

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        [ -z "$quiet" ] && red "生成 WireGuard 密钥对失败"
        return 1
    fi

    local install_id fcm_token tos_date reg_response
    install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
    fcm_token="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
    tos_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    local out_family curl_family peer_addr
    out_family=$(detect_warp_out_family)
    if [ "$out_family" = "6" ]; then
        curl_family="-6"
        peer_addr="2606:4700:d0::a29f:c001"
        [ -z "$quiet" ] && yellow "检测到本机为IPv6单栈，注册与WARP Endpoint均改用IPv6\n"
    else
        curl_family="-4"
        peer_addr="162.159.192.1"
    fi

    local try=0 max_try=5
    while [ "$try" -lt "$max_try" ]; do
        try=$((try + 1))
        reg_response=$(curl "$curl_family" -sS -m 15 --tlsv1.2 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json" \
            -H "User-Agent: okhttp/3.12.1" \
            -H "CF-Client-Version: a-6.30-3596" \
            -d "{\"key\":\"${public_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${fcm_token}\",\"tos\":\"${tos_date}\",\"model\":\"PC\",\"serial_number\":\"${install_id}\",\"locale\":\"en_US\"}" 2>/dev/null)

        if echo "$reg_response" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
            break
        fi
        [ -z "$quiet" ] && yellow "第 ${try}/${max_try} 次注册未拿到有效IPv4地址，重试中..."
        sleep 2
    done

    if ! echo "$reg_response" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
        [ -z "$quiet" ] && red "Cloudflare WARP 注册失败：重试 ${max_try} 次均未拿到有效IPv4地址（可能网络受限、触发了Cloudflare限流，或 API 变更）"
        [ -z "$quiet" ] && echo "$reg_response" | head -c 300
        return 1
    fi

    local v4 v6 client_id peer_pub reserved_json device_id token
    v4=$(echo "$reg_response" | jq -r '.config.interface.addresses.v4 // empty')
    v6=$(echo "$reg_response" | jq -r '.config.interface.addresses.v6 // empty')
    client_id=$(echo "$reg_response" | jq -r '.config.client_id // empty')
    peer_pub=$(echo "$reg_response" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
    device_id=$(echo "$reg_response" | jq -r '.id // empty')
    token=$(echo "$reg_response" | jq -r '.token // empty')

    [[ "$v4" != */* ]] && v4="${v4}/32"
    if [ -n "$v6" ] && [[ "$v6" != */* ]]; then
        v6="${v6}/128"
    fi

    if [ -n "$client_id" ]; then
        local r_bytes
        r_bytes=$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 -N3 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
        if [ -n "$r_bytes" ]; then
            reserved_json=$(echo "$r_bytes" | awk '{printf "[%d, %d, %d]", $1, $2, $3}')
        else
            reserved_json="[0, 0, 0]"
        fi
    else
        reserved_json="[0, 0, 0]"
    fi

    local candidate_ports=(2408 4500 1701 500)
    local port ok_port=""
    for port in "${candidate_ports[@]}"; do
        [ -z "$quiet" ] && yellow "正在探测端口 ${port}...\n"
        if warp_probe_endpoint "$port" "$v4" "$v6" "$private_key" "$peer_pub" "$reserved_json" "$peer_addr"; then
            ok_port="$port"
            [ -z "$quiet" ] && green "  端口 ${port} 探测成功，数据可正常经WARP转发\n"
            break
        fi
        [ -z "$quiet" ] && yellow "  端口 ${port} 未探测成功，尝试下一个端口\n"
    done

    if [ -z "$ok_port" ]; then
        [ -z "$quiet" ] && red "已尝试全部候选端口(${candidate_ports[*]})均未探测成功，当前网络很可能封锁了出站UDP，WARP出站暂时无法使用\n"
        [ -z "$quiet" ] && yellow "配置已保留(端口 ${candidate_ports[0]})，网络环境变化后可到「5. 重新生成独立 WARP 密钥」重试\n"
    fi

    local final_port="${ok_port:-${candidate_ports[0]}}"
    if [ -n "$v6" ]; then
        cat > "$endpoints_file" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "$v4",
        "$v6"
      ],
      "private_key": "$private_key",
      "peers": [
        {
          "address": "$peer_addr",
          "port": $final_port,
          "public_key": "$peer_pub",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25,
          "reserved": $reserved_json
        }
      ]
    }
  ]
}
EOF
    else
        cat > "$endpoints_file" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "$v4"
      ],
      "private_key": "$private_key",
      "peers": [
        {
          "address": "$peer_addr",
          "port": $final_port,
          "public_key": "$peer_pub",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25,
          "reserved": $reserved_json
        }
      ]
    }
  ]
}
EOF
    fi

    printf '{"id":"%s","token":"%s","private_key":"%s","client_id":"%s","reserved":%s,"v4":"%s","v6":"%s","port":"%s"}\n' \
        "$device_id" "$token" "$private_key" "$client_id" "$reserved_json" "$v4" "${v6:-}" "$final_port" > "$warp_info_file"
    chmod 600 "$warp_info_file" 2>/dev/null

    if [ -n "$ok_port" ]; then
        [ -z "$quiet" ] && green "WARP 独立密钥注册成功！\n  IPv4: ${purple}${v4}${re}\n  端口: ${purple}${ok_port}${re}\n  reserved: ${purple}${reserved_json}${re}\n"
        return 0
    else
        return 1
    fi
}

ensure_warp_endpoint() {
    local endpoints_file="${conf_dir}/endpoints.json"
    if [ -f "$endpoints_file" ] && jq -e '.endpoints[]? | select(.tag=="wireguard-out")' "$endpoints_file" >/dev/null 2>&1; then
        return 0
    fi
    yellow "检测到尚未申请 WARP 出站密钥，正在按需向 Cloudflare 注册...\n"
    generate_warp_endpoint
    if [ -f "$endpoints_file" ] && jq -e '.endpoints[]? | select(.tag=="wireguard-out")' "$endpoints_file" >/dev/null 2>&1; then
        return 0
    fi
    red "WARP 密钥注册失败，未能生成 wireguard-out 出站\n"
    return 1
}

sys_warp_iface() {
    [ "$1" = "4" ] && echo "wgcf-v4" || echo "wgcf-v6"
}

cf_warp_register() {
    local family="${1:-4}"
    local sb_bin="${work_dir}/sing-box"
    local priv="" pub="" key_output

    if [ -x "$sb_bin" ]; then
        key_output=$("$sb_bin" generate wg-keypair 2>/dev/null)
        priv=$(echo "$key_output" | awk '/PrivateKey:/ {print $2}')
        pub=$(echo "$key_output" | awk '/PublicKey:/ {print $2}')
    fi

    if [ -z "$priv" ] || [ -z "$pub" ]; then
        command_exists wg || manage_packages install wireguard-tools
        if command_exists wg; then
            priv=$(wg genkey)
            pub=$(echo "$priv" | wg pubkey)
        fi
    fi

    if [ -z "$priv" ] || [ -z "$pub" ]; then
        red "生成 WireGuard 密钥对失败\n"
        return 1
    fi

    local install_id fcm_token tos_date reg_response try=0 curl_family
    install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
    fcm_token="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
    tos_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [ "$family" = "4" ]; then
        curl_family="-6"
    else
        curl_family="-4"
    fi

    while [ "$try" -lt 5 ]; do
        try=$((try + 1))
        reg_response=$(curl "$curl_family" -sS -m 15 --tlsv1.2 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json" \
            -H "User-Agent: okhttp/3.12.1" \
            -H "CF-Client-Version: a-6.30-3596" \
            -d "{\"key\":\"${pub}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${fcm_token}\",\"tos\":\"${tos_date}\",\"model\":\"PC\",\"serial_number\":\"${install_id}\",\"locale\":\"en_US\"}" 2>/dev/null)

        if echo "$reg_response" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
            break
        fi
        yellow "第 ${try}/5 次注册未拿到有效IPv4地址，重试中...\n"
        sleep 2
    done

    if ! echo "$reg_response" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
        red "Cloudflare WARP 注册失败：重试5次均未拿到有效IPv4地址（可能网络受限、触发了Cloudflare限流，或 API 变更），本次不会继续加装\n"
        echo "$reg_response" | head -c 300
        return 1
    fi

    REG_PRIV="$priv"
    REG_V4=$(echo "$reg_response" | jq -r '.config.interface.addresses.v4 // empty')
    REG_V6=$(echo "$reg_response" | jq -r '.config.interface.addresses.v6 // empty')
    REG_PEER=$(echo "$reg_response" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')

    if [ "$family" = "4" ]; then
        REG_ENDPOINT="[2606:4700:d0::a29f:c001]:2408"
    else
        REG_ENDPOINT="162.159.192.1:2408"
    fi

    return 0
}

sys_warp_write_conf() {
    local family="$1" iface addr_line endpoint allowed
    iface=$(sys_warp_iface "$family")
    mkdir -p "$sys_warp_dir"

    if [ "$family" = "4" ]; then
        endpoint="${REG_ENDPOINT:-[2606:4700:d0::a29f:c001]:2408}"
        allowed="0.0.0.0/0"
    else
        endpoint="${REG_ENDPOINT:-162.159.192.1:2408}"
        allowed="::/0"
    fi

    addr_line="${REG_V4}/32"
    [ -n "$REG_V6" ] && addr_line="${addr_line}, ${REG_V6}/128"

    cat > "${sys_warp_dir}/${iface}.conf" << EOF
[Interface]
PrivateKey = ${REG_PRIV}
Address = ${addr_line}
MTU = 1280

[Peer]
PublicKey = ${REG_PEER}
Endpoint = ${endpoint}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
EOF
    chmod 600 "${sys_warp_dir}/${iface}.conf"
}

sys_warp_enable_boot() {
    local iface="$1"
    if command_exists systemctl; then
        systemctl enable "wg-quick@${iface}" &>/dev/null
    elif command_exists crontab; then
        (crontab -l 2>/dev/null | grep -v "wg-quick up ${iface}"; echo "@reboot wg-quick up ${iface}") | crontab - 2>/dev/null
    else
        yellow "未检测到systemd/crontab，请手动确保开机执行: wg-quick up ${iface}\n"
    fi
}

sys_warp_disable_boot() {
    local iface="$1"
    command_exists systemctl && systemctl disable "wg-quick@${iface}" &>/dev/null
    command_exists crontab && { crontab -l 2>/dev/null | grep -v "wg-quick up ${iface}" | crontab - 2>/dev/null; }
}

sys_warp_status() {
    local f iface
    for f in 4 6; do
        iface=$(sys_warp_iface "$f")
        if [ -f "${sys_warp_dir}/${iface}.conf" ]; then
            if ip link show "$iface" &>/dev/null; then
                green "  ${iface}: ${green}运行中${re}\n"
            else
                yellow "  ${iface}: 配置已生成但接口未运行\n"
            fi
        else
            purple "  ${iface}: 未安装\n"
        fi
    done
}

sys_warp_verify_handshake() {
    local iface="$1" tries=0 rx
    while [ "$tries" -lt 5 ]; do
        rx=$(wg show "$iface" transfer 2>/dev/null | awk '{print $2}')
        if [ -n "$rx" ] && [ "$rx" != "0" ]; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

sys_warp_find_working_port() {
    local iface="$1" conf="$2" host="$3" ipv6_endpoint="$4" port
    local ports=(2408 500 4500 1701)
    for port in "${ports[@]}"; do
        if [ "$ipv6_endpoint" = "1" ]; then
            sed -i "s|^Endpoint = .*|Endpoint = [${host}]:${port}|" "$conf"
        else
            sed -i "s|^Endpoint = .*|Endpoint = ${host}:${port}|" "$conf"
        fi
        wg-quick down "$iface" &>/dev/null
        if ! wg-quick up "$iface" &>/dev/null; then
            continue
        fi
        yellow "  正在尝试端口 ${port}...\n"
        if sys_warp_verify_handshake "$iface"; then
            green "  端口 ${port} 握手成功，已收到Cloudflare回包\n"
            return 0
        fi
        yellow "  端口 ${port} 未收到回包，尝试下一个端口\n"
    done
    return 1
}

sys_warp_add() {
    local family="$1" iface
    iface=$(sys_warp_iface "$family")

    if [ -f "${sys_warp_dir}/${iface}.conf" ]; then
        reading "检测到 ${iface} 已存在配置，是否重新生成并覆盖？(y/n): " sw_overwrite
        echo ""
        if [[ "$sw_overwrite" != "y" && "$sw_overwrite" != "Y" ]]; then
            yellow "已取消\n"
            return
        fi
        wg-quick down "$iface" &>/dev/null
    fi

    command_exists wg || manage_packages install wireguard-tools
    command_exists wg-quick || manage_packages install wireguard-tools
    command_exists curl || manage_packages install curl
    command_exists jq || manage_packages install jq

    yellow "正在向 Cloudflare 注册独立 WARP 账号...\n"
    if ! cf_warp_register "$family"; then
        return 1
    fi

    sys_warp_write_conf "$family"

    yellow "正在启动 WARP 出站接口 ${iface}...\n"
    if ! wg-quick up "$iface" 2>&1; then
        red "\n接口启动失败，当前环境可能不支持内核WireGuard(常见于部分OpenVZ/LXC容器)，请更换支持WireGuard/TUN的VPS后重试\n"
        rm -f "${sys_warp_dir}/${iface}.conf"
        return 1
    fi

    yellow "正在验证隧道是否真正握手成功...\n"
    if sys_warp_verify_handshake "$iface"; then
        :
    else
        yellow "默认端口(2408)未收到回包，自动尝试其他端口...\n"
        local host_ip ipv6_flag
        if [ "$family" = "4" ]; then
            host_ip="2606:4700:d0::a29f:c001"; ipv6_flag=1
        else
            host_ip="162.159.192.1"; ipv6_flag=0
        fi
        if ! sys_warp_find_working_port "$iface" "${sys_warp_dir}/${iface}.conf" "$host_ip" "$ipv6_flag"; then
            red "\n已尝试全部候选端口(2408/500/4500/1701)均未收到Cloudflare回包，当前网络很可能封锁了出站UDP，WARP出站暂时无法使用\n"
            yellow "接口配置已保留在 ${sys_warp_dir}/${iface}.conf，网络环境变化后可重新进入本菜单覆盖重试\n"
            sys_warp_enable_boot "$iface"
            _sb_cache_clear
            return 1
        fi
    fi

    sys_warp_enable_boot "$iface"
    _sb_cache_clear

    green "\n✅ WARP 出站已加装成功！接口: ${purple}${iface}${re}，已设置开机自启\n"
    if [ "$family" = "4" ]; then
        local got_v4
        got_v4=$(fetch_ip 4 8)
        green "当前出口IPv4: ${purple}${got_v4:-获取失败，可稍后自行执行: curl -4 ip.sb 检查}${re}\n"
    else
        local got_v6
        got_v6=$(fetch_ip 6 8)
        green "当前出口IPv6: ${purple}${got_v6:-获取失败，可稍后自行执行: curl -6 ip.sb 检查}${re}\n"
    fi
}

sys_warp_remove() {
    local family="$1" iface
    iface=$(sys_warp_iface "$family")
    wg-quick down "$iface" &>/dev/null || true
    ip link del "$iface" 2>/dev/null || true
    sys_warp_disable_boot "$iface"
    if [ -f "${sys_warp_dir}/${iface}.conf" ]; then
        rm -f "${sys_warp_dir}/${iface}.conf"
        green "${iface} 出站已删除\n"
    else
        yellow "${iface} 未安装，无需删除\n"
    fi
    _sb_cache_clear
}

sys_warp_delete_menu() {
    clear; echo ""
    purple "=== 删除WARP出站 ===\n"
    green  "1. 删除IPv4 WARP出站(wgcf-v4)"
    green  "2. 删除IPv6 WARP出站(wgcf-v6)"
    red    "3. 全部删除"
    purple "0. 返回上级菜单"
    echo "==========================="
    reading "请输入选择(0-3): " sw_del_choice
    echo ""
    case "$sw_del_choice" in
        1) sys_warp_remove 4 ;;
        2) sys_warp_remove 6 ;;
        3) sys_warp_remove 4; sys_warp_remove 6 ;;
        0) system_warp_menu; return ;;
        *) red "无效选项\n" ;;
    esac
    read -n 1 -s -r -p $'\n按任意键返回...'
    system_warp_menu
}

system_warp_menu() {
    clear; echo ""
    purple "=== 单栈VPS加装WARP全局出站(IPv4/IPv6) ===\n"
    yellow "通过系统级WireGuard为纯IPv4/纯IPv6主机加装缺失协议栈的WARP出站，全局生效(非仅sing-box)\n\n"
    sys_warp_status
    echo ""
    green  "1. 纯IPv6VPS —— 加装IPv4 WARP出站"
    green  "2. 纯IPv4VPS —— 加装IPv6 WARP出站"
    red    "3. 删除WARP出站"
    purple "0. 返回主菜单"
    echo "==========================="
    reading "请输入选择(0-3): " sw_choice
    echo ""
    case "$sw_choice" in
        1) sys_warp_add 4; read -n 1 -s -r -p $'\n按任意键返回...'; system_warp_menu ;;
        2) sys_warp_add 6; read -n 1 -s -r -p $'\n按任意键返回...'; system_warp_menu ;;
        3) sys_warp_delete_menu ;;
        0) return ;;
        *) red "无效选项\n"; sleep 1; system_warp_menu ;;
    esac
}

regenerate_warp_keys() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi
    yellow "\n将向 Cloudflare 重新注册独立 WARP 设备并替换当前 wireguard-out 配置。\n"
    reading "确认继续？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        yellow "已取消。"; sleep 1; return
    fi
    if generate_warp_endpoint; then
        restart_singbox
        green "WARP 密钥已更新并重启 sing-box。\n"
    else
        red "注册失败，保持原有配置不变。\n"
    fi
    sleep 2
}

default_route_rule_sets_json() {
    jq -n '[
      {"tag":"gemini","type":"inline","rules":[{"domain_suffix":["gemini.google.com","generativelanguage.googleapis.com","aistudio.google.com","alkalimakersuite-pa.clients6.google.com"]}]},
      {"tag":"claude","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/anthropic.srs","download_detour":"direct"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
      {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
      {"tag":"telegram-ip","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs","download_detour":"direct"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
      {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"}
    ]'
}

write_default_route_json() {
    local resolver_tag=${1:-local}
    local dns_strategy=${2:-prefer_ipv4}
    local rule_sets
    rule_sets=$(default_route_rule_sets_json) || return 1
    jq -n \
        --argjson rule_set "$rule_sets" \
        --arg resolver "$resolver_tag" \
        --arg strategy "$dns_strategy" \
        '{
          route: {
            rule_set: $rule_set,
            rules: [{"action":"sniff"}],
            final: "direct",
            default_domain_resolver: {server: $resolver, strategy: $strategy}
          }
        }' > "${conf_dir}/route.json"
}

write_install_configs() {
    local uuid=$1 private_key=$2
    local vless_port=$3 hy2_port=$4 tuic_port=$5 argo_port=$6
    local dns_strategy=$7 resolver_tag=$8 sys_dns_server=$9

    jq -n \
        --arg out "${work_dir}/sb.log" \
        '{log:{disabled:false, level:"warn", output:$out, timestamp:true}}' \
        > "${conf_dir}/log.json"

    jq -n \
        '{ntp:{enabled:true, server:"time.apple.com", server_port:123, interval:"60m"}}' \
        > "${conf_dir}/ntp.json"

    jq -n \
        --arg sys "$sys_dns_server" \
        --arg strategy "$dns_strategy" \
        '{
          dns: {
            servers: [
              {tag:"sys", type:"udp", server:$sys},
              {tag:"local", type:"local"}
            ],
            strategy: $strategy
          }
        }' > "${conf_dir}/dns.json"

    jq -n \
        --arg uuid "$uuid" \
        --arg pk "$private_key" \
        --arg cert "${work_dir}/cert.pem" \
        --arg key "${work_dir}/private.key" \
        --argjson vless_port "$vless_port" \
        --argjson hy2_port "$hy2_port" \
        --argjson tuic_port "$tuic_port" \
        --argjson argo_port "$argo_port" \
        '{
          inbounds: [
            {
              type: "vless", tag: "vless-reality", listen: "::", listen_port: $vless_port,
              users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
              tls: {
                enabled: true, server_name: "www.iij.ad.jp",
                reality: {
                  enabled: true,
                  handshake: {server: "www.iij.ad.jp", server_port: 443},
                  private_key: $pk,
                  short_id: [""]
                }
              }
            },
            {
              type: "vmess", tag: "vmess-ws", listen: "::", listen_port: $argo_port,
              users: [{uuid: $uuid}],
              transport: {type: "ws", path: "/vmess-argo", early_data_header_name: "Sec-WebSocket-Protocol"}
            },
            {
              type: "hysteria2", tag: "hysteria2", listen: "::", listen_port: $hy2_port,
              users: [{password: $uuid}],
              ignore_client_bandwidth: false,
              masquerade: "https://bing.com",
              tls: {
                enabled: true, alpn: ["h3"], min_version: "1.3", max_version: "1.3",
                certificate_path: $cert, key_path: $key
              }
            },
            {
              type: "tuic", tag: "tuic", listen: "::", listen_port: $tuic_port,
              users: [{uuid: $uuid, password: $uuid}],
              congestion_control: "bbr",
              tls: {enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key}
            }
          ]
        }' > "${conf_dir}/inbounds.json"

    jq -n '{outbounds:[{type:"direct", tag:"direct"}]}' > "${conf_dir}/outbounds.json"

    write_default_route_json "$resolver_tag" "$dns_strategy"
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; return 1 ;;
    esac

    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 755 "${work_dir}" 2>/dev/null || true

    if ! releases_json=$(gh_fetch_json "https://api.github.com/repos/SagerNet/sing-box/releases"); then
        red "获取 sing-box 最新版本号失败，请检查服务器是否能访问 api.github.com\n"
        gh_ipv6_hint
        return 1
    fi
    latest_version=$(echo "$releases_json" | jq -r '[.[] | select(.prerelease==false)][0].tag_name // empty' | sed 's/^v//')
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        red "获取 sing-box 最新版本号失败，请检查服务器是否能访问 api.github.com\n"
        return 1
    fi
    if ! gh_download "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz" "${work_dir}/${server_name}.tar.gz"; then
        red "从 GitHub 下载 sing-box 二进制失败，请检查服务器是否能访问 github.com\n"
        gh_ipv6_hint
        return 1
    fi
    if ! tar -xzf "${work_dir}/${server_name}.tar.gz" -C "${work_dir}/"; then
        red "解压 sing-box 失败\n"
        return 1
    fi
    if ! mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}/sing-box" "${work_dir}/"; then
        red "移动 sing-box 二进制失败\n"
        return 1
    fi
    rm -rf "${work_dir}/${server_name}.tar.gz" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}"

    if [ -f /etc/alpine-release ]; then
        if ! apk info -e gcompat >/dev/null 2>&1; then
            yellow "\n检测到 Alpine (musl) 系统，正在安装 glibc 兼容层 gcompat...\n"
            apk add --no-cache gcompat >/dev/null 2>&1
            if ! apk info -e gcompat >/dev/null 2>&1; then
                red "gcompat 安装失败，官方sing-box二进制在Alpine上大概率无法运行，请手动执行: apk add gcompat 后重新运行本脚本安装\n"
                return 1
            fi
        fi
    fi

    case "${ARCH}" in
        'amd64') CF_ARCH='amd64' ;;
        '386')   CF_ARCH='386' ;;
        'arm64') CF_ARCH='arm64' ;;
        'armv7') CF_ARCH='arm' ;;
        *) CF_ARCH='' ;;
    esac
    if [ -z "$CF_ARCH" ]; then
        yellow "架构 ${ARCH} 官方 cloudflared 不提供预编译包，argo 隧道功能将不可用\n"
        : > "${work_dir}/argo"
    elif ! curl -fsSLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"; then
        red "从 GitHub 下载 cloudflared 失败，请检查服务器是否能访问 github.com\n"
        return 1
    fi

    curl -sLo "${work_dir}/qrencode" "https://github.com/eooce/test/releases/download/${ARCH}/qrencode-linux-${ARCH}" 2>/dev/null || true
    chown root:root "${work_dir}" 2>/dev/null || true
    chmod +x "${work_dir}/${server_name}" 2>/dev/null || true
    [ -f "${work_dir}/argo" ] && chmod +x "${work_dir}/argo" 2>/dev/null || true
    [ -f "${work_dir}/qrencode" ] && chmod +x "${work_dir}/qrencode" 2>/dev/null || true

    while ! is_port_free "$vless_port"; do
        vless_port=$(shuf -i 10000-65000 -n 1)
    done
    tuic_port=$(get_free_port 10000 65000)
    hy2_port=$(get_free_port 10000 65000)
    while [ "$tuic_port" = "$vless_port" ] || [ "$hy2_port" = "$vless_port" ] || \
          [ "$tuic_port" = "$hy2_port" ]; do
        tuic_port=$(get_free_port 10000 65000)
        hy2_port=$(get_free_port 10000 65000)
    done
    uuid=$(cat /proc/sys/kernel/random/uuid)
    output=$(/etc/sing-box/sing-box generate reality-keypair)
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        red "生成 reality 密钥对失败！/etc/sing-box/sing-box 二进制可能无法在本机正常执行。\n"
        yellow "请先手动执行 /etc/sing-box/sing-box version 排查(Alpine系统常见原因是缺少gcompat，可执行 apk add gcompat 后重试)。\n"
        return 1
    fi

    allow_port $vless_port/tcp $tuic_port/udp $hy2_port/udp > /dev/null 2>&1 || true

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" || { red "生成证书私钥失败"; return 1; }
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    chmod 600 "${work_dir}/private.key"

    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))

    resolver_tag="local"
    if ip link show 2>/dev/null | grep -qE '^[0-9]+: (wgcf-v[46]|[a-z]*clat[a-z0-9]*)[:@]'; then
        resolver_tag="sys"
    fi
    sys_dns_server=$(awk '/^nameserver[ \t]+/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
    if [ -z "$sys_dns_server" ]; then
        case "$dns_strategy" in
            prefer_ipv6) sys_dns_server="2606:4700:4700::1111" ;;
            *)           sys_dns_server="1.1.1.1" ;;
        esac
    fi

    write_install_configs "$uuid" "$private_key" "$vless_port" "$hy2_port" "$tuic_port" "${ARGO_PORT}" "$dns_strategy" "$resolver_tag" "$sys_dns_server"

}

# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --url http://localhost:$(get_argo_port) --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}

# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF

    cat > /etc/init.d/argo << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/sing-box/argo tunnel --url http://localhost:$(get_argo_port) --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
command_background=true
pidfile="/var/run/argo.pid"

depend() {
    need net
    after firewall
}
EOF

    chmod +x /etc/init.d/sing-box
    chmod +x /etc/init.d/argo
    rc-update add sing-box default > /dev/null 2>&1
    rc-update add argo default     > /dev/null 2>&1
}

# 生成节点和订阅链接
get_info() {
    yellow "\nip检测中,请稍等...\n"
    server_ip=$(get_realip)
    clear
    isp=$(get_isp || echo "$(hostname)")

    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..5}; do
            purple "第 $i 次尝试获取ArgoDoamin中..."
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
            [ -n "$argodomain" ] && break
            sleep 2
        done
    else
        restart_argo
        sleep 6
        argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    VMESS="{ \"v\": \"2\", \"ps\": \"${isp}-VMess-Argo\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"

    extra_lines=""
    if [ -f "${client_dir}" ]; then
        extra_lines=$(grep -vE '^(vless://|vmess://|hysteria2://|tuic://)' "${client_dir}" || true)
    fi

    cat > ${work_dir}/url.txt << EOF
vmess://$(echo "$VMESS" | base64 -w0)

vless://${uuid}@${server_ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${isp}-Reality

tuic://${uuid}:${uuid}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}-TUIC5

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${isp}-Hysteria2
EOF

    if [ -n "$extra_lines" ]; then
        echo "" >> "${work_dir}/url.txt"
        echo "$extra_lines" >> "${work_dir}/url.txt"
    fi

    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
    base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
    chmod 644 ${work_dir}/sub.txt
    yellow "\n温馨提醒:"
    yellow "如果节点里的ip是ipv6的，可在 修改节点配置 菜单切换ipv4后重新订阅节点\n"
    red "如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    green "以上节点链接可直接复制导入客户端。\n"
    green "sing-box也已生成base64订阅内容，保存在：${purple}${work_dir}/sub.txt${re}"
    green "如需以订阅方式导入，可将该文件内容复制粘贴到客户端的订阅内容中。\n"
}

get_argo_port() {
    local p
    p=$(jq -r '.inbounds[]? | select(.type=="vmess") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
    echo "${p:-${ARGO_PORT}}"
}

# 从已安装配置中获取UUID
get_current_uuid() {
    local inbounds_file="${conf_dir}/inbounds.json"
    if [ -f "$inbounds_file" ]; then
        local uuid
        uuid=$(jq -r '.inbounds[] | select(.type == "vless") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
        [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "vmess") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
        [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "hysteria2") | .users[0].password // empty' "$inbounds_file" 2>/dev/null | head -1)
        echo "$uuid"
    fi
}

# 通用服务管理函数
manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"; return 1
    fi

    local svc_file="${work_dir}/${service_name}"
    [ "$service_name" = "sing-box" ] && svc_file="${work_dir}/${server_name}"
    local installed=1 running=0
    [ -f "$svc_file" ] && installed=0
    service_is_running "$service_name" && running=1

    case "$action" in
        "start")
            [ "$installed" -ne 0 ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            [ "$running" -eq 1 ] && { yellow "${service_name} 正在运行\n"; return 0; }
            yellow "正在启动 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" start
            elif command_exists systemctl; then systemctl daemon-reload && systemctl start "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功启动\n" || red "${service_name} 服务启动失败\n"
            ;;
        "stop")
            [ "$installed" -ne 0 ] && { yellow "${service_name} 尚未安装！\n"; return 2; }
            [ "$running" -eq 0 ] && { yellow "${service_name} 未运行\n"; return 1; }
            yellow "正在停止 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" stop
            elif command_exists systemctl; then systemctl stop "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功停止\n" || red "${service_name} 服务停止失败\n"
            ;;
        "restart")
            [ "$installed" -ne 0 ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            yellow "正在重启 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" restart
            elif command_exists systemctl; then systemctl daemon-reload && systemctl restart "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功重启\n" || red "${service_name} 服务重启失败\n"
            ;;
        "reload")
            [ "$installed" -ne 0 ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            yellow "正在重载 ${service_name} 配置\n"
            if command_exists systemctl; then
                if systemctl is-active --quiet "$service_name" 2>/dev/null && systemctl reload "$service_name" 2>/dev/null; then
                    green "${service_name} 配置已重载\n"; return 0
                fi
                yellow "reload 不可用，改为 restart\n"
                systemctl restart "$service_name" 2>/dev/null
                [ $? -eq 0 ] && green "${service_name} 服务已重启\n" || red "${service_name} 服务重启失败\n"
            elif command_exists rc-service; then
                local pidfile="/var/run/${service_name}.pid" pid=""
                [ -f "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null)
                if [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null; then
                    green "${service_name} 配置已重载 (HUP)\n"; return 0
                fi
                yellow "HUP 不可用，改为 restart\n"
                rc-service "$service_name" restart
                [ $? -eq 0 ] && green "${service_name} 服务已重启\n" || red "${service_name} 服务重启失败\n"
            else
                manage_service "$service_name" "restart"
            fi
            ;;
        *)
            red "无效的操作: $action\n"; return 1 ;;
    esac
}

validate_singbox_config() {
    local sb_bin="${work_dir}/sing-box"
    [ -x "$sb_bin" ] || return 0
    "$sb_bin" check -C "${conf_dir}" 2>&1
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }

restart_singbox(){
    local check_output
    if [ -x "${work_dir}/sing-box" ]; then
        check_output=$(validate_singbox_config)
        if [ $? -ne 0 ]; then
            red "配置校验未通过，sing-box 未重启，当前仍在使用旧配置运行：\n"
            echo "$check_output"
            return 1
        fi
    fi
    manage_service "sing-box" "restart"
}

reload_singbox() {
    local check_output
    if [ -x "${work_dir}/sing-box" ]; then
        check_output=$(validate_singbox_config)
        if [ $? -ne 0 ]; then
            red "配置校验未通过，sing-box 未重载，当前仍在使用旧配置运行：\n"
            echo "$check_output"
            return 1
        fi
    fi
    manage_service "sing-box" "reload"
}

ensure_singbox_running() {
    local i
    for i in 1 2 3; do
        if command_exists rc-service; then
            rc-service sing-box restart >/dev/null 2>&1
        elif command_exists systemctl; then
            systemctl restart sing-box >/dev/null 2>&1
        fi
        sleep 2
        if service_is_running "sing-box"; then
            green "sing-box 运行正常\n"
            return 0
        fi
        sleep 2
    done
    red "sing-box 未能正常启动，请检查配置：\n"
    if command_exists systemctl; then
        journalctl -u sing-box -n 15 --no-pager 2>/dev/null
    else
        "${work_dir}/${server_name}" check -C "${conf_dir}" 2>&1 | tail -15
    fi
    return 1
}

start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }

# 卸载 sing-box（交互式）
stop_and_remove_services() {
    quota_service_stop >/dev/null 2>&1 || true
    if command_exists rc-service; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-service argo stop >/dev/null 2>&1 || true
        rc-update del sing-box default >/dev/null 2>&1 || true
        rc-update del argo default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    fi
    if command_exists systemctl; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        systemctl stop argo >/dev/null 2>&1 || true
        systemctl disable sing-box >/dev/null 2>&1 || true
        systemctl disable argo >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed sing-box >/dev/null 2>&1 || true
        systemctl reset-failed argo >/dev/null 2>&1 || true
    fi
}

cleanup_singbox_residuals() {
    rm -rf "${work_dir}" 2>/dev/null || true

    # 快捷命令
    rm -f /usr/bin/sb 2>/dev/null || true

    rm -rf "${TMPDIR:-/tmp}/sb-ip-cache" 2>/dev/null || true

    if [ -f /etc/sysctl.d/99-bbr-fq.conf ]; then
        rm -f /etc/sysctl.d/99-bbr-fq.conf
        sysctl --system >/dev/null 2>&1 || true
    fi
    rm -f /etc/modules-load.d/tcp_bbr.conf 2>/dev/null || true

    if [ -f /etc/init.d/iptables ] && grep -q 'iptables-restore < /etc/iptables/rules.v4' /etc/init.d/iptables 2>/dev/null; then
        if command_exists rc-update; then
            rc-update del iptables default >/dev/null 2>&1 || true
        fi
        rm -f /etc/init.d/iptables
    fi
}

cleanup_acme_if_needed() {
    local domain="$1"
    local acme="${HOME}/.acme.sh/acme.sh"
    [ -n "$domain" ] && [ -f "$acme" ] || return 0
    "$acme" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
    rm -rf "${HOME}/.acme.sh/${domain}_ecc" 2>/dev/null || true
}

# 卸载 sing-box（交互式）
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"

            local cert_domain=""
            [ -f "${work_dir}/cert_domain.txt" ] && cert_domain=$(cat "${work_dir}/cert_domain.txt" 2>/dev/null)

            close_node_firewall_ports
            close_port80_if_unused

            stop_and_remove_services
            cleanup_singbox_residuals

            if [ -f "${sys_warp_dir}/$(sys_warp_iface 4).conf" ] || [ -f "${sys_warp_dir}/$(sys_warp_iface 6).conf" ]; then
                sys_warp_remove 4 >/dev/null 2>&1
                sys_warp_remove 6 >/dev/null 2>&1
                green "系统级WARP出站已一并卸载\n"
            fi

            if [ -n "$cert_domain" ] && [ -f "${HOME}/.acme.sh/acme.sh" ]; then
                cleanup_acme_if_needed "$cert_domain"
                green "acme.sh 中 ${cert_domain} 证书已删除\n"
            fi

            green "\nsing-box 卸载成功\n\n" && exit 0
            ;;
        *) purple "已取消卸载操作\n\n" ;;
    esac
}

# 创建快捷指令
create_shortcut() {
    cat > "$work_dir/sb.sh" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://raw.githubusercontent.com/tbjpvn/sb-re/main/sing-box.sh) $1
EOF
    chmod +x "$work_dir/sb.sh"
    ln -sf "$work_dir/sb.sh" /usr/bin/sb
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建成功\n" || red "\n快捷指令创建失败\n"
}

# 适配alpine
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range' 2>/dev/null || true
    grep -qE '^127\.0\.0\.1[[:space:]]+localhost' /etc/hosts 2>/dev/null || echo "127.0.0.1   localhost" >> /etc/hosts
    grep -qE '^::1[[:space:]]+localhost' /etc/hosts 2>/dev/null || echo "::1         localhost" >> /etc/hosts
}

# 非交互静默安装（-i 参数）
auto_install() {
    check_singbox &>/dev/null
    if [ $? -eq 0 ]; then
        yellow "sing-box 已经安装，跳过安装流程。"
        exit 0
    fi

    green "开始无交互式安装 sing-box..."
    ensure_core_deps || { red "依赖安装失败"; exit 1; }
    install_singbox || { red "安装失败，已中止"; exit 1; }

    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
        change_hosts
        restart_singbox
        rc-service argo restart
    else
        red "不支持的 init 系统，安装中止。"
        exit 1
    fi

    verify_udp_listening
    get_info || yellow "节点信息生成出现问题，请稍后到菜单「查看节点信息」重试"
    create_shortcut
    green "\nsing-box 安装完成\n"
}

auto_uninstall() {
    green "开始无交互式卸载sing-box..."

    local cert_domain=""
    [ -f "${work_dir}/cert_domain.txt" ] && cert_domain=$(cat "${work_dir}/cert_domain.txt" 2>/dev/null)

    close_node_firewall_ports >/dev/null 2>&1 || true
    close_port80_if_unused >/dev/null 2>&1 || true

    stop_and_remove_services
    cleanup_singbox_residuals

    sys_warp_remove 4 >/dev/null 2>&1
    sys_warp_remove 6 >/dev/null 2>&1

    cleanup_acme_if_needed "$cert_domain"

    green "\nsing-box 已完全卸载!\n"
}

# 变更配置
change_config() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?

    if [ "$singbox_installed" -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return 10
    fi

    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    local _inb="${conf_dir}/inbounds.json" _pl="" _p _jump
    if [ -f "$_inb" ]; then
        _p=$(jq -r '[.inbounds[]? | select(.type=="vmess") | .listen_port][0] // empty' "$_inb" 2>/dev/null)
        [ -n "$_p" ] && _pl="${_pl}${yellow}argo:${re}${purple}${_p}${re}  "
        _p=$(jq -r '[.inbounds[]? | select(.type=="vless") | .listen_port][0] // empty' "$_inb" 2>/dev/null)
        [ -n "$_p" ] && _pl="${_pl}${yellow}reality:${re}${purple}${_p}${re}  "
        _p=$(jq -r '[.inbounds[]? | select(.type=="tuic") | .listen_port][0] // empty' "$_inb" 2>/dev/null)
        [ -n "$_p" ] && _pl="${_pl}${yellow}tuic5:${re}${purple}${_p}${re}  "
        _p=$(jq -r '[.inbounds[]? | select(.type=="hysteria2") | .listen_port][0] // empty' "$_inb" 2>/dev/null)
        if [ -n "$_p" ]; then
            _jump=$(grep -m1 '^hysteria2://' "$client_dir" 2>/dev/null | sed -n 's/.*[&?]mport=\([^#&]*\).*/\1/p' | sed 's/^[0-9]*,//')
            _pl="${_pl}${yellow}hysteria2:${re}${purple}${_p}${re}"
            [ -n "$_jump" ] && _pl="${_pl}(${yellow}跳跃:${re}${purple}${_jump}${re})"
        fi
    fi
    echo -e "${green}节点端口: ${re}${_pl:-无}\n\n"
    green "1. 修改端口"
    skyblue "------------"
    green "2. 修改UUID"
    skyblue "------------"
    green "3. 修改Reality伪装域名"
    skyblue "------------"
    green "4. 添加hysteria2端口跳跃"
    skyblue "------------"
    green "5. 删除hysteria2端口跳跃"
    skyblue "------------"
    green "6. 修改vmess-argo优选域名"
    skyblue "------------"
    green "7. 修改节点ip为ipv4"
    skyblue "------------"
    green "8. 修改节点ip为ipv6"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            echo ""
            green "1. 修改vless-reality端口"
            skyblue "------------"
            green "2. 修改hysteria2端口"
            skyblue "------------"
            green "3. 修改tuic端口"
            skyblue "------------"
            green "4. 修改vmess-argo端口"
            skyblue "------------"
            purple "0. 返回上一级菜单"
            skyblue "------------"
            reading "请输入选择: " choice
            local inbounds_file="${conf_dir}/inbounds.json"
            case "${choice}" in
                1)
                    new_port=$(prompt_port "\n请输入vless-reality端口 (回车跳过将使用随机端口): " 10000 65000 "" 1)
                    jq_write "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "vless").listen_port) = ($port | tonumber)'
                    reload_singbox
                    allow_port $new_port/tcp > /dev/null 2>&1
                    sed -i -E 's#(vless://[^@]*@(\[[0-9a-fA-F:]+\]|[^:]*)):[0-9]+#\1:'"$new_port"'#' $client_dir
                    update_subscription
                    print_client_urls
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    new_port=$(prompt_port "\n请输入hysteria2端口 (回车跳过将使用随机端口): " 10000 65000 "" 1)
                    jq_write "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "hysteria2").listen_port) = ($port | tonumber)'
                    reload_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i -E 's#(hysteria2://[^@]*@(\[[0-9a-fA-F:]+\]|[^:]*)):[0-9]+#\1:'"$new_port"'#' $client_dir
                    update_subscription
                    print_client_urls
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    new_port=$(prompt_port "\n请输入tuic端口 (回车跳过将使用随机端口): " 10000 65000 "" 1)
                    jq_write "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "tuic").listen_port) = ($port | tonumber)'
                    reload_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i -E 's#(tuic://[^@]*@(\[[0-9a-fA-F:]+\]|[^:]*)):[0-9]+#\1:'"$new_port"'#' $client_dir
                    update_subscription
                    print_client_urls
                    green "\ntuic端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                4)
                    new_port=$(prompt_port "\n请输入vmess-argo端口 (回车跳过将使用随机端口): " 10000 65000 "" 1)
                    jq_write "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "vmess").listen_port) = ($port | tonumber)'
                    allow_port $new_port/tcp > /dev/null 2>&1
                    if command_exists rc-service; then
                        grep -q "localhost:" /etc/init.d/argo && \
                            sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/init.d/argo && \
                            get_quick_tunnel && change_argo_domain
                    else
                        grep -q "localhost:" /etc/systemd/system/argo.service && \
                            sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/systemd/system/argo.service && \
                            get_quick_tunnel && change_argo_domain
                    fi
                    reload_singbox
                    green "\nvmess-argo端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                0) change_config ;;
                *) red "无效的选项，请输入 1 到 4" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID(直接回车随机生成UUID): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            jq_write "${conf_dir}/inbounds.json" --arg uuid "$new_uuid" \
               '(.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.users != null) | .users[] | select(.password != null).password) = $uuid'
            reload_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/|anytls:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i -E "s#tuic://[0-9a-f-]{36}:[0-9a-f-]{36}@#tuic://$new_uuid:$new_uuid@#g" $client_dir
            local old_vmess new_vmess_b64
            old_vmess=$(grep -m1 '^vmess://' "$client_dir")
            if [ -n "$old_vmess" ]; then
                new_vmess_b64=$(printf '%s' "${old_vmess#vmess://}" | base64 -d 2>/dev/null | jq -c --arg id "$new_uuid" '.id = $id' | base64 -w0)
                if [ -n "$new_vmess_b64" ]; then
                    sed -i -E "s#^vmess://.*#vmess://${new_vmess_b64}#" "$client_dir"
                else
                    yellow "vmess 链接解析失败，未更新 vmess 节点的 UUID"
                fi
            fi
            update_subscription
            print_client_urls
            green "\nUUID已修改为：${purple}${new_uuid}${re}\n"
            ;;
        3)
            clear
            green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): " new_sni
            case "$new_sni" in
                ""|"1") new_sni="www.joom.com" ;;
                "2") new_sni="www.stengg.com" ;;
                "3") new_sni="www.wedgehr.com" ;;
                "4") new_sni="www.cerebrium.ai" ;;
                "5") new_sni="www.nazhumi.com" ;;
            esac
            jq_write "${conf_dir}/inbounds.json" --arg sni "$new_sni" \
               '(.inbounds[] | select(.type == "vless") | .tls.server_name) = $sni |
                (.inbounds[] | select(.type == "vless") | .tls.reality.handshake.server) = $sni'
            reload_singbox
            sed -i "s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*sni=\)[^&]*/\1$new_sni/" $client_dir
            update_subscription
            print_client_urls
            green "\nReality sni已修改为：${purple}${new_sni}${re}\n"
            ;;
        4)
            purple "端口跳跃需确保跳跃区间的端口没有被占用\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100))
            yellow "你的结束端口为：$max_port\n"
            listen_port=$(jq -r '.inbounds[] | select(.type == "hysteria2").listen_port' "${conf_dir}/inbounds.json")
            iptables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            command_exists ip6tables && ip6tables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            if command_exists rc-service 2>/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                command_exists ip6tables && ip6tables-save > /etc/iptables/rules.v6
                cat << 'IEOF' > /etc/init.d/iptables
#!/sbin/openrc-run
depend() { need net; }
start() {
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    command -v ip6tables >/dev/null 2>&1 && [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
    return 0
}
IEOF
                chmod +x /etc/init.d/iptables && rc-update add iptables default && /etc/init.d/iptables start
            elif [ -f /etc/debian_version ]; then
                DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1 && netfilter-persistent save > /dev/null 2>&1
                systemctl enable netfilter-persistent > /dev/null 2>&1 && systemctl start netfilter-persistent > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                manage_packages install iptables-services > /dev/null 2>&1 && service iptables save > /dev/null 2>&1
                systemctl enable iptables > /dev/null 2>&1 && systemctl start iptables > /dev/null 2>&1
                command_exists ip6tables && service ip6tables save > /dev/null 2>&1
                systemctl enable ip6tables > /dev/null 2>&1 && systemctl start ip6tables > /dev/null 2>&1
            fi
            local hy2_line new_hy2 tmp_url
            hy2_line=$(grep -m1 '^hysteria2://' "$client_dir")
            if [ -z "$hy2_line" ]; then
                red "\n未在订阅中找到 hysteria2 节点，跳跃端口规则已添加但链接未更新\n"
            else
                hy2_line=$(printf '%s' "$hy2_line" | sed -E 's/[&?]mport=[^#&]*//g')
                if printf '%s' "$hy2_line" | grep -q '#'; then
                    new_hy2="${hy2_line%%#*}&mport=${listen_port},${min_port}-${max_port}#${hy2_line#*#}"
                else
                    new_hy2="${hy2_line}&mport=${listen_port},${min_port}-${max_port}"
                fi
                tmp_url=$(mktemp)
                awk -v new="$new_hy2" '
                    /^hysteria2:\/\// { if (!done) { print new; done=1 } ; next }
                    { print }
                ' "$client_dir" > "$tmp_url" && cat "$tmp_url" > "$client_dir"
                rm -f "$tmp_url"
                update_subscription
                print_client_urls
            fi
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            iptables -t nat -F PREROUTING > /dev/null 2>&1
            command_exists ip6tables && ip6tables -t nat -F PREROUTING > /dev/null 2>&1
            if command_exists rc-service 2>/dev/null; then
                rc-update del iptables default && rm -rf /etc/init.d/iptables
            elif [ -f /etc/debian_version ]; then
                netfilter-persistent save > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                service iptables save > /dev/null 2>&1
                command_exists ip6tables && service ip6tables save > /dev/null 2>&1
            fi
            sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
            update_subscription
            green "\n端口跳跃已删除\n"
            ;;
        6) change_cfip ;;
        7)  
            local new_ipv4
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv4=$(fetch_ip 4)
            if ! printf '%s' "$new_ipv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                red "\n错误: 获取 IPv4 失败: $new_ipv4\n"
                return 1
            fi
            if is_warp_org 4; then
                red "\n当前服务器的ipv4: $new_ipv4 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@\[[0-9a-fA-F:]+\]' "$client_dir"; then
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@\[[0-9a-fA-F:]+\]#@${new_ipv4}#g" "$client_dir"
                green "\n已将 IPv6 修改为 IPv4: $new_ipv4 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv4, 无需切换\n" && return 0
            fi
            update_subscription
           ;;
        8) 
            local new_ipv6
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv6=$(fetch_ip 6 3)
            if ! printf '%s' "$new_ipv6" | grep -Eq '^[0-9a-fA-F:]+$'; then
                red "\n当前服务器没有可用的ipv6\n"
                return 1
            fi
            if is_warp_org 6; then
                red "\n当前服务器的ipv6 $new_ipv6 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "$client_dir"; then
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@(([0-9]{1,3}\.){3}[0-9]{1,3})#@[${new_ipv6}]#g" "$client_dir"
                green "\n已将 IPv4 修改为 IPv6: [${new_ipv6}] 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv6, 无需切换\n" && return 0
            fi
            update_subscription
           ;;
        0) return 10 ;;
        *) red "无效的选项！\n" ;;
    esac
}

# singbox 管理
manage_singbox() {
    local singbox_status=$(check_singbox 2>/dev/null)
    clear; echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 启动sing-box服务"
    skyblue "-------------------"
    green "2. 停止sing-box服务"
    skyblue "-------------------"
    green "3. 重启sing-box服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) menu ;;
        *) red "无效的选项！" && sleep 1 && manage_singbox ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n'
}

# Argo 管理
manage_argo() {
    local argo_status=$(check_argo 2>/dev/null)
    clear; echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 重启Argo服务"
    skyblue "------------"
    green "4. 添加Argo固定隧道"
    skyblue "----------------"
    green "5. 切换回Argo临时隧道"
    skyblue "------------------"
    green "6. 重新获取Argo临时域名"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_argo ;;
        2) stop_argo ;;
        3)
            clear
            if command_exists rc-service 2>/dev/null; then
                grep -Fq -- '--url http://localhost' /etc/init.d/argo && get_quick_tunnel && change_argo_domain || \
                    { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            else
                grep -q 'ExecStart=.*--url http://localhost' /etc/systemd/system/argo.service && get_quick_tunnel && change_argo_domain || \
                    { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            fi
            ;;
        4)
            clear
            yellow "\n固定隧道可为json或token，固定隧道端口为$(get_argo_port), 使用token请在cloudflare里设置一致\njson获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
            reading "\n请输入你的argo域名: " argo_domain
            ArgoDomain=$argo_domain
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo $argo_auth > ${work_dir}/tunnel.json
                cat > ${work_dir}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ArgoDomain
    service: http://localhost:$(get_argo_port)
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if command_exists rc-service 2>/dev/null; then
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1'\''"' /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 1; change_argo_domain
            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                if command_exists rc-service 2>/dev/null; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth 2>&1'\"" /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 1; change_argo_domain
            else
                yellow "输入不匹配，请重新输入"; manage_argo
            fi
            ;;
        5)
            clear
            if command_exists rc-service 2>/dev/null; then alpine_openrc_services
            else main_systemd_services; fi
            get_quick_tunnel; change_argo_domain
            ;;
        6)
            if command_exists rc-service 2>/dev/null; then
                grep -Fq -- '--url http://localhost' "/etc/init.d/argo" && get_quick_tunnel && change_argo_domain || \
                    { yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu; }
            else
                grep -q 'ExecStart=.*--url http://localhost' "/etc/systemd/system/argo.service" && get_quick_tunnel && change_argo_domain || \
                    { yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu; }
            fi
            ;;
        0) return 10 ;;
        *) red "无效的选项！" ;;
    esac
}

# 获取argo临时隧道
get_quick_tunnel() {
    restart_argo
    yellow "获取临时argo域名中，请稍等...\n"
    sleep 3
    if [ -f /etc/sing-box/argo.log ]; then
        for i in {1..5}; do
            purple "第 $i 次尝试获取ArgoDoamin中..."
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "/etc/sing-box/argo.log")
            [ -n "$get_argodomain" ] && break
            sleep 2
        done
    else
        restart_argo; sleep 6
        get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "/etc/sing-box/argo.log")
    fi
    green "ArgoDomain：${purple}$get_argodomain${re}\n"
    ArgoDomain=$get_argodomain
}

# 更新Argo域名到订阅
change_argo_domain() {
    content=$(cat "$client_dir")
    vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
    vmess_prefix="vmess://"
    encoded_vmess="${vmess_url#"$vmess_prefix"}"
    decoded_vmess=$(echo "$encoded_vmess" | base64 -d 2>/dev/null)
    updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain')
    encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
    new_vmess_url="${vmess_prefix}${encoded_updated_vmess}"
    new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
    echo "$new_content" > "$client_dir"
    update_subscription
    green "vmess节点已更新\n"
    purple "$new_vmess_url\n"
}

# 查看节点信息和订阅链接
check_nodes() {
    if [ ! -f "${work_dir}/url.txt" ]; then
        red "节点信息文件不存在，请先安装 sing-box"; return 1
    fi

    clear; echo ""
    green "=== 当前节点信息 ===\n"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
        [ -x "${work_dir}/qrencode" ] && echo "$line" | grep -qE '^(vless|vmess|hysteria2|tuic)://' && "${work_dir}/qrencode" "$line"
    done < "${work_dir}/url.txt"

    yellow "\n温馨提醒: 如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    update_subscription
    green "以上节点链接可直接复制导入客户端。"
    green "base64订阅内容已保存到: ${purple}${work_dir}/sub.txt${re}，如需以订阅方式导入，可复制该文件内容粘贴到客户端。\n"
}

change_cfip() {
    clear
    yellow "修改vmess-argo优选域名\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入你的优选域名或优选IP\n(请输入1至6选项,可输入域名:端口 或 IP:端口,直接回车默认使用1): " cfip_input

    case "$cfip_input" in
        ""|"1") cfip="cf.090227.xyz";          cfport="443" ;;
        "2")    cfip="cf.877774.xyz";           cfport="443" ;;
        "3")    cfip="cf.877771.xyz";           cfport="443" ;;
        "4")    cfip="cdns.doon.eu.org";        cfport="443" ;;
        "5")    cfip="cf.zhetengsha.eu.org";    cfport="443" ;;
        "6")    cfip="time.is";                 cfport="443" ;;
        *)
            if [[ "$cfip_input" =~ : ]]; then
                cfip=$(echo "$cfip_input" | cut -d':' -f1)
                cfport=$(echo "$cfip_input" | cut -d':' -f2)
            else
                cfip="$cfip_input"; cfport="443"
            fi
            ;;
    esac

    content=$(cat "$client_dir")
    vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
    encoded_part="${vmess_url#vmess://}"
    decoded_json=$(echo "$encoded_part" | base64 -d 2>/dev/null)
    updated_json=$(echo "$decoded_json" | jq --arg cfip "$cfip" --argjson cfport "$cfport" '.add = $cfip | .port = $cfport')
    new_encoded_part=$(echo "$updated_json" | base64 -w0)
    new_vmess_url="vmess://$new_encoded_part"
    new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
    echo "$new_content" > "$client_dir"
    update_subscription
    green "\nvmess节点优选域名已更新为：${purple}${cfip}:${cfport}${re}\n"
    purple "$new_vmess_url\n"
}

test_warp_connectivity() {
    local sb_bin="${work_dir}/sing-box"
    local test_port tmp_dir pid

    clear
    green "=== 测试 WARP 连通性 ===\n"
    yellow "说明：服务器本机直接 curl 不会经过 sing-box，因此会："
    yellow "  1. 另起一个独立的临时 sing-box 进程(仅监听 127.0.0.1)"
    yellow "  2. 该进程全局走 wireguard-out，用 curl 通过它测试出口"
    yellow "  3. 测试结束后自动清理；正在运行的 sing-box 与现有配置不受任何影响\n"

    if ! ensure_warp_endpoint; then
        red "WARP 密钥不可用，无法测试连通性\n"; sleep 2; return
    fi
    [ -x "$sb_bin" ] || { red "sing-box 二进制不存在\n"; sleep 2; return; }

    test_port=$(get_free_port 20000 40000)
    tmp_dir=$(mktemp -d /tmp/singbox-warptest.XXXXXX) || { red "创建临时目录失败\n"; return; }

    cp "${conf_dir}/endpoints.json" "${tmp_dir}/endpoints.json"
    if [ -f "${conf_dir}/dns.json" ]; then
        cp "${conf_dir}/dns.json" "${tmp_dir}/dns.json"
    else
        jq -n '{dns:{servers:[{tag:"sys",type:"local"}],strategy:"prefer_ipv4"}}' > "${tmp_dir}/dns.json"
    fi
    jq -n --argjson p "$test_port" '{inbounds:[{type:"socks",tag:"socks-warptest",listen:"127.0.0.1",listen_port:$p}]}' > "${tmp_dir}/inbounds.json"
    jq -n '{outbounds:[{type:"direct",tag:"direct"}]}' > "${tmp_dir}/outbounds.json"
    jq -n '{log:{level:"warn",output:"box.log"}}' > "${tmp_dir}/log.json"
    jq -n '{route:{rules:[{action:"sniff"}],final:"wireguard-out",default_domain_resolver:{server:"sys",strategy:"prefer_ipv4"}}}' > "${tmp_dir}/route.json"

    local check_output
    if ! check_output=$("$sb_bin" check -C "$tmp_dir" 2>&1); then
        red "临时测试配置校验失败：\n"; echo "$check_output"
        rm -rf "$tmp_dir"; sleep 2; return
    fi

    (cd "$tmp_dir" && exec "$sb_bin" run -C "$tmp_dir" >/dev/null 2>&1) &
    pid=$!
    sleep 3

    green "正在通过 socks5://127.0.0.1:${test_port} 测试 WARP 出口...\n"
    local ip_result warp_result
    ip_result=$(curl -4 -x "socks5h://127.0.0.1:${test_port}" -sm 12 https://ip.sb 2>/dev/null)
    warp_result=$(curl -4 -x "socks5h://127.0.0.1:${test_port}" -sm 12 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|warp|colo)=')

    echo ""
    if [ -n "$ip_result" ]; then
        green "出口 IP: ${purple}${ip_result}${re}"
    else
        red "获取出口 IP 失败（超时或连接失败）"
    fi
    if [ -n "$warp_result" ]; then
        echo "$warp_result" | while read -r line; do
            if echo "$line" | grep -q "warp=on"; then
                green "$line"
            else
                yellow "$line"
            fi
        done
    fi

    if echo "$warp_result" | grep -q "warp=on"; then
        green "\n✅ WARP 连通正常！"
    else
        red "\n❌ WARP 未生效。请检查："
        yellow "  - 是否已重新生成独立 WARP 密钥"
        yellow "  - 临时进程日志: ${tmp_dir}/box.log (本次退出前显示如下)"
        tail -n 10 "${tmp_dir}/box.log" 2>/dev/null
        yellow "  - endpoints.json 中 peer 地址/端口是否可达"
    fi

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$tmp_dir"
    green "\n临时测试进程已清理，现有配置未改动。\n"
    read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m\n'
    warp_manage
}

# WARP 分流管理
warp_manage() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear
    route_file="${conf_dir}/route.json"
    outbound_file="${conf_dir}/outbounds.json"

    echo ""
    green "=== WARP 分流管理 ===\n"
    green "当前已启用的分流规则集:"
    jq -r '
      .route.rules[]
      | select(.rule_set != null and .outbound != null)
      | . as $r
      | ($r.rule_set - ["telegram-ip"]) as $tags
      | select(($tags | length) > 0)
      | "\($tags | join(", "))\t\(if $r.override_address != null then "ProxyIP:" + $r.override_address else $r.outbound end)"
    ' "$route_file" 2>/dev/null | while IFS=$'\t' read -r tags outb; do
        echo -e " - ${skyblue}${tags}${re} ${purple}->${re} ${yellow}${outb}${re}"
    done
    if ! jq -e '.route.rules[]? | select(.rule_set != null and .outbound != null)' "$route_file" >/dev/null 2>&1; then
        echo "  无"
    fi
    cur_final=$(jq -r '.route.final // empty' "$route_file" 2>/dev/null)
    if [ -n "$cur_final" ] && [ "$cur_final" != "direct" ]; then
        echo -e "\n${green}全局代理出站(其余流量): ${purple}${cur_final}${re}"
    fi
    green "\n已添加的出站(代理socks/http/ss2022 及 本地IP直出):"
    if jq -e '.outbounds' "$outbound_file" >/dev/null 2>&1; then
        jq -r '.outbounds[] | select(.tag != "direct") | "\(.tag)\t\(.type)"' "$outbound_file" 2>/dev/null | while IFS=$'\t' read -r o_tag o_type; do
            echo -e " - ${yellow}${o_tag}${re} [${o_type}]$(quota_tag_flag "$o_tag")"
        done
    else
        echo "  无"
    fi

    echo ""
    green "1. 设置分流服务 (未添加代理出站直接设置则使用WARP)"
    skyblue "----------------------"
    red "2. 删除分流服务"
    skyblue "--------------"
    green "3. 添加代理出站 (Socks5/HTTP/SS2022)"
    skyblue "----------------------"
    green "4. 添加本地IP出站 (多IP机器选择出口IP)"
    skyblue "----------------------"
    red "5. 删除出站 (代理出站/本地IP出站)"
    skyblue "----------------------"
    green "6. 重新生成独立WARP密钥"
    skyblue "----------------------"
    green "7. 测试WARP连通性（推荐）"
    skyblue "----------------------"
    green "8. 代理流量限制 (定时流量上限，超限切断)"
    skyblue "----------------------"
    green "9. 添加公共ProxyIP分流 (仅限CF托管站点，输入域名/IP即可)"
    skyblue "----------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    purple "00. 退出脚本"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)  add_rule_menu ;;
        2)  delete_rule_menu ;;
        3)  add_socks5_proxy ;;
        4)  add_local_ip_outbound ;;
        5)  delete_socks5_proxy ;;
        6)  regenerate_warp_keys; warp_manage ;;
        7)  test_warp_connectivity ;;
        8)  quota_menu ;;
        9)  add_proxyip_route ;;
        0)  menu ;;
        00) exit 0 ;;
        *)  red "无效选项"; sleep 1; warp_manage ;;
    esac
}

add_rule_menu() {
    clear
    green "选择要分流的服务:\n"
    green "1.  OpenAI"
    green "2.  Claude"
    green "3.  Gemini"
    green "4.  Google"
    green "5.  Tiktok"
    green "6.  Twitter"
    green "7.  YouTube"
    green "8.  Netflix"
    green "9.  Telegram"
    skyblue "-----------------------------"
    green "10. 设置全局代理出站 (所有流量走指定代理)"
    green "11. 恢复服务器原IP出站 (所有流量走服务器ip)"
    skyblue "-----------------------------"
    green "12. 自定义分流 (自定义名称+域名，含下级域名)"
    skyblue "-----------------------------"
    purple "0.  返回上级菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " add_choice
    case "$add_choice" in
        1)  rule_tag="openai"   ;;
        2)  rule_tag="claude"   ;;
        3)  rule_tag="gemini"   ;;
        4)  rule_tag="google"   ;;
        5)  rule_tag="tiktok"   ;;
        6)  rule_tag="twitter"  ;;
        7)  rule_tag="youtube"  ;;
        8)  rule_tag="netflix"  ;;
        9)  rule_tag="telegram" ;;
        10) set_global_outbound; return ;;
        11) restore_direct_outbound; return ;;
        12) custom_rule_menu; return ;;
        0)  warp_manage; return ;;
        *)  red "无效选项"; sleep 1; add_rule_menu; return ;;
    esac

    finalize_rule_add "$rule_tag"
}

custom_rule_menu() {
    clear
    green "=== 自定义分流规则 ===\n"
    reading "请输入自定义规则名称(仅限字母/数字/下划线/中横线，用于标识该规则): " custom_name

    if [ -z "$custom_name" ]; then
        red "名称不能为空"; sleep 1; add_rule_menu; return
    fi

    local custom_tag
    custom_tag=$(echo "$custom_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')

    if [ -z "$custom_tag" ]; then
        red "名称无效"; sleep 1; add_rule_menu; return
    fi

    case "$custom_tag" in
        openai|claude|gemini|google|tiktok|twitter|youtube|netflix|telegram|telegram-ip)
            red "该名称与内置服务保留字冲突，请换一个名称"; sleep 1; custom_rule_menu; return ;;
    esac

    if jq -e --arg tag "$custom_tag" '.route.rule_set[]? | select(.tag == $tag)' "$route_file" >/dev/null 2>&1; then
        yellow "名称 '${custom_tag}' 已存在，请换一个名称，或先在「2. 删除分流服务」中移除旧规则"
        sleep 2; custom_rule_menu; return
    fi

    echo ""
    yellow "请输入要分流的域名，多个域名用空格或逗号分隔"
    yellow "示例: example.com openai.com sub.example.com"
    yellow "提示: 填写 example.com 会自动匹配其所有下级域名 (如 www.example.com、api.example.com)\n"
    reading "域名列表: " domain_input

    if [ -z "$domain_input" ]; then
        red "域名不能为空"; sleep 1; add_rule_menu; return
    fi

    domain_input="${domain_input//,/ }"
    local domains=()
    local d
    for d in $domain_input; do
        d=$(echo "$d" | xargs)
        [ -z "$d" ] && continue
        if ! [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            yellow "跳过无效域名: $d"
            continue
        fi
        domains+=("$d")
    done

    if [ ${#domains[@]} -eq 0 ]; then
        red "没有有效的域名，已取消"; sleep 1; add_rule_menu; return
    fi

    local domains_json
    domains_json=$(printf '%s\n' "${domains[@]}" | jq -R . | jq -s .)

    jq_write "$route_file" --arg tag "$custom_tag" --argjson domains "$domains_json" \
        '.route.rule_set += [{"tag": $tag, "type": "inline", "rules": [{"domain_suffix": $domains}]}]'

    green "\n已创建自定义分流规则 '${custom_tag}'，包含域名: ${domains[*]}\n"

    finalize_rule_add "$custom_tag"
}

finalize_rule_add() {
    local rule_tag="$1"

    if [ "$rule_tag" = "telegram" ]; then
        if jq -e '.route.rules[] | select(.rule_set != null) | .rule_set[]? | select(. == "telegram" or . == "telegram-ip")' \
            "$route_file" > /dev/null 2>&1; then
            yellow "规则集 'telegram' 已启用。"; sleep 1; warp_manage; return
        fi
    elif jq -e --arg tag "$rule_tag" \
        '.route.rules[] | select(.rule_set != null) | .rule_set[]? | select(. == $tag)' \
        "$route_file" > /dev/null 2>&1; then
        yellow "规则集 '${rule_tag}' 已启用。"; sleep 1; warp_manage; return
    fi

    if ! jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$route_file" > /dev/null 2>&1; then
        local builtin_defs matched_count
        builtin_defs=$(default_route_rule_sets_json 2>/dev/null)
        matched_count=$(echo "$builtin_defs" | jq --arg tag "$rule_tag" '[.[] | select(.tag == $tag)] | length' 2>/dev/null)
        if [ "$matched_count" = "1" ] && jq_write "$route_file" --argjson defs "$builtin_defs" --arg tag "$rule_tag" \
            '.route.rule_set += [$defs[] | select(.tag == $tag)]'; then
            yellow "规则集 '${rule_tag}' 的定义缺失，已自动补回。"
        else
            red "规则集 '${rule_tag}' 不存在，或自动补回失败，无法启用。"
            yellow "请使用「12. 自定义分流」重新创建该规则，或检查 route.json 是否有其他问题。"
            sleep 2; warp_manage; return
        fi
    fi

    jq_write "$route_file" '
      .route.rules = (
        [{"action":"sniff"}]
        + [
            .route.rules[]?
            | select(
                (.action != "sniff")
                and (
                  (.rule_set | type) != "array"
                  or (.rule_set | length) > 0
                )
              )
          ]
      )
    '

    local out_tags=($(jq -r '.outbounds[] | select(.tag != "direct") | .tag' "$outbound_file" 2>/dev/null))
    if [ ${#out_tags[@]} -eq 0 ]; then
        if ! ensure_warp_endpoint; then
            red "WARP 出站不可用，本次分流设置已取消，请检查网络后重试，或先添加其他代理出站。"
            sleep 2; warp_manage; return
        fi
        selected_out="wireguard-out"
        yellow "未找到其他出站，将自动使用 wireguard-out。"
    else
        echo ""
        green "请选择分流流量要走的出站:(直接回车使用warp分流)"
        for i in "${!out_tags[@]}"; do
            echo -e "  ${green}$((i+1)). ${skyblue}${out_tags[$i]}${re}"
        done
        echo -e "  ${purple}0. 返回上级菜单${re}"
        reading "请输入编号: " out_choice
        if [ -z "$out_choice" ]; then
            if ! ensure_warp_endpoint; then
                red "WARP 出站不可用，本次分流设置已取消，请检查网络后重试。"
                sleep 2; warp_manage; return
            fi
            selected_out="wireguard-out"
        elif [ "$out_choice" = "0" ]; then
            yellow "已取消"; sleep 1; warp_manage; return
        elif [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
           [ "$out_choice" -lt 1 ] || \
           [ "$out_choice" -gt "${#out_tags[@]}" ]; then
            red "无效选择"; sleep 1; warp_manage; return
        else
            selected_out="${out_tags[$((out_choice-1))]}"
        fi
    fi

    local tags_to_add=("$rule_tag")
    if [ "$rule_tag" = "telegram" ]; then
        tags_to_add=("telegram" "telegram-ip")
        if ! jq -e '.route.rule_set[]? | select(.tag == "telegram-ip")' "$route_file" >/dev/null 2>&1; then
            jq_write "$route_file" '.route.rule_set += [{"tag":"telegram-ip","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs","download_detour":"direct"}]'
        fi
    fi

    for tag in "${tags_to_add[@]}"; do
        if jq -e --arg tag "$tag" \
            '.route.rules[] | select(.rule_set != null) | .rule_set[]? | select(. == $tag)' \
            "$route_file" >/dev/null 2>&1; then
            continue
        fi
        jq_write "$route_file" --arg tag "$tag" --arg out "$selected_out" '
            .route.rules = (
              [{"action":"sniff"}]
              + (
                  [ .route.rules[]? | select(.action != "sniff") ]
                  | if (map(select(.outbound == $out)) | length) > 0 then
                      map(if .outbound == $out then .rule_set += [$tag] else . end)
                    else
                      . + [{"rule_set": [$tag], "outbound": $out}]
                    end
                )
            )
        '
    done

    reload_singbox
    if [ "$rule_tag" = "telegram" ]; then
        green "'telegram' 已分流至出站 '${selected_out}'（已自动包含 IP 规则）"
    else
        green "'${rule_tag}' 已分流至出站 '${selected_out}'"
    fi
    if [ "$selected_out" = "wireguard-out" ]; then
        yellow "提示：请用客户端连接节点后访问对应网站验证；也可到「7. 测试 WARP 连通性」一键检测。"
    fi
    sleep 2; warp_manage
}

# 设置全局代理出站
set_global_outbound() {
    local proxy_tags
    proxy_tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' \
        "$outbound_file" 2>/dev/null))

    if [ ${#proxy_tags[@]} -eq 0 ]; then
        yellow "\n当前没有可用的 socks5/http 代理出站。"
        yellow "请先返回 → 设置分流服务 → 添加 代理出站(Socks5/HTTP/SS2022)，再设置全局代理。\n"
        sleep 3; add_rule_menu; return
    fi

    echo ""
    green "请选择全局代理出站:"
    for i in "${!proxy_tags[@]}"; do
        echo -e "  ${green}$((i+1)). ${skyblue}${proxy_tags[$i]}${re}"
    done
    echo ""
    reading "请输入编号: " out_choice
    if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
       [ "$out_choice" -lt 1 ] || \
       [ "$out_choice" -gt "${#proxy_tags[@]}" ]; then
        red "无效选择"; sleep 1; add_rule_menu; return
    fi
    local selected_out="${proxy_tags[$((out_choice-1))]}"

    if [ ! -s "$route_file" ] || \
       ! jq -e '.route.default_domain_resolver' "$route_file" >/dev/null 2>&1; then
        repair_default_route || { red "生成默认路由配置失败"; sleep 2; warp_manage; return; }
    fi

    cp -f "$route_file" "${route_file}.bak"
    cp -f "$outbound_file" "${outbound_file}.bak"

    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$outbound_file" >/dev/null 2>&1; then
        jq_write "$outbound_file" '.outbounds = [{"type": "direct", "tag": "direct"}] + .outbounds'
    fi
    jq_write "$route_file" --arg out "$selected_out" '.route.final = $out'

    local check_output
    check_output=$(validate_singbox_config)
    if [ $? -ne 0 ]; then
        cp -f "${route_file}.bak" "$route_file"
        cp -f "${outbound_file}.bak" "$outbound_file"
        red "\n配置校验未通过，已自动回滚，未做任何更改：\n"
        echo "$check_output"
        sleep 3; warp_manage; return
    fi
    rm -f "${route_file}.bak" "${outbound_file}.bak"

    reload_singbox
    green "\n已设置全局代理出站：${purple}${selected_out}${re}"
    yellow "未命中分流规则的流量将通过 ${selected_out} 转发（已有分流规则仍然优先），如需恢复请选择「恢复服务器原IP出站」\n"
    sleep 2; warp_manage
}

repair_default_route() {
    local cur_dns_strategy
    cur_dns_strategy=$(jq -r '.dns.strategy // "prefer_ipv4"' "${conf_dir}/dns.json" 2>/dev/null)
    [ -z "$cur_dns_strategy" ] || [ "$cur_dns_strategy" = "null" ] && cur_dns_strategy="prefer_ipv4"

    if ! jq -e '.dns.servers[] | select(.tag=="sys")' "${conf_dir}/dns.json" >/dev/null 2>&1; then
        local heal_dns
        heal_dns=$(awk '/^nameserver[ \t]+/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
        [ -z "$heal_dns" ] && heal_dns="1.1.1.1"
        jq_write "${conf_dir}/dns.json" --arg s "$heal_dns" '.dns.servers = [{"tag":"sys","type":"udp","server":$s}] + .dns.servers'
    fi

    local cur_resolver_tag="local"
    if ip link show 2>/dev/null | grep -qE '^[0-9]+: (wgcf-v[46]|[a-z]*clat[a-z0-9]*)[:@]'; then
        cur_resolver_tag="sys"
    fi

    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$outbound_file" > /dev/null 2>&1; then
        jq_write "$outbound_file" '.outbounds = [{"type": "direct", "tag": "direct"}] + .outbounds'
    fi

    write_default_route_json "$cur_resolver_tag" "$cur_dns_strategy"
}

restore_direct_outbound() {
    yellow "\n正在恢复服务器原IP出站...\n"

    if [ -s "$route_file" ] && \
       jq -e '.route.default_domain_resolver' "$route_file" >/dev/null 2>&1 && \
       jq -e '.outbounds[] | select(.tag == "direct")' "$outbound_file" >/dev/null 2>&1; then
        jq_write "$route_file" '.route.final = "direct"'
    else
        repair_default_route
    fi

    reload_singbox
    green "\n已恢复服务器原IP出站，未命中分流规则的流量走 direct。\n"
    sleep 2; warp_manage
}

delete_rule_menu() {
    clear
    green "当前已启用的分流规则集:"
    local rule_tags=() i
    mapfile -t rule_tags < <(jq -r '[.route.rules[] | select(.rule_set != null) | .rule_set[]?] | map(select(. != "telegram-ip")) | unique | .[]' "$route_file")
    for i in "${!rule_tags[@]}"; do
        printf '%b%2d.%b %b%s%b\n' "$green" "$((i+1))" "$re" "$skyblue" "${rule_tags[$i]}" "$re"
    done
    echo -e "${purple} 0. 返回上级菜单${re}"
    reading "\n输入要删除的规则名称或序号: " del_input
    [ "$del_input" = "0" ] && { warp_manage; return; }
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag="${rule_tags[$((del_input-1))]:-}"
    else
        tag="$del_input"
    fi
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        red "无效的选择"; sleep 1; warp_manage; return
    fi
    local tags_to_del=("$tag")
    if [ "$tag" = "telegram" ] || [ "$tag" = "telegram-ip" ]; then
        tags_to_del=("telegram" "telegram-ip")
    fi
    for t in "${tags_to_del[@]}"; do
        jq_write "$route_file" --arg tag "$t" '
          .route.rules = (
            [{"action":"sniff"}]
            + [
                .route.rules[]?
                | select(.action != "sniff")
                | if .rule_set != null then
                    .rule_set = [.rule_set[] | select(. != $tag)]
                  else . end
                | select(
                    (.rule_set | type) != "array"
                    or (.rule_set | length) > 0
                  )
              ]
          )
        '

        if jq -e --arg tag "$t" '.route.rule_set[]? | select(.tag == $tag and .type == "inline")' "$route_file" >/dev/null 2>&1; then
            jq_write "$route_file" --arg tag "$t" '.route.rule_set = [.route.rule_set[] | select(.tag != $tag)]'
        fi
    done
    reload_singbox
    if [ "$tag" = "telegram" ] || [ "$tag" = "telegram-ip" ]; then
        green "规则集 'telegram' 已禁用。"
    else
        green "规则集 '${tag}' 已禁用。"
    fi
    sleep 1; warp_manage
}

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
    sleep 3; warp_manage
}

urldecode() {
    local data="${1//%/\\x}"
    printf '%b' "$data"
}

add_socks5_proxy() {
    clear
    reading "请输入代理URL (支持socks://,socks5://,http://,ss://(ss2022) 支持v2rayN导出的节点链接): " proxy_url
    [ -z "$proxy_url" ] && { red "输入为空！"; sleep 1; return; }

    proto="${proxy_url%%://*}"
    [[ ! "$proto" =~ ^(socks5|socks|http|ss|ss2022|shadowsocks)$ ]] && { red "不支持的协议"; sleep 2; return; }
    case "$proto" in
        socks|socks5)           outbound_type="socks" ;;
        http)                   outbound_type="http" ;;
        ss|ss2022|shadowsocks)  outbound_type="shadowsocks" ;;
    esac

    after_proto="${proxy_url#*://}"
    if [[ "$after_proto" == *"#"* ]]; then
        tag_from_url="${after_proto##*#}"; after_proto="${after_proto%%#*}"
    else
        tag_from_url=""
    fi

    if [[ "$after_proto" == *"@"* ]]; then
        user_pass="${after_proto%%@*}"; host_port="${after_proto##*@}"
    else
        user_pass=""; host_port="$after_proto"
    fi

    user=""; password=""
    if [ -n "$user_pass" ]; then
        decoded=$(echo "$user_pass" | base64 -d 2>/dev/null)
        if [ -n "$decoded" ] && [[ "$decoded" != "$user_pass" ]] && [[ "$decoded" == *":"* ]]; then
            user="${decoded%%:*}"; password="${decoded#*:}"
        elif [[ "$user_pass" == *":"* ]]; then
            user="${user_pass%%:*}"; password="${user_pass#*:}"
            user=$(urldecode "$user")
            password=$(urldecode "$password")
        else
            user="$user_pass"
        fi
    fi

    if [[ "$host_port" == \[*\]:* ]]; then
        server="${host_port%%]:*}"
        server="${server#\[}"
        port="${host_port##*]:}"
    else
        server="${host_port%%:*}"; port="${host_port##*:}"
    fi
    [ -z "$server" ] || [ -z "$port" ] && { red "格式错误：缺少ip或端口"; sleep 2; return; }

    if [ "$outbound_type" = "shadowsocks" ]; then
        method="$user"
        [ -z "$method" ] || [ -z "$password" ] && { red "格式错误：ss链接缺少加密方式(method)或密码"; sleep 2; return; }
        yellow "Shadowsocks/ss2022 出站暂不支持在线检测（检测API仅支持socks/http），将直接添加，请自行确认服务器信息无误。"
    else
        [[ "$proto" == "socks" || "$proto" == "socks5" ]] && check_proto="socks5" || check_proto="$proto"

        local server_for_url="$server"
        [[ "$server" == *:* ]] && server_for_url="[${server}]"

        local is_local=false
        if [[ "$server" == "127.0.0.1" || "$server" == "::1" || "$server" == "localhost" ]]; then
            is_local=true
        fi

        local proxy_auth=""
        [ -n "$user" ] && [ -n "$password" ] && proxy_auth="${user}:${password}@" || \
            { [ -n "$user" ] && proxy_auth="${user}@"; }

        if [ "$is_local" = true ]; then
            yellow "检测到本地代理 ${check_proto}://${server_for_url}:${port}，跳过外部API检测，正在用curl测试连通性..."
            local curl_proxy_url="${check_proto}://${proxy_auth}${server_for_url}:${port}"
            local test_result
            test_result=$(curl -s --max-time 8 --proxy "$curl_proxy_url" "https://api.ip.sb/ip" 2>/dev/null)
            if [ -z "$test_result" ]; then
                yellow "警告：通过本地代理访问外网失败，请确认代理服务正在运行。"
                reading "是否仍然添加此代理？(y/n): " force_add
                [[ ! "$force_add" =~ ^[yY]$ ]] && { yellow "已取消"; sleep 1; return; }
            else
                green "本地代理可用，出口IP: $test_result"
            fi
        else
            yellow "正在测试代理 ${check_proto}://${server_for_url}:${port} ..."
            local api_response
            api_response=$(curl -s --max-time 8 -G \
                --data-urlencode "proxy=${check_proto}://${proxy_auth}${server_for_url}:${port}" \
                "https://check.socks5.cmliussss.net/check" 2>/dev/null)
            [ -z "$api_response" ] && { red "API 请求失败"; sleep 2; return; }

            success=$(echo "$api_response" | jq -r '.success')
            if [ "$success" != "true" ]; then
                error_msg=$(echo "$api_response" | jq -r '.error // "未知错误"')
                red "代理不可用: $error_msg"; sleep 2; return
            fi
            exit_ip=$(echo "$api_response" | jq -r '.exit.ip // empty')
            green "代理可用"
            [ -n "$exit_ip" ] && green "出口 IP: $exit_ip"
        fi
    fi

    [ -n "$tag_from_url" ] && tag="$tag_from_url" || tag="${outbound_type}-${server}-${port}"
    jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" >/dev/null 2>&1 \
        && { red "出站标签 '${tag}' 已存在"; sleep 2; return; }

    if [ "$outbound_type" = "shadowsocks" ]; then
        jq_write "$outbound_file" --arg tag "$tag" --arg server "$server" --arg port "$port" \
           --arg method "$method" --arg password "$password" \
           '.outbounds += [{"type":"shadowsocks","tag":$tag,"server":$server,"server_port":($port|tonumber),"method":$method,"password":$password}]'
    elif [ -n "$user" ] && [ -n "$password" ]; then
        jq_write "$outbound_file" --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
           --arg port "$port" --arg user "$user" --arg password "$password" \
           '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber),"username":$user,"password":$password}]'
    else
        jq_write "$outbound_file" --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
           --arg port "$port" \
           '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber)}]'
    fi

    reload_singbox
    green "\n${tag} 代理出站已添加\n"
    sleep 2; warp_manage
}

add_local_ip_outbound() {
    clear
    green "=== 添加 本地IP出站 (多IP机器选择出口IP) ===\n"
    yellow "原理：为 direct 出站绑定本机某个具体公网IP，作用类似WARP/代理出站，\n可用于将指定分流规则固定从某张网卡/某个IP发出（如机房IPv4/机房IPv6/家宽IP三选一）。\n"

    local ip4_list ip6_list ip_list
    ip4_list=($(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
    ip6_list=($(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
    ip_list=("${ip4_list[@]}" "${ip6_list[@]}")

    if [ ${#ip_list[@]} -eq 0 ]; then
        red "未检测到本机可用的公网IP地址！"; sleep 2; return
    fi

    green "检测到本机以下可用IP:"
    local i=1
    for ip in "${ip_list[@]}"; do
        echo -e "  ${green}${i}. ${skyblue}${ip}${re}"
        i=$((i+1))
    done
    echo -e "  ${purple}0. 返回上级菜单${re}"

    reading "\n请输入编号选择出口IP(也可直接手动输入未列出的IP): " ip_choice
    local selected_ip
    if [ "$ip_choice" = "0" ]; then
        warp_manage; return
    elif [[ "$ip_choice" =~ ^[0-9]+$ ]] && [ "$ip_choice" -ge 1 ] && [ "$ip_choice" -le "${#ip_list[@]}" ]; then
        selected_ip="${ip_list[$((ip_choice-1))]}"
    else
        selected_ip="$ip_choice"
    fi
    [ -z "$selected_ip" ] && { red "输入为空！"; sleep 1; return; }

    reading "请输入该出站的标签名(仅限字母/数字/下划线/中横线，直接回车自动生成): " custom_tag
    local tag
    if [ -n "$custom_tag" ]; then
        tag=$(echo "$custom_tag" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')
    else
        tag="local-$(echo "$selected_ip" | tr ':.' '--')"
    fi

    jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" >/dev/null 2>&1 \
        && { red "出站标签 '${tag}' 已存在"; sleep 2; return; }

    local bind_field domain_strategy strict_family
    if [[ "$selected_ip" == *:* ]]; then
        bind_field="inet6_bind_address"
        strict_family="ipv6"
    else
        bind_field="inet4_bind_address"
        strict_family="ipv4"
    fi

    local dns_resolver_tag
    dns_resolver_tag=$(jq -r '.route.default_domain_resolver.server // .route.default_domain_resolver // empty' "$route_file" 2>/dev/null)
    [ -z "$dns_resolver_tag" ] || [ "$dns_resolver_tag" = "null" ] && dns_resolver_tag="local"

    yellow "\n该出站需要设置 domain_resolver（sing-box 1.12+ 已废弃 domain_strategy 字段），避免被全局策略带偏："
    echo -e "  ${green}1. 严格模式 (${strict_family}_only)${re} —— 保证100%走这个IP，但如果这个协议族连不通就直接失败，不会偷偷换别的出口"
    echo -e "  ${green}2. 优先模式 (prefer_${strict_family})${re} —— 优先走这个IP，连不通时会自动换成本机默认IP兜底（可能不是你想要的出口）"
    reading "请选择 [1/2，直接回车默认1]: " ds_choice
    if [ "$ds_choice" = "2" ]; then
        domain_strategy="prefer_${strict_family}"
    else
        domain_strategy="${strict_family}_only"
    fi

    yellow "正在测试从 ${selected_ip} 出站的连通性..."
    local test_ip
    if [ "$bind_field" = "inet4_bind_address" ]; then
        test_ip=$(curl -s --max-time 8 --interface "$selected_ip" -4 "https://api.ip.sb/ip" 2>/dev/null)
    else
        test_ip=$(curl -s --max-time 8 --interface "$selected_ip" -6 "https://api.ip.sb/ip" 2>/dev/null)
    fi
    if [ -z "$test_ip" ]; then
        yellow "警告：绑定 ${selected_ip} 测试出站失败（可能该IP未配置在本机网卡上，或被防火墙拦截）。"
        reading "是否仍然添加此出站？(y/n): " force_add
        [[ ! "$force_add" =~ ^[yY]$ ]] && { yellow "已取消"; sleep 1; return; }
    else
        green "测试成功，出口IP: ${test_ip}"
    fi

    jq_write "$outbound_file" --arg tag "$tag" --arg field "$bind_field" --arg ip "$selected_ip" --arg ds "$domain_strategy" --arg resolver "$dns_resolver_tag" \
        '.outbounds += [{"type":"direct","tag":$tag} + {($field): $ip} + {"domain_resolver": {"server": $resolver, "strategy": $ds}}]'

    reload_singbox
    green "\n本地IP出站 '${tag}' (绑定 ${selected_ip}, domain_resolver.strategy=${domain_strategy}) 已添加\n"
    yellow "提示: 到「1. 设置分流服务」或「10. 添加 全局代理出站」中选择该出站，\n即可让指定流量固定从这个本地IP发出。\n"
    sleep 2; warp_manage
}

delete_socks5_proxy() {
    clear
    green "当前可用出站列表:"
    local out_list=$(jq -r '[.outbounds[] | select(.tag != "direct")] | to_entries | .[] | "\(.key+1)\t\(.value.tag)\t\(.value.type)"' "$outbound_file" 2>/dev/null)
    [ -z "$out_list" ] && { yellow "没有可删除的出站。"; sleep 2; return; }
    echo "$out_list" | while IFS=$'\t' read -r o_idx o_tag o_type; do
        echo -e "${green}${o_idx}.${re} ${yellow}${o_tag}${re} [${o_type}]"
    done
    echo -e "${purple}0. 返回上级菜单${re}"

    reading "\n输入要删除的出站编号或标签: " del_input
    [ "$del_input" = "0" ] && { warp_manage; return; }
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '.outbounds | map(select(.tag != "direct")) | .[($idx | tonumber)-1].tag // empty' "$outbound_file")
        [ -z "$tag" ] && { red "编号无效！"; sleep 1; return; }
    else
        tag="$del_input"
        jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" > /dev/null 2>&1 || { red "标签 '${tag}' 不存在！"; sleep 1; return; }
    fi
    [ "$tag" == "wireguard-out" ] && { red "wireguard-out 为系统内置，不可删除！"; sleep 2; return; }

    jq_write "$outbound_file" --arg tag "$tag" 'del(.outbounds[] | select(.tag == $tag))'
    jq_write "$route_file" --arg tag "$tag" '.route.rules = [.route.rules[] | select(.outbound != $tag)]'
    jq_write "$route_file" --arg tag "$tag" 'if .route.final == $tag then .route.final = "direct" else . end'
    quota_forget "$tag"

    reload_singbox
    green "${tag} 代理出站已删除。"
    sleep 1
}

# =========================
# 代理流量限制 (按出站统计, 定时窗口内超限切断, 窗口结束自动解除并重新计量)
# 原理: sing-box Clash API 提供每条连接的上下行字节, 常驻监控服务每3秒累加到对应出站;
#       超限后把该出站替换为不可达的占位出站(路由规则不变), 窗口结束后换回原出站。
# =========================
quota_fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b >= 1073741824)      printf "%.2fGB", b/1073741824;
        else if (b >= 1048576)    printf "%.2fMB", b/1048576;
        else if (b >= 1024)       printf "%.1fKB", b/1024;
        else                      printf "%dB", b }'
}

quota_fmt_secs() {
    local s=${1:-0}
    [ "$s" -lt 0 ] && s=0
    printf "%dh%02dm" $((s/3600)) $(((s%3600)/60))
}

quota_is_pos_num() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$1" 'BEGIN{exit !(v>0)}'
}

# 供 warp_manage 出站列表显示限流状态
quota_tag_flag() {
    local tag=$1 line q_used q_lim q_blk
    [ -f "$quota_state" ] || return 0
    line=$(jq -r --arg t "$tag" '.limits[$t] // empty | "\(.used // 0)\t\(.limit_bytes)\t\(.blocked // false)\t\(.action // "block")"' "$quota_state" 2>/dev/null)
    [ -z "$line" ] && return 0
    IFS=$'\t' read -r q_used q_lim q_blk q_act <<< "$line"
    if [ "$q_blk" = "true" ] && [ "$q_act" = "direct" ]; then
        echo -e " ${yellow}[已超限·已回落本机IP]${re}"
    elif [ "$q_blk" = "true" ]; then
        echo -e " ${red}[已超限·流量已切断]${re}"
    else
        echo -e " ${skyblue}[限流 $(quota_fmt_bytes "$q_used")/$(quota_fmt_bytes "$q_lim")]${re}"
    fi
}

# 生成监控脚本 (独立运行, 不依赖本脚本)
quota_write_monitor() {
    cat > "$quota_bin" << 'QEOF'
#!/bin/bash
# sing-box 代理流量限制监控 —— 由 sing-box.sh 自动生成，请勿手动编辑
WORK_DIR="__WORK_DIR__"
CONF_DIR="${WORK_DIR}/conf"
OUT_FILE="${CONF_DIR}/outbounds.json"
STATE="${WORK_DIR}/quota.json"
SEEN="${WORK_DIR}/quota.seen.json"
LOCK="${WORK_DIR}/quota.lock"
LOG="${WORK_DIR}/quota.log"
INTERVAL=3

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

locked() {
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9; "$@" ) 9>"$LOCK"
    else
        local i=0 rc
        while ! mkdir "$LOCK.d" 2>/dev/null; do
            i=$((i+1)); [ "$i" -gt 100 ] && rm -rf "$LOCK.d"
            sleep 0.1
        done
        "$@"; rc=$?
        rmdir "$LOCK.d" 2>/dev/null
        return $rc
    fi
}

st_edit() { jq "$@" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }

sb_reload() {
    local sb="${WORK_DIR}/sing-box"
    if [ -x "$sb" ] && ! "$sb" check -C "$CONF_DIR" >/dev/null 2>&1; then
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet sing-box 2>/dev/null || return 0
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null
    elif command -v rc-service >/dev/null 2>&1; then
        local pid
        pid=$(cat /var/run/sing-box.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null; then
            return 0
        fi
        rc-service sing-box restart >/dev/null 2>&1
    fi
}

# 超限: 先在状态里记下原出站, 再换成占位出站并重载
do_block() {
    local tag=$1 now orig act stub
    now=$(date +%s)
    act=$(jq -r --arg t "$tag" '.limits[$t].action // "block"' "$STATE")
    if [ "$act" = "direct" ]; then
        stub=$(jq -nc --arg t "$tag" '{type:"direct",tag:$t}')
    else
        stub=$(jq -nc --arg t "$tag" '{type:"socks",tag:$t,server:"127.0.0.1",server_port:1}')
    fi
    orig=$(jq -c --arg t "$tag" '[.outbounds[] | select(.tag == $t)][0] // empty' "$OUT_FILE" 2>/dev/null)
    if [ -z "$orig" ]; then
        log "$tag 已超限, 但 outbounds.json 中找不到该出站, 移除其限制记录"
        st_edit --arg t "$tag" 'del(.limits[$t])'
        return 1
    fi
    st_edit --arg t "$tag" --argjson o "$orig" --argjson n "$now" \
        '.limits[$t] |= (.blocked = true | .blocked_at = $n | .orig = $o)'
    cp "$OUT_FILE" "$OUT_FILE.quota.bak"
    jq --arg t "$tag" --argjson s "$stub" \
        '.outbounds |= map(if .tag == $t then $s else . end)' \
        "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
    if ! sb_reload; then
        mv "$OUT_FILE.quota.bak" "$OUT_FILE"
        st_edit --arg t "$tag" --argjson r $((now+60)) \
            '.limits[$t] |= (del(.blocked, .blocked_at, .orig) | .retry_after = $r)'
        log "$tag 超限处理失败(配置校验/重载未通过), 60秒后重试"
        return 1
    fi
    rm -f "$OUT_FILE.quota.bak"
    if [ "$act" = "direct" ]; then log "$tag 已超限, 已回落为本机默认IP直连"; else log "$tag 已超限, 出站已切断"; fi
}

# 解除限制并重启计量 (已切断则先换回原出站)
do_reset() {
    local tag=$1 now blocked orig
    now=$(date +%s)
    blocked=$(jq -r --arg t "$tag" '.limits[$t].blocked // false' "$STATE")
    if [ "$blocked" = "true" ]; then
        orig=$(jq -c --arg t "$tag" '.limits[$t].orig // empty' "$STATE")
        if [ -z "$orig" ]; then
            log "$tag 解除失败: 状态文件中缺少原出站配置"
            return 1
        fi
        cp "$OUT_FILE" "$OUT_FILE.quota.bak"
        jq --arg t "$tag" --argjson o "$orig" \
            '.outbounds |= map(if .tag == $t then $o else . end)' \
            "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
        if ! sb_reload; then
            mv "$OUT_FILE.quota.bak" "$OUT_FILE"
            st_edit --arg t "$tag" --argjson r $((now+60)) '.limits[$t].retry_after = $r'
            log "$tag 解除失败(配置校验/重载未通过), 保持切断状态, 60秒后重试"
            return 1
        fi
        rm -f "$OUT_FILE.quota.bak"
    fi
    st_edit --arg t "$tag" --argjson n "$now" \
        '.limits[$t] |= (del(.blocked, .blocked_at, .orig, .retry_after) | .used = 0 | .window_start = $n)'
    log "$tag 已解除限制并重启计量"
}

tick_apply() {
    local now=$1 resp=$2 tag win ws blk retry out
    [ -f "$STATE" ] || return 0

    # 1) 统计窗口到期: 已切断的解除并重新计量, 未切断的清零开新窗口
    while IFS=$'\t' read -r tag win ws blk retry; do
        [ -z "$tag" ] && continue
        [ $((now - ws)) -lt "$win" ] && continue
        [ "$retry" -gt "$now" ] && continue
        if [ "$blk" = "true" ]; then
            do_reset "$tag"
        else
            st_edit --arg t "$tag" --argjson n "$now" '.limits[$t] |= (.used = 0 | .window_start = $n)'
            log "$tag 统计窗口结束, 已重新计量"
        fi
    done < <(jq -r '.limits | to_entries[] | [.key, .value.window_sec, .value.window_start, (.value.blocked // false), (.value.retry_after // 0)] | @tsv' "$STATE")

    # 2) 累加各出站新增流量 (按连接差值, 跨轮询去重)
    if [ -n "$resp" ]; then
        [ -f "$SEEN" ] || echo '{}' > "$SEEN"
        out=$(printf '%s' "$resp" | jq --slurpfile st "$STATE" --slurpfile seen "$SEEN" '
            ($st[0]) as $s | ($seen[0] // {}) as $p |
            ((.connections // []) | map({id: .id, tag: (((.chains // []) | last) // ""), t: ((.upload // 0) + (.download // 0))})) as $cur |
            ($cur | map({tag: .tag, d: (if .t >= ($p[.id] // 0) then .t - ($p[.id] // 0) else .t end)})
                  | group_by(.tag) | map({key: .[0].tag, value: (map(.d) | add)}) | from_entries) as $delta |
            {
              state: ($s | .limits |= with_entries(
                  if ((.value.blocked // false) | not) and (($delta[.key] // 0) > 0)
                  then .value.used = ((.value.used // 0) + $delta[.key])
                  else . end)),
              seen: ($cur | map({key: .id, value: .t}) | from_entries)
            }' 2>/dev/null)
        if [ -n "$out" ]; then
            printf '%s' "$out" | jq '.state' > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
            printf '%s' "$out" | jq -c '.seen' > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
        fi
    fi

    # 3) 超限的出站切断
    while IFS= read -r tag; do
        [ -n "$tag" ] && do_block "$tag"
    done < <(jq -r --argjson now "$now" '.limits | to_entries[]
        | select(((.value.blocked // false) | not) and ((.value.used // 0) >= .value.limit_bytes) and ((.value.retry_after // 0) <= $now))
        | .key' "$STATE")
}

tick() {
    local port secret resp now
    [ -f "$STATE" ] || return 0
    now=$(date +%s)
    port=$(jq -r '.clash.port // empty' "$STATE")
    secret=$(jq -r '.clash.secret // empty' "$STATE")
    resp=""
    if [ -n "$port" ]; then
        resp=$(curl -s --max-time 3 -H "Authorization: Bearer ${secret}" "http://127.0.0.1:${port}/connections" 2>/dev/null)
        printf '%s' "$resp" | jq -e 'type == "object" and has("connections")' >/dev/null 2>&1 || resp=""
    fi
    locked tick_apply "$now" "$resp"
}

cli_set() {
    local tag=$1 lim=$2 win=$3 act=${4:-block} now
    [ -f "$STATE" ] || return 1
    now=$(date +%s)
    if [ "$(jq -r --arg t "$tag" '.limits[$t].blocked // false' "$STATE")" = "true" ]; then
        do_reset "$tag" || return 1
    fi
    st_edit --arg t "$tag" --argjson l "$lim" --argjson w "$win" --argjson n "$now" --arg a "$act" \
        '.limits[$t] = {limit_bytes: $l, window_sec: $w, window_start: $n, used: 0, action: $a}'
}

cli_del() {
    local tag=$1
    [ -f "$STATE" ] || return 0
    if [ "$(jq -r --arg t "$tag" '.limits[$t].blocked // false' "$STATE")" = "true" ]; then
        do_reset "$tag" || return 1
    fi
    st_edit --arg t "$tag" 'del(.limits[$t])'
}

cli_forget() {
    [ -f "$STATE" ] || return 0
    st_edit --arg t "$1" 'del(.limits[$t])'
}

case "$1" in
    daemon) while true; do tick; sleep "$INTERVAL"; done ;;
    set)    locked cli_set "$2" "$3" "$4" "$5" ;;
    reset)  locked do_reset "$2" ;;
    del)    locked cli_del "$2" ;;
    forget) locked cli_forget "$2" ;;
    *)      echo "usage: $0 daemon|set TAG BYTES SECS [block|direct]|reset TAG|del TAG|forget TAG"; exit 1 ;;
esac
QEOF
    sed -i "s#__WORK_DIR__#${work_dir}#" "$quota_bin"
    chmod 700 "$quota_bin"
}

quota_service_start() {
    quota_write_monitor
    if command_exists systemctl; then
        cat > /etc/systemd/system/sb-quota.service << EOF
[Unit]
Description=sing-box proxy traffic quota monitor
After=sing-box.service

[Service]
Type=simple
ExecStart=/bin/bash ${quota_bin} daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sb-quota >/dev/null 2>&1
        systemctl restart sb-quota >/dev/null 2>&1
    elif command_exists rc-service; then
        cat > /etc/init.d/sb-quota << EOF
#!/sbin/openrc-run
description="sing-box proxy traffic quota monitor"
command="/bin/bash"
command_args="${quota_bin} daemon"
command_background=true
pidfile="/var/run/sb-quota.pid"

depend() {
    need net
    after sing-box
}
EOF
        chmod +x /etc/init.d/sb-quota
        rc-update add sb-quota default >/dev/null 2>&1
        rc-service sb-quota restart >/dev/null 2>&1
    fi
}

quota_service_stop() {
    if command_exists systemctl && [ -f /etc/systemd/system/sb-quota.service ]; then
        systemctl disable --now sb-quota >/dev/null 2>&1
        rm -f /etc/systemd/system/sb-quota.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    if command_exists rc-service && [ -f /etc/init.d/sb-quota ]; then
        rc-service sb-quota stop >/dev/null 2>&1
        rc-update del sb-quota default >/dev/null 2>&1
        rm -f /etc/init.d/sb-quota
    fi
}

# 确保状态文件与 Clash API 配置存在; 新增了API配置时 quota_api_added=1 (需要重载 sing-box 才生效)
quota_enable_api() {
    quota_api_added=0
    local port secret check_output
    if [ ! -f "$quota_state" ]; then
        port=$(get_free_port 20000 60000)
        secret=$(openssl rand -hex 16)
        jq -n --argjson p "$port" --arg s "$secret" '{clash:{port:$p, secret:$s}, limits:{}}' > "$quota_state"
        chmod 600 "$quota_state"
        echo '{}' > "${work_dir}/quota.seen.json"
    fi
    if [ ! -f "$quota_api_conf" ]; then
        port=$(jq -r '.clash.port' "$quota_state")
        secret=$(jq -r '.clash.secret' "$quota_state")
        jq -n --arg addr "127.0.0.1:${port}" --arg s "$secret" \
            '{experimental:{clash_api:{external_controller:$addr, secret:$s}}}' > "$quota_api_conf"
        check_output=$(validate_singbox_config)
        if [ $? -ne 0 ]; then
            red "当前 sing-box 内核无法启用 Clash API（流量统计依赖它）：\n"
            echo "$check_output" | head -10
            rm -f "$quota_api_conf"
            [ "$(jq '.limits | length' "$quota_state" 2>/dev/null)" = "0" ] && rm -f "$quota_state" "${work_dir}/quota.seen.json"
            return 1
        fi
        quota_api_added=1
    fi
    return 0
}

# 没有任何限制时, 关闭监控服务并移除 Clash API 配置; 移除了API配置时 quota_api_removed=1
quota_cleanup_if_empty() {
    quota_api_removed=0
    [ -f "$quota_state" ] || return 0
    [ "$(jq '.limits | length' "$quota_state" 2>/dev/null)" = "0" ] || return 0
    quota_service_stop
    rm -f "$quota_state" "${work_dir}/quota.seen.json" "${work_dir}/quota.lock" "${work_dir}/quota.log" "$quota_bin"
    if [ -f "$quota_api_conf" ]; then
        rm -f "$quota_api_conf"
        quota_api_removed=1
    fi
}

# 删除出站时同步清理其限制记录 (调用方随后会 reload)
quota_forget() {
    local tag=$1
    [ -f "$quota_state" ] || return 0
    jq -e --arg t "$tag" '.limits[$t]' "$quota_state" >/dev/null 2>&1 || return 0
    bash "$quota_bin" forget "$tag"
    quota_cleanup_if_empty
}

quota_show() {
    local rows now
    now=$(date +%s)
    if [ ! -f "$quota_state" ] || [ "$(jq '.limits | length' "$quota_state" 2>/dev/null)" = "0" ]; then
        echo "  暂无已设置的流量限制"
        return
    fi
    if ! service_is_running "sb-quota"; then
        yellow "  ⚠ 监控服务 sb-quota 未运行，流量不会被统计，请重新设置一次限制以拉起服务"
    fi
    rows=$(jq -r '.limits | to_entries[] | [.key, (.value.used // 0), .value.limit_bytes, .value.window_sec, .value.window_start, (.value.blocked // false), (.value.action // "block")] | @tsv' "$quota_state")
    while IFS=$'\t' read -r q_tag q_used q_lim q_win q_ws q_blk q_act; do
        local left=$((q_ws + q_win - now))
        local status
        local act_txt="超限后阻断"
        [ "$q_act" = "direct" ] && act_txt="超限后回落本机IP"
        if [ "$q_blk" = "true" ] && [ "$q_act" = "direct" ]; then
            status="${yellow}已超限·已回落本机IP${re}，$(quota_fmt_secs "$left")后自动恢复"
        elif [ "$q_blk" = "true" ]; then
            status="${red}已超限·已切断${re}，$(quota_fmt_secs "$left")后自动解除"
        else
            status="${green}计量中${re}，窗口剩余 $(quota_fmt_secs "$left")，${act_txt}"
        fi
        echo -e " - ${yellow}${q_tag}${re}  $(quota_fmt_bytes "$q_used") / $(quota_fmt_bytes "$q_lim")  周期$(quota_fmt_secs "$q_win")  ${status}"
    done <<< "$rows"
}

# 选择一个出站: 参数1=candidates 来源(all=所有可限流出站 / limited=已设置限制的出站); 结果写入 quota_pick_tag
quota_pick_tag() {
    local mode=$1 tags=() i=1 t
    quota_pick_tag_result=""
    if [ "$mode" = "limited" ]; then
        [ -f "$quota_state" ] && tags=($(jq -r '.limits | keys[]' "$quota_state" 2>/dev/null))
    else
        tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' "$outbound_file" 2>/dev/null))
    fi
    if [ ${#tags[@]} -eq 0 ]; then
        if [ "$mode" = "limited" ]; then yellow "没有已设置限制的出站。"; else yellow "没有可限流的出站，请先添加代理出站或本地IP出站。"; fi
        sleep 2; return 1
    fi
    echo ""
    for t in "${tags[@]}"; do
        echo -e "  ${green}${i}.${re} ${yellow}${t}${re}$(quota_tag_flag "$t")"
        i=$((i+1))
    done
    echo -e "  ${purple}0. 返回${re}"
    reading "\n请输入编号或标签: " q_in
    [ -z "$q_in" ] || [ "$q_in" = "0" ] && return 1
    if [[ "$q_in" =~ ^[0-9]+$ ]]; then
        [ "$q_in" -ge 1 ] && [ "$q_in" -le "${#tags[@]}" ] || { red "编号无效！"; sleep 1; return 1; }
        quota_pick_tag_result="${tags[$((q_in-1))]}"
    else
        for t in "${tags[@]}"; do [ "$t" = "$q_in" ] && quota_pick_tag_result="$t"; done
        [ -z "$quota_pick_tag_result" ] && { red "标签 '${q_in}' 不存在！"; sleep 1; return 1; }
    fi
    return 0
}

quota_set_limit() {
    clear
    green "=== 设置/修改 流量限制 ===\n"
    yellow "统计口径: 该出站的 上行+下行 总流量 (1GB=1024MB)。\n超限后按你选择的方式处理(阻断 或 回落本机默认IP)，统计周期结束时自动恢复并重新计量。\n修改已有限制会清零计量并重新开始周期。"
    quota_pick_tag all || return
    local tag="$quota_pick_tag_result" q_gb q_hours q_act act limit_bytes window_sec
    reading "流量上限 (GB，可小数，如 20): " q_gb
    quota_is_pos_num "$q_gb" || { red "流量上限必须是大于0的数字"; sleep 2; return; }
    reading "统计周期 (小时，可小数，如 12): " q_hours
    quota_is_pos_num "$q_hours" || { red "统计周期必须是大于0的数字"; sleep 2; return; }
    echo ""
    green "超限后的处理方式:"
    echo -e "  ${green}1. 阻断出站${re} —— 该代理/出站无法再使用，相关流量直接失败"
    echo -e "  ${green}2. 回落本机默认IP${re} —— 命中该出站的流量改走本机默认IP直连，仍可正常出站"
    reading "请选择 [1/2，直接回车默认1]: " q_act
    act="block"; [ "$q_act" = "2" ] && act="direct"
    limit_bytes=$(awk -v g="$q_gb" 'BEGIN{printf "%.0f", g*1073741824}')
    window_sec=$(awk -v h="$q_hours" 'BEGIN{printf "%.0f", h*3600}')
    [ "$window_sec" -lt 60 ] && { red "统计周期不能小于1分钟"; sleep 2; return; }

    quota_enable_api || { sleep 2; return; }
    quota_write_monitor
    if ! bash "$quota_bin" set "$tag" "$limit_bytes" "$window_sec" "$act"; then
        red "设置失败，请查看 ${work_dir}/quota.log"; sleep 2; return
    fi
    if [ "$quota_api_added" = "1" ]; then
        reload_singbox || { red "sing-box 重载失败，限制未生效"; sleep 2; return; }
    fi
    quota_service_start
    if [ "$act" = "direct" ]; then
        green "\n已设置: ${tag} 每 ${q_hours} 小时最多 ${q_gb} GB，超限后回落为本机默认IP直连。"
    else
        green "\n已设置: ${tag} 每 ${q_hours} 小时最多 ${q_gb} GB，超限后阻断该出站。"
    fi
    sleep 2
}

quota_reset_limit() {
    clear
    green "=== 解除限制并重启计量 ===\n"
    quota_pick_tag limited || return
    local tag="$quota_pick_tag_result"
    if bash "$quota_bin" reset "$tag"; then
        green "\n${tag} 已解除限制，计量已清零并重新开始。"
    else
        red "\n解除失败，请查看 ${work_dir}/quota.log"
    fi
    sleep 2
}

quota_cancel_limit() {
    clear
    green "=== 取消流量限制 ===\n"
    quota_pick_tag limited || return
    local tag="$quota_pick_tag_result"
    if ! bash "$quota_bin" del "$tag"; then
        red "取消失败，请查看 ${work_dir}/quota.log"; sleep 2; return
    fi
    quota_cleanup_if_empty
    [ "$quota_api_removed" = "1" ] && reload_singbox
    green "\n${tag} 的流量限制已取消。"
    sleep 2
}

quota_menu() {
    while true; do
        clear
        echo ""
        green "=== 代理流量限制 ===\n"
        green "已设置的限制 (已用 / 上限):"
        quota_show
        echo ""
        green "1. 设置/修改流量限制"
        skyblue "----------------------"
        green "2. 手动解除限制并重启计量"
        skyblue "----------------------"
        red "3. 取消流量限制"
        skyblue "----------------------"
        green "4. 刷新状态"
        skyblue "----------------------"
        purple "0. 返回上级菜单"
        skyblue "------------"
        reading "请输入选择: " q_choice
        case "${q_choice}" in
            1) quota_set_limit ;;
            2) quota_reset_limit ;;
            3) quota_cancel_limit ;;
            4) ;;
            0) warp_manage; return ;;
            *) red "无效选项"; sleep 1 ;;
        esac
    done
}

# 协议管理模块 - 增加/删除 socks5 / anytls / shadowsocks-2022
# 检查指定 tag 是否已在 inbounds 中存在
proto_exists() {
    local tag="$1"
    jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "${conf_dir}/inbounds.json" > /dev/null 2>&1
}

# 更新订阅文件
remove_url_by_tag() {
    local tag="$1"
    sed -i '/'^${tag}':\/\//d' "$client_dir"
    sed -i '/^$/{N; /\n$/D}' "$client_dir"
}

update_sub() {
    update_subscription
}

# ---- Socks5 入站 ----
add_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if proto_exists "$tag"; then
        yellow "Socks5 协议已存在，无需重复添加。"; sleep 1; return
    fi

    local current_uuid
    current_uuid=$(get_current_uuid | tr -d '\n\r')

    sk_port=$(prompt_port "请输入 Socks5 监听端口 (回车随机生成): " 10000 65000 "socks5监听端口" 0)

    reading "请输入 Socks5 用户名 (回车自动使用UUID前8位): " sk_user
    if [ -n "$sk_user" ]; then
        green "socks5用户名：${purple}${sk_user}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_user=$(printf '%s' "${current_uuid:0:8}" | tr -d '\n\r')
            green "自动设置用户名: ${purple}${sk_user}${re}"
        else
            red "无法获取UUID，请手动输入用户名"
            reading "请输入 Socks5 用户名: " sk_user
            [ -z "$sk_user" ] && { red "用户名不能为空"; sleep 1; return; }
        fi
    fi

    reading "请输入 Socks5 密码 (回车自动使用UUID后12位): " sk_pass
    if [ -n "$sk_pass" ]; then
        green "socks5密码：${purple}${sk_pass}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_pass=$(printf '%s' "${current_uuid: -12}" | tr -d '\n\r')
            green "自动设置密码: ${purple}${sk_pass}${re}"
        else
            red "无法获取UUID，请手动输入密码"
            reading "请输入 Socks5 密码: " sk_pass
            [ -z "$sk_pass" ] && { red "密码不能为空"; sleep 1; return; }
        fi
    fi

    jq_write "$inbounds_file" --arg tag "$tag" \
       --argjson port "$sk_port" \
       --arg user "$sk_user" \
       --arg pass "$sk_pass" \
       '.inbounds += [{
           "type": "socks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"username": $user, "password": $pass}]
       }]'

    allow_port ${sk_port}/tcp ${sk_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(get_isp || echo "Socks5")

    local url_line="socks://$(printf '%s' "${sk_user}:${sk_pass}" | base64 -w0)@${server_ip}:${sk_port}#${isp}-Socks5"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    reload_singbox

    green "\nSocks5 协议已添加！"
    green "端口: ${purple}${sk_port}${re}"
    green "用户名: ${purple}${sk_user}${re}  ${green}密码:${re} ${purple}${sk_pass}${re}"
    green "节点链接: ${purple}${url_line}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$url_line"
}

remove_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if ! proto_exists "$tag"; then
        yellow "Socks5 协议未添加，无需删除。"; sleep 1; return
    fi

    jq_write "$inbounds_file" --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))'

    remove_url_by_tag "socks"
    update_sub
    reload_singbox
    green "\nSocks5 协议已删除\n"
}

# ---- AnyTLS ----
add_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"

    if proto_exists "$tag"; then
        yellow "AnyTLS 协议已存在，无需重复添加。"; sleep 1; return
    fi

    local current_uuid
    current_uuid=$(get_current_uuid)
    if [ -z "$current_uuid" ]; then
        red "无法获取当前UUID，请确认 sing-box 已正确安装并配置。"; sleep 2; return
    fi

    at_port=$(prompt_port "请输入 AnyTLS 监听端口 (回车随机生成): " 10000 65000 "Anytls监听端口" 0)

    jq_write "$inbounds_file" --arg tag "$tag" \
       --argjson port "$at_port" \
       --arg pass "$current_uuid" \
       --arg cert "${work_dir}/cert.pem" \
       --arg key "${work_dir}/private.key" \
       '.inbounds += [{
           "type": "anytls",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"password": $pass}],
           "tls": {
               "enabled": true,
               "certificate_path": $cert,
               "key_path": $key
           }
       }]'

    allow_port ${at_port}/tcp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(get_isp || echo "AnyTLS")

    local at_sni="bing.com" at_insecure=1
    if [ -s "${work_dir}/cert_domain.txt" ]; then
        at_sni=$(cat "${work_dir}/cert_domain.txt")
        at_insecure=0
    fi
    local url_line="anytls://${current_uuid}@${server_ip}:${at_port}?insecure=${at_insecure}&sni=${at_sni}#${isp}-AnyTLS"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    reload_singbox

    green "\nAnyTLS 协议已添加！"
    green "密码(UUID): ${purple}${current_uuid}${re}"
    green "端口: ${purple}${at_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$url_line"
}

remove_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"

    if ! proto_exists "$tag"; then
        yellow "AnyTLS 协议未添加，无需删除。"; sleep 1; return
    fi

    jq_write "$inbounds_file" --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))'

    remove_url_by_tag "anytls"
    update_sub
    reload_singbox
    green "\nAnyTLS 协议已删除\n"
}

# ---- Shadowsocks-2022 ----
add_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议已存在，无需重复添加。"; sleep 1; return
    fi

    ss_port=$(prompt_port "请输入 Shadowsocks-2022 监听端口 (回车随机生成): " 10000 65000 "Shadowsocks-2022监听端口" 0)

    echo ""
    green "请选择加密方式:"
    green "1. 2022-blake3-aes-128-gcm       (推荐，密钥16字节)"
    green "2. 2022-blake3-aes-256-gcm       (密钥32字节)"
    green "3. 2022-blake3-chacha20-poly1305 (密钥32字节)"
    reading "请输入选择 (默认1): " ss_method_choice
    local ss_method key_len
    case "${ss_method_choice}" in
        2) ss_method="2022-blake3-aes-256-gcm";        key_len=32 ;;
        3) ss_method="2022-blake3-chacha20-poly1305";   key_len=32 ;;
        *) ss_method="2022-blake3-aes-128-gcm";         key_len=16 ;;
    esac
    green "加密方式为：${purple}${ss_method}${re}"
    local ss_key
    ss_key=$(dd if=/dev/urandom bs=1 count=${key_len} 2>/dev/null | base64 -w0)

    jq_write "$inbounds_file" --arg tag "$tag" \
       --argjson port "$ss_port" \
       --arg method "$ss_method" \
       --arg key "$ss_key" \
       '.inbounds += [{
           "type": "shadowsocks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "method": $method,
           "password": $key,
           "multiplex": {"enabled": true}
       }]'

    allow_port ${ss_port}/tcp ${ss_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(get_isp || echo "SS2022")

    local ss_userinfo
    ss_userinfo=$(printf '%s:%s' "${ss_method}" "${ss_key}" | base64 -w0)
    local url_line="ss://${ss_userinfo}@${server_ip}:${ss_port}#${isp}-SS2022"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    reload_singbox

    green "\nShadowsocks-2022 协议已添加！"
    green "加密方式: ${purple}${ss_method}${re}"
    green "密钥(base64): ${purple}${ss_key}${re}"
    green "端口: ${purple}${ss_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$url_line"
}

remove_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if ! proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议未添加，无需删除。"; sleep 1; return
    fi

    jq_write "$inbounds_file" --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))'

    remove_url_by_tag "ss"
    update_sub
    reload_singbox
    green "\nShadowsocks-2022 协议已删除\n"
}

# 显示当前已启用的额外协议状态
show_extra_proto_status() {
    local inbounds_file="${conf_dir}/inbounds.json"
    echo ""
    green "--- 额外协议状态 ---"

    if jq -e '.inbounds[] | select(.tag == "socks5-in")' "$inbounds_file" > /dev/null 2>&1; then
        local sk_port sk_user
        sk_port=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")
        sk_user=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].username // "N/A"' "$inbounds_file")
        sk_pass=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " Socks5:           ${green}已启用${re} (端口: ${skyblue}${sk_port}${re}, 用户名: ${skyblue}${sk_user}${re}，密码：${skyblue}${sk_pass}${re})"
    else
        echo -e " Socks5:           ${yellow}未启用${re}"
    fi

    if jq -e '.inbounds[] | select(.tag == "anytls")' "$inbounds_file" > /dev/null 2>&1; then
        local at_port at_pass
        at_port=$(jq -r '.inbounds[] | select(.tag == "anytls") | .listen_port' "$inbounds_file")
        at_pass=$(jq -r '.inbounds[] | select(.tag == "anytls") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " AnyTLS:           ${green}已启用${re} (端口: ${skyblue}${at_port}${re}, 密码: ${skyblue}${at_pass}${re})"
    else
        echo -e " AnyTLS:           ${yellow}未启用${re}"
    fi

    if jq -e '.inbounds[] | select(.tag == "shadowsocks-2022")' "$inbounds_file" > /dev/null 2>&1; then
        local ss_port ss_method
        ss_port=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .listen_port' "$inbounds_file")
        ss_method=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .method' "$inbounds_file")
        echo -e " Shadowsocks-2022: ${green}已启用${re} (端口: ${skyblue}${ss_port}${re}, 加密: ${skyblue}${ss_method}${re})"
    else
        echo -e " Shadowsocks-2022: ${yellow}未启用${re}"
    fi
    echo ""
}

# 协议管理主菜单
manage_protocols() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
    fi

    clear; echo ""
    green "=== 协议管理 (增加/删除) ===\n"
    show_extra_proto_status

    green "--- Socks5 协议 ---"
    green "1. 添加 Socks5 协议"
    red   "2. 删除 Socks5 协议"
    skyblue "-----------------------------"
    green "--- AnyTLS 协议 ---"
    green "3. 添加 AnyTLS 协议"
    red   "4. 删除 AnyTLS 协议"
    skyblue "-----------------------------"
    green "--- Shadowsocks-2022 协议 ---"
    green "5. 添加 Shadowsocks-2022 协议"
    red   "6. 删除 Shadowsocks-2022 协议"
    skyblue "-----------------------------"
    purple "0. 返回主菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " proto_choice
    echo ""
    case "${proto_choice}" in
        1) add_socks5_inbound ;;
        2) remove_socks5_inbound ;;
        3) add_anytls ;;
        4) remove_anytls ;;
        5) add_ss2022 ;;
        6) remove_ss2022 ;;
        0) menu; return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}

install_acme() {
    local acme_email="$1"
    [ -z "$acme_email" ] && acme_email="admin@gmail.com"

    if command_exists apt; then
        manage_packages install cron >/dev/null 2>&1
        systemctl enable --now cron >/dev/null 2>&1
    elif command_exists dnf || command_exists yum; then
        manage_packages install cronie >/dev/null 2>&1
        systemctl enable --now crond >/dev/null 2>&1
    elif command_exists apk; then
        manage_packages install dcron >/dev/null 2>&1
        rc-update add dcron default >/dev/null 2>&1
        rc-service dcron start >/dev/null 2>&1
    fi

    if [ -f "${HOME}/.acme.sh/acme.sh" ]; then
        "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
        return 0
    fi

    yellow "正在安装 acme.sh...\n"

    local install_log
    install_log=$(curl -s https://get.acme.sh | sh -s email="$acme_email" --force 2>&1)

    if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
        yellow "官方源安装失败，尝试使用Gitee镜像安装...\n"
        manage_packages install git >/dev/null 2>&1
        local tmp_acme_dir
        tmp_acme_dir=$(mktemp -d)
        if git clone -q --depth=1 https://gitee.com/neilpang/acme.sh.git "${tmp_acme_dir}/acme.sh" 2>/dev/null; then
            ( cd "${tmp_acme_dir}/acme.sh" && ./acme.sh --install -m "$acme_email" --force >/dev/null 2>&1 )
        fi
        rm -rf "$tmp_acme_dir"
    fi

    if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
        red "\nacme.sh 安装失败！错误信息如下：\n"
        echo "$install_log" | tail -15
        red "\n请检查网络后重试，或手动执行以下命令安装后重试本菜单：\n"
        yellow "curl https://get.acme.sh | sh -s email=your@email.com\n"
        return 1
    fi

    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    return 0
}

resolve_dns_record() {
    local domain="$1" family="$2" ip="" qtype="A" resp
    [ "$family" = "6" ] && qtype="AAAA"

    resp=$(curl -sm 5 -H "accept: application/dns-json" \
        "https://cloudflare-dns.com/dns-query?name=${domain}&type=${qtype}" 2>/dev/null)
    if [ -n "$resp" ]; then
        if printf '%s' "$resp" | grep -q '"Answer"'; then
            ip=$(printf '%s' "$resp" | grep -o '"data":"[^"]*"' | tail -1 | cut -d'"' -f4)
        fi
        echo "$ip"
        return
    fi

    if command_exists getent; then
        if [ "$family" = "4" ]; then
            ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
        else
            ip=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
        fi
    fi
    echo "$ip"
}

write_port80_hooks() {
    mkdir -p "${work_dir}"
    cat > "${work_dir}/port80-prehook.sh" << 'EOF'
#!/bin/bash
STATE_FILE="/etc/sing-box/.port80_state"
: > "$STATE_FILE"
for svc in nginx apache2 httpd caddy reality-80; do
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "systemctl:$svc" >> "$STATE_FILE"
        systemctl stop "$svc" >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1 && rc-service "$svc" status 2>/dev/null | grep -q started; then
        echo "rc-service:$svc" >> "$STATE_FILE"
        rc-service "$svc" stop >/dev/null 2>&1
    fi
done
port80_pids() {
    if command -v fuser >/dev/null 2>&1; then
        fuser 80/tcp 2>/dev/null
    elif command -v ss >/dev/null 2>&1; then
        ss -H -tlnp 2>/dev/null | grep -E '[.:]80 ' | grep -oE 'pid=[0-9]+' | cut -d= -f2
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:80 -sTCP:LISTEN -t 2>/dev/null
    fi
}
for pid in $(port80_pids); do
    case "$(readlink -f /proc/$pid/exe 2>/dev/null)" in
        */sing-box) continue ;;
    esac
    kill -9 "$pid" >/dev/null 2>&1
done
exit 0
EOF

    cat > "${work_dir}/port80-posthook.sh" << 'EOF'
#!/bin/bash
STATE_FILE="/etc/sing-box/.port80_state"
[ -f "$STATE_FILE" ] || exit 0
while IFS=: read -r mgr svc; do
    [ -z "$svc" ] && continue
    if [ "$mgr" = "systemctl" ]; then
        systemctl start "$svc" >/dev/null 2>&1
    elif [ "$mgr" = "rc-service" ]; then
        rc-service "$svc" start >/dev/null 2>&1
    fi
done < "$STATE_FILE"
rm -f "$STATE_FILE"
exit 0
EOF
    chmod +x "${work_dir}/port80-prehook.sh" "${work_dir}/port80-posthook.sh"
}

apply_domain_cert() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; return
    fi

    clear; echo ""
    green "=== 申请域名证书 (用于 Hysteria2 / TUIC5) ===\n"
    yellow "申请前请确保："
    yellow "1. 域名已经解析到本机IP"
    yellow "2. 脚本会在验证期间临时强制释放80端口(自动停掉nginx/apache/caddy等)，验证完成后自动恢复\n"
    reading "请输入你要申请证书的域名: " domain
    if [ -z "$domain" ]; then
        red "域名不能为空！"; sleep 1; return
    fi
    reading "请输入联系邮箱 (回车默认使用 admin@gmail.com): " cert_email
    [ -z "$cert_email" ] && cert_email="admin@gmail.com"

    yellow "\n正在检测域名解析..."
    local server_ip4 server_ip6 resolved_ip4 resolved_ip6
    server_ip4=$(fetch_ip 4 5)
    server_ip6=$(fetch_ip 6 5)
    resolved_ip4=$(resolve_dns_record "$domain" 4)
    resolved_ip6=$(resolve_dns_record "$domain" 6)
    if [ -n "$server_ip4" ] && [ -n "$resolved_ip4" ] && [ "$server_ip4" != "$resolved_ip4" ]; then
        red "警告：域名 ${domain} 的A记录(${resolved_ip4}) 与本机IPv4(${server_ip4}) 不一致！"
        reading "证书申请大概率会失败，是否仍然继续? (y/n，默认n): " force_continue
        if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
            yellow "已取消申请。"; sleep 1; return
        fi
    fi
    if [ -n "$server_ip6" ] && [ -n "$resolved_ip6" ] && [ "$server_ip6" != "$resolved_ip6" ]; then
        red "警告：域名 ${domain} 的AAAA记录(${resolved_ip6}) 与本机IPv6(${server_ip6}) 不一致！"
        reading "证书申请大概率会失败，是否仍然继续? (y/n，默认n): " force_continue
        if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
            yellow "已取消申请。"; sleep 1; return
        fi
    fi
    if [ -z "$resolved_ip4" ] && [ -z "$resolved_ip6" ]; then
        red "警告：域名 ${domain} 未检测到任何A/AAAA解析记录！"
        reading "证书申请大概率会失败，是否仍然继续? (y/n，默认n): " force_continue
        if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
            yellow "已取消申请。"; sleep 1; return
        fi
    fi

    manage_packages install socat >/dev/null 2>&1
    install_acme "$cert_email" || { sleep 2; return; }
    allow_port 80/tcp >/dev/null 2>&1
    write_port80_hooks

    local acme="${HOME}/.acme.sh/acme.sh"

    yellow "\n正在申请证书，请稍候...\n"
    local issue_log
    local listen_opts=""
    if [ -z "$resolved_ip4" ] && [ -n "$resolved_ip6" ]; then
        listen_opts="--listen-v6"
    fi
    issue_log=$("$acme" --issue -d "$domain" --standalone $listen_opts -k ec-256 --force \
        --pre-hook "${work_dir}/port80-prehook.sh" \
        --post-hook "${work_dir}/port80-posthook.sh" 2>&1)
    local issue_result=$?
    echo "$issue_log" | tail -20

    if [ "$issue_result" -ne 0 ]; then
        [ -f "${work_dir}/.port80_state" ] && bash "${work_dir}/port80-posthook.sh" >/dev/null 2>&1
        red "\n证书申请失败！以上是acme.sh的详细输出，请检查域名解析是否生效、80端口是否仍被占用。\n"
        sleep 2; return
    fi

    local reload_cmd
    if command_exists systemctl; then
        reload_cmd="systemctl restart sing-box"
    elif command_exists rc-service; then
        reload_cmd="rc-service sing-box restart"
    else
        reload_cmd="true"
    fi

    "$acme" --install-cert -d "$domain" --ecc \
        --key-file "${work_dir}/private.key" \
        --fullchain-file "${work_dir}/cert.pem" \
        --reloadcmd "$reload_cmd"

    if [ $? -ne 0 ] || [ ! -s "${work_dir}/cert.pem" ] || [ ! -s "${work_dir}/private.key" ]; then
        red "\n证书安装失败！\n"; sleep 2; return
    fi

    chmod 644 "${work_dir}/cert.pem"
    chmod 600 "${work_dir}/private.key"
    echo "$domain" > "${work_dir}/cert_domain.txt"

    sleep 2
    ensure_singbox_running || { sleep 2; return; }

    if [ -f "$client_dir" ]; then
        sed -i -E "s#(hysteria2://[^?]*\?)sni=[^&]*&insecure=1&pinSHA256=[^&]*#\1sni=${domain}\&insecure=0#" "$client_dir"
        sed -i -E "s#(tuic://[^?]*\?)sni=[^&]*#\1sni=${domain}#" "$client_dir"
        sed -i -E "s|(anytls://[^?]*\?)insecure=1&sni=[^&#]*|\1insecure=0\&sni=${domain}|" "$client_dir"
        sed -i -E "s#(tuic://[^#]*)allow_insecure=1#\1allow_insecure=0#" "$client_dir"
        update_subscription
    fi

    green "\n域名证书申请成功！原bing.com自签证书已失效，hysteria2和tuic现已使用域名证书: ${purple}${domain}${re}"
    yellow "证书路径: ${work_dir}/cert.pem  密钥路径: ${work_dir}/private.key"
    yellow "acme.sh 已配置自动续期任务，到期前会自动续签证书并重启sing-box；"
    yellow "如果续期时80端口被其他服务占用，会自动临时停掉并在续期完成后恢复。\n"
    if [ -f "$client_dir" ]; then
        print_client_urls
    fi
}

restore_selfsigned_cert() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi

    if [ ! -f "${work_dir}/cert_domain.txt" ]; then
        yellow "当前未使用域名证书，无需恢复。"; sleep 1; return
    fi

    local old_domain
    old_domain=$(cat "${work_dir}/cert_domain.txt")
    reading "\n确认要停用域名证书(${old_domain})并恢复bing.com自签证书吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        yellow "已取消。"; sleep 1; return
    fi

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    chmod 600 "${work_dir}/private.key"

    [ -f "${HOME}/.acme.sh/acme.sh" ] && "${HOME}/.acme.sh/acme.sh" --remove -d "$old_domain" --ecc >/dev/null 2>&1
    rm -f "${work_dir}/cert_domain.txt"
    close_port80_if_unused

    ensure_singbox_running

    local fingerprint
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
    if [ -f "$client_dir" ]; then
        sed -i -E "s#(hysteria2://[^?]*\?)sni=[^&]*&insecure=0#\1sni=www.bing.com\&insecure=1\&pinSHA256=${fingerprint}#" "$client_dir"
        sed -i -E "s#(tuic://[^?]*\?)sni=[^&]*#\1sni=www.bing.com#" "$client_dir"
        sed -i -E "s|(anytls://[^?]*\?)insecure=0&sni=[^&#]*|\1insecure=1\&sni=www.bing.com|" "$client_dir"
        sed -i -E "s#(tuic://[^#]*)allow_insecure=0#\1allow_insecure=1#" "$client_dir"
        update_subscription
    fi

    green "\n已恢复为bing.com自签证书\n"
}

# 显示当前证书是否在有效期内及有效期时间
show_cert_validity() {
    local cert="${work_dir}/cert.pem"
    if [ ! -s "$cert" ] || ! command_exists openssl; then
        yellow "证书有效期: 无法读取证书文件"
        return 1
    fi

    local not_before not_after start_epoch end_epoch now_epoch days_left
    not_before=$(openssl x509 -noout -startdate -in "$cert" 2>/dev/null | cut -d= -f2)
    not_after=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2)
    if [ -z "$not_after" ]; then
        yellow "证书有效期: 解析失败"
        return 1
    fi

    local fmt_start="$not_before" fmt_end="$not_after"
    start_epoch=$(date -d "$not_before" +%s 2>/dev/null)
    end_epoch=$(date -d "$not_after" +%s 2>/dev/null)
    [ -n "$start_epoch" ] && fmt_start=$(date -d "@${start_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$not_before")
    [ -n "$end_epoch" ] && fmt_end=$(date -d "@${end_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$not_after")

    if ! openssl x509 -noout -checkend 0 -in "$cert" >/dev/null 2>&1; then
        red "证书有效性: 已过期"
    elif [ -n "$end_epoch" ]; then
        now_epoch=$(date +%s)
        days_left=$(( (end_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -le 7 ]; then
            yellow "证书有效性: 有效期内 (仅剩 ${days_left} 天，即将到期)"
        else
            green "证书有效性: 有效期内 (剩余 ${days_left} 天)"
        fi
    else
        green "证书有效性: 有效期内"
    fi
    echo -e "${skyblue}有效期: ${fmt_start} ~ ${fmt_end}${re}"
    return 0
}

manage_cert() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
    fi

    clear; echo ""
    green "=== 域名证书管理 (Hysteria2 / TUIC5) ===\n"
    if [ -f "${work_dir}/cert_domain.txt" ]; then
        green "当前证书状态: 域名证书 (${purple}$(cat "${work_dir}/cert_domain.txt")${re})"
    else
        yellow "当前证书状态: bing.com 自签证书"
    fi
    show_cert_validity
    echo ""
    green "1. 申请/更换域名证书"
    red   "2. 恢复自签证书"
    skyblue "-----------------------------"
    purple "0. 返回主菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " cert_choice
    echo ""
    case "${cert_choice}" in
        1) apply_domain_cert ;;
        2) restore_selfsigned_cert ;;
        0) menu; return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回域名证书管理菜单...\033[0m\n'
    manage_cert
}

manage_outbound_strategy() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
    fi

    local dns_file="${conf_dir}/dns.json"
    local current_strategy
    current_strategy=$(jq -r '.dns.strategy // "未设置"' "$dns_file" 2>/dev/null)

    clear; echo ""
    green "=== 出站 IPv4/IPv6 优先级设置 ===\n"
    green "当前策略: ${purple}${current_strategy}${re}\n"
    green "1. IPV4单独出站 (ipv4_only)"
    skyblue "-----------------------------"
    green "2. IPV4优先出站 (prefer_ipv4)"
    skyblue "-----------------------------"
    green "3. IPV6单独出站 (ipv6_only)"
    skyblue "-----------------------------"
    green "4. IPV6优先出站 (prefer_ipv6)"
    skyblue "-----------------------------"
    purple "0. 返回主菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " strategy_choice
    echo ""

    local new_strategy=""
    case "${strategy_choice}" in
        1) new_strategy="ipv4_only" ;;
        2) new_strategy="prefer_ipv4" ;;
        3) new_strategy="ipv6_only" ;;
        4) new_strategy="prefer_ipv6" ;;
        0) menu; return ;;
        *)
            red "无效的选项！"
            read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n'
            manage_outbound_strategy; return
            ;;
    esac

    local route_file="${conf_dir}/route.json"
    local outbound_file="${conf_dir}/outbounds.json"

    if ! jq -e '.dns.servers[] | select(.tag=="sys")' "$dns_file" >/dev/null 2>&1; then
        local heal_dns
        heal_dns=$(awk '/^nameserver[ \t]+/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
        [ -z "$heal_dns" ] && heal_dns="1.1.1.1"
        jq_write "$dns_file" --arg s "$heal_dns" '.dns.servers = [{"tag":"sys","type":"udp","server":$s}] + .dns.servers'
    fi

    jq_write "$dns_file" --arg s "$new_strategy" '.dns.strategy = $s'

    if [ -f "$outbound_file" ] && jq -e '.outbounds[] | select(.tag == "direct") | has("domain_strategy")' "$outbound_file" 2>/dev/null | grep -q true; then
        jq_write "$outbound_file" '(.outbounds[] | select(.tag == "direct")) |= del(.domain_strategy)'
    fi

    local cur_resolver_tag="local"
    if ip link show 2>/dev/null | grep -qE '^[0-9]+: (wgcf-v[46]|[a-z]*clat[a-z0-9]*)[:@]'; then
        cur_resolver_tag="sys"
    fi
    if [ -f "$route_file" ]; then
        jq_write "$route_file" --arg s "$new_strategy" --arg srv "$cur_resolver_tag" \
            '.route.default_domain_resolver = {"server": $srv, "strategy": $s}'
    fi

    reload_singbox
    green "\n出站IPv4/IPv6优先级已设置为：${purple}${new_strategy}${re}\n"
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回主菜单...\033[0m\n'
    menu
}

update_singbox_core() {
    local target_version="$1"
    local label="$2"

    if [ -z "$target_version" ]; then
        red "未获取到有效的版本号！"; sleep 1; return 1
    fi

    local ARCH_RAW ARCH
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; return 1 ;;
    esac

    if [ -f /etc/alpine-release ]; then
        if ! apk info -e gcompat >/dev/null 2>&1; then
            yellow "\n检测到 Alpine (musl) 系统，正在安装 glibc 兼容层 gcompat...\n"
            apk add --no-cache gcompat >/dev/null 2>&1
            if ! apk info -e gcompat >/dev/null 2>&1; then
                red "gcompat 安装失败，官方sing-box二进制在Alpine上大概率无法运行，请手动执行: apk add gcompat\n"
            fi
        fi
    fi

    local tmp_dir pkg_name dl_url
    tmp_dir=$(mktemp -d)
    pkg_name="sing-box-${target_version}-linux-${ARCH}"
    dl_url="https://github.com/SagerNet/sing-box/releases/download/v${target_version}/${pkg_name}.tar.gz"

    yellow "\n正在下载 ${label} v${target_version} (${ARCH})...\n"
    if ! gh_download "$dl_url" "${tmp_dir}/${pkg_name}.tar.gz"; then
        red "下载失败！请确认版本号 v${target_version} 是否存在，以及是否有对应架构(${ARCH})的发行包。\n"
        gh_ipv6_hint
        rm -rf "$tmp_dir"; return 1
    fi

    tar -xzf "${tmp_dir}/${pkg_name}.tar.gz" -C "$tmp_dir" 2>/dev/null
    if [ ! -f "${tmp_dir}/${pkg_name}/sing-box" ]; then
        red "解压失败或未找到sing-box二进制文件！\n"
        rm -rf "$tmp_dir"; return 1
    fi

    cp "${work_dir}/sing-box" "${work_dir}/sing-box.bak" 2>/dev/null
    stop_singbox >/dev/null 2>&1
    cp "${tmp_dir}/${pkg_name}/sing-box" "${work_dir}/sing-box"
    chmod +x "${work_dir}/sing-box"
    rm -rf "$tmp_dir"

    local new_ver new_ver_err
    new_ver_err=$("${work_dir}/sing-box" version 2>&1 >/dev/null)
    new_ver=$("${work_dir}/sing-box" version 2>/dev/null | head -1)
    if [ -z "$new_ver" ]; then
        red "\n新内核校验失败，正在回滚到旧版本...\n"
        [ -n "$new_ver_err" ] && { yellow "错误详情：\n"; echo "$new_ver_err" | head -10; }
        [ -f "${work_dir}/sing-box.bak" ] && mv "${work_dir}/sing-box.bak" "${work_dir}/sing-box" && chmod +x "${work_dir}/sing-box"
        restart_singbox
        return 1
    fi

    yellow "正在校验现有配置与新内核的兼容性...\n"
    local check_output
    check_output=$("${work_dir}/sing-box" check -C "${conf_dir}" 2>&1)
    if [ $? -ne 0 ]; then
        red "\n新内核 ${new_ver} 无法加载现有配置，可能存在破坏性变更，正在回滚到旧版本...\n"
        echo "$check_output" | head -20
        if [ -f "${work_dir}/sing-box.bak" ]; then
            mv "${work_dir}/sing-box.bak" "${work_dir}/sing-box" && chmod +x "${work_dir}/sing-box"
        fi
        restart_singbox
        yellow "\n已回滚到更新前的内核版本。如需使用新内核，请根据上方报错信息手动调整 ${conf_dir} 下的配置文件后再重试。\n"
        return 1
    fi

    restart_singbox
    sleep 2
    if ! service_is_running "sing-box"; then
        red "\n新内核 ${new_ver} 配置校验通过，但服务实际启动失败，正在回滚到旧版本...\n"
        if [ -f "${work_dir}/sing-box.bak" ]; then
            mv "${work_dir}/sing-box.bak" "${work_dir}/sing-box" && chmod +x "${work_dir}/sing-box"
        fi
        restart_singbox
        yellow "\n已回滚到更新前的内核版本，请检查 ${work_dir}/sb.log 或 journalctl -u sing-box 获取详细报错。\n"
        return 1
    fi

    rm -f "${work_dir}/sing-box.bak"
    green "\nsing-box 内核已更新为 ${label}：${purple}${new_ver}${re}\n"
    return 0
}

manage_singbox_core() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
    fi

    clear; echo ""
    green "=== sing-box 内核查看与更新 ===\n"
    local cur_ver
    cur_ver=$("${work_dir}/sing-box" version 2>/dev/null | head -1)
    green "当前内核版本: ${purple}${cur_ver:-未知}${re}\n"
    green "1. 查看更新到最新正式版"
    skyblue "-----------------------------"
    green "2. 更新到最新测试版(Beta/RC/Pre-release)"
    skyblue "-----------------------------"
    green "3. 更新到指定版本"
    skyblue "-----------------------------"
    purple "0. 返回主菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " core_choice
    echo ""
    case "${core_choice}" in
        1)
            yellow "正在获取最新稳定正式版信息...\n"
            local releases_json latest_version cur_num
            if releases_json=$(gh_fetch_json "https://api.github.com/repos/SagerNet/sing-box/releases"); then
                latest_version=$(echo "$releases_json" | jq -r '[.[] | select(.prerelease==false and .draft==false)][0].tag_name // empty' | sed 's/^v//')
            fi
            if [ -z "$latest_version" ]; then
                red "获取版本信息失败，请检查网络！\n"
                gh_ipv6_hint
            else
                cur_num=$(echo "$cur_ver" | awk '{print $3}' | sed 's/^v//')
                green "最新稳定正式版: ${purple}v${latest_version}${re}\n"
                if [ "$cur_num" = "$latest_version" ]; then
                    green "已经是最新正式版，无需更新！\n"
                else
                    if [ -n "$cur_num" ] && [ "$(printf '%s\n%s\n' "$cur_num" "$latest_version" | sort -V | tail -n1)" = "$cur_num" ]; then
                        yellow "当前版本 v${cur_num} 高于最新正式版（可能正在使用测试版），继续将切换(回退)到正式版 v${latest_version}。\n"
                        reading "确认切换到正式版 v${latest_version}？(y/n): " confirm
                    else
                        reading "发现新正式版 v${latest_version}，是否更新？(y/n): " confirm
                    fi
                    [[ "$confirm" == "y" || "$confirm" == "Y" ]] && update_singbox_core "$latest_version" "最新稳定正式版"
                fi
            fi
            ;;
        2)
            yellow "正在获取最新测试版信息...\n"
            local releases_json beta_version
            if releases_json=$(gh_fetch_json "https://api.github.com/repos/SagerNet/sing-box/releases"); then
                beta_version=$(echo "$releases_json" | jq -r '[.[] | select(.prerelease==true and .draft==false)][0].tag_name // empty' | sed 's/^v//')
            fi
            if [ -z "$beta_version" ]; then
                red "未获取到测试版信息（可能当前没有可用的测试版，也可能是网络问题）！\n"
                gh_ipv6_hint
            else
                reading "即将更新到最新测试版 v${beta_version}，确认继续？(y/n): " confirm
                [[ "$confirm" == "y" || "$confirm" == "Y" ]] && update_singbox_core "$beta_version" "最新测试版"
            fi
            ;;
        3)
            reading "请输入要更新到的版本号 (如 1.11.4，不需要带v前缀): " spec_version
            spec_version=$(echo "$spec_version" | sed 's/^v//')
            if [ -z "$spec_version" ]; then
                red "版本号不能为空！\n"
            else
                update_singbox_core "$spec_version" "指定版本"
            fi
            ;;
        0) menu; return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回内核管理菜单...\033[0m\n'
    manage_singbox_core
}

# 检查是否有其它 sysctl 配置会在重启后覆盖 BBR+fq：
# 只报「值不一致」且「加载顺序晚于本配置」的文件；软链接按真实路径去重
check_sysctl_conflicts() {
    local ours="$1" ours_real f real base line key val expected found=0
    local seen=" "

    ours_real=$(readlink -f "$ours" 2>/dev/null || echo "$ours")

    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ -f "$f" ] || continue
        real=$(readlink -f "$f" 2>/dev/null || echo "$f")
        [ "$real" = "$ours_real" ] && continue
        case "$seen" in *" $real "*) continue ;; esac
        seen="$seen$real "

        # /etc/sysctl.conf 最后加载；sysctl.d 内按文件名排序，排在本配置之前的会被本配置覆盖，无需关心
        if [ "$f" != "/etc/sysctl.conf" ] && [ "$real" != "/etc/sysctl.conf" ]; then
            base=$(basename "$f")
            [ "$(printf '%s\n%s\n' "$base" "$(basename "$ours")" | LC_ALL=C sort | tail -n1)" = "$base" ] || continue
        fi

        while IFS= read -r line; do
            key=$(echo "$line" | sed -E 's/^[[:space:]]*([^=[:space:]]+).*/\1/')
            val=$(echo "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
            case "$key" in
                net.ipv4.tcp_congestion_control) expected="bbr" ;;
                net.core.default_qdisc) expected="fq" ;;
                *) continue ;;
            esac
            if [ "$val" != "$expected" ]; then
                if [ "$found" -eq 0 ]; then
                    yellow "检测到以下配置与 BBR+fq 不一致，重启后可能覆盖本设置，请检查："
                    found=1
                fi
                echo "  $real: $key = $val"
            fi
        done < <(grep -E '^[[:space:]]*net\.(ipv4\.tcp_congestion_control|core\.default_qdisc)[[:space:]]*=' "$f" 2>/dev/null)
    done
}

# 让网卡立即用上 fq：单队列网卡直接替换（无需重启），多队列(mq)只提示，虚拟网卡(noqueue)跳过
apply_fq_to_nics() {
    local iface root_qdisc ifaces

    command -v tc >/dev/null 2>&1 || return 0
    command -v ip >/dev/null 2>&1 || return 0

    # 默认路由出口 + 物理/半虚拟化网卡（/sys/class/net/xxx/device 存在）
    ifaces=$( {
        ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
        ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
        for d in /sys/class/net/*; do
            [ -e "$d/device" ] && basename "$d"
        done
    } | sort -u)

    for iface in $ifaces; do
        [ "$iface" = "lo" ] && continue
        root_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root/ {print $2; exit}')
        case "$root_qdisc" in
            ""|noqueue)
                # 虚拟网卡（隧道/NAT64/veth 等），本身不排队，无需处理
                ;;
            fq)
                green "网卡 ${iface} 当前队列已是 fq。"
                ;;
            mq|mqprio)
                yellow "网卡 ${iface} 是多队列网卡（${root_qdisc}），其子队列将在重启后变为 fq；不重启也不影响 BBR 工作。"
                ;;
            *)
                if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
                    green "网卡 ${iface} 队列已从 ${root_qdisc} 即时切换为 fq（无需重启）。"
                else
                    yellow "网卡 ${iface} 队列（${root_qdisc}）切换 fq 失败，fq 将在重启后生效；BBR 本身已即时生效。"
                fi
                ;;
        esac
    done
}

enable_bbr_fq() {
    local sysctl_conf="/etc/sysctl.d/99-bbr-fq.conf"
    local modload_conf="/etc/modules-load.d/tcp_bbr.conf"
    local old_cc old_qdisc cc qdisc

    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    old_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
        red "当前内核不支持 BBR（OpenVZ/LXC 等容器需宿主机开启），切换失败。"
        return 1
    fi

    # 先改运行时参数，成功后再写配置文件，避免失败时残留无效配置
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || \
       ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        [ -n "$old_qdisc" ] && sysctl -w net.core.default_qdisc="$old_qdisc" >/dev/null 2>&1
        [ -n "$old_cc" ] && sysctl -w net.ipv4.tcp_congestion_control="$old_cc" >/dev/null 2>&1
        red "写入内核参数失败（可能是容器环境禁止修改 sysctl），已回滚。"
        return 1
    fi

    mkdir -p /etc/sysctl.d
    cat > "$sysctl_conf" << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 开机提前加载 tcp_bbr 模块，避免 sysctl 先于模块加载而失效
    if [ -d /etc/modules-load.d ]; then
        echo "tcp_bbr" > "$modload_conf"
    fi

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [ "$cc" != "bbr" ] || [ "$qdisc" != "fq" ]; then
        red "切换失败，当前为: ${cc:-unknown}+${qdisc:-unknown}"
        return 1
    fi

    green "已成功切换为 BBR + fq，并已设置为永久生效。"

    check_sysctl_conflicts "$sysctl_conf"

    # default_qdisc 只对新建的队列生效，这里让现有网卡立即切换
    apply_fq_to_nics
}

http_date_to_epoch() {
    local s="$1" epoch
    [ -z "$s" ] && return 1
    epoch=$(date -d "$s" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    epoch=$(date -D '%a, %d %b %Y %H:%M:%S GMT' -d "$s" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    epoch=$(date -D '%a, %d %b %Y %H:%M:%S %Z' -d "$s" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        epoch=$(HTTP_DATE="$s" python3 -c 'import os; from email.utils import parsedate_to_datetime; print(int(parsedate_to_datetime(os.environ["HTTP_DATE"]).timestamp()))' 2>/dev/null) && { echo "$epoch"; return 0; }
    fi
    return 1
}

get_time_offset() {
    local url remote_str remote_epoch local_epoch
    for url in "https://www.cloudflare.com" "https://www.qq.com" "https://www.baidu.com"; do
        remote_str=$(curl -sI --max-time 4 "$url" 2>/dev/null | grep -i '^date:' | head -1 | sed 's/^[Dd]ate:[[:space:]]*//' | tr -d '\r')
        [ -n "$remote_str" ] && break
    done
    [ -z "$remote_str" ] && return 1
    remote_epoch=$(http_date_to_epoch "$remote_str") || return 1
    local_epoch=$(date +%s)
    echo $((local_epoch - remote_epoch))
    return 0
}

time_sync_status() {
    local installed=0 running=0 svc="chrony" offset abs_offset

    if command_exists chronyd || command_exists chronyc; then
        installed=1
        if command_exists systemctl; then
            systemctl list-unit-files 2>/dev/null | grep -q '^chronyd\.service' && svc="chronyd"
            systemctl is-active "$svc" &>/dev/null && running=1
        elif command_exists rc-service; then
            rc-service chronyd status &>/dev/null && running=1
        fi
    fi

    if [ "$installed" -eq 1 ] && [ "$running" -eq 1 ]; then
        green "校时服务: 已安装并运行中(chrony)\n"
    elif [ "$installed" -eq 1 ]; then
        yellow "校时服务: 已安装但未运行(chrony)\n"
    else
        yellow "校时服务: 未安装\n"
    fi

    yellow "本机系统时间: $(date)\n"

    offset=$(get_time_offset)
    if [ -z "$offset" ]; then
        red "网络时间校验: 获取失败(可能是网络受限)，暂无法判断偏差\n"
        return 1
    fi
    abs_offset=${offset#-}
    if [ "$abs_offset" -le 3 ]; then
        green "时间偏差: 约 ${offset}s，正常，无需处理\n"
    elif [ "$abs_offset" -le 30 ]; then
        yellow "时间偏差: 约 ${offset}s，偏差较小，建议关注\n"
    else
        red "时间偏差: 约 ${offset}s，偏差过大！建议执行「2. 安装并立即同步时间」修复(或先用「1. 仅校准一次」应急)\n"
    fi
    return 0
}

remove_system_time_sync() {
    clear; echo ""
    purple "=== 卸载时间同步服务 ===\n"
    if ! command_exists chronyd && ! command_exists chronyc; then
        yellow "未检测到已安装的 chrony，无需卸载\n"
        return 0
    fi

    if command_exists systemctl; then
        local svc="chrony"
        systemctl list-unit-files 2>/dev/null | grep -q '^chronyd\.service' && svc="chronyd"
        systemctl disable --now "$svc" &>/dev/null
    elif command_exists rc-service; then
        rc-service chronyd stop &>/dev/null
        rc-update del chronyd default &>/dev/null
    fi

    manage_packages uninstall chrony

    if command_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
        yellow "正在恢复 systemd-timesyncd 作为基础时间同步...\n"
        systemctl enable --now systemd-timesyncd &>/dev/null
    fi

    green "chrony 已卸载\n"
    return 0
}

quick_time_sync() {
    clear; echo ""
    purple "=== 仅校准一次(不安装chrony) ===\n"
    yellow "校准前系统时间: $(date)\n"

    local url remote_str
    for url in "https://www.cloudflare.com" "https://www.qq.com" "https://www.baidu.com"; do
        remote_str=$(curl -sI --max-time 4 "$url" 2>/dev/null | grep -i '^date:' | head -1 | sed 's/^[Dd]ate:[[:space:]]*//' | tr -d '\r')
        [ -n "$remote_str" ] && break
    done

    if [ -z "$remote_str" ]; then
        red "获取网络时间失败(可能是网络受限)，无法校准\n"
        return 1
    fi

    local remote_epoch
    remote_epoch=$(http_date_to_epoch "$remote_str")
    if [ -n "$remote_epoch" ] && date -s @"$remote_epoch" &>/dev/null; then
        green "已根据网络时间校准系统时间\n"
    elif date -s "$remote_str" &>/dev/null; then
        green "已根据网络时间校准系统时间\n"
    else
        red "校准失败，请确认当前是root权限；Alpine/BusyBox 可尝试安装: apk add coreutils，或改用菜单「2. 安装并立即同步时间」\n"
        return 1
    fi

    if command_exists hwclock; then
        hwclock --systohc &>/dev/null && yellow "已同步写入硬件时钟(RTC)\n"
    fi

    echo ""
    green "校准后系统时间: $(date)\n"
    yellow "提示：此校准为一次性操作，不会常驻后台防止时间再次漂移。若服务器时钟经常跑偏，建议用「2. 安装并立即同步时间」装 chrony 常驻校准。\n"
    return 0
}

time_sync_menu() {
    clear; echo ""
    purple "=== 系统时间同步管理 ===\n"
    time_sync_status
    echo ""
    green  "1. 仅校准一次(不安装chrony)"
    green  "2. 安装并立即同步时间(chrony)"
    red    "3. 卸载时间同步服务(chrony)"
    purple "0. 返回主菜单"
    echo "==========================="
    reading "请输入选择(0-3，回车默认1): " tsm_choice
    [ -z "$tsm_choice" ] && tsm_choice=1
    echo ""
    case "$tsm_choice" in
        1) quick_time_sync; read -n 1 -s -r -p $'\n按任意键返回...'; time_sync_menu ;;
        2) sync_system_time; read -n 1 -s -r -p $'\n按任意键返回...'; time_sync_menu ;;
        3) remove_system_time_sync; read -n 1 -s -r -p $'\n按任意键返回...'; time_sync_menu ;;
        0) return ;;
        *) red "无效选项\n"; sleep 1; time_sync_menu ;;
    esac
}

sync_system_time() {
    clear; echo ""
    green "=== 系统时间同步（校时，缓解因时间偏差导致的连接异常/卡顿） ===\n"
    yellow "同步前系统时间: $(date)\n"

    if ! command_exists chronyd && ! command_exists chronyc; then
        yellow "正在安装 chrony...\n"
        manage_packages install chrony || { red "chrony 安装失败，请检查网络后重试，或手动安装。\n"; return 1; }
    else
        green "chrony 已安装\n"
    fi

    if command_exists systemctl; then
        if systemctl is-active systemd-timesyncd &>/dev/null; then
            yellow "检测到 systemd-timesyncd 正在运行，为避免与 chrony 冲突，先将其停用...\n"
            systemctl disable --now systemd-timesyncd &>/dev/null
        fi
        local svc="chrony"
        systemctl list-unit-files 2>/dev/null | grep -q '^chronyd\.service' && svc="chronyd"
        systemctl enable --now "$svc" &>/dev/null
        yellow "正在强制校准一次系统时间...\n"
        command_exists chronyc && chronyc -a makestep &>/dev/null
        sleep 1
        if systemctl is-active "$svc" &>/dev/null; then
            green "时间同步服务(${svc})已启用并正在运行。\n"
        else
            red "时间同步服务启动失败，请手动检查: systemctl status ${svc}\n"
        fi
    elif command_exists rc-service; then
        rc-update add chronyd default &>/dev/null
        rc-service chronyd start &>/dev/null || rc-service chronyd restart &>/dev/null
        command_exists chronyc && chronyc -a makestep &>/dev/null
        green "chronyd 已通过 OpenRC 启用。\n"
    else
        yellow "未识别到 systemctl / OpenRC，尝试直接前台校时一次...\n"
        command_exists chronyd && chronyd -q 'server pool.ntp.org iburst' 2>&1 | tail -5
    fi

    echo ""
    green "同步后系统时间: $(date)\n"
    yellow "提示：VPS 卡顿/连接异常除了时间偏差，也可能是 CPU/内存/带宽跑满导致，同步后若问题依旧，建议用 top/负载排查或联系服务商。\n"
    return 0
}

do_install_singbox() {
    local singbox_check
    check_singbox &>/dev/null; singbox_check=$?
    if [ "${singbox_check}" -eq 0 ]; then
        yellow "sing-box 已经安装！\n"
        return 0
    fi

    ensure_core_deps || { red "依赖安装失败"; return 1; }
    install_singbox || { red "安装失败，已中止"; return 1; }
    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
        change_hosts
        restart_singbox
        rc-service argo restart
    else
        echo "Unsupported init system"; exit 1
    fi
    verify_udp_listening
    get_info
    create_shortcut
    return 0
}

swap_file="/swapfile"

get_swap_size_mb() {
    if swapon --show=NAME 2>/dev/null | grep -qx "$swap_file"; then
        local kb
        kb=$(awk -v f="$swap_file" '$1==f{print $3}' /proc/swaps 2>/dev/null)
        if [ -n "$kb" ]; then
            echo $(( kb / 1024 ))
        else
            echo "?"
        fi
    else
        echo 0
    fi
}

check_swap_status() {
    local mb
    mb=$(get_swap_size_mb)
    if [ "$mb" != "0" ] && [ -n "$mb" ]; then
        echo "已启用 (约${mb}M)"
    else
        echo "未启用"
    fi
}

system_swap_summary() {
    local total_kb
    total_kb=$(awk 'NR>1{sum+=$3} END{print sum+0}' /proc/swaps 2>/dev/null)
    if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ]; then
        echo "已启用 (系统总计约 $(( total_kb / 1024 ))M)"
    else
        echo "未启用"
    fi
}

# 是否存在非本脚本创建的系统默认swap
has_system_swap() {
    local n
    n=$(awk -v f="$swap_file" 'NR>1 && $1!=f{c++} END{print c+0}' /proc/swaps 2>/dev/null)
    [ -n "$n" ] && [ "$n" -gt 0 ]
}

create_swap() {
    local size_mb="$1"
    if ! [[ "$size_mb" =~ ^[0-9]+$ ]] || [ "$size_mb" -le 0 ]; then
        red "无效的大小，请输入正整数(单位M)\n"
        return 1
    fi

    local avail_mb
    avail_mb=$(df -Pm "$(dirname "$swap_file")" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$size_mb" ]; then
        red "磁盘可用空间不足(可用约${avail_mb}M，需要${size_mb}M)，已取消\n"
        return 1
    fi

    yellow "正在配置 ${size_mb}M 虚拟内存(swap)...\n"

    if swapon --show=NAME 2>/dev/null | grep -qx "$swap_file"; then
        swapoff "$swap_file" 2>/dev/null
    fi
    rm -f "$swap_file"

    if command_exists fallocate && fallocate -l "${size_mb}M" "$swap_file" 2>/dev/null; then
        :
    else
        dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" status=none
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file" >/dev/null 2>&1
    if ! swapon "$swap_file" 2>/dev/null; then
        red "swap启用失败，请检查系统是否支持或内核限制\n"
        rm -f "$swap_file"
        return 1
    fi

    if ! grep -qE "^[^#].*${swap_file}[[:space:]]" /etc/fstab 2>/dev/null; then
        echo "${swap_file} none swap sw 0 0" >> /etc/fstab
    fi

    green "虚拟内存已设置为 ${size_mb}M 并已启用(开机自动挂载)\n"
    free -h
}

delete_swap() {
    if [ ! -f "$swap_file" ] && ! swapon --show=NAME 2>/dev/null | grep -qx "$swap_file"; then
        yellow "未检测到本脚本创建的swap，无需处理\n"
        return 0
    fi
    swapoff "$swap_file" 2>/dev/null
    sed -i "\|^${swap_file}[[:space:]]|d" /etc/fstab 2>/dev/null
    rm -f "$swap_file"
    green "本脚本管理的虚拟内存(${swap_file})已关闭并删除\n"
}

swap_manage_menu() {
    clear; echo ""
    purple "=== 调整虚拟内存(SWAP) ===\n"
    green "系统当前SWAP状态: $(system_swap_summary)"
    if has_system_swap; then
        if swapon --show=NAME 2>/dev/null | grep -qx "$swap_file"; then
            green "扩展虚拟内存(SWAP): $(check_swap_status)"
        fi
        yellow "系统默认已配置虚拟内存(SWAP)，继续操作将会作为系统虚拟内存(SWAP)的扩展部分\n"
    else
        echo ""
    fi
    green  "1. 512M"
    green  "2. 1024M"
    green  "3. 1536M"
    green  "4. 自定义大小"
    red    "5. 关闭并删除虚拟内存"
    purple "0. 返回主菜单"
    echo "==========================="
    reading "请输入选择(0-5): " swap_choice
    echo ""
    case "$swap_choice" in
        1) create_swap 512;  read -n 1 -s -r -p $'\n按任意键返回...'; swap_manage_menu ;;
        2) create_swap 1024; read -n 1 -s -r -p $'\n按任意键返回...'; swap_manage_menu ;;
        3) create_swap 1536; read -n 1 -s -r -p $'\n按任意键返回...'; swap_manage_menu ;;
        4)
            reading "请输入自定义大小(单位M，例如 2048 表示2G): " swap_custom_mb
            create_swap "$swap_custom_mb"
            read -n 1 -s -r -p $'\n按任意键返回...'; swap_manage_menu
            ;;
        5) delete_swap; read -n 1 -s -r -p $'\n按任意键返回...'; swap_manage_menu ;;
        0) return ;;
        *) red "无效选项\n"; sleep 1; swap_manage_menu ;;
    esac
}

# 主菜单
menu() {
    singbox_status=$(check_singbox 2>/dev/null)
    dualstack_status=$(check_dualstack 2>/dev/null)
    argo_status=$(check_argo 2>/dev/null)
    congestion_status=$(check_congestion 2>/dev/null)

    clear; echo ""
    green "Telegram群组: ${purple}https://t.me/eooceu${re}"
    green "YouTube频道: ${purple}https://youtube.com/@eooce${re}"
    green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
    purple "=== 老王sing-box四合一安装脚本 ===\n"
    purple "---Argo 状态: ${argo_status}"
    purple "singbox 状态: ${singbox_status}"
    purple "拥塞控制算法: ${congestion_status}"
    purple "-双栈IP 状态: ${dualstack_status}\n"
    green " 1. 安装sing-box"
    red   " 2. 卸载sing-box"
    echo "================"
    green " 3. sing-box管理"
    green " 4. sing-box更新"
    echo "================"
    green " 5. 查看节点信息"
    green " 6. 修改节点配置"
    green " 7. 增加删除协议"
    green " 8. Argo隧道管理"
    green " 9. 域名证书管理"
    echo "================"
    green "10. WARP分流管理"
    green "11. WARP全局出站"
    green "12. 双栈出站优先"
    echo "================"
    green "13. 切换为BBR+fq"
    green "14. 系统时间同步"
    green "15. 调整虚拟内存"
    echo "================"
    purple "20. ssh综合工具箱"
    echo "================"
    red " 0. 退出脚本"
    echo "============"
}

# 捕获 Ctrl+C
trap 'red "\n强制退出"; exit' INT

# ---- 参数解析入口 ----
case "$1" in
    -i | --install)
        auto_install
        exit 0
        ;;
    -u | --uninstall)
        auto_uninstall
        exit 0
        ;;
    -c | --check)
        check_nodes
        exit 0
        ;;
    -r | --restart)
        get_quick_tunnel
        change_argo_domain
        exit 0
        ;;
    -h | --help)
        echo ""
        green "用法: [sb或脚本] [参数], 示例: sb -c(查看节点信息)"
        echo ""
        green "  -i, --install     无交互安装sing-box"
        green "  -c, --check       查看节点信息"
        green "  -r, --restart     重新获取argo临时隧道并更新到订阅"
        green "  -u, --uninstall   无交互卸载sing-box"
        green "  -h, --help        显示此帮助信息"
        echo ""
        green "  不带参数          进入交互式主菜单"
        echo ""
        exit 0
        ;;
    "")
        while true; do
            menu
            reading "请输入选择(0-15,20): " choice 
            echo ""
            need_pause=true  
            case "${choice}" in
                1)  do_install_singbox || continue ;;
                2)  uninstall_singbox;  need_pause=false ;;
                3)  manage_singbox;     need_pause=false ;;
                4)  manage_singbox_core; need_pause=false ;;
                5)  check_nodes;        need_pause=true ;;
                6)  change_config;      [ $? -eq 10 ] && need_pause=false || need_pause=true ;;
                7)  manage_protocols;   need_pause=false ;;
                8)  manage_argo;        [ $? -eq 10 ] && need_pause=false || need_pause=true ;;
                9)  manage_cert;        need_pause=false ;;
                10) warp_manage;        need_pause=false ;;
                11) system_warp_menu;   need_pause=false ;;
                12) manage_outbound_strategy; need_pause=false ;;
                13) enable_bbr_fq;       need_pause=true ;;
                14) time_sync_menu;      need_pause=false ;;
                15) swap_manage_menu;    need_pause=false ;;
                20)
                    clear
                    bash <(curl -Ls ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                0)  exit 0 ;;       
                *)
                    red "无效的选项，请输入 0-15 或 20"
                    need_pause=true
                    ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
        done
        ;;
    *)
        red "未知参数: $1"
        echo ""
        green "用法: sb [参数],相关参数:[-i|-u|-c|-r|-h], 首次安装：bash脚本 -i(前面可带环境变量)"
        exit 1
        ;;
esac
