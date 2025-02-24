#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请以 root 用户运行此脚本${NC}"
    exit 1
fi

# 全局变量
CONFIG_DIR="/usr/local/etc/xray"
USER_FILE="$CONFIG_DIR/users.json"
CADDY_CONFIG="/etc/caddy/Caddyfile"
SCRIPT_PATH="/etc/v2ray-agent/xray_install.sh"
DOMAIN=""
EMAIL=""

# 生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 生成客户端链接和订阅
generate_client_link() {
    local username=$1
    local uuid=$2
    vless_link="vless://$uuid@$DOMAIN:443?encryption=none&security=tls&type=tcp#$username"
    subscribe_url="https://$DOMAIN/subscribe/$username.yml"
    echo -e "\n${YELLOW}用户 $username 的链接和订阅:${NC}"
    echo -e "VLESS 链接: $vless_link"
    echo -e "订阅 URL: $subscribe_url"
}

# 初始化用户文件
init_users() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$USER_FILE" ]; then
        uuid=$(generate_uuid)
        echo "{\"users\": [{\"id\": 1, \"name\": \"sinian\", \"uuid\": \"$uuid\", \"expire_time\": \"permanent\", \"status\": \"enabled\"}]}" > "$USER_FILE"
        echo -e "${GREEN}用户文件已创建，默认用户 sinian 已添加${NC}"
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}检测系统类型...${NC}"
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        echo "检测到系统: Ubuntu/Debian"
        # 安装基本依赖
        apt update -y || { echo -e "${RED}apt update 失败，请检查网络${NC}"; exit 1; }
        apt install -y socat jq qrencode lsb-release curl unzip systemd openssl dnsutils || { echo -e "${RED}基本依赖安装失败${NC}"; exit 1; }
        
        # 安装 Caddy
        echo -e "${YELLOW}安装 Caddy...${NC}"
        apt install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor | tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null || { echo -e "${RED}GPG 密钥导入失败${NC}"; exit 1; }
        echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update -y || { echo -e "${RED}Caddy 仓库更新失败，请检查网络或 GPG 密钥${NC}"; exit 1; }
        apt install -y caddy || { echo -e "${RED}Caddy 安装失败${NC}"; exit 1; }
        
        # 验证 Caddy 服务
        systemctl status caddy >/dev/null 2>&1 || { echo -e "${RED}Caddy 服务未正确安装${NC}"; exit 1; }
    elif grep -qi "centos" /etc/os-release; then
        echo "检测到系统: CentOS"
        yum install -y epel-release && yum install -y socat jq qrencode curl unzip systemd openssl bind-utils || { echo -e "${RED}依赖安装失败${NC}"; exit 1; }
        yum install -y caddy || { echo -e "${RED}Caddy 安装失败，请检查 CentOS 源${NC}"; exit 1; }
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi
}

# 检查域名和 IP 绑定
check_domain_ip() {
    local server_ip=$(curl -s ifconfig.me)
    local domain_ip=$(dig +short "$DOMAIN" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    echo -e "${YELLOW}检查域名和 IP 绑定情况...${NC}"
    echo "服务器公网 IP: $server_ip"
    echo "域名 $DOMAIN 解析 IP: $domain_ip"
    if [ "$server_ip" = "$domain_ip" ]; then
        echo -e "${GREEN}域名和服务器 IP 绑定一致，继续安装...${NC}"
    else
        echo -e "${RED}错误：域名 $DOMAIN 解析的 IP 与服务器 IP 不一致！${NC}"
        echo "请检查 DNS 配置，确保域名正确解析到 $server_ip。"
        exit 1
    fi
}

# 配置 Caddy
install_caddy() {
    echo -e "${YELLOW}配置 Caddy 并申请证书...${NC}"
    mkdir -p /etc/caddy
    cat > "$CADDY_CONFIG" <<EOF
$DOMAIN:443 {
    tls $EMAIL
    reverse_proxy localhost:8443 {
        transport http {
            versions h2
        }
    }
}
EOF
    systemctl restart caddy || { echo -e "${RED}Caddy 重启失败${NC}"; exit 1; }
    echo -e "${GREEN}Caddy 配置完成，证书已自动申请并支持续签${NC}"
}

# 安装 Xray
install_xray() {
    echo -e "${YELLOW}安装 Xray-core...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || { echo -e "${RED}Xray 安装失败${NC}"; exit 1; }
    systemctl stop xray
}

# 生成 Xray 配置
generate_config() {
    local protocols=("$@")
    local inbounds=""
    for proto in "${protocols[@]}"; do
        case $proto in
            1) inbounds+='{"port": 8443, "protocol": "vless", "settings": {"clients": '$(jq -r '.users | map({"id": .uuid})' "$USER_FILE")', "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"certificates": [{"certificateFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.crt", "keyFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.key"}]}},' ;;
            2) inbounds+='{"port": 8443, "protocol": "vless", "settings": {"clients": '$(jq -r '.users | map({"id": .uuid})' "$USER_FILE")', "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "tls", "vision": true, "tlsSettings": {"certificates": [{"certificateFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.crt", "keyFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.key"}]}},' ;;
            3) inbounds+='{"port": 8443, "protocol": "vless", "settings": {"clients": '$(jq -r '.users | map({"id": .uuid})' "$USER_FILE")', "decryption": "none"}, "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"certificates": [{"certificateFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.crt", "keyFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.key"}]}, "wsSettings": {"path": "/vless"}},' ;;
            4) inbounds+='{"port": 8443, "protocol": "vless", "settings": {"clients": '$(jq -r '.users | map({"id": .uuid})' "$USER_FILE")', "decryption": "none"}, "streamSettings": {"network": "grpc", "security": "tls", "tlsSettings": {"certificates": [{"certificateFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.crt", "keyFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.key"}]}, "grpcSettings": {"serviceName": "vless-grpc"}},' ;;
            5) inbounds+='{"port": 8443, "protocol": "vless", "settings": {"clients": '$(jq -r '.users | map({"id": .uuid})' "$USER_FILE")', "decryption": "none"}, "streamSettings": {"network": "http", "security": "tls", "tlsSettings": {"certificates": [{"certificateFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.crt", "keyFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.key"}]}, "httpSettings": {"path": "/h2"}},' ;;
            6) inbounds+='{"port": 8443, "protocol": "vmess", "settings": {"clients": '$(jq -r '.users | map({"id": .uuid})' "$USER_FILE")'}, "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"certificates": [{"certificateFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.crt", "keyFile": "/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/'"$DOMAIN"'/'"$DOMAIN"'.key"}]}, "wsSettings": {"path": "/vmess"}},' ;;
        esac
    done
    inbounds=${inbounds%,} # 移除最后一个逗号
    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [$inbounds],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    systemctl restart xray || echo -e "${RED}Xray 重启失败${NC}"
}

# 主安装流程
main_install() {
    read -p "请输入你的域名: " DOMAIN
    read -p "请输入你的邮箱（用于证书申请）: " EMAIL
    
    install_dependencies
    check_domain_ip
    install_caddy
    install_xray
    
    echo -e "${YELLOW}选择要安装的协议（多选用空格分隔，例如: 1 3）:${NC}"
    echo "1. VLESS+TCP[TLS/XTLS]"
    echo "2. VLESS+TLS_Vision+TCP"
    echo "3. VLESS+TLS+WS"
    echo "4. VLESS+TLS+gRPC"
    echo "5. VLESS+TLS+HTTP/2"
    echo "6. VMess+TLS+WS"
    read -p "请输入选项: " proto_input
    IFS=' ' read -r -a protocols <<< "$proto_input"
    generate_config "${protocols[@]}"
    
    systemctl enable xray caddy
    
    mkdir -p /etc/v2ray-agent
    cp "$0" "$SCRIPT_PATH"
    chmod 700 "$SCRIPT_PATH"
    echo "alias sinian='bash $SCRIPT_PATH'" >> /root/.bashrc
    source /root/.bashrc
    
    # 随机创建测试用户
    init_users
    uuid=$(generate_uuid)
    max_id=$(jq -r '[.users[].id] | max // 0' "$USER_FILE")
    new_id=$((max_id + 1))
    expire_time=$(date -d "+1 month" +%Y-%m-%d)
    jq --argjson id "$new_id" --arg uuid "$uuid" --arg expire_time "$expire_time" \
        '.users += [{"id": $id, "name": "自用", "uuid": $uuid, "expire_time": $expire_time, "status": "enabled"}]' "$USER_FILE" > tmp.json && mv tmp.json "$USER_FILE"
    echo -e "${GREEN}创建测试用户 自用 用于验证链接...${NC}"
    echo -e "用户 自用 已添加，ID: $new_id，UUID: $uuid，过期时间: $expire_time"
    generate_client_link "自用" "$uuid"
    
    echo -e "${GREEN}安装完成！请输入 'sinian' 打开脚本${NC}"
    echo -e "\n操作完成。按回车键返回主菜单..."
    read
}

# 添加用户
add_user() {
    init_users
    read -p "输入新用户名: " username
    read -p "输入 UUID（回车自动生成）: " uuid
    if [ -z "$uuid" ]; then
        uuid=$(generate_uuid)
    fi
    read -p "选择到期时间类型（1. 年 2. 月 3. 自定义天数 4. 永久）: " expire_type
    case $expire_type in
        1) expire_time=$(date -d "+1 year" +%Y-%m-%d) ;;
        2) expire_time=$(date -d "+1 month" +%Y-%m-%d) ;;
        3) read -p "输入天数: " days; expire_time=$(date -d "+$days days" +%Y-%m-%d) ;;
        4) expire_time="permanent" ;;
        *) echo "无效选择"; return ;;
    esac
    max_id=$(jq -r '[.users[].id] | max // 0' "$USER_FILE")
    new_id=$((max_id + 1))
    jq --arg username "$username" --arg uuid "$uuid" --argjson id "$new_id" --arg expire_time "$expire_time" \
        '.users += [{"id": $id, "name": $username, "uuid": $uuid, "expire_time": $expire_time, "status": "enabled"}]' "$USER_FILE" > tmp.json && mv tmp.json "$USER_FILE"
    echo -e "${GREEN}用户 $username 已添加，ID: $new_id，UUID: $uuid，过期时间: $expire_time${NC}"
    generate_client_link "$username" "$uuid"
    echo -e "\n操作完成。按回车键返回主菜单..."
    read
}

# 查看到期禁用用户
list_disabled_users() {
    echo -e "\n${YELLOW}到期禁用的用户列表${NC}"
    jq -r '.users[] | select(.status == "disabled") | "ID: \(.id) - 名称: \(.name) - UUID: \(.uuid) - 过期时间: \(.expire_time)"' "$USER_FILE"
    echo -e "\n操作完成。按回车键返回主菜单..."
    read
}

# 续费用户
renew_user() {
    init_users
    read -p "输入要续费的用户 ID 或用户名: " input
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        user=$(jq -r --argjson id "$input" '.users[] | select(.id == $id)' "$USER_FILE")
        username=$(echo "$user" | jq -r '.name')
        uuid=$(echo "$user" | jq -r '.uuid')
    else
        user=$(jq -r --arg name "$input" '.users[] | select(.name == $name)' "$USER_FILE")
        username="$input"
        uuid=$(echo "$user" | jq -r '.uuid')
    fi
    if [ -z "$user" ]; then
        echo -e "${RED}用户 $input 不存在${NC}"
        return
    fi
    read -p "选择续费时间类型（1. 年 2. 月 3. 自定义天数）: " renew_type
    case $renew_type in
        1) new_expire_time=$(date -d "+1 year" +%Y-%m-%d) ;;
        2) new_expire_time=$(date -d "+1 month" +%Y-%m-%d) ;;
        3) read -p "输入天数: " days; new_expire_time=$(date -d "+$days days" +%Y-%m-%d) ;;
        *) echo "无效选择"; return ;;
    esac
    jq --arg name "$username" --arg new_expire_time "$new_expire_time" \
        '(.users[] | select(.name == $name)).expire_time = $new_expire_time | (.users[] | select(.name == $name)).status = "enabled"' "$USER_FILE" > tmp.json && mv tmp.json "$USER_FILE"
    echo -e "${GREEN}用户 $username 已续费，新的过期时间: $new_expire_time，状态: 已启用${NC}"
    generate_client_link "$username" "$uuid"
    echo -e "\n操作完成。按回车键返回主菜单..."
    read
}

# 查看用户链接
view_user_link() {
    init_users
    read -p "输入要查看链接的用户名: " username
    uuid=$(jq -r --arg username "$username" '.users[] | select(.name == $username) | .uuid' "$USER_FILE")
    if [ -n "$uuid" ]; then
        generate_client_link "$username" "$uuid"
    else
        echo -e "${RED}用户 $username 不存在${NC}"
    fi
    echo -e "\n操作完成。按回车键返回主菜单..."
    read
}

# 查询证书有效期
check_cert_validity() {
    echo -e "${YELLOW}查询证书有效期...${NC}"
    cert_path="/var/lib/caddy/acme/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt"
    if [ -f "$cert_path" ]; then
        start_date=$(openssl x509 -in "$cert_path" -noout -startdate | cut -d= -f2)
        end_date=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
        days_left=$(expr $(date -d "$end_date" +%s) - $(date +%s) / 86400)
        echo "证书路径: $cert_path"
        echo "签发时间: $start_date"
        echo "有效期: $days_left 天"
        echo "有效期至: $end_date"
    else
        echo -e "${RED}证书文件不存在${NC}"
    fi
    echo -e "\n操作完成。按回车键返回主菜单..."
    read
}

# 用户管理菜单
user_menu() {
    while true; do
        echo -e "\n${YELLOW}用户管理菜单${NC}"
        echo "1. 添加用户"
        echo "2. 查看所有用户"
        echo "3. 查看到期禁用的用户"
        echo "4. 续费用户"
        echo "5. 查看链接"
        echo "6. 退出"
        read -p "请选择操作（回车返回主菜单）: " choice
        if [ -z "$choice" ]; then
            echo "返回主菜单..."
            break
        fi
        case $choice in
            1) add_user ;;
            2) jq -r '.users[] | "ID: \(.id) - 名称: \(.name) - UUID: \(.uuid) - 过期时间: \(.expire_time) - 状态: \(.status | if . == \"enabled\" then \"已启用\" else \"已禁用\" end)"' "$USER_FILE"; echo -e "\n操作完成。按回车键返回主菜单..."; read ;;
            3) list_disabled_users ;;
            4) renew_user ;;
            5) view_user_link ;;
            6) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${YELLOW}Xray 安装与管理脚本${NC}"
        echo "1. 安装 Xray 服务"
        echo "2. 用户管理"
        echo "3. 查询证书有效期"
        echo "4. 退出"
        read -p "请选择操作: " choice
        case $choice in
            1) main_install ;;
            2) user_menu ;;
            3) check_cert_validity ;;
            4) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

main_menu
