#!/bin/bash
# 安装mosdns二进制服务
# 定义变量

# 获取 GitHub 上 mosdns 的最新版本号
MOSDNS_VERSION=$(curl -s https://api.github.com/repos/IrineSistiana/mosdns/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

# 检查是否成功获取版本号，如果失败则设置默认值
if [ -z "$MOSDNS_VERSION" ]; then
    echo "Failed to fetch the latest mosdns version. Using default version v5.3.3."
    MOSDNS_VERSION="v5.3.3"
fi

echo "Using mosdns version: $MOSDNS_VERSION"

# 定义下载地址
MOSDNS_URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-amd64.zip"
MOSDNS_DIR="/etc/mosdns"
SERVICE_FILE="/etc/systemd/system/mosdns.service"

# 下载mosdns二进制文件
echo "Downloading mosdns..."
wget $MOSDNS_URL -O mosdns-linux-amd64.zip

# 创建运行目录
echo "Creating directory ${MOSDNS_DIR}..."
mkdir -p $MOSDNS_DIR

# 安装解压工具
echo "Installing unzip..."
apt update && apt install -y unzip

# 解压文件至指定目录
echo "Unzipping mosdns..."
unzip mosdns-linux-amd64.zip -d $MOSDNS_DIR

# 进入运行目录并赋予可执行权限
echo "Setting executable permissions for mosdns..."
chmod +x ${MOSDNS_DIR}/mosdns

# 将mosdns复制到/usr/local/bin
echo "Copying mosdns to /usr/local/bin..."
cp ${MOSDNS_DIR}/mosdns /usr/local/bin

# 创建systemd服务文件
echo "Creating systemd service file..."
cat <<EOL > $SERVICE_FILE
[Unit]
Description=mosdns daemon, DNS server.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml -d /etc/mosdns

[Install]
WantedBy=multi-user.target
EOL

# 重新加载systemd并启用mosdns服务
echo "Reloading systemd and enabling mosdns service..."
systemctl daemon-reload
systemctl enable mosdns.service

# 启动mosdns服务
echo "Starting mosdns service..."
systemctl start mosdns.service

# 清理下载的zip文件
echo "Cleaning up..."
rm mosdns-linux-amd64.zip

echo "mosdns 安装完成"