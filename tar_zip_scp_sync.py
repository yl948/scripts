#!/usr/bin/env python3
import os
import tarfile
import zipfile
from datetime import datetime

def compress_item(path, output_path=None, archive_type='tar', compression='gz'):
    """
    打包文件或文件夹
    :param path: 要打包的文件或文件夹路径
    :param output_path: 输出文件路径
    :param archive_type: 打包类型 ('tar' 或 'zip')
    :param compression: 压缩方式 (tar: 'gz'/'bz2'/'xz'/'', zip: 'deflated'/'stored')
    """
    # 检查路径是否存在
    if not os.path.exists(path):
        raise FileNotFoundError(f"找不到文件或文件夹: {path}")

    # 确保路径不以斜杠结尾
    path = path.rstrip('/')
    name = os.path.basename(path)
    
    # 处理输出路径
    if not output_path:  # 如果输出路径为空或None
        ext = f'.tar.{compression}' if archive_type == 'tar' else '.zip'
        output_path = f'{name}{ext}'
    else:
        if os.path.isdir(output_path):
            # 如果输出路径是目录，在目录下创建文件
            ext = f'.tar.{compression}' if archive_type == 'tar' else '.zip'
            output_path = os.path.join(output_path, f'{name}{ext}')
        elif archive_type == 'tar' and not any(output_path.endswith(ext) for ext in ['.tar', '.tar.gz', '.tar.bz2', '.tar.xz']):
            # 如果是tar格式但没有正确的扩展名
            output_path = f'{output_path}.tar.{compression}'
        elif archive_type == 'zip' and not output_path.endswith('.zip'):
            # 如果是zip格式但没有.zip扩展名
            output_path = f'{output_path}.zip'
    
    # 确保输出目录存在
    output_dir = os.path.dirname(output_path) or '.'
    os.makedirs(output_dir, exist_ok=True)

    # 检查输出文件是否已存在
    if os.path.exists(output_path):
        print(f"\n警告：文件 '{output_path}' 已存在")
        choice = input("是否覆盖？(y/n): ").strip().lower()
        if choice != 'y':
            raise FileExistsError(f"文件 '{output_path}' 已存在，操作已取消")

    if archive_type == 'tar':
        mode = f'w:{compression}' if compression else 'w'
        with tarfile.open(output_path, mode) as tar:
            parent_dir = os.path.dirname(os.path.abspath(path))
            item_name = os.path.basename(path)
            
            original_dir = os.getcwd()
            try:
                os.chdir(parent_dir)
                tar.add(item_name)
            finally:
                os.chdir(original_dir)
    else:
        compression_mode = (zipfile.ZIP_DEFLATED 
                          if compression == 'deflated' 
                          else zipfile.ZIP_STORED)
        with zipfile.ZipFile(output_path, 'w', compression_mode) as zipf:
            if os.path.isfile(path):
                # 如果是文件，直接添加
                zipf.write(path, os.path.basename(path))
            else:
                # 如果是文件夹，添加所有内容
                for root, dirs, files in os.walk(path):
                    for file in files:
                        file_path = os.path.join(root, file)
                        rel_path = os.path.relpath(file_path, os.path.dirname(path))
                        zipf.write(file_path, rel_path)

    # 返回实际的输出路径
    return output_path

def is_archive_file(file_path):
    """
    检查文件是否是支持的压缩文件
    :param file_path: 文件路径
    :return: 是否是压缩文件
    """
    supported_extensions = (
        '.tar.gz', '.tgz', 
        '.tar.bz2', '.tbz2', 
        '.tar.xz', '.txz', 
        '.tar', '.zip'
    )
    return any(file_path.lower().endswith(ext) for ext in supported_extensions)

def extract_archive(archive_path, output_path=None):
    """
    解压缩文件
    :param archive_path: 要解压的文件路径
    :param output_path: 解压输出路径，默认为当前目录
    """
    # 首先检查是否是支持的压缩文件
    if not is_archive_file(archive_path):
        raise ValueError(f'不支持的文件格式。支持的格式：tar.gz, tar.bz2, tar.xz, tar, zip')
    
    if output_path is None:
        output_path = os.getcwd()
    
    # 确保输出目录存在
    os.makedirs(output_path, exist_ok=True)
    
    # 根据文件扩展名判断解压方式
    if archive_path.endswith(('.tar.gz', '.tgz', '.tar.bz2', '.tbz2', '.tar.xz', '.txz', '.tar')):
        with tarfile.open(archive_path, 'r:*') as tar:
            # 检查是否有恶意路径（例如 ../）
            for member in tar.getmembers():
                if member.name.startswith(('/', '..')):
                    raise ValueError(f'检测到不安全的路径: {member.name}')
            tar.extractall(path=output_path)
    elif archive_path.endswith('.zip'):
        with zipfile.ZipFile(archive_path, 'r') as zipf:
            # 检查是否有恶意路径
            for member in zipf.namelist():
                if member.startswith(('/', '..')):
                    raise ValueError(f'检测到不安全的路径: {member}')
            zipf.extractall(path=output_path)

def transfer_menu():
    """显示传输选项菜单"""
    print("\n=== 传输选项 ===")
    print("1. 直接传输文件夹")
    print("2. 压缩后传输")
    print("0. 不传输")
    choice = input("\n请选择 (0-2): ").strip()
    return choice

def transfer_folder(folder_path, compress=False):
    """传输文件夹到远程服务器"""
    transfer_with_method(folder_path, is_folder=True, compress=compress)

def transfer_single_file(file_path):
    """传输单个文件到远程服务器"""
    transfer_with_method(file_path, is_folder=False)

def check_command(command):
    """
    检查命令是否可用
    :param command: 要检查的命令
    :return: 命令是否存在
    """
    return os.system(f"which {command} > /dev/null 2>&1") == 0

def install_command_guide(command):
    """
    显示安装命令的指南
    :param command: 需要安装的命令
    """
    print(f"\n未检测到 {command} 命令，请先安装：")
    print("\n在 Ubuntu/Debian 系统上运行：")
    print(f"sudo apt-get install {command}")
    print("\n在 CentOS/RHEL 系统上运行：")
    print(f"sudo yum install {command}")
    print("\n在 macOS 系统上运行：")
    print(f"brew install {command}")

def show_transfer_method_menu():
    """显示传输方式选项菜单"""
    print("\n=== 选择传输方式 ===")
    print("1. scp  (简单文件拷贝)")
    print("2. rsync (增量传输，带断点续传)")
    print("3. sftp (交互式文件传输)")
    choice = input("\n请选择传输方式 (1-3): ").strip()
    return choice

def transfer_with_method(source_path, is_folder=False, compress=False):
    """
    使用选择的方式传输文件或文件夹
    :param source_path: 要传输的文件或文件夹路径
    :param is_folder: 是否是文件夹
    :param compress: 是否使用压缩传输（仅用于rsync）
    """
    while True:
        method = show_transfer_method_menu()
        
        if method not in ['1', '2', '3']:
            print("无效的选择！")
            continue
            
        # 检查所需命令是否安装
        required_command = {'1': 'scp', '2': 'rsync', '3': 'sftp'}[method]
        if not check_command(required_command):
            install_command_guide(required_command)
            retry = input("\n安装后是否重试？(y/n): ").strip().lower()
            if retry != 'y':
                return
            continue
            
        host = input("\n请输入远程服务器地址: ").strip()
        user = input("请输入用户名: ").strip()
        remote_path = input("请输入远程路径 (如 /home/user/): ").strip()
        
        if not all([host, user, remote_path]):
            print("错误：所有字段都必须填写！")
            continue
        
        # 根据选择的方式构建命令
        if method == '1':  # scp
            cmd = f"scp {'-r' if is_folder else ''} {source_path} {user}@{host}:{remote_path}"
        elif method == '2':  # rsync
            options = '-avz' if compress else '-av'
            cmd = f"rsync {options} {source_path} {user}@{host}:{remote_path}"
        else:  # sftp
            # 创建 sftp 批处理命令文件
            with open('/tmp/sftp_batch', 'w') as f:
                f.write(f"cd {remote_path}\n")
                f.write(f"put -r {source_path}\n" if is_folder else f"put {source_path}\n")
            cmd = f"sftp -b /tmp/sftp_batch {user}@{host}"
        
        print(f"\n开始传输到 {user}@{host}:{remote_path}")
        try:
            result = os.system(cmd)
            if result == 0:
                print("传输成功！")
                if method == '3':  # 清理 sftp 批处理文件
                    os.remove('/tmp/sftp_batch')
                break
            else:
                retry = input("\n传输失败！是否重试？(y/n): ").strip().lower()
                if retry != 'y':
                    break
        except Exception as e:
            print(f"传输错误: {str(e)}")
            retry = input("\n是否重试？(y/n): ").strip().lower()
            if retry != 'y':
                break

def show_menu():
    """显示交互式菜单"""
    print("\n=== 文件压缩/解压工具 ===")
    print("1. 压缩文件或文件夹")
    print("2. 解压文件")
    print("3. 传输文件或文件夹")
    print("0. 退出")
    choice = input("\n请选择操作 (0-3): ").strip()
    return choice

def transfer_item(path):
    """
    传输文件或文件夹到远程服务器
    :param path: 要传输的文件或文件夹路径
    """
    if os.path.isdir(path):
        # 如果是文件夹，显示压缩选项
        print("\n=== 传输选项 ===")
        print("1. 直接传输")
        print("2. 压缩后传输")
        print("0. 不传输")
        choice = input("\n请选择 (0-2): ").strip()
        
        if choice == '0':
            return
        elif choice == '1':
            transfer_with_method(path, is_folder=True, compress=False)
        elif choice == '2':
            transfer_with_method(path, is_folder=True, compress=True)
        else:
            print("\n无效的选择！")
    else:
        # 如果是文件，直接传输
        transfer_with_method(path, is_folder=False)

def show_compression_menu():
    """显示压缩方式选项菜单"""
    print("\n=== 选择压缩方式 ===")
    print("1. tar.gz  (推荐，压缩率适中，速度快)")
    print("2. tar.bz2 (压缩率最高，速度较慢)")
    print("3. tar.xz  (压缩率最高，速度最慢)")
    print("4. zip     (通用格式，兼容性好)")
    print("5. tar     (无压缩)")
    print("6. zip stored (无压缩)")
    choice = input("\n请选择压缩方式 (1-6): ").strip()
    
    compression_map = {
        '1': ('tar', 'gz'),
        '2': ('tar', 'bz2'),
        '3': ('tar', 'xz'),
        '4': ('zip', 'deflated'),
        '5': ('tar', ''),
        '6': ('zip', 'stored')
    }
    return compression_map.get(choice, ('tar', 'gz'))  # 默认返回 tar.gz

def transfer_file(file_path):
    """
    传输文件到远程服务器
    :param file_path: 要传输的文件路径
    """
    print("\n=== 文件传输 ===")
    print("1. 传输到远程服务器")
    print("0. 不传输")
    
    choice = input("\n请选择 (0-1): ").strip()
    
    if choice == '1':
        while True:
            host = input("\n请输入远程服务器地址: ").strip()
            user = input("请输入用户名: ").strip()
            remote_path = input("请输入远程路径 (如 /home/user/): ").strip()
            
            if not all([host, user, remote_path]):
                print("错误：所有字段都必须填写！")
                continue
            
            # 构建 scp 命令
            remote_dest = f"{user}@{host}:{remote_path}"
            cmd = f"scp {file_path} {remote_dest}"
            
            print(f"\n开始传输到 {remote_dest}")
            try:
                result = os.system(cmd)
                if result == 0:
                    print("传输成功！")
                    break
                else:
                    retry = input("\n传输失败！是否重试？(y/n): ").strip().lower()
                    if retry != 'y':
                        break
            except Exception as e:
                print(f"传输错误: {str(e)}")
                retry = input("\n是否重试？(y/n): ").strip().lower()
                if retry != 'y':
                    break

if __name__ == '__main__':
    while True:
        choice = show_menu()
        
        if choice == '0':
            print("\n感谢使用！再见！")
            break
            
        elif choice == '1':  # 压缩
            path = input("\n请输入要压缩的文件或文件夹路径: ").strip()
            if not os.path.exists(path):
                print("错误：文件或文件夹不存在！")
                continue
            
            archive_type, compression = show_compression_menu()
            
            output_path = input("\n请输入输出文件路径 (直接回车使用默认路径，输入目录则在该目录下创建文件): ").strip() or None
            
            try:
                actual_output_path = compress_item(path, output_path, archive_type, compression)
                print(f'\n压缩完成！输出文件: {actual_output_path}')
                transfer_file(actual_output_path)
            except FileExistsError as e:
                print(f'\n{str(e)}')
            except Exception as e:
                print(f'\n压缩过程中出现错误: {str(e)}')
                
        elif choice == '2':  # 解压
            archive_path = input("\n请输入要解压的文件路径: ").strip()
            if not os.path.isfile(archive_path):
                print("错误：文件不存在！")
                continue
                
            output_path = input("\n请输入解压输出路径 (直接回车解压到当前目录): ").strip()
            output_path = output_path if output_path else None
            
            try:
                extract_archive(archive_path, output_path)
                output_desc = output_path or '当前目录'
                print(f'\n解压完成！文件已解压到: {output_desc}')
            except Exception as e:
                print(f'\n解压过程中出现错误: {str(e)}')
                
        elif choice == '3':  # 传输文件或文件夹
            path = input("\n请输入要传输的文件或文件夹路径: ").strip()
            if not os.path.exists(path):
                print("错误：文件或文件夹不存在！")
                continue
            
            try:
                transfer_item(path)
            except Exception as e:
                print(f"\n传输过程中出现错误: {str(e)}")
                
        else:
            print("\n无效的选择，请重新输入！")
        
        input("\n按回车继续...") 
