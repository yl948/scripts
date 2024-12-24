#!/bin/bash

# 设置变量
REMOTE_HOST="" #设置你可以拉取镜像的服务器ip地址
DEFAULT_USER=""    # 在这里设置默认用户名，留空则在运行时提示输入
DEFAULT_PASSWORD="" # 在这里设置默认密码，留空则在运行时提示输入

# 如果没有设置默认用户名，则提示输入
if [ -z "$DEFAULT_USER" ]; then
    read -p "请输入远程服务器用户名: " REMOTE_USER
else
    REMOTE_USER="$DEFAULT_USER"
fi

# 如果没有设置默认密码，则提示输入
if [ -z "$DEFAULT_PASSWORD" ]; then
    read -s -p "请输入远程服务器密码: " REMOTE_PASS
    echo ""  # 换行
else
    REMOTE_PASS="$DEFAULT_PASSWORD"
fi

# 交互式输入镜像名称
read -p "请输入要拉取的镜像名称(例如 nginx:latest): " IMAGE_NAME

# 处理镜像名称，将 '/' 替换为 '_' 以用作文件名
SAFE_IMAGE_NAME=$(echo ${IMAGE_NAME} | tr '/' '_' | tr ':' '_')
TAR_NAME="${SAFE_IMAGE_NAME}.tar"

echo "开始处理镜像: ${IMAGE_NAME}"

# 安装sshpass（如果没有安装的话）
if ! command -v sshpass &> /dev/null; then
    echo "正在安装sshpass..."
    sudo apt-get update && sudo apt-get install -y sshpass
fi

# 在远程主机上拉取镜像并保存为tar文件
sshpass -p "${REMOTE_PASS}" ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} << EOF
    docker pull ${IMAGE_NAME}
    docker save ${IMAGE_NAME} -o /tmp/${TAR_NAME}
    exit
EOF

# 从远程主机复制tar文件到本地
sshpass -p "${REMOTE_PASS}" scp -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST}:/tmp/${TAR_NAME} /tmp/

# 在本地导入镜像
docker load -i /tmp/${TAR_NAME}

# 清理临时文件
sshpass -p "${REMOTE_PASS}" ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} "rm /tmp/${TAR_NAME}; exit"
rm /tmp/${TAR_NAME}

echo "镜像已成功拉取并导入到本地" 
