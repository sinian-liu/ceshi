#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检测系统
detect_os() {
    if [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        echo "centos"
    elif [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release; then
        echo "ubuntu" 
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 安装Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker 已安装"
        return 0
    fi
    
    log_info "安装 Docker..."
    local os_type=$1
    
    case $os_type in
        "ubuntu"|"debian")
            # 卸载旧版本
            apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            # 安装依赖
            apt update -y
            apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
            # 添加Docker官方GPG密钥
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            # 添加Docker仓库
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            # 安装Docker
            apt update -y
            apt install -y docker-ce docker-ce-cli containerd.io
            ;;
        "centos")
            # 卸载旧版本
            yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
            # 安装依赖
            yum install -y yum-utils device-mapper-persistent-data lvm2
            # 添加Docker仓库
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            # 安装Docker
            yum install -y docker-ce docker-ce-cli containerd.io
            ;;
    esac
    
    # 启动Docker服务
    systemctl start docker
    systemctl enable docker
    
    # 验证安装
    if docker --version; then
        log_info "Docker 安装成功"
    else
        log_error "Docker 安装失败"
        exit 1
    fi
}

# 安装Docker Compose
install_docker_compose() {
    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose 已安装"
        return 0
    fi
    
    log_info "安装 Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    if docker-compose --version; then
        log_info "Docker Compose 安装成功"
    else
        log_error "Docker Compose 安装失败"
        exit 1
    fi
}

# 安装Nginx和Certbot
install_nginx_certbot() {
    local os_type=$1
    
    # 安装Nginx
    if ! command -v nginx &> /dev/null; then
        log_info "安装 Nginx..."
        case $os_type in
            "ubuntu"|"debian")
                apt install -y nginx
                ;;
            "centos")
                yum install -y nginx
                ;;
        esac
        systemctl start nginx
        systemctl enable nginx
    else
        log_info "Nginx 已安装"
    fi
    
    # 安装Certbot
    if ! command -v certbot &> /dev/null; then
        log_info "安装 Certbot..."
        case $os_type in
            "ubuntu"|"debian")
                apt install -y certbot python3-certbot-nginx
                ;;
            "centos")
                yum install -y epel-release
                yum install -y certbot python3-certbot-nginx
                ;;
        esac
    else
        log_info "Certbot 已安装"
    fi
}

# 配置应用
setup_application() {
    local domain=$1
    local email=$2
    
    log_info "创建应用配置..."
    
    # 创建docker-compose.yml
    cat > /root/docker-compose.yml <<EOF
version: '3.8'
services:
  nekonekostatus:
    image: nkeonkeo/nekonekostatus:latest
    container_name: nekonekostatus
    restart: unless-stopped
    ports:
      - "5555:5555"
    environment:
      - NODE_ENV=production
    networks:
      - app-network

networks:
  app-network:
    driver: bridge
EOF

    # 启动应用
    log_info "启动 Neko Neko Status 容器..."
    cd /root
    docker-compose up -d
    
    # 等待应用启动
    sleep 10
    
    # 检查容器状态
    if docker ps | grep -q nekonekostatus; then
        log_info "应用容器启动成功"
    else
        log_error "应用容器启动失败"
        docker-compose logs
        exit 1
    fi
}

# 配置HTTPS和域名
setup_https() {
    local domain=$1
    local email=$2
    local os_type=$3
    
    log_info "配置HTTPS和域名绑定..."
    
    # 检查域名解析
    log_info "检查域名解析..."
    public_ip=$(curl -s http://ipv4.icanhazip.com)
    dns_ip=$(dig +short $domain A 2>/dev/null || nslookup $domain 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
    
    if [[ -z "$dns_ip" ]]; then
        log_warn "无法获取域名 $domain 的DNS解析"
        log_info "请确保域名已解析到服务器IP: $public_ip"
        read -p "继续配置? (y/n): " continue_setup
        if [[ $continue_setup != "y" && $continue_setup != "Y" ]]; then
            exit 1
        fi
    else
        log_info "域名 $domain 解析到: $dns_ip"
        if [[ "$dns_ip" != "$public_ip" ]]; then
            log_warn "域名解析IP与服务器IP不匹配!"
            log_warn "解析IP: $dns_ip"
            log_warn "服务器IP: $public_ip"
            read -p "继续配置? (y/n): " continue_mismatch
            if [[ $continue_mismatch != "y" && $continue_mismatch != "Y" ]]; then
                exit 1
            fi
        fi
    fi
    
    # 创建Nginx配置
    log_info "创建Nginx配置..."
    
    case $os_type in
        "ubuntu"|"debian")
            nginx_dir="/etc/nginx"
            ;;
        "centos")
            nginx_dir="/etc/nginx"
            ;;
    esac
    
    cat > $nginx_dir/conf.d/$domain.conf <<EOF
server {
    listen 80;
    server_name $domain;
    
    # 安全头
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    location / {
        proxy_pass http://127.0.0.1:5555;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # 健康检查
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
    
    # 测试并重载Nginx
    if nginx -t; then
        systemctl reload nginx
        log_info "Nginx配置加载成功"
    else
        log_error "Nginx配置测试失败"
        exit 1
    fi
    
    # 等待域名可访问
    log_info "等待域名配置生效..."
    sleep 5
    
    # 申请SSL证书
    log_info "申请SSL证书..."
    if certbot --nginx -d $domain --email $email --agree-tos --non-interactive; then
        log_info "SSL证书申请成功!"
    else
        log_error "SSL证书申请失败，尝试standalone模式..."
        
        # 停止Nginx释放端口
        systemctl stop nginx
        
        if certbot certonly --standalone -d $domain --email $email --agree-tos --non-interactive; then
            log_info "SSL证书申请成功(standalone模式)!"
            
            # 更新Nginx配置使用SSL
            cat > $nginx_dir/conf.d/$domain.conf <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;
    
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    
    # 安全头
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=63072000" always;
    
    location / {
        proxy_pass http://127.0.0.1:5555;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # 健康检查
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
        else
            log_error "SSL证书申请完全失败"
            # 重新启动Nginx
            systemctl start nginx
            exit 1
        fi
        
        # 重新启动Nginx
        systemctl start nginx
    fi
    
    # 配置自动续期
    log_info "配置证书自动续期..."
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx") | crontab -
}

# 显示结果
show_result() {
    local domain=$1
    
    log_info "=== 安装完成! ==="
    echo ""
    echo "🎉 访问地址: https://$domain"
    echo ""
    echo "📊 服务状态:"
    echo "   Docker容器: docker ps | grep nekonekostatus"
    echo "   Nginx状态: systemctl status nginx"
    echo "   应用日志: docker-compose logs -f"
    echo ""
    echo "🔧 管理命令:"
    echo "   重启应用: docker-compose restart"
    echo "   停止应用: docker-compose down"
    echo "   更新应用: docker-compose pull && docker-compose up -d"
    echo ""
    echo "📝 证书信息:"
    echo "   证书状态: certbot certificates"
    echo "   自动续期: 已配置"
    echo ""
    log_info "现在您可以通过 https://$domain 访问您的状态监控面板了!"
}

# 主函数
main() {
    log_info "开始全系统兼容安装..."
    
    # 检测系统
    OS_TYPE=$(detect_os)
    if [ "$OS_TYPE" = "unknown" ]; then
        log_error "不支持的操作系统"
        exit 1
    fi
    log_info "检测到系统: $OS_TYPE"
    
    # 获取配置信息
    echo ""
    read -p "请输入您的域名 (例如: status.yourdomain.com): " DOMAIN
    read -p "请输入您的邮箱 (用于SSL证书): " EMAIL
    
    # 显示配置确认
    echo ""
    log_info "配置确认:"
    echo "   域名: $DOMAIN"
    echo "   邮箱: $EMAIL"
    echo "   系统: $OS_TYPE"
    echo ""
    read -p "确认开始安装? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        log_info "安装已取消"
        exit 0
    fi
    
    # 安装步骤
    install_docker "$OS_TYPE"
    install_docker_compose
    install_nginx_certbot "$OS_TYPE"
    setup_application "$DOMAIN" "$EMAIL"
    setup_https "$DOMAIN" "$EMAIL" "$OS_TYPE"
    show_result "$DOMAIN"
}

# 执行主函数
main "$@"
