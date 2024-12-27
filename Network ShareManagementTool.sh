#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "请使用 sudo 运行此脚本"
    exit 1
fi

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
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    echo "$global_config" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' > /etc/samba/smb.conf

    # 获取共享配置信息
    read -p "请输入要共享的本地路径: " local_path
    read -p "请输入共享名称: " share_name
    read -p "是否允许匿名访问？(y/n): " allow_guest
    
    # 如果不允许匿名访问，先获取用户信息
    if [[ ! "$allow_guest" =~ ^[Yy] ]]; then
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
        read -p "目录不存在，是否创建？(y/n): " create_dir
        if [[ "$create_dir" =~ ^[Yy] ]]; then
            mkdir -p "$local_path"
            # 如果不是匿名访问，设置目录所有者为 Samba 用户
            if [[ ! "$allow_guest" =~ ^[Yy] ]]; then
                chown "$smb_user:$smb_user" "$local_path"
                chmod 755 "$local_path"
            else
                chmod 777 "$local_path"
            fi
        else
            echo "取消操作"
            return 1
        fi
    else
        # 如果目录已存在，询问是否更改所有权
        if [[ ! "$allow_guest" =~ ^[Yy] ]]; then
            echo "----------------------------------------"
            echo "所有权说明："
            echo "- 如果这是专门为用户 $smb_user 创建的共享，建议更改所有权"
            echo "- 如果是系统目录（如 /mnt）或多用户共享，建议保持原有所有权"
            echo "- 更改所有权后，用户 $smb_user 将可以完全控制此目录"
            echo "- 当前所有权："
            ls -ld "$local_path" | awk '{print "  所有者: "$3"\n  组: "$4}'
            echo "----------------------------------------"
            read -p "是否将目录 $local_path 的所有权更改为用户 $smb_user？(y/n): " change_owner
            if [[ "$change_owner" =~ ^[Yy] ]]; then
                chown "$smb_user:$smb_user" "$local_path"
                chmod 755 "$local_path"
                echo "已更改所有权为 $smb_user:$smb_user"
                echo "权限设置为 755（用户完全访问，其他人只读）"
            fi
        fi
    fi

    # 添加共享配置
    cat >> /etc/samba/smb.conf << EOF

[$share_name]
    path = $local_path
    browseable = yes
    read only = no
    guest ok = $(if [[ "$allow_guest" =~ ^[Yy] ]]; then echo "yes"; else echo "no"; fi)
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
    echo "检查 Samba 配置..."
    testparm -s
    
    # 显示网络发现相关信息
    echo "确保以下服务已启用："
    systemctl status smbd nmbd wsdd2 2>/dev/null || echo "建议安装 wsdd2 以改善 Windows 网络发现"
    
    echo "共享配置完成！"
    echo "共享名称: $share_name"
    echo "共享路径: $local_path"
    if [[ ! "$allow_guest" =~ ^[Yy] ]]; then
        echo "访问用户: $smb_user"
        echo "请使用设置的密码访问"
    else
        echo "允许匿名访问"
    fi
    
    # 显示本机IP地址
    echo "本机IP地址："
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
}

# 列出远程共享
list_remote_shares() {
    read -p "请输入服务器IP地址: " server_ip
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
    read -p "是否要挂载列表中的共享？(y/n): " mount_now
    if [[ "$mount_now" =~ ^[Yy] ]]; then
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
        while true; do
            read -p "是否需要永久挂载? (y/n): " permanent
            case $permanent in
                [Yy]* ) permanent="y"; break;;
                [Nn]* ) permanent="n"; break;;
                * ) echo "请���入 y 或 n";;
            esac
        done

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
    # 将挂载信息存储到��组中
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
    echo "当前系统中的 SMB 挂载："
    echo "----------------------------------------"
    mount | grep "type cifs"
    echo "----------------------------------------"
    echo "fstab 中的 SMB 配置："
    echo "----------------------------------------"
    grep "cifs" /etc/fstab
}

# 查看本地共享功能
show_local_shares() {
    echo "当前本地共享列表："
    echo "----------------------------------------"
    if [ -f "/etc/samba/smb.conf" ]; then
        # 检查 Samba 服务状态
        if ! systemctl is-active --quiet smbd; then
            echo "警告: Samba 服务未运行"
            echo "正在启动 Samba 服务..."
            systemctl start smbd nmbd
        fi

        # 跳过注释和系统默认共享
        echo "共享目录列表："
        echo "----------------------------------------"
        grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf | tr -d '[]'
        echo "----------------------------------------"
        echo "共享详细配置："
        echo "----------------------------------------"
        # 显示每个共享的详细配置
        while IFS= read -r share; do
            share=$(echo "$share" | tr -d '[]')
            [ -z "$share" ] && continue
            echo "[$share]"
            testparm -s --show-all-parameters 2>/dev/null | grep -A 20 "^\s*\[$share\]" | grep -B 20 "^$\|^\[" | grep -v "^$\|^\[" | sed 's/^/    /'
            # 显示目录权限
            path=$(grep -A 5 "^\s*\[$share\]" /etc/samba/smb.conf | grep "path" | awk '{print $3}')
            if [ -n "$path" ]; then
                echo "    目录权限："
                ls -ld "$path" | awk '{print "        权限: "$1"\n        所有者: "$3"\n        组: "$4}'
            fi
            echo "----------------------------------------"
        done < <(grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf)
    else
        echo "未找到 Samba 配置文件"
    fi
}

# 删除本地共享功能
delete_local_share() {
    echo "当前本地共享列表："
    echo "----------------------------------------"
    if [ -f "/etc/samba/smb.conf" ]; then
        # 获取所有非系统默认共享
        mapfile -t shares < <(grep -P '^\s*\[([^p]|p[^r]|pr[^i]|pri[^n]|prin[^t]).*\]' /etc/samba/smb.conf | grep -v '\[global\]' | tr -d '[]')
        
        if [ ${#shares[@]} -eq 0 ]; then
            echo "没有找到可删除的本地共享"
            echo "提示：系统默认共享（如 global）不能删除"
            return 1
        fi
        
        # 显示共享列表
        for i in "${!shares[@]}"; do
            echo "$((i+1)). ${shares[i]}"
        done
        echo "----------------------------------------"
        
        # 选择要删除的共享
        read -p "请选择要删除的共享序号 [1-${#shares[@]}]: " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
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
        echo "未找到 Samba 配置文件"
        return 1
    fi
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
        
        # 选择要删除的用户
        read -p "请选择要删除的用户序号 [1-${#users[@]}]: " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#users[@]}" ]; then
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

    if ! command -v showmount &> /dev/null; then
        need_install=1
        packages_to_install+=("nfs-common")
    fi
    if ! command -v nfs-kernel-server &> /dev/null; then
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
    # 检查��安装 NFS 服务器
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
    echo "1. 只读 (ro)"
    echo "2. 读写 (rw)"
    echo "3. 读写 + 安全选项"
    read -p "请选择 [1-3]: " perm_choice
    case $perm_choice in
        1) perm="ro";;
        2) perm="rw";;
        3) perm="rw,sec=sys,root_squash,all_squash,anonuid=65534,anongid=65534";;
        *) echo "无效选择，默认设置为只读"; perm="ro";;
    esac

    # 配置访问控制
    echo "网段访问控制："
    echo "1. 指定 IP 地址（如：192.168.1.100）"
    echo "2. 指定网段（如：192.168.1.0/24）"
    echo "3. 指定多个地址（用空格分隔）"
    read -p "请选择访问控制类型 [1-3]: " net_type
    
    case $net_type in
        1)
            read -p "请输入允许访问的 IP 地址: " network
            ;;
        2)
            read -p "请输入允许访问的网段（如：192.168.1.0/24）: " network
            ;;
        3)
            read -p "请输入允许访问的地址列表（空格分隔）: " network
            ;;
        *)
            echo "无效选择，默认使用网段方式"
            read -p "请输入允许访问的网段（如：192.168.1.0/24）: " network
            ;;
    esac

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
    echo "当前 NFS 共享列表："
    echo "----------------------------------------"
    if [ -f "/etc/exports" ]; then
        cat /etc/exports | grep -v "^#"
        echo "----------------------------------------"
        echo "活动的 NFS 共享："
        exportfs -v
    else
        echo "未找到 NFS 配置文件"
    fi
}

# 删除 NFS 共享
delete_nfs_share() {
    echo "当前 NFS 共享列表："
    echo "----------------------------------------"
    # 获取所有共享路径
    mapfile -t shares < <(cat /etc/exports | grep -v "^#" | awk '{print $1}')
    
    if [ ${#shares[@]} -eq 0 ]; then
        echo "没有找到 NFS 共享"
        return 1
    fi
    
    # 显示共享列表
    for i in "${!shares[@]}"; do
        echo "$((i+1)). ${shares[i]}"
    done
    echo "----------------------------------------"
    
    # 选择要删除的共享
    read -p "请选择要删除的共享序号 [1-${#shares[@]}]: " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
        share_path="${shares[$((choice-1))]}"
        
        # 备份配置文件
        cp /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
        
        # 删除选中的共享配置
        sed -i "\|^$share_path|d" /etc/exports
        
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
        
        echo "已删除 NFS 共享: $share_path"
    else
        echo "无效的选择"
        return 1
    fi
}

# 挂载 NFS 共享
mount_nfs_share() {
    check_and_install_nfs
    
    read -p "请输入 NFS 服务器IP: " server_ip
    
    echo "正在获取可用的共享列表..."
    if ! showmount -e "$server_ip" &>/dev/null; then
        echo "无法连接到 NFS 服务器或服务器没有共享"
        return 1
    fi
    
    mapfile -t shares < <(showmount -e "$server_ip" | tail -n +2 | awk '{print $1}')
    
    echo "可用的共享列表："
    echo "----------------------------------------"
    for i in "${!shares[@]}"; do
        echo "$((i+1)). ${shares[i]}"
    done
    echo "----------------------------------------"
    
    read -p "请选择要挂载的共享序号 [1-${#shares[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shares[@]}" ]; then
        share_path="${shares[$((choice-1))]}"
        
        read -p "请输入本地挂载点 (默认: /mnt/nfs): " mount_point
        mount_point=${mount_point:-/mnt/nfs}
        
        # 创建挂载点
        if [ ! -d "$mount_point" ]; then
            mkdir -p "$mount_point"
        fi
        
        # 询问是否永久挂载
        read -p "是否需要永久挂载? (y/n): " permanent
        if [[ "$permanent" =~ ^[Yy] ]]; then
            # 添加到 fstab
            echo "$server_ip:$share_path $mount_point nfs defaults 0 0" >> /etc/fstab
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
    echo "4. 返回上级菜单"
    echo "----------------------------------------"
    read -p "请选择要卸载的内容 [1-4]: " uninstall_choice

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
            read -p "确定要继续���？(y/n): " confirm
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
        4)
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

# 主菜单
while true; do
    echo
    echo "网络共享管理工具"
    echo "----------------------------------------"
    echo "SMB/NFS 功能："
    echo "  1. 挂载新的 SMB/NFS 共享"
    echo "  2. 查看当前挂载"
    echo "  3. 取消挂载"
    echo "本地共享管理："
    echo "  4. SMB 共享管理"
    echo "  5. NFS 共享管理"
    echo "其他功能："
    echo "  6. 卸载软件包"
    echo "  7. 退出"
    echo "----------------------------------------"
    read -p "请选择操作 [1-7]: " main_choice

    case $main_choice in
        1)
            while true; do
                echo
                echo "挂载新的 SMB/NFS 共享"
                echo "----------------------------------------"
                echo "1. SMB 挂载"
                echo "2. NFS 挂载"
                echo "3. 返回上级菜单"
                echo "----------------------------------------"
                read -p "请选择操作 [1-3]: " mount_choice

                case $mount_choice in
                    1) check_and_install_cifs; list_remote_shares ;;
                    2) mount_nfs_share ;;
                    3) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        2)
            echo "当前挂载状态："
            echo "----------------------------------------"
            echo "SMB 挂载："
            mount | grep "type cifs" || echo "无 SMB 挂载"
            echo "----------------------------------------"
            echo "NFS 挂载："
            mount | grep "type nfs" || echo "无 NFS 挂载"
            ;;
        3)
            do_umount
            ;;
        4)
            while true; do
                echo
                echo "SMB 共享管理"
                echo "----------------------------------------"
                echo "1. 添加 SMB 共享"
                echo "2. 查看 SMB 共享"
                echo "3. 删除 SMB 共享"
                echo "4. 删除 Samba 用户"
                echo "5. 返回上级菜单"
                echo "----------------------------------------"
                read -p "请选择操作 [1-5]: " smb_choice

                case $smb_choice in
                    1) check_and_install_cifs; add_local_share ;;
                    2) show_local_shares ;;
                    3) delete_local_share ;;
                    4) delete_smb_user ;;
                    5) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        5)
            while true; do
                echo
                echo "NFS 共享管理"
                echo "----------------------------------------"
                echo "1. 添加 NFS 共享"
                echo "2. 查看 NFS 共享"
                echo "3. 删除 NFS 共享"
                echo "4. 返回上级菜单"
                echo "----------------------------------------"
                read -p "请选择操作 [1-4]: " nfs_choice

                case $nfs_choice in
                    1) add_nfs_share ;;
                    2) show_nfs_shares ;;
                    3) delete_nfs_share ;;
                    4) break ;;
                    *) echo "无效的选择，请重试" ;;
                esac
            done
            ;;
        6)
            uninstall_packages
            ;;
        7)
            echo "退出程序"
            exit 0
            ;;
        *)
            echo "无效的选择，请重试"
            ;;
    esac
done 
