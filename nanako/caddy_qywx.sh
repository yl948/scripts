#!/bin/sh

# fonts color
red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}
blue(){
    echo -e "\033[34m\033[01m$1\033[0m"
}
bold(){
    echo -e "\033[1m\033[01m$1\033[0m"
}

Title="Caddy && 企业微信转发代理 一键安装脚本"
System_Support="系统支持：centos7 / debian9+ / Ubuntu16.04+"
Author="By NaNaKo"

echo "
███╗   ██╗ █████╗ ███╗   ██╗ █████╗ ██╗  ██╗ ██████╗ 
████╗  ██║██╔══██╗████╗  ██║██╔══██╗██║ ██╔╝██╔═══██╗
██╔██╗ ██║███████║██╔██╗ ██║███████║█████╔╝ ██║   ██║
██║╚██╗██║██╔══██║██║╚██╗██║██╔══██║██╔═██╗ ██║   ██║
██║ ╚████║██║  ██║██║ ╚████║██║  ██║██║  ██╗╚██████╔╝
╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ "

green "==================================================================================================="
green " ${Title} | ${System_Support} | ${Author}"
green "==================================================================================================="

function install_ubuntu()
{
	sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
	sudo apt update
	sudo apt install caddy
	systemctl restart caddy
}

function install_centos()
{
	yum install yum-plugin-copr
	yum copr enable @caddy/caddy
	yum install caddy
	systemctl restart caddy
}

SystemVersion=""
while true; do
	echo -e "\033[33m\033[01m"
	read -p "请选择你的系统发行版：[1、Debian 2、Ubuntu 3、CentOS7]: " SystemVersion
	echo -e "\e[0m"
	if [ "$SystemVersion" = "1" ];then
		yellow "你选择的是Debian，接下来请依据系统提示按y继续流程。"
		install_ubuntu
		break
	elif [ "$SystemVersion" = "2" ];then
		yellow "你选择的是Ubuntu，接下来请依据系统提示按y继续流程。"
		install_ubuntu
		break
	elif [ "$SystemVersion" = "3" ];then
		yellow "你选择的是CentOS7，接下来请依据系统提示按y继续流程。"
		install_centos
		break
	else
		red "输入错误，请重新执行脚本!"
		exit 1
	fi
done

if ! which caddy >/dev/null; then
	red "==================================================================================================="
	red "caddy安装貌似出了点问题，退出重试一次吧。"
	red "==================================================================================================="
	exit 1
else
	green "==================================================================================================="
	green "caddy安装完毕！"
	green "==================================================================================================="
fi

Set_Domain=""
Set_Port=""
is80=""
Domain=""
Port=""
result=""
while true; do
	echo -e "\E[1;33m"
	read -p "要使用服务器的ip访问还是已配置域名？(直接回车默认使用ip，或者输入域名）" Set_Domain
	read -p "请输入要使用的端口，请确保该端口未被占用。回车默认使用80端口。" Set_Port
	echo -e "\e[0m"
	Local_IP=$(curl ifconfig.io)
	if [ "$Set_Port" = "" -o "$Set_Port" = "80" ]; then
		Port=":80"
		is80="true"
	else
		Port=":$Set_Port"
		is80="false"
	fi
	if [ "$Set_Domain" = "" ]; then
		result="$Port"
		Domain_result="http://${Local_IP}${Port}"
	else
		if [ "$is80" = "true" ]; then
			result=$Set_Domain
			Domain_result="http://${result}"
		else
			result=$Set_Domain$Port
			Domain_result="http://${result}"
		fi
			
	fi
	rm -rf /etc/caddy/Caddyfile
	echo "${result} {
	reverse_proxy https://qyapi.weixin.qq.com {
		header_up Host {upstream_hostport}
	}
}" >> /etc/caddy/Caddyfile

    systemctl restart caddy

    green "==================================================================================================="
    green "Caddy && 企业微信转发代理配置完毕。使用${Domain_result}访问。"
    green "==================================================================================================="
    break
done
