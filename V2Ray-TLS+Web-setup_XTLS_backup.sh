#!/bin/bash

#安装选项
nginx_version="nginx-1.19.4"
openssl_version="openssl-openssl-3.0.0-alpha8"
v2ray_config="/usr/local/etc/v2ray/config.json"
nginx_prefix="/etc/nginx"
nginx_config="${nginx_prefix}/conf.d/v2ray.conf"
temp_dir="/temp_install_update_v2ray_tls_web"
v2ray_is_installed=""
nginx_is_installed=""
is_installed=""
update=""

#配置信息
unset domain_list
unset domainconfig_list
unset pretend_list
#V2Ray-TCP-TLS使用的协议，0代表禁用，1代表VLESS
protocol_1=""
#V2Ray-WS-TLS使用的协议，0代表禁用，1代表VLESS，2代表VMess
protocol_2=""
path=""
v2id_1=""
v2id_2=""

#系统信息
release=""
systemVersion=""
redhat_package_manager=""
redhat_version=""
mem_ok=""

#定义几个颜色
purple()
{
    echo -e "\033[35;1m${@}\033[0m"
}
tyblue()                           #天依蓝
{
    echo -e "\033[36;1m${@}\033[0m"
}
green()                            #水鸭青
{
    echo -e "\033[32;1m${@}\033[0m"
}
yellow()                           #鸭屎黄
{
    echo -e "\033[33;1m${@}\033[0m"
}
red()                              #姨妈红
{
    echo -e "\033[31;1m${@}\033[0m"
}

if [ "$EUID" != "0" ]; then
    red "请用root用户运行此脚本！！"
    exit 1
fi
if [[ ! -f '/etc/os-release' ]]; then
    red "系统版本太老，V2Ray官方脚本不支持"
    exit 1
fi
if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
    true
elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
    true
else
    red "仅支持使用systemd的系统！"
    exit 1
fi
if [[ ! -d /dev/shm ]]; then
    red "/dev/shm不存在，不支持的系统"
    exit 1
fi
if [ "$(cat /proc/meminfo |grep 'MemTotal' |awk '{print $3}' | tr [A-Z] [a-z])" == "kb" ]; then
    if [ "$(cat /proc/meminfo |grep 'MemTotal' |awk '{print $2}')" -le 400000 ]; then
        mem_ok=0
    else
        mem_ok=1
    fi
else
    mem_ok=2
fi
if [ -e /usr/local/bin/v2ray ]; then
    v2ray_is_installed=1
else
    v2ray_is_installed=0
fi
if [ -e $nginx_config ]; then
    nginx_is_installed=1
else
    nginx_is_installed=0
fi
if [ $v2ray_is_installed -eq 1 ] && [ $nginx_is_installed -eq 1 ]; then
    is_installed=1
else
    is_installed=0
fi
if [ -e /usr/bin/v2ray ] && [ -e /etc/nginx ]; then
    yellow "当前安装的V2Ray版本过旧，脚本已不再支持！"
    yellow "请选择1选项重新安装"
    sleep 3s
fi

check_important_dependence_installed()
{
    if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
        if ! dpkg -s $1 2>&1 >/dev/null; then
            if ! apt -y --no-install-recommends install $1; then
                apt update
                if ! apt -y --no-install-recommends install $1; then
                    yellow "重要组件安装失败！！"
                    red "不支持的系统！！"
                    exit 1
                fi
            fi
        fi
    else
        if ! rpm -q $2 2>&1 >/dev/null; then
            if ! $redhat_package_manager -y install $2; then
                yellow "重要组件安装失败！！"
                red "不支持的系统！！"
                exit 1
            fi
        fi
    fi
}
version_ge()
{
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}
#获取系统信息
get_system_info()
{
    if [[ "$(type -P apt)" ]]; then
        if [[ "$(type -P dnf)" ]] || [[ "$(type -P yum)" ]]; then
            red "同时存在apt和yum/dnf"
            red "不支持的系统！"
            exit 1
        fi
        release="other-debian"
        redhat_package_manager="true"
    elif [[ "$(type -P dnf)" ]]; then
        release="other-redhat"
        redhat_package_manager="dnf"
    elif [[ "$(type -P yum)" ]]; then
        release="other-redhat"
        redhat_package_manager="yum"
    else
        red "不支持的系统或apt/yum/dnf缺失"
        exit 1
    fi
    check_important_dependence_installed lsb-release redhat-lsb-core
    if lsb_release -a 2>/dev/null | grep -qi "ubuntu"; then
        release="ubuntu"
    elif lsb_release -a 2>/dev/null | grep -qi "centos"; then
        release="centos"
    elif lsb_release -a 2>/dev/null | grep -qi "fedora"; then
        release="fedora"
    fi
    systemVersion=`lsb_release -r -s`
    if [ $release == "fedora" ]; then
        if version_ge $systemVersion 28; then
            redhat_version=8
        elif version_ge $systemVersion 19; then
            redhat_version=7
        elif version_ge $systemVersion 12; then
            redhat_version=6
        else
            redhat_version=5
        fi
    else
        redhat_version=$systemVersion
    fi
}

#检查SELinux
check_SELinux()
{
    turn_off_selinux()
    {
        check_important_dependence_installed selinux-utils libselinux-utils
        setenforce 0
        sed -i 's/^[ \t]*SELINUX[ \t]*=[ \t]*enforcing[ \t]*$/SELINUX=disabled/g' /etc/sysconfig/selinux
        $redhat_package_manager -y remove libselinux-utils
        apt -y purge selinux-utils
    }
    if getenforce 2>/dev/null | grep -wqi Enforcing || grep -Eq '^[ '$'\t]*SELINUX[ '$'\t]*=[ '$'\t]*enforcing[ '$'\t]*$' /etc/sysconfig/selinux 2>/dev/null; then
        yellow "检测到SELinux开启，脚本可能无法正常运行"
        choice=""
        while [[ "$choice" != "y" && "$choice" != "n" ]]
        do
            tyblue "尝试关闭SELinux?(y/n)"
            read choice
        done
        if [ $choice == y ]; then
            turn_off_selinux
        else
            exit 0
        fi
    fi
}

#将域名列表转化为一个数组
get_all_domains()
{
    unset all_domains
    for ((i=0;i<${#domain_list[@]};i++))
    do
        if [ ${domainconfig_list[i]} -eq 1 ]; then
            all_domains+=("www.${domain_list[i]}")
            all_domains+=("${domain_list[i]}")
        else
            all_domains+=("${domain_list[i]}")
        fi
    done
}

#配置sshd
setsshd()
{
    echo
    tyblue "------------------------------------------"
    tyblue " 安装可能需要比较长的时间(5-40分钟)"
    tyblue " 如果中途断开连接将会很麻烦"
    tyblue " 设置ssh连接超时时间将有效降低断连可能性"
    tyblue "------------------------------------------"
    choice=""
    while [ "$choice" != "y" -a "$choice" != "n" ]
    do
        tyblue "是否设置ssh连接超时时间？(y/n)"
        read choice
    done
    if [ $choice == y ]; then
        echo >> /etc/ssh/sshd_config
        echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
        echo "ClientAliveCountMax 60" >> /etc/ssh/sshd_config
        echo "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" >> /etc/ssh/sshd_config
        service sshd restart
        green  "----------------------配置完成----------------------"
        tyblue " 请重新进行ssh连接(即重新登陆服务器)，并再次运行此脚本"
        yellow " 按回车键退出。。。。"
        read -s
        exit 0
    fi
}

#删除防火墙和阿里云盾
uninstall_firewall()
{
    green "正在删除防火墙。。。"
    ufw disable
    apt -y purge firewalld
    apt -y purge ufw
    systemctl stop firewalld
    systemctl disable firewalld
    $redhat_package_manager -y remove firewalld
    green "正在删除阿里云盾和腾讯云盾 (仅对阿里云和腾讯云服务器有效)。。。"
#阿里云盾
    if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
        systemctl stop CmsGoAgent
        systemctl disable CmsGoAgent
        rm -rf /usr/local/cloudmonitor
        rm -rf /etc/systemd/system/CmsGoAgent.service
        systemctl daemon-reload
    else
        systemctl stop cloudmonitor
        /etc/rc.d/init.d/cloudmonitor remove
        rm -rf /usr/local/cloudmonitor
        systemctl daemon-reload
    fi

    systemctl stop aliyun
    systemctl disable aliyun
    rm -rf /etc/systemd/system/aliyun.service
    systemctl daemon-reload
    apt -y purge aliyun-assist
    $redhat_package_manager -y remove aliyun_assist
    rm -rf /usr/local/share/aliyun-assist
    rm -rf /usr/sbin/aliyun_installer
    rm -rf /usr/sbin/aliyun-service
    rm -rf /usr/sbin/aliyun-service.backup

    pkill -9 AliYunDun
    pkill -9 AliHids
    /etc/init.d/aegis uninstall
    rm -rf /usr/local/aegis
    rm -rf /etc/init.d/aegis
    rm -rf /etc/rc2.d/S80aegis
    rm -rf /etc/rc3.d/S80aegis
    rm -rf /etc/rc4.d/S80aegis
    rm -rf /etc/rc5.d/S80aegis
#腾讯云盾
    /usr/local/qcloud/stargate/admin/uninstall.sh
    /usr/local/qcloud/YunJing/uninst.sh
    /usr/local/qcloud/monitor/barad/admin/uninstall.sh
    systemctl daemon-reload
    systemctl stop YDService
    systemctl disable YDService
    rm -rf /lib/systemd/system/YDService.service
    systemctl daemon-reload
    sed -i 's#/usr/local/qcloud#rcvtevyy4f5d#g' /etc/rc.local
    sed -i '/rcvtevyy4f5d/d' /etc/rc.local
    rm -rf $(find /etc/udev/rules.d -iname *qcloud* 2>/dev/null)
    pkill -9 YDService
    pkill -9 YDLive
    pkill -9 sgagent
    pkill -9 /usr/local/qcloud
    pkill -9 barad_agent
    rm -rf /usr/local/qcloud
    rm -rf /usr/local/yd.socket.client
    rm -rf /usr/local/yd.socket.server
    mkdir /usr/local/qcloud
    mkdir /usr/local/qcloud/action
    mkdir /usr/local/qcloud/action/login_banner.sh
    mkdir /usr/local/qcloud/action/action.sh
}

#升级系统组件
doupdate()
{
    updateSystem()
    {
        if ! [[ "$(type -P do-release-upgrade)" ]]; then
            if ! apt -y --no-install-recommends install ubuntu-release-upgrader-core; then
                apt update
                if ! apt -y --no-install-recommends install ubuntu-release-upgrader-core; then
                    red    "脚本出错！"
                    yellow "按回车键继续或者Ctrl+c退出"
                    read -s
                fi
            fi
        fi
        echo -e "\n\n\n"
        tyblue "------------------请选择升级系统版本--------------------"
        tyblue " 1.最新beta版(现在是21.04)(2020.10)"
        tyblue " 2.最新发行版(现在是20.10)(2020.10)"
        tyblue " 3.最新LTS版(现在是20.04)(2020.10)"
        tyblue "-------------------------版本说明-------------------------"
        tyblue " beta版：即测试版"
        tyblue " 发行版：即稳定版"
        tyblue " LTS版：长期支持版本，可以理解为超级稳定版"
        tyblue "-------------------------注意事项-------------------------"
        yellow " 1.升级过程中遇到问话/对话框，如果不明白，选择yes/y/第一个选项"
        yellow " 2.升级系统完成后将会重启，重启后，请再次运行此脚本完成剩余安装"
        yellow " 3.升级系统可能需要15分钟或更久"
        yellow " 4.有的时候不能一次性更新到所选择的版本，可能要更新多次"
        yellow " 5.升级系统后以下配置可能会恢复系统默认配置："
        yellow "     ssh端口   ssh超时时间    bbr加速(恢复到关闭状态)"
        tyblue "----------------------------------------------------------"
        green  " 您现在的系统版本是$systemVersion"
        tyblue "----------------------------------------------------------"
        echo
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" ]
        do
            read -p "您的选择是：" choice
        done
        if ! [[ "$(cat /etc/ssh/sshd_config | grep -i "^[ \t]*port " | awk '{print $2}')" =~ ^("22"|"")$ ]]; then
            red "检测到ssh端口号被修改"
            red "升级系统后ssh端口号可能恢复默认值(22)"
            yellow "按回车键继续。。。"
            read -s
        fi
        local i
        for ((i=0;i<2;i++))
        do
            sed -i '/^[ \t]*Prompt[ \t]*=/d' /etc/update-manager/release-upgrades
            echo 'Prompt=normal' >> /etc/update-manager/release-upgrades
            case "$choice" in
                1)
                    do-release-upgrade -d
                    do-release-upgrade -d
                    sed -i 's/Prompt=normal/Prompt=lts/' /etc/update-manager/release-upgrades
                    do-release-upgrade -d
                    do-release-upgrade -d
                    sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
                    do-release-upgrade
                    do-release-upgrade
                    sed -i 's/Prompt=normal/Prompt=lts/' /etc/update-manager/release-upgrades
                    do-release-upgrade
                    do-release-upgrade
                    ;;
                2)
                    do-release-upgrade
                    do-release-upgrade
                    ;;
                3)
                    sed -i 's/Prompt=normal/Prompt=lts/' /etc/update-manager/release-upgrades
                    do-release-upgrade
                    do-release-upgrade
                    ;;
            esac
            if ! version_ge $systemVersion 20.04; then
                sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
                do-release-upgrade
                do-release-upgrade
            fi
            apt update
            apt -y --auto-remove --purge full-upgrade
        done
    }
    echo -e "\n\n\n"
    tyblue "-----------------------是否更新系统组件？-----------------------"
    if [ "$release" == "ubuntu" ]; then
        green  " 1. 更新已安装软件，并升级系统(仅对ubuntu有效)"
        green  " 2. 仅更新已安装软件"
        red    " 3. 不更新"
        if [ $mem_ok == 2 ]; then
            echo
            yellow "如果要升级系统，请确保服务器的内存>=512MB"
            yellow "否则可能无法开机"
        elif [ $mem_ok == 0 ]; then
            echo
            red "检测到内存过小，升级系统可能导致无法开机，请谨慎选择"
        fi
        echo
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" ]
        do
            read -p "您的选择是：" choice
        done
    else
        green  " 1. 仅更新已安装软件"
        red    " 2. 不更新"
        echo
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" ]
        do
            read -p "您的选择是：" choice
        done
    fi
    if [[ "$release" == "ubuntu" && "$choice" == "1" ]]; then
        updateSystem
        apt -y --purge autoremove
        apt clean
    elif [[ $release == "ubuntu" && $choice -eq 2 || $choice -eq 1 ]]; then
        tyblue "-----------------------即将开始更新-----------------------"
        yellow " 更新过程中若有问话/对话框，优先选择yes/y/第一个选项"
        yellow " 按回车键继续。。。"
        read -s
        $redhat_package_manager -y autoremove
        $redhat_package_manager -y update
        apt update
        apt -y --auto-remove --purge full-upgrade
        apt -y --purge autoremove
        apt clean
        $redhat_package_manager -y autoremove
        $redhat_package_manager clean all
    fi
}

#进入工作目录
enter_temp_dir()
{
    rm -rf "$temp_dir"
    mkdir "$temp_dir"
    cd "$temp_dir"
}

#安装bbr
install_bbr()
{
    #输出：latest_kernel_version 和 your_kernel_version
    get_kernel_info()
    {
        green "正在获取最新版本内核版本号。。。。(60内秒未获取成功自动跳过)"
        local kernel_list
        local kernel_list_temp=($(timeout 60 wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/ | awk -F'\"v' '/v[0-9]/{print $2}' | cut -d '"' -f1 | cut -d '/' -f1 | sort -rV))
        if [ ${#kernel_list_temp[@]} -le 1 ]; then
            latest_kernel_version="error"
            your_kernel_version=`uname -r | cut -d - -f 1`
            return 1
        fi
        local i=0
        local i2=0
        local i3=0
        local kernel_rc=""
        local kernel_list_temp2
        while ((i2<${#kernel_list_temp[@]}))
        do
            if [[ "${kernel_list_temp[i2]}" =~ "rc" ]] && [ "$kernel_rc" == "" ]; then
                kernel_list_temp2[i3]="${kernel_list_temp[i2]}"
                kernel_rc="${kernel_list_temp[i2]%%-*}"
                ((i3++))
                ((i2++))
            elif [[ "${kernel_list_temp[i2]}" =~ "rc" ]] && [ "${kernel_list_temp[i2]%%-*}" == "$kernel_rc" ]; then
                kernel_list_temp2[i3]=${kernel_list_temp[i2]}
                ((i3++))
                ((i2++))
            elif [[ "${kernel_list_temp[i2]}" =~ "rc" ]] && [ "${kernel_list_temp[i2]%%-*}" != "$kernel_rc" ]; then
                for((i3=0;i3<${#kernel_list_temp2[@]};i3++))
                do
                    kernel_list[i]=${kernel_list_temp2[i3]}
                    ((i++))
                done
                kernel_rc=""
                i3=0
                unset kernel_list_temp2
            elif version_ge "$kernel_rc" "${kernel_list_temp[i2]}"; then
                if [ "$kernel_rc" == "${kernel_list_temp[i2]}" ]; then
                    kernel_list[i]=${kernel_list_temp[i2]}
                    ((i++))
                    ((i2++))
                fi
                for((i3=0;i3<${#kernel_list_temp2[@]};i3++))
                do
                    kernel_list[i]=${kernel_list_temp2[i3]}
                    ((i++))
                done
                kernel_rc=""
                i3=0
                unset kernel_list_temp2
            else
                kernel_list[i]=${kernel_list_temp[i2]}
                ((i++))
                ((i2++))
            fi
        done
        if [ "$kernel_rc" != "" ]; then
            for((i3=0;i3<${#kernel_list_temp2[@]};i3++))
            do
                kernel_list[i]=${kernel_list_temp2[i3]}
                ((i++))
            done
        fi
        latest_kernel_version=${kernel_list[0]}
        your_kernel_version=`uname -r | cut -d - -f 1`
        check_fake_version()
        {
            local temp=${1##*.}
            if [ ${temp} -eq 0 ]; then
                return 0
            else
                return 1
            fi
        }
        while check_fake_version ${your_kernel_version}
        do
            your_kernel_version=${your_kernel_version%.*}
        done
        if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
            local rc_version=`uname -r | cut -d - -f 2`
            if [[ $rc_version =~ "rc" ]]; then
                rc_version=${rc_version##*'rc'}
                your_kernel_version=${your_kernel_version}-rc${rc_version}
            fi
        else
            latest_kernel_version=${latest_kernel_version%%-*}
        fi
    }
    #卸载多余内核
    remove_other_kernel()
    {
        if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
            local kernel_list_image=($(dpkg --list | grep 'linux-image' | awk '{print $2}'))
            local kernel_list_modules=($(dpkg --list | grep 'linux-modules' | awk '{print $2}'))
            local kernel_now=`uname -r`
            local ok_install=0
            for ((i=${#kernel_list_image[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list_image[$i]}" =~ "$kernel_now" ]]; then     
                    unset kernel_list_image[$i]
                    ((ok_install++))
                fi
            done
            if [ $ok_install -lt 1 ]; then
                red "未发现正在使用的内核，可能已经被卸载"
                yellow "按回车键继续。。。"
                read -s
                return 1
            fi
            ok_install=0
            for ((i=${#kernel_list_modules[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list_modules[$i]}" =~ "$kernel_now" ]]; then
                    unset kernel_list_modules[$i]
                    ((ok_install++))
                fi
            done
            if [ $ok_install -lt 1 ]; then
                red "未发现正在使用的内核，可能已经被卸载"
                yellow "按回车键继续。。。"
                read -s
                return 1
            fi
            if [ ${#kernel_list_modules[@]} -eq 0 ] && [ ${#kernel_list_image[@]} -eq 0 ]; then
                yellow "没有内核可卸载"
                return 0
            fi
            apt -y purge ${kernel_list_image[@]} ${kernel_list_modules[@]}
        else
            local kernel_list=($(rpm -qa |grep '^kernel-[0-9]\|^kernel-ml-[0-9]'))
            local kernel_list_devel=($(rpm -qa | grep '^kernel-devel\|^kernel-ml-devel'))
            if version_ge $redhat_version 8; then
                local kernel_list_modules=($(rpm -qa |grep '^kernel-modules\|^kernel-ml-modules'))
                local kernel_list_core=($(rpm -qa | grep '^kernel-core\|^kernel-ml-core'))
            fi
            local kernel_now=`uname -r`
            local ok_install=0
            for ((i=${#kernel_list[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list[$i]}" =~ "$kernel_now" ]]; then
                    unset kernel_list[$i]
                    ((ok_install++))
                fi
            done
            if [ $ok_install -lt 1 ]; then
                red "未发现正在使用的内核，可能已经被卸载"
                yellow "按回车键继续。。。"
                read -s
                return 1
            fi
            for ((i=${#kernel_list_devel[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list_devel[$i]}" =~ "$kernel_now" ]]; then
                    unset kernel_list_devel[$i]
                fi
            done
            if version_ge $redhat_version 8; then
                ok_install=0
                for ((i=${#kernel_list_modules[@]}-1;i>=0;i--))
                do
                    if [[ "${kernel_list_modules[$i]}" =~ "$kernel_now" ]]; then
                        unset kernel_list_modules[$i]
                        ((ok_install++))
                    fi
                done
                if [ $ok_install -lt 1 ]; then
                    red "未发现正在使用的内核，可能已经被卸载"
                    yellow "按回车键继续。。。"
                    read -s
                    return 1
                fi
                ok_install=0
                for ((i=${#kernel_list_core[@]}-1;i>=0;i--))
                do
                    if [[ "${kernel_list_core[$i]}" =~ "$kernel_now" ]]; then
                        unset kernel_list_core[$i]
                        ((ok_install++))
                    fi
                done
                if [ $ok_install -lt 1 ]; then
                    red "未发现正在使用的内核，可能已经被卸载"
                    yellow "按回车键继续。。。"
                    read -s
                    return 1
                fi
            fi
            if ([ ${#kernel_list[@]} -eq 0 ] && [ ${#kernel_list_devel[@]} -eq 0 ]) && (! version_ge $redhat_version 8 || ([ ${#kernel_list_modules[@]} -eq 0 ] && [ ${#kernel_list_core[@]} -eq 0 ])); then
                yellow "没有内核可卸载"
                return 0
            fi
            if version_ge $redhat_version 8; then
                $redhat_package_manager -y remove ${kernel_list[@]} ${kernel_list_modules[@]} ${kernel_list_core[@]} ${kernel_list_devel[@]}
            else
                $redhat_package_manager -y remove ${kernel_list[@]} ${kernel_list_devel[@]}
            fi
        fi
        green "-------------------卸载完成-------------------"
    }
    local your_kernel_version
    local latest_kernel_version
    if ! grep -q "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" /etc/sysctl.conf; then
        echo >> /etc/sysctl.conf
        echo "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" >> /etc/sysctl.conf
    fi
    if [ "$latest_kernel_version" == "" ]; then
        get_kernel_info
    else
        sleep 3s
    fi
    echo -e "\n\n\n"
    tyblue "------------------请选择要使用的bbr版本------------------"
    green  " 1. 升级最新版内核并启用bbr(推荐)"
    if version_ge $your_kernel_version 4.9; then
        tyblue " 2. 启用bbr"
    else
        tyblue " 2. 升级内核启用bbr"
    fi
    tyblue " 3. 启用bbr2(需更换第三方内核)"
    tyblue " 4. 启用bbrplus/bbr魔改版/暴力bbr魔改版/锐速(需更换第三方内核)"
    tyblue " 5. 卸载多余内核"
    tyblue " 6. 退出bbr安装"
    tyblue "------------------关于安装bbr加速的说明------------------"
    green  " bbr加速可以大幅提升网络速度，建议安装"
    yellow " 更换第三方内核可能造成系统不稳定，甚至无法开机"
    yellow " 更换/升级内核需重启，重启后，请再次运行此脚本完成剩余安装"
    tyblue "---------------------------------------------------------"
    tyblue " 当前内核版本：${your_kernel_version}"
    tyblue " 最新内核版本：${latest_kernel_version}"
    tyblue " 当前内核是否支持bbr："
    if version_ge $your_kernel_version 4.9; then
        green "     是"
    else
        red "     否，需升级内核"
    fi
    tyblue "  bbr启用状态："
    if sysctl net.ipv4.tcp_congestion_control | grep -Eq "bbr|nanqinlang|tsunami"; then
        local bbr_info=`sysctl net.ipv4.tcp_congestion_control`
        bbr_info=${bbr_info#*=}
        if [ $bbr_info == nanqinlang ]; then
            bbr_info="暴力bbr魔改版"
        elif [ $bbr_info == tsunami ]; then
            bbr_info="bbr魔改版"
        fi
        green "   正在使用：${bbr_info}"
    else
        red "   bbr未启用"
    fi
    echo
    choice=""
    while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" -a "$choice" != "4" -a "$choice" != "5" -a "$choice" != "6" ]
    do
        read -p "您的选择是：" choice
    done
    case "$choice" in
        1)
            sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
            sed -i '/^[ \t]*net.ipv4.tcp_congestion_control[ \t]*=/d' /etc/sysctl.conf
            echo 'net.core.default_qdisc = fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control = bbr' >> /etc/sysctl.conf
            sysctl -p
            if ! wget -O update-kernel.sh https://github.com/kirin10000/update-kernel/raw/master/update-kernel.sh; then
                red    "获取内核升级脚本失败"
                yellow "按回车键继续或者按ctrl+c终止"
                read -s
            fi
            chmod +x update-kernel.sh
            ./update-kernel.sh
            if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
                red "开启bbr失败"
                red "如果刚安装完内核，请先重启"
                red "如果重启仍然无效，请尝试选择2选项"
            else
                green "--------------------bbr已安装--------------------"
            fi
            install_bbr
            ;;
        2)
            sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
            sed -i '/^[ \t]*net.ipv4.tcp_congestion_control[ \t]*=/d' /etc/sysctl.conf
            echo 'net.core.default_qdisc = fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control = bbr' >> /etc/sysctl.conf
            sysctl -p
            sleep 1s
            if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
                if ! wget -O bbr.sh https://github.com/teddysun/across/raw/master/bbr.sh; then
                    red    "获取bbr脚本失败"
                    yellow "按回车键继续或者按ctrl+c终止"
                    read -s
                fi
                chmod +x bbr.sh
                ./bbr.sh
            else
                green "--------------------bbr已安装--------------------"
            fi
            install_bbr
            ;;
        3)
            tyblue "--------------------即将安装bbr2加速，安装完成后服务器将会重启--------------------"
            tyblue " 重启后，请再次选择这个选项完成bbr2剩余部分安装(开启bbr和ECN)"
            yellow " 按回车键以继续。。。。"
            read -s
            if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
                if ! wget -O bbr2.sh https://github.com/yeyingorg/bbr2.sh/raw/master/bbr2.sh; then
                    red    "获取bbr2脚本失败"
                    yellow "按回车键继续或者按ctrl+c终止"
                    read -s
                fi
            else
                if ! wget -O bbr2.sh https://github.com/jackjieYYY/bbr2/raw/master/bbr2.sh; then
                    red    "获取bbr2脚本失败"
                    yellow "按回车键继续或者按ctrl+c终止"
                    read -s
                fi
            fi
            chmod +x bbr2.sh
            ./bbr2.sh
            install_bbr
            ;;
        4)
            if ! wget -O tcp.sh "https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh"; then
                red    "获取脚本失败"
                yellow "按回车键继续或者按ctrl+c终止"
                read -s
            fi
            chmod +x tcp.sh
            ./tcp.sh
            install_bbr
            ;;
        5)
            tyblue " 该操作将会卸载除现在正在使用的内核外的其余内核"
            tyblue "    您正在使用的内核是：$(uname -r)"
            choice=""
            while [[ "$choice" != "y" && "$choice" != "n" ]]
            do
                read -p "是否继续？(y/n)" choice
            done
            if [ $choice == y ]; then
                remove_other_kernel
            fi
            install_bbr
            ;;
    esac
}

#读取域名
readDomain()
{
    check_domain()
    {
        local temp=${1%%.*}
        if [ "$temp" == "www" ]; then
            red "域名前面不要带www！"
            return 0
        elif [ "$1" == "" ]; then
            return 0
        else
            return 1
        fi
    }
    local domain=""
    local domainconfig=""
    local pretend=""
    echo -e "\n\n\n"
    tyblue "--------------------请选择域名解析情况--------------------"
    tyblue " 1. 一级域名 和 www.一级域名 都解析到此服务器上"
    green  "    如：123.com 和 www.123.com 都解析到此服务器上"
    tyblue " 2. 仅某个域名解析到此服务器上"
    green  "    如：123.com 或 www.123.com 或 xxx.123.com 中的某一个解析到此服务器上"
    echo
    while [ "$domainconfig" != "1" -a "$domainconfig" != "2" ]
    do
        read -p "您的选择是：" domainconfig
    done
    case "$domainconfig" in
        1)
            echo
            tyblue "--------------------请输入一级域名(不带www.，http，:，/)--------------------"
            read -p "请输入域名：" domain
            while check_domain $domain
            do
                read -p "请输入域名：" domain
            done
            ;;
        2)
            echo
            tyblue "----------------请输入解析到此服务器的域名(不带http，:，/)----------------"
            read -p "请输入域名：" domain
            ;;
    esac
    echo -e "\n\n\n"
    tyblue "------------------------------请选择要伪装的网站页面------------------------------"
    tyblue " 1. 403页面 (模拟网站后台)"
    green  "    说明：大型网站几乎都有使用网站后台，比如bilibili的每个视频都是由"
    green  "    另外一个域名提供的，直接访问那个域名的根目录将返回403或其他错误页面"
    tyblue " 2. 镜像腾讯视频网站"
    green  "    说明：是真镜像站，非链接跳转，默认为腾讯视频，搭建完成后可以自己修改，可能构成侵权"
    tyblue " 3. nextcloud登陆页面"
    green  "    说明：nextclound是开源的私人网盘服务，假装你搭建了一个私人网盘(可以换成别的自定义网站)"
    echo
    while [[ x"$pretend" != x"1" && x"$pretend" != x"2" && x"$pretend" != x"3" ]]
    do
        read -p "您的选择是：" pretend
    done
    domain_list+=("$domain")
    domainconfig_list+=("$domainconfig")
    pretend_list+=("$pretend")
}

#读取v2ray_protocol配置
readProtocolConfig()
{
    echo -e "\n\n\n"
    tyblue "---------------------请选择V2Ray要使用协议---------------------"
    tyblue " 1. (VLESS-TCP+XTLS) + (VMess-WebSocket+TLS) + Web"
    green  "    适合有时使用CDN，且CDN不可信任(如国内CDN)"
    tyblue " 2. (VLESS-TCP+XTLS) + (VLESS-WebSocket+TLS) + Web"
    green  "    适合有时使用CDN，且CDN可信任"
    tyblue " 3. VLESS-TCP+XTLS+Web"
    green  "    适合完全不用CDN"
    tyblue " 4. VMess-WebSocket+TLS+Web"
    green  "    适合一直使用CDN，且CDN不可信任(如国内CDN)"
    tyblue " 5. VLESS-WebSocket+TLS+Web"
    green  "    适合一直使用CDN，且CDN可信任"
    echo
    yellow " 注："
    yellow "   1.各协议理论速度对比：https://github.com/badO1a5A90/v2ray-doc/blob/main/v2ray_speed_test_v4.32.1.md"
    yellow "   2.XTLS完全兼容TLS"
    yellow "   3.WebSocket协议支持CDN，TCP不支持"
    yellow "   4.VLESS协议用于CDN，CDN可以看见传输的明文"
    yellow "   5.若不知CDN为何物，请选3"
    echo
    local mode=""
    while [[ "$mode" != "1" && "$mode" != "2" && "$mode" != "3" && "$mode" != "4" && "$mode" != "5" ]]
    do
        read -p "您的选择是：" mode
    done
    if [ $mode -eq 1 ]; then
        protocol_1=1
        protocol_2=2
    elif [ $mode -eq 2 ]; then
        protocol_1=1
        protocol_2=1
    elif [ $mode -eq 3 ]; then
        protocol_1=1
        protocol_2=0
    elif [ $mode -eq 4 ]; then
        protocol_1=0
        protocol_2=2
    elif [ $mode -eq 5 ]; then
        protocol_1=0
        protocol_2=1
    fi
}

#备份域名伪装网站
backup_domains_web()
{
    local i
    mkdir "${temp_dir}/domain_backup"
    for i in ${!domain_list[@]}
    do
        if [ "$1" == "cp" ]; then
            cp -rf ${nginx_prefix}/html/${domain_list[i]} "${temp_dir}/domain_backup" 2>/dev/null
        else
            mv ${nginx_prefix}/html/${domain_list[i]} "${temp_dir}/domain_backup" 2>/dev/null
        fi
    done
}

#卸载v2ray和nginx
remove_v2ray()
{
    systemctl stop v2ray
    bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove
    systemctl disable v2ray
    rm -rf /usr/bin/v2ray
    rm -rf /etc/v2ray
    rm -rf /usr/local/bin/v2ray
    rm -rf /usr/local/etc/v2ray
    rm -rf /etc/systemd/system/v2ray.service
    rm -rf /etc/systemd/system/v2ray@.service
    systemctl daemon-reload
}
remove_nginx()
{
    systemctl stop nginx
    ${nginx_prefix}/sbin/nginx -s stop
    pkill -9 nginx
    systemctl disable nginx
    rm -rf /etc/systemd/system/nginx.service
    systemctl daemon-reload
    rm -rf ${nginx_prefix}
}

#安装nignx
install_nginx()
{
    green "正在编译和安装nginx。。。。"
    if ! wget -O ${nginx_version}.tar.gz https://nginx.org/download/${nginx_version}.tar.gz; then
        red    "获取nginx失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    tar -zxf ${nginx_version}.tar.gz
    if ! wget -O ${openssl_version}.tar.gz https://github.com/openssl/openssl/archive/${openssl_version#*-}.tar.gz; then
        red    "获取openssl失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    tar -zxf ${openssl_version}.tar.gz
    cd ${nginx_version}
    sed -i "s/OPTIMIZE[ \t]*=>[ \t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    ./configure --prefix=${nginx_prefix} --with-openssl=../$openssl_version --with-openssl-opt="enable-ec_nistp_64_gcc_128 shared threads zlib-dynamic sctp" --with-mail=dynamic --with-mail_ssl_module --with-stream=dynamic --with-stream_ssl_module --with-stream_realip_module --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module --with-http_ssl_module --with-http_v2_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic --with-http_geoip_module=dynamic --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module=dynamic --with-pcre --with-libatomic --with-compat --with-cpp_test_module --with-google_perftools_module --with-file-aio --with-threads --with-poll_module --with-select_module --with-cc-opt="-Wno-error -g0 -O3"
    if ! make; then
        red    "nginx编译失败！"
        yellow "请尝试更换系统，建议使用Ubuntu最新版系统"
        green  "欢迎进行Bug report(https://github.com/kirin10000/V2Ray-TLS-Web-setup-script/issues)，感谢您的支持"
        exit 1
    fi
    if [ $update == 1 ]; then
        backup_domains_web
    fi
    remove_nginx
    make install
    cd ..
}

#安装/更新V2Ray
install_update_v2ray()
{
    green "正在安装/更新V2Ray。。。。"
    if ! bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) && ! bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh); then
        red    "安装/更新V2Ray失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
        return 1
    fi
    #解决透明代理 Too many files 问题
    #https://guide.v2fly.org/app/tproxy.html#%E8%A7%A3%E5%86%B3-too-many-open-files-%E9%97%AE%E9%A2%98
    if ! grep -qE 'LimitNPROC|LimitNOFILE' /etc/systemd/system/v2ray.service /etc/systemd/system/v2ray@.service; then
        echo >> /etc/systemd/system/v2ray.service
        echo "[Service]" >> /etc/systemd/system/v2ray.service
        echo "LimitNPROC=10000" >> /etc/systemd/system/v2ray.service
        echo "LimitNOFILE=1000000" >> /etc/systemd/system/v2ray.service
        echo >> /etc/systemd/system/v2ray@.service
        echo "[Service]" >> /etc/systemd/system/v2ray@.service
        echo "LimitNPROC=10000" >> /etc/systemd/system/v2ray@.service
        echo "LimitNOFILE=1000000" >> /etc/systemd/system/v2ray@.service
        systemctl daemon-reload
        sleep 1s
        if systemctl is-active v2ray > /dev/null 2>&1; then
            systemctl restart v2ray
        fi
    fi
}

#获取证书 参数: domain domainconfig
get_cert()
{
    mv $v2ray_config $v2ray_config.bak
    echo "{}" > $v2ray_config
    if [ $2 -eq 1 ]; then
        local temp="-d www.$1"
    else
        local temp=""
    fi
    if ! $HOME/.acme.sh/acme.sh --issue -d $1 $temp -w ${nginx_prefix}/html -k ec-256 -ak ec-256 --pre-hook "mv ${nginx_prefix}/conf/nginx.conf ${nginx_prefix}/conf/nginx.conf.bak && cp ${nginx_prefix}/conf/nginx.conf.default ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --post-hook "mv ${nginx_prefix}/conf/nginx.conf.bak ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --ocsp; then
        $HOME/.acme.sh/acme.sh --issue -d $1 $temp -w ${nginx_prefix}/html -k ec-256 -ak ec-256 --pre-hook "mv ${nginx_prefix}/conf/nginx.conf ${nginx_prefix}/conf/nginx.conf.bak && cp ${nginx_prefix}/conf/nginx.conf.default ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --post-hook "mv ${nginx_prefix}/conf/nginx.conf.bak ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --ocsp --debug
    fi
    if id nobody | grep -qw 'nogroup'; then
        temp="chown -R nobody:nogroup ${nginx_prefix}/certs"
    else
        temp="chown -R nobody:nobody ${nginx_prefix}/certs"
    fi
    if ! $HOME/.acme.sh/acme.sh --installcert -d $1 --key-file ${nginx_prefix}/certs/${1}.key --fullchain-file ${nginx_prefix}/certs/${1}.cer --reloadcmd "$temp && sleep 2s && systemctl restart v2ray" --ecc; then
        yellow "证书安装失败，请检查您的域名，确保80端口未打开并且未被占用。并在安装完成后，使用选项9修复"
        yellow "按回车键继续。。。"
        read -s
    fi
    mv $v2ray_config.bak $v2ray_config
}
get_all_certs()
{
    local i
    for ((i=0;i<${#domain_list[@]};i++))
    do
        get_cert ${domain_list[i]} ${domainconfig_list[i]}
    done
}

#配置nginx
config_nginx_init()
{
cat > ${nginx_prefix}/conf/nginx.conf <<EOF

user  root root;
worker_processes  auto;

#error_log  logs/error.log;
#error_log  logs/error.log  notice;
#error_log  logs/error.log  info;

#pid        logs/nginx.pid;
google_perftools_profiles /dev/shm/nginx_tcmalloc/tcmalloc;

events {
    worker_connections  1024;
}


http {
    include       mime.types;
    default_type  application/octet-stream;

    #log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
    #                  '\$status \$body_bytes_sent "\$http_referer" '
    #                  '"\$http_user_agent" "\$http_x_forwarded_for"';

    #access_log  logs/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    #keepalive_timeout  0;
    keepalive_timeout  65;

    #gzip  on;

    include       $nginx_config;
    #server {
        #listen       80;
        #server_name  localhost;

        #charset koi8-r;

        #access_log  logs/host.access.log  main;

        #location / {
        #    root   html;
        #    index  index.html index.htm;
        #}

        #error_page  404              /404.html;

        # redirect server error pages to the static page /50x.html
        #
        #error_page   500 502 503 504  /50x.html;
        #location = /50x.html {
        #    root   html;
        #}

        # proxy the PHP scripts to Apache listening on 127.0.0.1:80
        #
        #location ~ \\.php\$ {
        #    proxy_pass   http://127.0.0.1;
        #}

        # pass the PHP scripts to FastCGI server listening on 127.0.0.1:9000
        #
        #location ~ \\.php\$ {
        #    root           html;
        #    fastcgi_pass   127.0.0.1:9000;
        #    fastcgi_index  index.php;
        #    fastcgi_param  SCRIPT_FILENAME  /scripts\$fastcgi_script_name;
        #    include        fastcgi_params;
        #}

        # deny access to .htaccess files, if Apache's document root
        # concurs with nginx's one
        #
        #location ~ /\\.ht {
        #    deny  all;
        #}
    #}


    # another virtual host using mix of IP-, name-, and port-based configuration
    #
    #server {
    #    listen       8000;
    #    listen       somename:8080;
    #    server_name  somename  alias  another.alias;

    #    location / {
    #        root   html;
    #        index  index.html index.htm;
    #    }
    #}


    # HTTPS server
    #
    #server {
    #    listen       443 ssl;
    #    server_name  localhost;

    #    ssl_certificate      cert.pem;
    #    ssl_certificate_key  cert.key;

    #    ssl_session_cache    shared:SSL:1m;
    #    ssl_session_timeout  5m;

    #    ssl_ciphers  HIGH:!aNULL:!MD5;
    #    ssl_prefer_server_ciphers  on;

    #    location / {
    #        root   html;
    #        index  index.html index.htm;
    #    }
    #}

}
EOF
}
config_nginx()
{
    config_nginx_init
    local i
    get_all_domains
cat > $nginx_config<<EOF
server {
    listen 80 fastopen=100 reuseport default_server;
    listen [::]:80 fastopen=100 reuseport default_server;
    return 301 https://${all_domains[0]};
}
server {
    listen 80;
    listen [::]:80;
    server_name ${all_domains[@]};
    return 301 https://\$host\$request_uri;
}
server {
    listen unix:/dev/shm/nginx_unixsocket/default.sock default_server;
    listen unix:/dev/shm/nginx_unixsocket/h2.sock http2 default_server;
    return 301 https://${all_domains[0]};
}
EOF
    for ((i=0;i<${#domain_list[@]};i++))
    do
cat >> $nginx_config<<EOF
server {
    listen unix:/dev/shm/nginx_unixsocket/default.sock;
    listen unix:/dev/shm/nginx_unixsocket/h2.sock http2;
EOF
        if [ ${domainconfig_list[i]} -eq 1 ]; then
            echo "    server_name www.${domain_list[i]} ${domain_list[i]};" >> $nginx_config
        else
            echo "    server_name ${domain_list[i]};" >> $nginx_config
        fi
        if [ ${pretend_list[i]} -eq 1 ]; then
            echo "    return 403;" >> $nginx_config
        elif [ ${pretend_list[i]} -eq 2 ]; then
cat >> $nginx_config<<EOF
    location / {
        proxy_pass https://v.qq.com;
        proxy_set_header referer "https://v.qq.com";
    }
EOF
        elif [ ${pretend_list[i]} -eq 3 ]; then
            echo "    root ${nginx_prefix}/html/${domain_list[i]};" >> $nginx_config
        fi
        echo "}" >> $nginx_config
    done
}
config_service_nginx()
{
    systemctl disable nginx
    rm -rf /etc/systemd/system/nginx.service
cat > /etc/systemd/system/nginx.service << EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
User=root
ExecStartPre=/bin/rm -rf /dev/shm/nginx_unixsocket
ExecStartPre=/bin/mkdir /dev/shm/nginx_unixsocket
ExecStartPre=/bin/chmod 711 /dev/shm/nginx_unixsocket
ExecStartPre=/bin/rm -rf /dev/shm/nginx_tcmalloc
ExecStartPre=/bin/mkdir /dev/shm/nginx_tcmalloc
ExecStartPre=/bin/chmod 0777 /dev/shm/nginx_tcmalloc
ExecStart=${nginx_prefix}/sbin/nginx
ExecStop=${nginx_prefix}/sbin/nginx -s stop
ExecStopPost=/bin/rm -rf /dev/shm/nginx_tcmalloc
ExecStopPost=/bin/rm -rf /dev/shm/nginx_unixsocket
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/nginx.service
    systemctl daemon-reload
    systemctl enable nginx
}

#配置v2ray
config_v2ray()
{
    local i
cat > $v2ray_config <<EOF
{
    "log": {
        "loglevel": "none"
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
EOF
    if [ $protocol_1 -eq 1 ]; then
cat >> $v2ray_config <<EOF
                "clients": [
                    {
                        "id": "$v2id_1",
                        "flow": "xtls-rprx-direct",
                        "level": 2
                    }
                ],
EOF
    fi
    echo '                "decryption": "none",' >> $v2ray_config
    echo '                "fallbacks": [' >> $v2ray_config
    if [ $protocol_2 -ne 0 ]; then
cat >> $v2ray_config <<EOF
                    {
                        "path": "$path",
                        "dest": "@/dev/shm/v2ray/ws.sock",
                        "xver": 0
                    },
EOF
    fi
cat >> $v2ray_config <<EOF
                    {
                        "dest": "/dev/shm/nginx_unixsocket/default.sock",
                        "xver": 0
                    },
                    {
                        "alpn": "h2",
                        "dest": "/dev/shm/nginx_unixsocket/h2.sock",
                        "xver": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "xtls",
                "xtlsSettings": {
                    "alpn": [
                        "h2",
                        "http/1.1"
                    ],
                    "certificates": [
EOF
    for ((i=0;i<${#domain_list[@]};i++))
    do
cat >> $v2ray_config <<EOF
                        {
                            "certificateFile": "${nginx_prefix}/certs/${domain_list[i]}.cer",
                            "keyFile": "${nginx_prefix}/certs/${domain_list[i]}.key"
EOF
        if (($i==${#domain_list[@]}-1)); then
            echo "                        }" >> $v2ray_config
        else
            echo "                        }," >> $v2ray_config
        fi
    done
cat >> $v2ray_config <<EOF
                    ]
                },
                "sockopt": {
                    "tcpFastOpen": true
                }
            }
EOF
    if [ $protocol_2 -ne 0 ]; then
        echo '        },' >> $v2ray_config
        echo '        {' >> $v2ray_config
        echo '            "listen": "@/dev/shm/v2ray/ws.sock",' >> $v2ray_config
        if [ $protocol_2 -eq 2 ]; then
            echo '            "protocol": "vmess",' >> $v2ray_config
        else
            echo '            "protocol": "vless",' >> $v2ray_config
        fi
        echo '            "settings": {' >> $v2ray_config
        echo '                "clients": [' >> $v2ray_config
        echo '                    {' >> $v2ray_config
        echo '                        "id": "'"$v2id_2"'",' >> $v2ray_config
        echo '                        "level": 1' >> $v2ray_config
        echo '                    }' >> $v2ray_config
        if [ $protocol_2 -eq 2 ]; then
            echo '                ]' >> $v2ray_config
        else
            echo '                ],' >> $v2ray_config
            echo '                "decryption": "none"' >> $v2ray_config
        fi
cat >> $v2ray_config <<EOF
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "$path"
                }
            }
EOF
    fi
cat >> $v2ray_config <<EOF
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "streamSettings": {
                "sockopt": {
                    "tcpFastOpen": true
                }
            }
        }
    ]
}
EOF
}

#下载nextcloud模板，用于伪装    参数: domain pretend
get_web()
{
    if [ $2 -eq 3 ]; then
        rm -rf ${nginx_prefix}/html/$1
        mkdir ${nginx_prefix}/html/$1
        if ! wget -O ${nginx_prefix}/html/$1/Website-Template.zip https://github.com/kirin10000/V2Ray-TLS-Web-setup-script/raw/master/Website-Template.zip; then
            red    "获取网站模板失败"
            yellow "按回车键继续或者按ctrl+c终止"
            read -s
        fi
        unzip -q -d ${nginx_prefix}/html/$1 ${nginx_prefix}/html/$1/Website-Template.zip
        rm -rf ${nginx_prefix}/html/$1/Website-Template.zip
    fi
}
get_all_webs()
{
    local i
    for ((i=0;i<${#domain_list[@]};i++))
    do
        get_web ${domain_list[i]} ${pretend_list[i]}
    done
}

echo_end()
{
    get_all_domains
    echo -e "\n\n\n"
    if [ $protocol_1 -ne 0 ]; then
        tyblue "--------------------- V2Ray-TCP+XTLS+Web (不走CDN) ---------------------"
        tyblue " 服务器类型            ：VLESS"
        tyblue " address(地址)         ：服务器ip"
        purple "  (Qv2ray:主机)"
        tyblue " port(端口)            ：443"
        tyblue " id(用户ID/UUID)       ：${v2id_1}"
        tyblue " flow(流控)            ：使用XTLS：xtls-rprx-direct-udp443;使用TLS：空"
        tyblue " encryption(加密)      ：none"
        tyblue " ---Transport/StreamSettings(底层传输方式/流设置)---"
        tyblue "  network(传输协议)             ：tcp"
        purple "   (Shadowrocket:传输方式:none)"
        tyblue "  type(伪装类型)                ：none"
        purple "   (Qv2ray:协议设置-类型)"
        tyblue "  security(传输层加密)          ：xtls或tls \033[35;1m(此选项将决定是使用XTLS还是TLS)"
        purple "   (V2RayN(G):底层传输安全;Qv2ray:TLS设置-安全类型)"
        if [ ${#all_domains[@]} -eq 1 ]; then
            tyblue "  serverName(验证服务端证书域名)：${all_domains[@]}"
        else
            tyblue "  serverName(验证服务端证书域名)：${all_domains[@]} \033[35;1m(任选其一)"
        fi
        purple "   (V2RayN(G):伪装域名;Qv2ray:TLS设置-服务器地址;Shadowrocket:Peer 名称)"
        tyblue "  allowInsecure                 ：false"
        purple "   (Qv2ray:允许不安全的证书(不打勾);Shadowrocket:允许不安全(关闭))"
        tyblue "  tcpFastOpen(TCP快速打开)      ：可以启用"
        tyblue " ------------------------其他-----------------------"
        tyblue "  Mux(多路复用)                 ：使用XTLS必须关闭;不使用XTLS也建议关闭"
        tyblue "  Sniffing(流量探测)            ：建议开启"
        purple "   (Qv2ray:首选项-入站设置-SOCKS设置-嗅探)"
        tyblue "------------------------------------------------------------------------"
        echo
        yellow " 请确保客户端V2Ray版本为v4.30.0+(VLESS在4.30.0版本中对UDP传输进行了一次更新，并且不向下兼容)"
        yellow " 使用XLTS请确保客户端V2Ray版本为v4.31.0+(XTLS在4.31.0版本中对流控进行了一次升级，并且不向下兼容)"
        echo
        green  " 目前支持支持XTLS的图形化客户端："
        green  "   Windows    ：V2RayN  v3.26+  Qv2ray v2.7.0-pre1+"
        green  "   Android    ：V2RayNG v1.4.8+"
        green  "   Linux/MacOS：Qv2ray  v2.7.0-pre1+"
    fi
    if [ $protocol_2 -ne 0 ]; then
        echo
        tyblue "------------- V2Ray-WebSocket+TLS+Web (如果有CDN，会走CDN) -------------"
        if [ $protocol_2 -eq 1 ]; then
            tyblue " 服务器类型            ：VLESS"
        else
            tyblue " 服务器类型            ：VMess"
        fi
        if [ ${#all_domains[@]} -eq 1 ]; then
            tyblue " address(地址)         ：${all_domains[@]}"
        else
            tyblue " address(地址)         ：${all_domains[@]} \033[35;1m(任选其一)"
        fi
        purple "  (Qv2ray:主机)"
        tyblue " port(端口)            ：443"
        tyblue " id(用户ID/UUID)       ：${v2id_2}"
        if [ $protocol_2 -eq 1 ]; then
            tyblue " flow(流控)            ：空"
            tyblue " encryption(加密)      ：none"
        else
            tyblue " alterId(额外ID)       ：0"
            tyblue " security(加密方式)    ：使用CDN，推荐auto;不使用CDN，推荐none"
            purple "  (Qv2ray:安全选项;Shadowrocket:算法)"
        fi
        tyblue " ---Transport/StreamSettings(底层传输方式/流设置)---"
        tyblue "  network(传输协议)             ：ws"
        purple "   (Shadowrocket:传输方式:websocket)"
        tyblue "  path(路径)                    ：${path}"
        tyblue "  Host                          ：空"
        purple "   (V2RayN(G):伪装域名;Qv2ray:协议设置-请求头)"
        tyblue "  security(传输层加密)          ：tls"
        purple "   (V2RayN(G):底层传输安全;Qv2ray:TLS设置-安全类型)"
        tyblue "  serverName(验证服务端证书域名)：空"
        purple "   (V2RayN(G):伪装域名;Qv2ray:TLS设置-服务器地址;Shadowrocket:Peer 名称)"
        tyblue "  allowInsecure                 ：false"
        purple "   (Qv2ray:允许不安全的证书(不打勾);Shadowrocket:允许不安全(关闭))"
        tyblue "  tcpFastOpen(TCP快速打开)      ：可以启用"
        tyblue " ------------------------其他-----------------------"
        tyblue "  Mux(多路复用)                 ：建议关闭"
        tyblue "  Sniffing(流量探测)            ：建议开启"
        purple "   (Qv2ray:首选项-入站设置-SOCKS设置-嗅探)"
        tyblue "------------------------------------------------------------------------"
        echo
        if [ $protocol_2 -eq 2 ]; then
            yellow " 使用 VMess-WebSocket+TLS+Web 时，请尽快将V2Ray升级至v4.28.0+以启用VMessAEAD"
        else
            yellow " 使用 VLESS-WebSocket+TLS+Web 时，请确保客户端V2Ray版本为v4.30.0+(VLESS在4.30.0版本中对UDP传输进行了一次更新，并且不向下兼容)"
        fi
    fi
    echo
    tyblue " 如果要更换被镜像的伪装网站"
    tyblue " 修改$nginx_config"
    tyblue " 将v.qq.com修改为你要镜像的网站"
    echo
    tyblue " 脚本最后更新时间：2020.11.07"
    echo
    red    " 此脚本仅供交流学习使用，请勿使用此脚本行违法之事。网络非法外之地，行非法之事，必将接受法律制裁!!!!"
    tyblue " 2020.08"
}

#获取配置信息 protocol_1 v2id_1 protocol_2 v2id_2 path
get_base_information()
{
    if [ $(grep "clients" $v2ray_config | wc -l) -eq 2 ] || [ $(grep -E "vmess|vless" $v2ray_config | wc -l) -eq 1 ]; then
        protocol_1=1
        v2id_1=`grep id $v2ray_config | head -n 1`
        v2id_1=${v2id_1##*' '}
        v2id_1=${v2id_1#*'"'}
        v2id_1=${v2id_1%'"'*}
    else
        protocol_1=0
        v2id_1=""
    fi
    if [ $(grep -E "vmess|vless" $v2ray_config | wc -l) -eq 2 ]; then
        grep -q "vmess" $v2ray_config && protocol_2=2 || protocol_2=1
        path=`grep path $v2ray_config`
        path=${path##*' '}
        path=${path#*'"'}
        path=${path%'"'*}
        v2id_2=`grep id $v2ray_config | tail -n 1`
        v2id_2=${v2id_2##*' '}
        v2id_2=${v2id_2#*'"'}
        v2id_2=${v2id_2%'"'*}
    else
        protocol_2=0
        path=""
        v2id_2=""
    fi
}

#获取域名列表
get_domainlist()
{
    unset domain_list
    domain_list=($(grep server_name $nginx_config | sed 's/;//g' | awk 'NR>1 {print $NF}'))
    local line
    local i
    for i in ${!domain_list[@]}
    do
        line=`grep -n "server_name www.${domain_list[i]} ${domain_list[i]};" $nginx_config | tail -n 1 | awk -F : '{print $1}'`
        if [ "$line" == "" ]; then
            line=`grep -n "server_name ${domain_list[i]};" $nginx_config | tail -n 1 | awk -F : '{print $1}'`
            domainconfig_list[i]=2
        else
            domainconfig_list[i]=1
        fi
        if awk 'NR=='"$(($line+1))"' {print $0}' $nginx_config | grep -q "return 403"; then
            pretend_list[i]=1
        elif awk 'NR=='"$(($line+1))"' {print $0}' $nginx_config | grep -q "location / {"; then
            pretend_list[i]=2
        else
            pretend_list[i]=3
        fi
    done
}

#安装v2ray_tls_web
install_update_v2ray_tls_web()
{
    install_dependence()
    {
        if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
            if ! apt -y --no-install-recommends install $1; then
                apt update
                if ! apt -y --no-install-recommends install $1; then
                    yellow "依赖安装失败！！"
                    green  "欢迎进行Bug report(https://github.com/kirin10000/V2Ray-TLS-Web-setup-script/issues)，感谢您的支持"
                    yellow "按回车键继续或者ctrl+c退出"
                    read -s
                fi
            fi
        else
            if [ $release == "centos" ] && version_ge $systemVersion 8; then
                if $redhat_package_manager --help | grep -q "\-\-enablerepo="; then
                    local redhat_install_command="$redhat_package_manager -y --enablerepo=PowerTools install"
                else
                    local redhat_install_command="$redhat_package_manager -y --enablerepo PowerTools install"
                fi
            else
                local redhat_install_command="$redhat_package_manager -y install"
            fi
            if ! $redhat_install_command $1; then
                yellow "依赖安装失败！！"
                green  "欢迎进行Bug report(https://github.com/kirin10000/V2Ray-TLS-Web-setup-script/issues)，感谢您的支持"
                yellow "按回车键继续或者ctrl+c退出"
                read -s
            fi
        fi
    }
    check_SELinux
    if ! grep -q "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" /etc/ssh/sshd_config; then
        setsshd
    fi
    systemctl stop nginx
    systemctl stop v2ray
    uninstall_firewall
    doupdate
    if ! grep -q "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" /etc/sysctl.conf; then
        echo >> /etc/sysctl.conf
        echo "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" >> /etc/sysctl.conf
    fi
    if ! grep -Eq '^[ '$'\t]*net.ipv4.tcp_fastopen[ '$'\t]*=[ '$'\t]*3[ '$'\t]*$' /etc/sysctl.conf || ! sysctl net.ipv4.tcp_fastopen | grep -wq 3; then
        sed -i '/^[ \t]*net.ipv4.tcp_fastopen[ \t]*=/d' /etc/sysctl.conf
        echo 'net.ipv4.tcp_fastopen = 3' >> /etc/sysctl.conf
        sysctl -p
    fi
    enter_temp_dir
    install_bbr
    apt -y -f install

#读取信息
    if [ $update == 0 ]; then
        readDomain
        readProtocolConfig
    else
        get_base_information
        get_domainlist
    fi

    green "正在安装依赖。。。。"
    if [ $release == "centos" ] || [ $release == "fedora" ] || [ $release == "other-redhat" ]; then
        install_dependence "gperftools-devel libatomic_ops-devel pcre-devel zlib-devel libxslt-devel gd-devel perl-ExtUtils-Embed perl-Data-Dumper perl-IPC-Cmd geoip-devel lksctp-tools-devel libxml2-devel gcc gcc-c++ wget unzip curl make openssl crontabs"
        ##libxml2-devel非必须
    else
        if [ "$release" == "ubuntu" ] && [ "$systemVersion" == "20.04" ] && [ "$(uname -m)" == "x86_64" ]; then
            install_dependence "gcc-10 g++-10"
            apt -y purge gcc g++ gcc-9 g++-9 gcc-8 g++-8 gcc-7 g++-7
            apt -y autopurge
            install_dependence "gcc-10 g++-10 libgoogle-perftools-dev libatomic-ops-dev libperl-dev libxslt-dev zlib1g-dev libpcre3-dev libgeoip-dev libgd-dev libxml2-dev libsctp-dev wget unzip curl make openssl cron"
            ln -s -f /usr/bin/gcc-10                         /usr/bin/gcc
            ln -s -f /usr/bin/gcc-10                         /usr/bin/cc
            ln -s -f /usr/bin/x86_64-linux-gnu-gcc-10        /usr/bin/x86_64-linux-gnu-gcc
            ln -s -f /usr/bin/g++-10                         /usr/bin/g++
            ln -s -f /usr/bin/g++-10                         /usr/bin/c++
            ln -s -f /usr/bin/x86_64-linux-gnu-g++-10        /usr/bin/x86_64-linux-gnu-g++
            ln -s -f /usr/bin/gcc-ar-10                      /usr/bin/gcc-ar
            ln -s -f /usr/bin/x86_64-linux-gnu-gcc-ar-10     /usr/bin/x86_64-linux-gnu-gcc-ar
            ln -s -f /usr/bin/gcc-nm-10                      /usr/bin/gcc-nm
            ln -s -f /usr/bin/x86_64-linux-gnu-gcc-nm-10     /usr/bin/x86_64-linux-gnu-gcc-nm
            ln -s -f /usr/bin/gcc-ranlib-10                  /usr/bin/gcc-ranlib
            ln -s -f /usr/bin/x86_64-linux-gnu-gcc-ranlib-10 /usr/bin/x86_64-linux-gnu-gcc-ranlib
            ln -s -f /usr/bin/cpp-10                         /usr/bin/cpp
            ln -s -f /usr/bin/x86_64-linux-gnu-cpp-10        /usr/bin/x86_64-linux-gnu-cpp
            ln -s -f /usr/bin/gcov-10                        /usr/bin/gcov
            ln -s -f /usr/bin/gcov-dump-10                   /usr/bin/gcov-dump
            ln -s -f /usr/bin/gcov-tool-10                   /usr/bin/gcov-tool
            ln -s -f /usr/bin/x86_64-linux-gnu-gcov-10       /usr/bin/x86_64-linux-gnu-gcov
            ln -s -f /usr/bin/x86_64-linux-gnu-gcov-dump-10  /usr/bin/x86_64-linux-gnu-gcov-dump
            ln -s -f /usr/bin/x86_64-linux-gnu-gcov-tool-10  /usr/bin/x86_64-linux-gnu-gcov-tool
        else
            install_dependence "gcc g++ libgoogle-perftools-dev libatomic-ops-dev libperl-dev libxslt-dev zlib1g-dev libpcre3-dev libgeoip-dev libgd-dev libxml2-dev libsctp-dev wget unzip curl make openssl cron"
            ##libxml2-dev非必须
        fi
    fi
    apt clean
    $redhat_package_manager clean all

##安装nginx
    if [ $nginx_is_installed -eq 0 ] || [ $update -eq 1 ]; then
        install_nginx
    else
        tyblue "---------------检测到nginx已存在---------------"
        tyblue " 1. 尝试使用现有nginx"
        tyblue " 2. 卸载现有nginx并重新编译安装"
        echo
        yellow " 若安装完成后nginx无法启动，请卸载并重新安装"
        green  " 若想更新nginx，请选择2"
        echo
        choice=""
        while [ "$choice" != "1" ] && [ "$choice" != "2" ]
        do
            read -p "您的选择是：" choice
        done
        if [ $choice -eq 2 ]; then
            install_nginx
        else
            rm -rf ${nginx_prefix}/conf.d
            rm -rf ${nginx_prefix}/certs
            cp ${nginx_prefix}/conf/nginx.conf.default ${nginx_prefix}/conf/nginx.conf
        fi
    fi
    mkdir ${nginx_prefix}/conf.d
    mkdir ${nginx_prefix}/certs
    config_service_nginx

#安装V2Ray
    remove_v2ray
    install_update_v2ray
    systemctl enable v2ray

    green "正在获取证书。。。。"
    if [ $update -eq 0 ]; then
        [ -e $HOME/.acme.sh/acme.sh ] && $HOME/.acme.sh/acme.sh --uninstall
        rm -rf $HOME/.acme.sh
        curl https://get.acme.sh | sh
    fi
    $HOME/.acme.sh/acme.sh --upgrade --auto-upgrade
    get_all_certs

    if [ $update == 0 ]; then
        path=$(cat /dev/urandom | head -c 8 | md5sum | head -c 7)
        path="/$path"
        v2id_1=`cat /proc/sys/kernel/random/uuid`
        v2id_2=`cat /proc/sys/kernel/random/uuid`
    fi
    config_nginx
    config_v2ray
    if [ $update == 1 ]; then
        mv "${temp_dir}/domain_backup/"* ${nginx_prefix}/html 2>/dev/null
    else
        get_all_webs
    fi
    sleep 2s
    systemctl restart nginx
    systemctl restart v2ray
    if [ $update == 1 ]; then
        green "-------------------升级完成-------------------"
    else
        green "-------------------安装完成-------------------"
    fi
    echo_end
    rm -rf "$temp_dir"
}

#开始菜单
start_menu()
{
    change_protocol()
    {
        get_base_information
        local protocol_1_old=$protocol_1
        local protocol_2_old=$protocol_2
        readProtocolConfig
        if [ $protocol_1_old -eq $protocol_1 ] && [ $protocol_2_old -eq $protocol_2 ]; then
            red "传输协议未更换"
            return 0
        fi
        [ $protocol_1_old -eq 0 ] && [ $protocol_1 -ne 0 ] && v2id_1=`cat /proc/sys/kernel/random/uuid`
        if [ $protocol_2_old -eq 0 ] && [ $protocol_2 -ne 0 ]; then
            path=$(cat /dev/urandom | head -c 8 | md5sum | head -c 7)
            path="/$path"
            v2id_2=`cat /proc/sys/kernel/random/uuid`
        fi
        get_domainlist
        config_v2ray
        systemctl restart v2ray
        green "更换成功！！"
        echo_end
    }
    change_dns()
    {
        red    "注意！！"
        red    "1.部分云服务商(如阿里云)使用本地服务器作为软件包源，修改dns后需要换源！！"
        red    "  如果不明白，那么请在安装完成后再修改dns，并且修改完后不要重新安装"
        red    "2.Ubuntu系统重启后可能会恢复原dns"
        tyblue "此操作将修改dns服务器为1.1.1.1和1.0.0.1(cloudflare公共dns)"
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            tyblue "是否要继续?(y/n)"
            read choice
        done
        if [ $choice == y ]; then
            if ! grep -q "#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script" /etc/resolv.conf; then
                sed -i 's/^[ \t]*nameserver[ \t][ \t]*/#&/' /etc/resolv.conf
                echo >> /etc/resolv.conf
                echo 'nameserver 1.1.1.1' >> /etc/resolv.conf
                echo 'nameserver 1.0.0.1' >> /etc/resolv.conf
                echo '#This file has been edited by v2ray-WebSocket-TLS-Web-setup-script' >> /etc/resolv.conf
            fi
            green "修改完成！！"
        fi
    }
    if [ $v2ray_is_installed -eq 1 ]; then
        local v2ray_status="\033[32m已安装"
    else
        local v2ray_status="\033[31m未安装"
    fi
    if systemctl is-active v2ray > /dev/null 2>&1; then
        v2ray_status="${v2ray_status}                \033[32m运行中"
    else
        v2ray_status="${v2ray_status}                \033[31m未运行"
    fi
    if [ $nginx_is_installed -eq 1 ]; then
        local nginx_status="\033[32m已安装"
    else
        local nginx_status="\033[31m未安装"
    fi
    if systemctl is-active nginx > /dev/null 2>&1; then
        nginx_status="${nginx_status}                \033[32m运行中"
    else
        nginx_status="${nginx_status}                \033[31m未运行"
    fi
    tyblue "--------------------- V2Ray-TLS(1.3)+Web 搭建/管理脚本 ---------------------"
    echo
    tyblue "            V2Ray：            ${v2ray_status}"
    echo
    tyblue "            Nginx：            ${nginx_status}"
    echo
    tyblue " 官网：https://github.com/kirin10000/V2Ray-TLS-Web-setup-script"
    echo
    tyblue "----------------------------------注意事项----------------------------------"
    yellow " 此脚本需要一个解析到本服务器的域名!!!!"
    tyblue " 推荐服务器系统使用Ubuntu最新版"
    yellow " 部分ssh工具会出现退格键无法使用问题，建议先保证退格键正常，再安装"
    yellow " 测试退格键正常方法：按一下退格键，不会出现奇怪的字符即为正常"
    yellow " 若退格键异常可以选择选项14修复"
    tyblue "----------------------------------------------------------------------------"
    echo
    echo
    tyblue " -----------安装/升级/卸载-----------"
    if [ $is_installed -eq 0 ]; then
        green  "   1. 安装V2Ray-TLS+Web"
    else
        green  "   1. 重新安装V2Ray-TLS+Web"
    fi
    green  "   2. 升级V2Ray-TLS+Web"
    tyblue "   3. 仅安装bbr(包含bbr2/bbrplus/bbr魔改版/暴力bbr魔改版/锐速)"
    tyblue "   4. 仅升级V2Ray"
    red    "   5. 卸载V2Ray-TLS+Web"
    echo
    tyblue " --------------启动/停止-------------"
    if systemctl is-active v2ray > /dev/null 2>&1 && systemctl is-active nginx > /dev/null 2>&1; then
        tyblue "   6. 重新启动V2Ray-TLS+Web"
    else
        tyblue "   6. 启动V2Ray-TLS+Web"
    fi
    tyblue "   7. 停止V2Ray-TLS+Web"
    echo
    tyblue " ----------------管理----------------"
    tyblue "   8. 查看配置信息"
    tyblue "   9. 重置域名"
    tyblue "      (会覆盖原有域名配置，安装过程中域名输错了造成V2Ray无法启动可以用此选项修复)"
    tyblue "  10. 添加域名"
    tyblue "  11. 删除域名"
    tyblue "  12. 修改id(用户ID/UUID)"
    tyblue "  13. 修改path(路径)"
    tyblue "  14. 修改V2Ray传输协议(TCP/WebSocket)"
    echo
    tyblue " ----------------其它----------------"
    tyblue "  15. 尝试修复退格键无法使用的问题"
    tyblue "  16. 修改dns"
    yellow "  17. 退出脚本"
    echo
    echo
    choice=""
    while [[ "$choice" != "1" && "$choice" != "2" && "$choice" != "3" && "$choice" != "4" && "$choice" != "5" && "$choice" != "6" && "$choice" != "7" && "$choice" != "8" && "$choice" != "9" && "$choice" != "10" && "$choice" != "11" && "$choice" != "12" && "$choice" != "13" && "$choice" != "14" && "$choice" != "15" && "$choice" != "16" && "$choice" != "17" ]]
    do
        read -p "您的选择是：" choice
    done
    if [ $choice -le 5 ] || [ $choice -eq 9 ] || [ $choice -eq 10 ]; then
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
    fi
    if [ $choice -eq 1 ]; then
        install_update_v2ray_tls_web
    elif [ $choice -eq 2 ]; then
        if [ $is_installed == 1 ]; then
            if [ $release == ubuntu ]; then
                yellow "升级bbr/系统可能需要重启，重启后请再次选择'升级V2Ray-TLS+Web'"
            else
                yellow "升级bbr可能需要重启，重启后请再次选择'升级V2Ray-TLS+Web'"
            fi
            yellow "按回车键继续，或者ctrl+c中止"
            read -s
        else
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        rm -rf "$0"
        wget -O "$0" "https://github.com/kirin10000/V2Ray-TLS-Web-setup-script/raw/master/V2Ray-TLS+Web-setup.sh"
        chmod +x "$0"
        "$0" --update
    elif [ $choice -eq 3 ]; then
        enter_temp_dir
        install_bbr
        apt -y -f install
        rm -rf "$temp_dir"
    elif [ $choice -eq 4 ]; then
        if install_update_v2ray; then
            green "V2Ray升级完成！"
        else
            red   "V2Ray升级失败！"
        fi
    elif [ $choice -eq 5 ]; then
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            yellow "确定要删除吗?(y/n)"
            read choice
        done
        if [ "$choice" == "n" ]; then
            exit 0
        fi
        remove_v2ray
        remove_nginx
        $HOME/.acme.sh/acme.sh --uninstall
        rm -rf $HOME/.acme.sh
        green  "删除完成！"
    elif [ $choice -eq 6 ]; then
        if systemctl is-active v2ray > /dev/null 2>&1 && systemctl is-active nginx > /dev/null 2>&1; then
            local temp_is_active=1
        else
            local temp_is_active=0
        fi
        systemctl restart nginx
        systemctl restart v2ray
        sleep 1s
        if ! systemctl is-active v2ray > /dev/null 2>&1; then
            red "V2Ray启动失败！！"
        elif ! systemctl is-active nginx > /dev/null 2>&1; then
            red "nginx启动失败！！"
        else
            if [ $temp_is_active -eq 1 ]; then
                green "重启成功！！"
            else
                green "启动成功！！"
            fi
        fi
    elif [ $choice -eq 7 ]; then
        systemctl stop nginx
        systemctl stop v2ray
        green "已停止！"
    elif [ $choice -eq 8 ]; then
        get_base_information
        get_domainlist
        echo_end
    elif [ $choice -eq 9 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        yellow "重置域名将删除所有现有域名(包括域名证书、伪装网站等)"
        choice=""
        while [[ "$choice" != "y" && "$choice" != "n" ]]
        do
            tyblue "是否继续？(y/n)"
            read choice
        done
        if [ $choice == n ]; then
            return 0
        fi
        green "重置域名中。。。"
        $HOME/.acme.sh/acme.sh --uninstall
        rm -rf $HOME/.acme.sh
        curl https://get.acme.sh | sh
        get_base_information
        get_domainlist
        for i in ${!domain_list[@]}
        do
            rm -rf ${nginx_prefix}/html/${domain_list[$i]}
        done
        unset domain_list
        unset domainconfig_list
        unset pretend_list
        readDomain
        get_all_certs
        get_all_webs
        config_nginx
        config_v2ray
        sleep 2s
        systemctl restart nginx
        systemctl restart v2ray
        green "域名重置完成！！"
        echo_end
    elif [ $choice -eq 10 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        get_base_information
        get_domainlist
        readDomain
        get_cert ${domain_list[-1]} ${domainconfig_list[-1]}
        get_web ${domain_list[-1]} ${pretend_list[-1]}
        config_nginx
        config_v2ray
        sleep 2s
        systemctl restart nginx
        systemctl restart v2ray
        green "域名添加完成！！"
        echo_end
    elif [ $choice -eq 11 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        get_base_information
        get_domainlist
        if [ ${#domain_list[@]} -le 1 ]; then
            red "只有一个域名"
            exit 1
        fi
        tyblue "-----------------------请选择要删除的域名-----------------------"
        for i in ${!domain_list[@]}
        do
            if [ ${domainconfig_list[i]} -eq 1 ]; then
                tyblue " ${i}. www.${domain_list[i]} ${domain_list[i]}"
            else
                tyblue " ${i}. ${domain_list[i]}"
            fi
        done
        yellow " ${#domain_list[@]}. 不删除"
        local delete=""
        while ! [[ "$delete" =~ ^([1-9][0-9]*|0)$ ]] || [ $delete -gt ${#domain_list[@]} ]
        do
            read -p "你的选择是：" delete
        done
        if [ $delete -eq ${#domain_list[@]} ]; then
            exit 0
        fi
        $HOME/.acme.sh/acme.sh --remove --domain ${domain_list[$delete]} --ecc
        rm -rf $HOME/.acme.sh/${domain_list[$delete]}_ecc
        rm -rf ${nginx_prefix}/html/${domain_list[$delete]}
        unset domain_list[$delete]
        unset domainconfig_list[$delete]
        unset pretend_list[$delete]
        domain_list=(${domain_list[@]})
        domainconfig_list=(${domainconfig_list[@]})
        pretend_list=(${pretend_list[@]})
        config_nginx
        config_v2ray
        systemctl restart nginx
        systemctl restart v2ray
        green "域名删除完成！！"
        echo_end
    elif [ $choice -eq 12 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        get_base_information
        if [ $protocol_1 -ne 0 ] && [ $protocol_2 -ne 0 ]; then
            tyblue "-------------请输入你要修改的id-------------"
            tyblue " 1. V2Ray-TCP+XTLS 的id"
            tyblue " 2. V2Ray-WebSocket+TLS 的id"
            echo
            local flag=""
            while [ "$flag" != "1" -a "$flag" != "2" ]
            do
                read -p "您的选择是：" flag
            done
        elif [ $protocol_1 -ne 0 ]; then
            local flag=1
        else
            local flag=2
        fi
        local v2id="v2id_$flag"
        tyblue "您现在的id是：${!v2id}"
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            tyblue "是否要继续?(y/n)"
            read choice
        done
        if [ $choice == "n" ]; then
            exit 0
        fi
        tyblue "-------------请输入新的id-------------"
        read v2id
        [ $flag -eq 1 ] && v2id_1="$v2id" || v2id_2="$v2id"
        get_domainlist
        config_v2ray
        systemctl restart v2ray
        green "更换成功！！"
        echo_end
    elif [ $choice -eq 13 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        get_base_information
        if [ $protocol_2 -eq 0 ]; then
            red "V2Ray-TCP+XTLS+Web模式没有path!!"
            exit 0
        fi
        tyblue "您现在的path是：$path"
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            tyblue "是否要继续?(y/n)"
            read choice
        done
        if [ $choice == "n" ]; then
            exit 0
        fi
        local temp_old_path="$path"
        tyblue "---------------请输入新的path(带\"/\")---------------"
        read path
        get_domainlist
        config_v2ray
        systemctl restart v2ray
        green "更换成功！！"
        echo_end
    elif [ $choice -eq 14 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装V2Ray-TLS+Web！！"
            exit 1
        fi
        change_protocol
    elif [ $choice -eq 15 ]; then
        echo
        yellow "尝试修复退格键异常问题，退格键正常请不要修复"
        yellow "按回车键继续或按Ctrl+c退出"
        read -s
        if stty -a | grep -q 'erase = ^?'; then
            stty erase '^H'
        elif stty -a | grep -q 'erase = ^H'; then
            stty erase '^?'
        fi
        green "修复完成！！"
        sleep 3s
        start_menu
    elif [ $choice -eq 16 ]; then
        change_dns
    fi
}

if ! [ "$1" == "--update" ]; then
    update=0
    start_menu
else
    update=1
    install_update_v2ray_tls_web
fi
