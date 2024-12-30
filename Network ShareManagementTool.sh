#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "请使用 sudo 运行此脚本"
    exit 1
fi

# 添加一个通用的 y/n 选择函数
confirm_action() {
    local prompt="$1"  # 传入提示信息
    while true; do
        read -p "$prompt (y/n): " choice
        case "$choice" in
            [Yy]) return 0 ;;  # 返回 0 表示选择了 yes
            [Nn]) return 1 ;;  # 返回 1 表示选择了 no
            *) echo -e "${RED}错误：请输入 y 或 n${NC}" ;;
        esac
    done
}

# 添加一个通用的数字选择函数
select_option() {
    local prompt="$1"    # 提示信息
    local min="$2"       # 最小值
    local max="$3"       # 最大值
    
    while true; do
        read -p "$prompt [$min-$max]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
            echo "$choice"
            return 0
        else
            echo -e "${RED}错误：请输入有效的数字 [$min-$max]${NC}"
        fi
    done
}

# 添加一个通用的 IP 地址验证函数
validate_ip() {
    local prompt="$1"    # 提示信息
    
    while true; do
        read -p "$prompt: " ip_addr
        if [[ $ip_addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # 验证每个数字在0-255范围内
            valid=true
            IFS='.' read -r -a octets <<< "$ip_addr"
            for octet in "${octets[@]}"; do
                if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                    valid=false
                    break
                fi
            done
            if [ "$valid" = true ]; then
                echo "$ip_addr"
                return 0
            fi
        fi
        echo -e "${RED}错误：请输入有效的 IP 地址（格式：xxx.xxx.xxx.xxx）${NC}"
    done
}

# 检查是否安装了 cifs-utils
check_and_install_cifs() {
    if ! command -v mount.cifs &> /dev/null; then
        echo "未检测到 SMB 相关软件包"
        echo "需要安装的软件包："
        echo "- cifs-utils: SMB 挂载支持"
        echo "- smbclient: SMB 客户端工具"
        echo "- samba: SMB 服务器"
        read -p "是否安装这些软件包？(y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy] ]]; then
            echo "正在安装 cifs-utils..."
            apt update && apt install -y cifs-utils smbclient samba
            if [ $? -eq 0 ]; then
                echo "安装成功"
            else
                echo "安装失败，请检查网络或手动安装"
                return 1
            fi
        else
            echo "取消安装"
            return 1
        fi
    fi
}

# 添加本地共享功能
add_local_share() {
    # 检查 Samba 是否安装
    if ! command -v smbd &> /dev/null; then
        echo "正在安装 Samba..."
        apt update && apt install -y samba
    fi

    # 检查并创建 Samba 配置目录
    if [ ! -d "/etc/samba" ]; then
        mkdir -p /etc/samba
    fi

    # 检查是否存在 smb.conf，如果不存在则创建基本配置
    if [ ! -f "/etc/samba/smb.conf" ]; then
        echo "未找到 Samba 配置文件，正在创建基本配置..."
        # 获取所有非本地回环的 IP 地址
        local ip_list=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | paste -sd ' ')
        
        # 创建基本配置
        cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = WORKGROUP
    server string = Samba Server
    security = user
    map to guest = bad user
    interfaces = $ip_list
    bind interfaces only = no
    unix charset = UTF-8
    dos charset = cp936

[homes]
    comment = Home Directories
    browseable = no
    read only = yes
    create mask = 0700
    directory mask = 0700
    valid users = %S
EOF
        echo "已创建基本 Samba 配置文件"
    fi

    # 配置全局设置
    # 获取所有非本地回环的 IP 地址
    local ip_list=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | paste -sd ' ')
    
    local global_config="[global]
    workgroup = WORKGROUP
    server string = Samba Server
    security = user
    map to guest = bad user
    interfaces = $ip_list
    bind interfaces only = no
    unix charset = UTF-8
    dos charset = cp936"

    # 备份并更新 smb.conf
    # 如果文件不存在，创建新文件
    if [ ! -f "/etc/samba/smb.conf" ]; then
        echo "$global_config" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' > /etc/samba/smb.conf
    else
        # 检查是否已有 global 配置
        if ! grep -q "\[global\]" /etc/samba/smb.conf; then
            # 备份原文件
            cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
            # 添加 global 配置到文件开头
            echo "$global_config" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' > /etc/samba/smb.conf.tmp
            cat /etc/samba/smb.conf >> /etc/samba/smb.conf.tmp
            mv /etc/samba/smb.conf.tmp /etc/samba/smb.conf
        fi
    fi

    # 获取共享配置信息
    read -p "请输入要共享的本地路径: " local_path
    read -p "请输入共享名称: " share_name
    if confirm_action "是否允许匿名访问？"; then
        allow_guest="y"
    else
        allow_guest="n"
    fi

    if [ "$allow_guest" = "n" ]; then
        echo "----------------------------------------"
        echo "SMB 用户管理："
        if pdbedit -L &>/dev/null; then
            echo "现有 SMB 用户列表："
            pdbedit -L | cut -d: -f1 | nl
            echo "----------------------------------------"
            while true; do
                read -p "是否使用现有用户？(y/n): " use_existing
                if [[ "$use_existing" =~ ^[Yy] ]]; then
                    while true; do
                        read -p "请输入用户序号: " user_num
                        smb_user=$(pdbedit -L | cut -d: -f1 | sed -n "${user_num}p")
                        if [ -n "$smb_user" ]; then
                            break
                        else
                            echo -e "${RED}无效的用户序号${NC}"
                        fi
                    done
                    break
                elif [[ "$use_existing" =~ ^[Nn] ]]; then
                    read -p "请设置新用户名: " smb_user
                    # 添加系统用户（如果不存在）
                    if ! id "$smb_user" &>/dev/null; then
                        useradd -M -s /sbin/nologin "$smb_user"
                        echo "创建新用户: $smb_user"
                    else
                        echo "用户 $smb_user 已存在"
                    fi
                    break
                else
                    echo -e "${RED}错误：请输入 y 或 n${NC}"
                fi
            done
        else
            echo "未找到现有 SMB 用户"
            read -p "请设置访问用户名: " smb_user
            # 添加系统用户（如果不存在）
            if ! id "$smb_user" &>/dev/null; then
                useradd -M -s /sbin/nologin "$smb_user"
                echo "创建新用户: $smb_user"
            else
                echo "用户 $smb_user 已存在"
            fi
        fi

        # 验证路径是否存在
        if [ ! -d "$local_path" ]; then
            if confirm_action "目录不存在，是否创建？"; then
                mkdir -p "$local_path"
                if [ "$allow_guest" = "n" ]; then
                    # 如果不是匿名访问，设置目录所有者为 Samba 用户
                    chown "$smb_user:$smb_user" "$local_path"
                    chmod 755 "$local_path"
                    echo "已创建目录: $local_path"
                    echo "已设置所有者为: $smb_user"
                else
                    # 如果是匿名访问，设置目录权限为 777
                    chmod 777 "$local_path"
                    echo "已创建目录: $local_path"
                    echo "已设置权限为: 777（允许所有用户访问）"
                fi
            else
                echo "取消操作"
                return 1
            fi
        else
            # 如果目录已存在，询问是否更改所有权
            echo "----------------------------------------"
            echo "目录所有权设置："
            echo "当前目录: $local_path"
            echo "当前所有权："
            ls -ld "$local_path" | awk '{print "  所有者: "$3"\n  组: "$4}'
            echo
            echo "选项说明："
            echo "1. 设置为 $smb_user 的专属目录（推荐用于个人目录）"
            echo "   - $smb_user 将拥有完全控制权"
            echo "   - 其他用户只有读取权限"
            echo "2. 保持当前所有权（推荐用于共享目录）"
            echo "   - 适合多用户共享的情况"
            echo "   - 保持系统目录的权限不变"
            echo "----------------------------------------"
            while true; do
                read -p "请选择 [1-2]: " ownership_choice
                case $ownership_choice in
                    1)
                        chown "$smb_user:$smb_user" "$local_path"
                        chmod 755 "$local_path"
                        echo "已设置所有权为 $smb_user:$smb_user"
                        echo "权限设置为 755（用户完全访问，其他人只读）"
                        break
                        ;;
                    2)
                        echo "保持当前所有权不变"
                        break
                        ;;
                    *)
                        echo -e "${RED}错误：请输入有效的选项 [1-2]${NC}"
                        ;;
                esac
            done
        fi

        # 添加共享配置
        cat >> /etc/samba/smb.conf << EOF

[$share_name]
    path = $local_path
    browseable = yes
    read only = no
    guest ok = $(if [ "$allow_guest" = "y" ]; then echo "yes"; else echo "no"; fi)
    create mask = 0777
    directory mask = 0777
    force user = root
EOF

        # 检查是否已经是 Samba 用户
        if pdbedit -L | grep -q "^$smb_user:"; then
            echo "用户已经是 Samba 用户"
            read -p "是否要重置密码？(y/n): " reset_password
            if [[ "$reset_password" =~ ^[Yy] ]]; then
                smbpasswd "$smb_user"
            fi
        else
            # 添加新的 Samba 用户
            echo "添加新的 Samba 用户"
            smbpasswd -a "$smb_user"
        fi

        # 重启 Samba 服务
        systemctl restart smbd nmbd
        
        # 检查服务状态
        if ! systemctl is-active --quiet smbd; then
            echo "警告: Samba 服务启动失败"
            echo "查看错误信息："
            systemctl status smbd
            return 1
        fi
        
        # 测试配置文件
        echo "----------------------------------------"
        echo -e "${GREEN}检查 Samba 配置...${NC}"
        # 只显示关键配置信息
        testparm -s 2>/dev/null | grep -A 10 "\[$share_name\]"
        
        # 显示网络发现相关信息
        echo "----------------------------------------"
        echo -e "${GREEN}服务状态检查：${NC}"
        if systemctl is-active --quiet smbd; then
            echo -e "- Samba 服务 (smbd): ${GREEN}运行中${NC}"
        else
            echo -e "- Samba 服务 (smbd): ${RED}未运行${NC}"
        fi
        
        if systemctl is-active --quiet nmbd; then
            echo -e "- NetBIOS 服务 (nmbd): ${GREEN}运行中${NC}"
        else
            echo -e "- NetBIOS 服务 (nmbd): ${RED}未运行${NC}"
        fi
        
        if systemctl is-active --quiet wsdd2 2>/dev/null; then
            echo -e "- Windows 发现服务 (wsdd2): ${GREEN}运行中${NC}"
        else
            echo -e "- Windows 发现服务 (wsdd2): ${YELLOW}未安装${NC}"
            echo "  提示：建议安装 wsdd2 以改善 Windows 网络发现"
        fi
        
        echo "----------------------------------------"
        echo "共享配置完成！"
        echo "共享名称: $share_name"
        echo "共享路径: $local_path"
        if [ "$allow_guest" = "y" ]; then
            echo "允许匿名访问"
        else
            echo "访问用户: $smb_user"
            echo "请使用设置的密码访问"
        fi
        
        # 显示本机IP地址
        echo "----------------------------------------"
        echo "本机IP地址："
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
    fi
}

# 列出远程共享
list_remote_shares() {
    server_ip=$(validate_ip "请输入服务器IP地址")
    read -p "请输入用户名: " username
    read -s -p "请输入密码: " password
    echo
    
    echo "正在获取可用的共享列表..."
    mapfile -t shares < <(smbclient -L "$server_ip" -U "$username%$password" 2>/dev/null | grep "Disk" | awk '{print $1}')
    
    if [ ${#shares[@]} -eq 0 ]; then
        echo "未找到共享或无法连接到服务器"
        return 1
    fi
    
    echo "可用的共享列表："
    echo "----------------------------------------"
    for i in "${!shares[@]}"; do
        echo "$((i+1)). ${shares[i]}"
    done
    echo "----------------------------------------"
    
    # 询问是否要挂载
    if confirm_action "是否要挂载列表中的共享？"; then
        # 选择要挂载的共享
        while true; do
            read -p "请选择要挂载的共享序号 [1-${#shares[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
                share_name="${shares[$((choice-1))]}"
                break
            else
                echo "无效的选择，请重试"
            fi
        done

        read -p "请输入本地挂载点 (默认: /mnt/share): " mount_point
        mount_point=${mount_point:-/mnt/share}

        # 创建挂载点
        if [ ! -d "$mount_point" ]; then
            mkdir -p "$mount_point"
            echo "已创建挂载点: $mount_point"
        fi

        # 询问是否永久挂载
        if confirm_action "是否需要永久挂载？"; then
            permanent="y"
        else
            permanent="n"
        fi

        if [ "$permanent" = "y" ]; then
            # 创建凭据文件
            cred_file="/root/.smbcredentials"
            echo "username=$username" > "$cred_file"
            echo "password=$password" >> "$cred_file"
            chmod 600 "$cred_file"
            
            # 检查 fstab 是否已有相同配置
            if grep -q "$server_ip/$share_name" /etc/fstab; then
                echo "警告：fstab 中已存在相同的挂载配置"
            else
                # 添加到 fstab
                echo "//$server_ip/$share_name $mount_point cifs credentials=$cred_file,iocharset=utf8,vers=3.0,uid=$(id -u),gid=$(id -g) 0 0" >> /etc/fstab
                echo "已添加到 fstab"
                systemctl daemon-reload
            fi
            
            # 挂载
            mount -a
            echo "永久挂载配置完成"
        else
            # 临时挂载
            mount -t cifs "//$server_ip/$share_name" "$mount_point" -o "username=$username,password=$password,iocharset=utf8,vers=3.0,uid=$(id -u),gid=$(id -g)"
            echo "临时挂载完成"
        fi
    fi
    
    return 0
}

# 取消挂载功能
do_umount() {
    echo "当前已挂载的 SMB 共享："
    # 将挂载信息存储到数组中
    mapfile -t mount_points < <(mount | grep "type cifs" | awk '{print $3}')
    
    if [ ${#mount_points[@]} -eq 0 ]; then
        echo "当前没有 SMB 挂载"
        return
    fi
    
    # 显示带编号的挂载点列表
    for i in "${!mount_points[@]}"; do
        echo "$((i+1)). ${mount_points[i]}"
    done

    read -p "请输入要取消挂载的序号 [1-${#mount_points[@]}]: " choice
    
    # 验证输入
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mount_points[@]}" ]; then
        umount_path="${mount_points[$((choice-1))]}"
        umount "$umount_path"
        if [ $? -eq 0 ]; then
            echo "已成功取消挂载 $umount_path"
            read -p "是否从 fstab 中删除此挂载点配置？(y/n): " remove_fstab
            if [[ "$remove_fstab" =~ ^[Yy] ]]; then
                sed -i "\|$umount_path|d" /etc/fstab
                systemctl daemon-reload
                echo "已从 fstab 中删除配置"
            fi
        else
            echo "取消挂载失败，请检查路径是否正确或确认设备未被使用"
        fi
    else
        echo "无效的选择"
    fi
}

# 查看挂载功能
show_mounts() {
    # 定义颜色代码
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m' # No Color

    echo "当前系统中的 SMB 挂载："
    echo "----------------------------------------"
    if mount | grep "type cifs" > /dev/null; then
        mount | grep "type cifs"
    else
        echo -e "${YELLOW}无 SMB 挂载${NC}"
    fi
    echo "----------------------------------------"
    echo "fstab 中的 SMB 配置："
    echo "----------------------------------------"
    if grep "cifs" /etc/fstab > /dev/null; then
        grep "cifs" /etc/fstab
    else
        echo -e "${YELLOW}无 SMB 永久挂载配置${NC}"
    fi
    echo "----------------------------------------"
    echo "当前系统中的 NFS 挂载："
    echo "----------------------------------------"
    if mount | grep "type nfs" | grep -v "/proc/fs/nfsd" > /dev/null; then
        mount | grep "type nfs" | grep -v "/proc/fs/nfsd"
    else
        echo -e "${YELLOW}无 NFS 挂载${NC}"
    fi
    echo "----------------------------------------"
    echo "fstab 中的 NFS 配置："
    echo "----------------------------------------"
    if grep "nfs" /etc/fstab | grep -v "^#" > /dev/null; then
        grep "nfs" /etc/fstab | grep -v "^#"
    else
        echo -e "${YELLOW}无 NFS 永久挂载配置${NC}"
    fi
}

# 查看本地共享功能
show_local_shares() {
    # 定义颜色代码
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m' # No Color

    echo "当前本地共享列表："
    echo "----------------------------------------"
    if [ -f "/etc/samba/smb.conf" ]; then
        # 检查 Samba 服务状态
        if ! systemctl is-active --quiet smbd; then
            echo -e "${YELLOW}警告: Samba 服务未运行${NC}"
            echo "正在启动 Samba 服务..."
            systemctl start smbd nmbd
        fi

        # 跳过注释和系统默认共享
        # 获取共享数量
        local share_count=$(grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf | wc -l)
        
        if [ $share_count -eq 0 ]; then
            echo -e "${YELLOW}当前无任何 SMB 共享配置${NC}"
        else
            echo -e "${GREEN}当前共有 $share_count 个 SMB 共享：${NC}"
            echo
            echo "----------------------------------------"
            grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf | tr -d '[]' | while read -r share; do
                echo -e "${GREEN}共享名称：${NC}$share"
            done
            echo "----------------------------------------"
            echo -e "${GREEN}共享详细配置：${NC}"
            echo "----------------------------------------"
            # 显示每个共享的详细配置
            while IFS= read -r share; do
                share=$(echo "$share" | tr -d '[]')
                [ -z "$share" ] && continue
                echo -e "${GREEN}[$share]${NC}"
                testparm -s --show-all-parameters 2>/dev/null | grep -A 20 "^\s*\[$share\]" | grep -B 20 "^$\|^\[" | grep -v "^$\|^\[" | sed 's/^/    /'
                # 显示目录权限
                path=$(grep -A 5 "^\s*\[$share\]" /etc/samba/smb.conf | grep "path" | awk '{print $3}')
                if [ -n "$path" ]; then
                    if [ -d "$path" ]; then
                        echo -e "    ${GREEN}目录状态：${NC}存在"
                        echo -e "    ${GREEN}目录权限：${NC}"
                        ls -ld "$path" | awk '{print "        权限: "$1"\n        所有者: "$3"\n        组: "$4}'
                    else
                        echo -e "    ${RED}目录状态：不存在${NC}"
                    fi
                fi
                echo "----------------------------------------"
            done < <(grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf)
        fi
    else
        echo -e "${RED}未找到 Samba 配置文件 (/etc/samba/smb.conf)${NC}"
    fi
}

# 删除本地共享功能
delete_local_share() {
    # 定义颜色代码
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m' # No Color

    echo -e "${GREEN}请选择要删除的内容：${NC}"
    echo "----------------------------------------"
    echo "1. 删除本机的 SMB 共享（删除本机提供给其他设备的共享）"
    echo "2. 删除已挂载的 SMB 共享（删除已挂载的其他设备的共享）"
    echo "3. 返回上级菜单"
    echo "----------------------------------------"
    del_choice=$(select_option "请选择" 1 3)

    case $del_choice in
        1)
            echo "当前本地共享列表："
            echo "----------------------------------------"
            if [ -f "/etc/samba/smb.conf" ]; then
                # 获取所有非系统默认共享
                mapfile -t shares < <(grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf | grep -v '\[global\]' | tr -d '[]')
                
                if [ ${#shares[@]} -eq 0 ]; then
                    echo -e "${YELLOW}没有找到可删除的 Samba 共享${NC}"
                    echo "提示：系统默认共享（如 global）不能删除"
                    return 1
                fi
                
                # 显示共享列表
                for i in "${!shares[@]}"; do
                    echo "$((i+1)). ${shares[i]}"
                done
                echo "----------------------------------------"
                echo "输入 0 返回上级菜单"
                echo "----------------------------------------"
                
                # 选择要删除的共享
                choice=$(select_option "请选择要删除的共享序号" 0 ${#shares[@]})
                
                if [ "$choice" -eq 0 ]; then
                    return 0
                elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
                    share_name="${shares[$((choice-1))]}"
                    
                    # 备份配置文件
                    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)
                    
                    # 删除选中的共享配置
                    sed -i "/\[$share_name\]/,/^$/d" /etc/samba/smb.conf
                    
                    # 获取共享路径
                    path=$(grep -A 5 "^\s*\[$share_name\]" /etc/samba/smb.conf.bak.* | grep "path" | awk '{print $3}' | tail -1)
                    
                    # 询问是否删除共享目录
                    if [ -n "$path" ] && [ -d "$path" ]; then
                        read -p "是否删除共享目录 $path？(y/n): " delete_dir
                        if [[ "$delete_dir" =~ ^[Yy] ]]; then
                            rm -rf "$path"
                            echo "已删除目录: $path"
                        fi
                    fi
                    
                    # 重启 Samba 服务
                    systemctl restart smbd nmbd
                    
                    echo "已删除共享: $share_name"
                    echo "配置文件已备份为: /etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)"
                else
                    echo "无效的选择"
                    return 1
                fi
            else
                echo -e "${RED}未找到 Samba 配置文件${NC}"
                return 1
            fi
            ;;
        2)
            echo "当前 SMB 挂载配置："
            echo "----------------------------------------"
            # 获取 fstab 中的 SMB 挂载
            mapfile -t mounts < <(grep "cifs" /etc/fstab | grep -v "^#")
            
            if [ ${#mounts[@]} -eq 0 ]; then
                echo -e "${YELLOW}没有找到 SMB 挂载配置${NC}"
                return 1
            fi
            
            # 显示挂载列表
            for i in "${!mounts[@]}"; do
                echo "$((i+1)). ${mounts[i]}"
            done
            echo "----------------------------------------"
            
            # 选择要删除的挂载
            choice=$(select_option "请选择要删除的挂载序号" 1 ${#mounts[@]})
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mounts[@]}" ]; then
                mount_line="${mounts[$((choice-1))]}"
                mount_point=$(echo "$mount_line" | awk '{print $2}')
                
                # 取消挂载
                if mount | grep -q " on $mount_point "; then
                    umount "$mount_point"
                    echo "已取消挂载: $mount_point"
                fi
                
                # 从 fstab 中删除
                sed -i "\|$mount_line|d" /etc/fstab
                systemctl daemon-reload
                
                # 询问是否删除挂载点目录
                read -p "是否删除挂载点目录 $mount_point？(y/n): " delete_dir
                if [[ "$delete_dir" =~ ^[Yy] ]]; then
                    if rm -rf "$mount_point"; then
                        echo "已删除挂载点目录: $mount_point"
                    else
                        echo -e "${RED}删除目录失败，可能目录正在使用或没有权限${NC}"
                    fi
                fi
                
                echo "已从 fstab 中删除挂载配置"
            else
                echo "无效的选择"
                return 1
            fi
            ;;
        3)
            return 0
            ;;
        *)
            echo "无效的选择"
            return 1
            ;;
    esac
}

# 删除 Samba 用户功能
delete_smb_user() {
    echo "当前 Samba 用户列表："
    echo "----------------------------------------"
    if pdbedit -L &>/dev/null; then
        mapfile -t users < <(pdbedit -L | cut -d: -f1)
        
        if [ ${#users[@]} -eq 0 ]; then
            echo "没有找到 Samba 用户"
            return 1
        fi
        
        # 显示用户列表
        for i in "${!users[@]}"; do
            echo "$((i+1)). ${users[i]}"
        done
        echo "----------------------------------------"
        echo "输入 0 返回上级菜单"
        echo "----------------------------------------"
        
        # 选择要删除的用户
        choice=$(select_option "请选择要删除的用户序号" 0 ${#users[@]})
        
        if [ "$choice" -eq 0 ]; then
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#users[@]}" ]; then
            user_name="${users[$((choice-1))]}"
            
            # 删除 Samba 用户
            smbpasswd -x "$user_name"
            
            # 询问是否删除系统用户
            read -p "是否同时删除系统用户 $user_name？(y/n): " delete_system_user
            if [[ "$delete_system_user" =~ ^[Yy] ]]; then
                userdel "$user_name"
                echo "已删除系统用户: $user_name"
            fi
            
            echo "已删除 Samba 用户: $user_name"
        else
            echo "无效的选择"
            return 1
        fi
    else
        echo "无法获取 Samba 用户列表"
        return 1
    fi
}

# 检查是否安装了 NFS
check_and_install_nfs() {
    local need_install=0
    local packages_to_install=()

    if ! dpkg -l | grep -q "^ii.*nfs-common\s"; then
        need_install=1
        packages_to_install+=("nfs-common")
    fi
    if ! dpkg -l | grep -q "^ii.*nfs-kernel-server\s"; then
        need_install=1
        packages_to_install+=("nfs-kernel-server")
    fi

    # 如果需要安装软件包
    if [ $need_install -eq 1 ]; then
        echo "未检测到 NFS 相关软件包"
        echo "需要安装的软件包："
        for pkg in "${packages_to_install[@]}"; do
            echo "- $pkg"
        done
        read -p "是否安装这些软件包？(y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy] ]]; then
            echo "正在安装 NFS..."
            apt update
            for pkg in "${packages_to_install[@]}"; do
                echo "安装 $pkg..."
                apt install -y "$pkg"
            done
            if [ $? -eq 0 ]; then
                echo "安装成功"
                echo "正在启动 NFS 服务..."
                systemctl restart nfs-kernel-server
            else
                echo "安装失败，请检查网络或手动安装"
                return 1
            fi
        else
            echo "取消安装"
            return 1
        fi
    fi
}

# 添加 NFS 共享
add_nfs_share() {
    # 检查是否安装 NFS 服务器
    check_and_install_nfs

    # 获取共享配置信息
    read -p "请输入要共享的本地路径: " local_path
    
    # 验证路径是否存在
    if [ ! -d "$local_path" ]; then
        read -p "目录不存在，是否创建？(y/n): " create_dir
        if [[ "$create_dir" =~ ^[Yy] ]]; then
            mkdir -p "$local_path"
            chmod 777 "$local_path"
        else
            echo "取消操作"
            return 1
        fi
    fi

    # 使用普通 NFS 安全选项
    echo "访问权限设置："
    echo "----------------------------------------"
    echo "1. 只读 (ro)"
    echo "   - 推荐用于只需要读取的共享"
    echo "   - 适合共享文档、媒体文件等只读内容"
    echo "2. 读写 (rw)"
    echo "   - 推荐用于需要读写的普通共享"
    echo "   - 适合一般的文件共享场景"
    echo "3. 读写 + 安全选项"
    echo "   - 推荐用于需要更高安全性的共享"
    echo "   - 限制root权限，增强安全性"
    echo "   - 适合多用户或公共访问场景"
    echo "----------------------------------------"
    echo -e "建议：如果不确定，建议选择选项 3，这样更安全\n"
    while true; do
        read -p "请选择 [1-3]: " perm_choice
        case $perm_choice in
            1) perm="ro"; break;;
            2) perm="rw"; break;;
            3) perm="rw,sec=sys,root_squash,all_squash,anonuid=65534,anongid=65534"; break;;
            *) echo -e "${RED}错误：请选择有效的选项 [1-3]${NC}";;
        esac
    done

    # 配置访问控制
    echo "网段访问控制："
    echo "1. 指定 IP 地址（如：192.168.1.100）"
    echo "2. 指定网段（如：192.168.1.0/24）"
    echo "3. 指定多个地址（用空格分隔）"
    while true; do
        read -p "请选择访问控制类型 [1-3]: " net_type
        case $net_type in
            1)
                while true; do
                    read -p "请输入允许访问的 IP 地址: " network
                    if [[ $network =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        # 验证每个数字在0-255范围内
                        valid=true
                        IFS='.' read -r -a octets <<< "$network"
                        for octet in "${octets[@]}"; do
                            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                                valid=false
                                break
                            fi
                        done
                        if [ "$valid" = true ]; then
                            break 2
                        fi
                    fi
                    echo "错误：请输入有效的 IP 地址（格式：xxx.xxx.xxx.xxx）"
                done
                ;;
            2)
                while true; do
                    read -p "请输入允许访问的网段（如：192.168.1.0/24）: " network
                    if [[ $network =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                        # 验证IP部分
                        ip_part=${network%/*}
                        mask_part=${network#*/}
                        valid=true
                        
                        # 验证IP部分的每个数字
                        IFS='.' read -r -a octets <<< "$ip_part"
                        for octet in "${octets[@]}"; do
                            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                                valid=false
                                break
                            fi
                        done
                        
                        # 验证掩码部分
                        if [ "$mask_part" -lt 0 ] || [ "$mask_part" -gt 32 ]; then
                            valid=false
                        fi
                        
                        if [ "$valid" = true ]; then
                            break 2
                        fi
                    fi
                    echo "错误：请输入有效的网段（格式：xxx.xxx.xxx.xxx/xx）"
                done
                ;;
            3)
                while true; do
                    read -p "请输入允许访问的地址列表（空格分隔）: " network
                    valid=true
                    for ip in $network; do
                        if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            valid=false
                            break
                        fi
                        # 验证每个IP地址的每个数字
                        IFS='.' read -r -a octets <<< "$ip"
                        for octet in "${octets[@]}"; do
                            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                                valid=false
                                break 2
                            fi
                        done
                    done
                    if [ "$valid" = true ]; then
                        break 2
                    fi
                    echo "错误：请输入有效的IP地址列表（格式：xxx.xxx.xxx.xxx xxx.xxx.xxx.xxx ...）"
                done
                ;;
            *)
                echo -e "${RED}错误：请选择有效的序号 [1-3]${NC}"
                continue
                ;;
        esac
    done

    # 添加到 exports 文件
    echo "$local_path $network($perm,sync,no_subtree_check)" >> /etc/exports
    
    # 重新加载 NFS 配置
    exportfs -ra
    
    # 启动 NFS 服务
    systemctl restart nfs-kernel-server
    
    echo "NFS 共享配置完成！"
    echo "共享路径: $local_path"
    echo "访问权限: $perm"
    echo "允许访问的网段: $network"
    echo "客户端挂载命令: mount -t nfs $(hostname -I | awk '{print $1}'):$local_path /挂载点"
}

# 查看 NFS 共享
show_nfs_shares() {
    # 定义颜色代码
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m' # No Color

    echo "当前 NFS 共享列表："
    echo "----------------------------------------"
    if [ -f "/etc/exports" ]; then
        # 获取非注释的共享行数
        local share_count=$(grep -v "^#" /etc/exports | grep -v "^$" | wc -l)
        
        if [ $share_count -eq 0 ]; then
            echo -e "${YELLOW}当前无任何 NFS 共享配置${NC}"
        else
            echo -e "${GREEN}当前共有 $share_count 个 NFS 共享：${NC}"
            echo
            # 显示每个共享的详细信息
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    echo -e "${GREEN}共享配置：${NC}$line"
                    # 提取共享路径
                    local share_path=$(echo "$line" | awk '{print $1}')
                    if [ -d "$share_path" ]; then
                        echo -e "${GREEN}目录状态：${NC}存在"
                        echo -e "${GREEN}目录权限：${NC}$(ls -ld "$share_path")"
                    else
                        echo -e "${RED}目录状态：不存在${NC}"
                    fi
                    echo "----------------------------------------"
                fi
            done < <(grep -v "^#" /etc/exports)
        fi

        echo "----------------------------------------"
        echo "活动的 NFS 共享："
        if exportfs -v | grep -v "^$" > /dev/null; then
            exportfs -v
        else
            echo -e "${YELLOW}当前无活动的 NFS 共享${NC}"
        fi
    else
        echo -e "${RED}未找到 NFS 配置文件 (/etc/exports)${NC}"
    fi
}

# 删除 NFS 共享
delete_nfs_share() {
    # 定义颜色代码
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m' # No Color

    echo "当前 NFS 共享列表："
    echo "----------------------------------------"
    # 获取所有共享路径
    mapfile -t shares < <(grep -v "^#" /etc/exports | grep -v "^$" | awk '{print $1}')
    
    if [ ${#shares[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有找到 NFS 共享${NC}"
        return 1
    fi
    
    # 显示共享列表
    for i in "${!shares[@]}"; do
        echo "$((i+1)). ${shares[i]}"
    done
    echo "----------------------------------------"
    
    # 选择要删除的共享
    choice=$(select_option "请选择要删除的共享序号" 1 ${#shares[@]})
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
        share_path="${shares[$((choice-1))]}"
        
        # 备份配置文件
        cp /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
        
        # 获取完整的配置行
        local share_line=$(grep "^$share_path[[:space:]]" /etc/exports)
        # 使用完整的行进行删除
        sed -i "\|^$share_path[[:space:]]|d" /etc/exports
        
        # 检查并删除相关的挂载配置
        local server_ip=$(hostname -I | awk '{print $1}')
        if grep -q "$server_ip:$share_path" /etc/fstab; then
            echo -e "${YELLOW}发现相关的挂载配置，正在删除...${NC}"
            # 先取消挂载
            if mount | grep -q "$server_ip:$share_path"; then
                umount -f "$share_path" 2>/dev/null
            fi
            # 从 fstab 中删除配置
            sed -i "\|$server_ip:$share_path|d" /etc/fstab
            systemctl daemon-reload
            echo "已删除相关的挂载配置"
        fi
        
        # 重新加载 NFS 配置
        exportfs -ra
        
        # 询问是否删除共享目录
        if [ -d "$share_path" ]; then
            read -p "是否删除共享目录 $share_path？(y/n): " delete_dir
            if [[ "$delete_dir" =~ ^[Yy] ]]; then
                rm -rf "$share_path"
                echo "已删除目录: $share_path"
            fi
        fi
        
        echo -e "${GREEN}已删除 NFS 共享: $share_path${NC}"
        echo "其他共享配置保持不变"
        
        # 显示剩余的共享
        if grep -v "^#" /etc/exports | grep -v "^$" > /dev/null; then
            echo "----------------------------------------"
            echo "剩余的共享配置："
            grep -v "^#" /etc/exports | grep -v "^$"
        fi
    else
        echo -e "${RED}无效的选择${NC}"
        return 1
    fi
}

# NFS 自动扫描功能
mount_nfs_share() {
    while true; do
        server_ip=$(validate_ip "请输入服务器IP地址")
        
        # 验证IP地址格式
        if [[ $server_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # 验证每个数字在0-255范围内
            valid=true
            IFS='.' read -r -a octets <<< "$server_ip"
            for octet in "${octets[@]}"; do
                if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                    valid=false
                    break
                fi
            done
            
            if [ "$valid" = true ]; then
                echo "正在获取可用的共享列表..."
                if showmount -e "$server_ip" &>/dev/null; then
                    break
                else
                    echo -e "${RED}无法连接到 NFS 服务器或服务器没有共享${NC}"
                    read -p "是否重试？(y/n): " retry
                    if [[ ! "$retry" =~ ^[Yy] ]]; then
                        return 1
                    fi
                fi
            fi
        fi
        echo -e "${RED}错误：请输入有效的 IP 地址（格式：xxx.xxx.xxx.xxx）${NC}"
    done
    
    mapfile -t shares < <(showmount -e "$server_ip" | tail -n +2 | awk '{print $1}')
    
    if [ ${#shares[@]} -eq 0 ]; then
        echo "未找到共享"
        return 1
    fi
    
    echo "可用的共享列表："
    echo "----------------------------------------"
    for i in "${!shares[@]}"; do
        local share_path="${shares[i]}"
        # 检查是否已经挂载
        if mount | grep -q "$server_ip:$share_path"; then
            echo -e "$((i+1)). ${share_path} ${YELLOW}[已挂载]${NC}"
        # 检查是否在 fstab 中配置
        elif grep -q "$server_ip:$share_path" /etc/fstab; then
            echo -e "$((i+1)). ${share_path} ${YELLOW}[已配置在 fstab]${NC}"
        else
            echo "$((i+1)). ${share_path}"
        fi
    done
    echo "----------------------------------------"
    
    # 选择要挂载的共享
    choice=$(select_option "请选择要挂载的共享序号" 1 ${#shares[@]})
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
        share_path="${shares[$((choice-1))]}"
        
        # 再次检查是否已经挂载
        if mount | grep -q "$server_ip:$share_path"; then
            echo -e "${RED}错误：此共享已经挂载${NC}"
            return 1
        elif grep -q "$server_ip:$share_path" /etc/fstab; then
            echo -e "${YELLOW}警告：此共享已配置在 fstab 中${NC}"
            read -p "是否继续配置？(y/n): " continue_config
            if [[ ! "$continue_config" =~ ^[Yy] ]]; then
                return 1
            fi
        fi
        
        read -p "请输入本地挂载点 (默认: /mnt/nfs): " mount_point
        mount_point=${mount_point:-/mnt/nfs}
        
        # 创建挂载点
        if [ ! -d "$mount_point" ]; then
            mkdir -p "$mount_point"
            echo "已创建挂载点: $mount_point"
        fi
        
        # 询问是否永久挂载
        if confirm_action "是否需要永久挂载？"; then
            permanent="y"
        else
            permanent="n"
        fi
        
        if [ "$permanent" = "y" ]; then
            # 检查 fstab 是否已有相同配置
            if grep -q "$server_ip:$share_path" /etc/fstab; then
                echo "警告：fstab 中已存在相同的挂载配置"
            else
                # 添加到 fstab
                echo "$server_ip:$share_path $mount_point nfs defaults 0 0" >> /etc/fstab
                echo "已添加到 fstab"
                systemctl daemon-reload
            fi
            
            # 挂载
            mount -a
            echo "永久挂载配置完成"
        else
            # 临时挂载
            mount -t nfs "$server_ip:$share_path" "$mount_point"
            echo "临时挂载完成"
        fi
    else
        echo "无效的选择"
        return 1
    fi
}

# 卸载软件包功能
uninstall_packages() {
    echo "卸载选项："
    echo "----------------------------------------"
    echo "1. 卸载 SMB 相关软件包"
    echo "2. 卸载 NFS 相关软件包"
    echo "3. 卸载所有网络共享软件包"
    echo "0. 返回上级菜单"
    echo "----------------------------------------"
    read -p "请选择要卸载的内容 [0-3]: " uninstall_choice

    case $uninstall_choice in
        1)
            echo "即将卸载 SMB 相关软件包..."
            echo "这将删除以下软件包："
            echo "- cifs-utils"
            echo "- smbclient"
            echo "- samba"
            read -p "确定要继续吗？(y/n): " confirm
            if [[ "$confirm" =~ ^[Yy] ]]; then
                # 先停止服务
                systemctl stop smbd nmbd
                # 卸载软件包
                apt remove --purge -y cifs-utils smbclient samba
                # 清理配置文件
                rm -rf /etc/samba
                echo "SMB 相关软件包已卸载"
            fi
            ;;
        2)
            echo "即将卸载 NFS 相关软件包..."
            echo "这将删除以下软件包："
            echo "- nfs-common"
            echo "- nfs-kernel-server"
            read -p "确定要继续吗？(y/n): " confirm
            if [[ "$confirm" =~ ^[Yy] ]]; then
                # 先停止服务
                systemctl stop nfs-kernel-server
                # 卸载软件包
                apt remove --purge -y nfs-common nfs-kernel-server
                # 清理配置文件
                rm -f /etc/exports
                echo "NFS 相关软件包已卸载"
            fi
            ;;
        3)
            echo "即将卸载所有网络共享软件包..."
            echo "这将删除以下所有软件包："
            echo "- cifs-utils"
            echo "- smbclient"
            echo "- samba"
            echo "- nfs-common"
            echo "- nfs-kernel-server"
            read -p "确定要继续吗？(y/n): " confirm
            if [[ "$confirm" =~ ^[Yy] ]]; then
                # 停止所有相关服务
                systemctl stop smbd nmbd nfs-kernel-server
                # 卸载所有软件包
                apt remove --purge -y cifs-utils smbclient samba nfs-common nfs-kernel-server
                # 清理所有配置文件
                rm -rf /etc/samba
                rm -f /etc/exports
                echo "所有网络共享软件包已卸载"
            fi
            ;;
        0)
            return
            ;;
        *)
            echo "无效的选择"
            return 1
            ;;
    esac

    # 清理不再需要的依赖
    apt autoremove -y
    # 清理 apt 缓存
    apt clean
}

# 在 list_remote_shares 函数前添加新的手动输入函数
manual_input_server() {
    read -p "请输入服务器IP地址或主机名: " server_ip
    read -p "请输入共享名称: " share_name

    echo "----------------------------------------"
    echo "SMB 用户管理："
    if pdbedit -L &>/dev/null; then
        echo "现有 SMB 用户列表："
        pdbedit -L | cut -d: -f1 | nl
        echo "----------------------------------------"
        while true; do
            read -p "是否使用现有用户？(y/n): " use_existing
            if [[ "$use_existing" =~ ^[Yy] ]]; then
                while true; do
                    read -p "请输入用户序号: " user_num
                    username=$(pdbedit -L | cut -d: -f1 | sed -n "${user_num}p")
                    if [ -n "$username" ]; then
                        break
                    else
                        echo -e "${RED}无效的用户序号${NC}"
                    fi
                done
                break
            elif [[ "$use_existing" =~ ^[Nn] ]]; then
                read -p "请设置新用户名: " smb_user
                # 添加系统用户（如果不存在）
                if ! id "$smb_user" &>/dev/null; then
                    useradd -M -s /sbin/nologin "$smb_user"
                    echo "创建新用户: $smb_user"
                else
                    echo "用户 $smb_user 已存在"
                fi
                break
            else
                echo -e "${RED}错误：请输入 y 或 n${NC}"
            fi
        done
    else
        echo "未找到现有 SMB 用户，创建新用户："
        read -p "请输入用户名: " username
        # 添加系统用户
        useradd -M -s /sbin/nologin "$username"
        # 添加 SMB 用户
        smbpasswd -a "$username"
    fi

    read -s -p "请输入密码: " password
    echo

    read -p "请输入本地挂载点 (默认: /mnt/share): " mount_point
    mount_point=${mount_point:-/mnt/share}

    # 创建挂载点
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
        echo "已创建挂载点: $mount_point"
    fi

    # 询问是否永久挂载
    if confirm_action "是否需要永久挂载？"; then
        permanent="y"
    else
        permanent="n"
    fi

    if [ "$permanent" = "y" ]; then
        # 创建凭据文件
        cred_file="/root/.smbcredentials"
        echo "username=$username" > "$cred_file"
        echo "password=$password" >> "$cred_file"
        chmod 600 "$cred_file"
        
        # 检查 fstab 是否已有相同配置
        if grep -q "$server_ip/$share_name" /etc/fstab; then
            echo "警告：fstab 中已存在相同的挂载配置"
        else
            # 添加到 fstab
            echo "//$server_ip/$share_name $mount_point cifs credentials=$cred_file,iocharset=utf8,vers=3.0,uid=$(id -u),gid=$(id -g) 0 0" >> /etc/fstab
            echo "已添加到 fstab"
            systemctl daemon-reload
        fi
        
        # 挂载
        mount -a
        echo "永久挂载配置完成"
    else
        # 临时挂载
        mount -t cifs "//$server_ip/$share_name" "$mount_point" -o "username=$username,password=$password,iocharset=utf8,vers=3.0,uid=$(id -u),gid=$(id -g)"
        echo "临时挂载完成"
    fi
}

# 添加 NFS 手动输入功能
manual_mount_nfs() {
    echo "----------------------------------------"
    echo "NFS 手动挂载配置示例："
    echo "服务器地址: 192.168.1.100"
    echo "共享路径: /mnt/share 或 /home/user/share"
    echo "挂载点: /mnt/nfs 或 /mnt/myshare"
    echo "----------------------------------------"

    while true; do
        read -p "请输入服务器IP地址或主机名: " server_ip
        # 验证IP地址格式
        if [[ $server_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # 验证每个数字在0-255范围内
            valid=true
            IFS='.' read -r -a octets <<< "$server_ip"
            for octet in "${octets[@]}"; do
                if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                    valid=false
                    break
                fi
            done
            if [ "$valid" = true ]; then
                break
            fi
        fi
        echo -e "${RED}错误：请输入有效的 IP 地址（格式：xxx.xxx.xxx.xxx）${NC}"
    done

    read -p "请输入共享路径 (如: /mnt/share): " share_path
    
    # 验证共享路径格式
    if [[ ! "$share_path" =~ ^/ ]]; then
        echo -e "${RED}错误：共享路径必须以 / 开头${NC}"
        return 1
    fi

    read -p "请输入本地挂载点 (如: /mnt/nfs，默认: /mnt/nfs): " mount_point
    mount_point=${mount_point:-/mnt/nfs}

    # 创建挂载点
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
        echo "已创建挂载点: $mount_point"
    fi

    # 询问是否永久挂载
    if confirm_action "是否需要永久挂载？"; then
        permanent="y"
    else
        permanent="n"
    fi

    if [ "$permanent" = "y" ]; then
        # 检查 fstab 是否已有相同配置
        if grep -q "$server_ip:$share_path" /etc/fstab; then
            echo "警告：fstab 中已存在相同的挂载配置"
        else
            # 添加到 fstab
            echo "$server_ip:$share_path $mount_point nfs defaults 0 0" >> /etc/fstab
            echo "已添加到 fstab"
            systemctl daemon-reload
        fi
        
        # 挂载
        mount -a
        echo "永久挂载配置完成"
    else
        # 临时挂载
        mount -t nfs "$server_ip:$share_path" "$mount_point"
        echo "临时挂载完成"
    fi
}

# 显示当前挂载状态
show_current_mounts() {
    # 定义颜色代码
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m' # No Color

    # 创建数组存储所有挂载
    declare -a all_mounts=()
    local mount_count=0

    echo "当前挂载状态："
    echo "----------------------------------------"
    echo "SMB 挂载："
    while IFS= read -r line; do
        ((mount_count++))
        all_mounts+=("$line")
        # 检查是否在 fstab 中配置（永久挂载）
        mount_point=$(echo "$line" | awk '{print $3}')
        if grep -q " $mount_point " /etc/fstab; then
            echo -e "$mount_count. $line ${GREEN}[永久挂载]${NC}"
        else
            echo -e "$mount_count. $line ${YELLOW}[临时挂载]${NC}"
        fi
    done < <(mount | grep "type cifs")
    if [ $mount_count -eq 0 ]; then
        echo -e "${YELLOW}无 SMB 挂载${NC}"
    fi

    echo "----------------------------------------"
    echo "NFS 挂载："
    local nfs_start=$mount_count
    if mount | grep "type nfs" | grep -v "/proc/fs/nfsd" > /dev/null; then
        while IFS= read -r line; do
            ((mount_count++))
            all_mounts+=("$line")
            # 检查是否在 fstab 中配置（永久挂载）
            mount_point=$(echo "$line" | awk '{print $3}')
            if grep -q " $mount_point " /etc/fstab; then
                echo -e "$mount_count. $line ${GREEN}[永久挂载]${NC}"
            else
                echo -e "$mount_count. $line ${YELLOW}[临时挂载]${NC}"
            fi
        done < <(mount | grep "type nfs" | grep -v "/proc/fs/nfsd")
    else
        echo -e "${YELLOW}无 NFS 挂载${NC}"
    fi

    if [ $mount_count -gt 0 ]; then
        echo "----------------------------------------"
        echo -e "输入挂载序号以删除挂载，或输入 0 继续: "
        choice=$(select_option "请选择" 0 $mount_count)
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$mount_count" ]; then
            local mount_line="${all_mounts[$((choice-1))]}"
            local mount_point=$(echo "$mount_line" | awk '{print $3}')
            
            # 取消挂载
            if umount "$mount_point"; then
                echo "已取消挂载: $mount_point"
                
                # 检查并删除 fstab 中的配置
                if grep -q " $mount_point " /etc/fstab; then
                    read -p "是否从 fstab 中删除此挂载配置？(y/n): " remove_fstab
                    if [[ "$remove_fstab" =~ ^[Yy] ]]; then
                        sed -i "\| $mount_point |d" /etc/fstab
                        systemctl daemon-reload
                        echo "已从 fstab 中删除配置"
                    fi
                fi
                
                # 询问是否删除挂载点目录
                read -p "是否删除挂载点目录 $mount_point？(y/n): " delete_dir
                if [[ "$delete_dir" =~ ^[Yy] ]]; then
                    if rm -rf "$mount_point"; then
                        echo "已删除挂载点目录: $mount_point"
                    else
                        echo -e "${RED}删除目录失败，可能目录正在使用或没有权限${NC}"
                    fi
                fi
            else
                echo -e "${RED}取消挂载失败，请检查设备是否正在使用${NC}"
            fi
        elif [ "$choice" -ne 0 ]; then
            echo -e "${RED}无效的选择${NC}"
        fi
    fi

    echo "----------------------------------------"
    echo "永久挂载配置："
    if grep "nfs\|cifs" /etc/fstab | grep -v "^#" > /dev/null; then
        grep "nfs\|cifs" /etc/fstab | grep -v "^#"
    else
        echo -e "${YELLOW}无永久挂载配置${NC}"
    fi
}

# 主菜单
while true; do
    echo
    echo "网络共享管理工具"
    echo "----------------------------------------"
    echo "SMB/NFS 功能："
    echo "  1. 挂载新的 SMB/NFS 共享"
    echo "  2. 查看/管理已挂载的共享（客户端）"
    echo "本地共享管理："
    echo "  3. SMB 服务器共享管理（服务端）"
    echo "  4. NFS 服务器共享管理（服务端）"
    echo "其他功能："
    echo "  5. 卸载软件包"
    echo "  0. 退出"
    echo "----------------------------------------"
    main_choice=$(select_option "请选择操作" 0 5)

    case $main_choice in
        1)
            while true; do
                echo
                echo "挂载新的 SMB/NFS 共享"
                echo "----------------------------------------"
                echo "1. SMB 自动扫描"
                echo "2. SMB 手动输入"
                echo "3. NFS 自动扫描"
                echo "4. NFS 手动输入"
                echo "0. 返回上级菜单"
                echo "----------------------------------------"
                mount_choice=$(select_option "请选择操作" 0 4)

                case $mount_choice in
                    1) check_and_install_cifs; list_remote_shares ;;
                    2) check_and_install_cifs; manual_input_server ;;
                    3) check_and_install_nfs; mount_nfs_share ;;
                    4) check_and_install_nfs; manual_mount_nfs ;;
                    0) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        2)
            while true; do
                echo
                echo "查看/管理已挂载的共享（客户端）"
                echo "----------------------------------------"
                echo "1. 查看并管理当前挂载"
                echo "0. 返回上级菜单"
                echo "----------------------------------------"
                mount_manage_choice=$(select_option "请选择操作" 0 1)

                case $mount_manage_choice in
                    1) show_current_mounts ;;
                    0) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        3)
            while true; do
                echo
                echo "SMB 服务器共享管理（服务端）"
                echo "----------------------------------------"
                echo "1. 添加 SMB 共享"
                echo "2. 查看 SMB 共享"
                echo "3. 删除 SMB 共享"
                echo "4. 删除 Samba 用户"
                echo "0. 返回上级菜单"
                echo "----------------------------------------"
                smb_choice=$(select_option "请选择操作" 0 4)

                case $smb_choice in
                    1) check_and_install_cifs; add_local_share ;;
                    2) show_local_shares ;;
                    3) delete_local_share ;;
                    4) delete_smb_user ;;
                    0) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        4)
            while true; do
                echo
                echo "NFS 服务器共享管理（服务端）"
                echo "----------------------------------------"
                echo "1. 添加 NFS 共享"
                echo "2. 查看 NFS 共享"
                echo "3. 删除 NFS 共享"
                echo "0. 返回上级菜单"
                echo "----------------------------------------"
                nfs_choice=$(select_option "请选择操作" 0 3)

                case $nfs_choice in
                    1) add_nfs_share ;;
                    2) show_nfs_shares ;;
                    3) delete_nfs_share ;;
                    0) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        5) uninstall_packages ;;
        0)
            echo "退出程序"
            exit 0
            ;;
        *)
            echo "无效的选择，请重试"
            ;;
    esac
done 
