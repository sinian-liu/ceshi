#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检测系统类型
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

# 安装系统依赖
install_dependencies() {
    local os_type=$1
    log_info "检测到系统: $os_type"
    
    case $os_type in
        "ubuntu"|"debian")
            log_info "更新系统包管理器..."
            apt update -y
            log_info "安装系统依赖..."
            apt install -y curl wget git build-essential python3 make gcc g++ sqlite3
            ;;
        "centos")
            log_info "更新系统包管理器..."
            yum update -y
            log_info "安装系统依赖..."
            yum install -y curl wget git make gcc gcc-c++ python3 sqlite
            ;;
        *)
            log_error "不支持的操作系统"
            exit 1
            ;;
    esac
}

# 安装 Node.js (使用兼容版本)
install_nodejs() {
    if command -v node &> /dev/null && node --version | grep -q "v16"; then
        log_info "Node.js 16 已安装"
        return 0
    fi
    
    log_info "安装 Node.js 16 (兼容版本)..."
    
    local os_type=$1
    case $os_type in
        "ubuntu"|"debian")
            curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
            apt-get install -y nodejs
            ;;
        "centos")
            curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
            yum install -y nodejs
            ;;
    esac
    
    # 验证安装
    if node --version && npm --version; then
        log_info "Node.js 安装成功: $(node --version)"
    else
        log_error "Node.js 安装失败"
        exit 1
    fi
}

# 克隆和设置应用
setup_application() {
    local app_dir="/root/nekonekostatus"
    
    # 如果目录已存在，备份并重新克隆
    if [ -d "$app_dir" ]; then
        log_warn "检测到现有安装，创建备份..."
        mv "$app_dir" "${app_dir}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    log_info "克隆仓库..."
    git clone https://github.com/nkeonkeo/nekonekostatus.git "$app_dir"
    cd "$app_dir"
    
    log_info "安装 npm 依赖..."
    
    # 先安装基础构建工具
    npm install -g node-gyp
    
    # 安装依赖，忽略可选依赖以减少错误
    npm config set optional false
    npm install --no-optional --build-from-source
    
    # 如果安装失败，尝试逐个安装
    if [ $? -ne 0 ]; then
        log_warn "标准安装失败，尝试替代方案..."
        rm -rf node_modules
        npm install sqlite3 express compression cors helmet --save
    fi
}

# 配置系统服务
setup_service() {
    local os_type=$1
    local service_file="/etc/systemd/system/nekonekostatus-dashboard.service"
    
    log_info "配置系统服务..."
    
    cat > "$service_file" <<EOF
[Unit]
Description=Neko Neko Status Dashboard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/nekonekostatus
ExecStart=/usr/bin/node /root/nekonekostatus/nekonekostatus.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nekonekostatus-dashboard.service
    
    log_info "启动服务..."
    systemctl start nekonekostatus-dashboard.service
    
    # 检查服务状态
    sleep 3
    if systemctl is-active --quiet nekonekostatus-dashboard.service; then
        log_info "服务启动成功!"
    else
        log_error "服务启动失败，检查日志: journalctl -u nekonekostatus-dashboard.service -f"
    fi
}

# 配置 HTTPS (可选)
setup_https() {
    read -p "是否要配置HTTPS和域名? (y/n): " setup_https
    
    if [[ $setup_https == "y" || $setup_https == "Y" ]]; then
        log_info "开始HTTPS配置..."
        
        # 安装 Nginx 和 Certbot
        local os_type=$1
        case $os_type in
            "ubuntu"|"debian")
                apt install -y nginx certbot python3-certbot-nginx
                ;;
            "centos")
                yum install -y nginx certbot python3-certbot-nginx
                ;;
        esac
        
        # 获取域名
        read -p "请输入您的域名 (例如: status.yourdomain.com): " domain
        read -p "请输入您的邮箱 (用于SSL证书): " email
        
        # 配置 Nginx
        cat > /etc/nginx/sites-available/$domain <<EOF
server {
    listen 80;
    server_name $domain;
    
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

        ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx
        
        # 申请 SSL 证书
        certbot --nginx -d $domain --email $email --agree-tos --non-interactive
        
        log_info "HTTPS配置完成! 访问: https://$domain"
    fi
}

# 主函数
main() {
    log_info "开始 Neko Neko Status 安装..."
    
    # 检测系统
    OS_TYPE=$(detect_os)
    if [ "$OS_TYPE" = "unknown" ]; then
        log_error "不支持的操作系统"
        exit 1
    fi
    
    # 安装步骤
    install_dependencies "$OS_TYPE"
    install_nodejs "$OS_TYPE"
    setup_application
    setup_service "$OS_TYPE"
    setup_https "$OS_TYPE"
    
    log_info "=== 安装完成 ==="
    echo "管理命令:"
    echo "启动: systemctl start nekonekostatus-dashboard.service"
    echo "停止: systemctl stop nekonekostatus-dashboard.service"
    echo "状态: systemctl status nekonekostatus-dashboard.service"
    echo "日志: journalctl -u nekonekostatus-dashboard.service -f"
    echo ""
    echo "默认访问地址: http://服务器IP:8080"
}

# 执行主函数
main "$@"
