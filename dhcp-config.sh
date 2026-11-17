#!/bin/bash
# ===========================================================================
#  Alt Server 11 — методичка: DHCP + NAT + SSH
#  Кладётся В КОРЕНЬ флешки. Команды идут строго в порядке из методички.
# ===========================================================================
set -uo pipefail

# ------------------------- ПАРАМЕТРЫ СТЕНДА (поменяйте под задание) -------
EXT_IF="ens18"          # интерфейс с интернетом (адрес выдан автоматически)
GW="192.168.0.1"        # шлюз по умолчанию, узнать: ip r
DNS="77.88.8.8"         # DNS по заданию

LAN1_IF="ens19"                     # первый интерфейс DHCP-сервера
LAN1_ADDR="192.168.10.1/26"         # адрес сервера / префикс
LAN1_NET="192.168.10.0"
LAN1_MASK="255.255.255.192"         # /26 = 255.255.255.192 (64 адреса)
LAN1_R1="192.168.10.2"
LAN1_R2="192.168.10.63"

LAN2_IF="ens20"                     # второй интерфейс DHCP-сервера
LAN2_ADDR="192.168.20.1/27"
LAN2_NET="192.168.20.0"
LAN2_MASK="255.255.255.224"         # /27 = 255.255.255.224 (32 адреса)
LAN2_R1="192.168.20.2"
LAN2_R2="192.168.20.31"

SSH_PORT="22"                       # порт ssh по заданию

# Как в методичке: Gateway прописан и в LAN-файлах. Если systemd-networkd
# начнёт ругаться на недостижимый шлюз — поставьте LAN_GATEWAY="".
LAN_GATEWAY="$GW"
# ------------------------------------------------------------------------

printf '\033[1m=== Alt Server 11: DHCP + NAT ===\033[0m\n'
printf 'внешний: %s (gw %s)\n' "$EXT_IF" "$GW"
printf 'LAN1:    %s %s\n' "$LAN1_IF" "$LAN1_ADDR"
printf 'LAN2:    %s %s\n\n' "$LAN2_IF" "$LAN2_ADDR"

[ "$(id -u)" -eq 0 ] || {
    echo
    echo "ОШИБКА: нужны права root. Запустите одним из способов:"
    echo "    sudo bash $0"
    echo "    su - -c \"bash $0\""
    echo
    echo "sudo спрашивает пароль ВАШЕГО пользователя, su - — пароль root."
    echo "Если sudo пишет 'user is not in the sudoers file', на ALT добавьте себя:"
    echo "    su - -c 'usermod -aG wheel \$USER'   (затем перелогиниться)"
    exit 1
}

step() {
    printf '\n\033[1;36m$ %s\033[0m\n' "$*"
    sleep 0.4
    eval "$@"
    local rc=$?
    sleep 0.2
    return $rc
}

# =========================================================================
# 0. Пакеты
# =========================================================================
step "apt-get update"
step "apt-get install -y dhcp-server iptables openssh-server"

# =========================================================================
# 1. Настройка адаптеров (/etc/systemd/network/<NN>-<if>.network)
# =========================================================================
step "ip -br a"

for spec in "$LAN1_IF|$LAN1_ADDR" "$LAN2_IF|$LAN2_ADDR"; do
    ifc="${spec%%|*}"
    addr="${spec##*|}"
    f="/etc/systemd/network/99-${ifc}.network"

    printf '\n\033[1;36m$ cat > %s <<EOF ...\033[0m\n' "$f"
    sleep 0.4
    {
        echo '[Match]'
        echo "Name=${ifc}"
        echo '[Network]'
        echo "Address=${addr}"
        [ -n "$LAN_GATEWAY" ] && echo "Gateway=${LAN_GATEWAY}"
        echo "DNS=${DNS}"
    } > "$f"
    sleep 0.3
    cat "$f"
done

step "systemctl enable systemd-networkd"
step "systemctl restart systemd-networkd"
step "ip -br a"

# =========================================================================
# 2. DHCP-сервер
# =========================================================================
step "cp -n /etc/dhcp/dhcpd.conf.sample /etc/dhcp/dhcpd.conf"

printf '\n\033[1;36m$ cat > /etc/dhcp/dhcpd.conf <<EOF ...\033[0m\n'
sleep 0.4
cat > /etc/dhcp/dhcpd.conf <<EOF
ddns-update-style none;

subnet ${LAN1_NET} netmask ${LAN1_MASK} {
        option routers                  ${LAN1_ADDR%/*};
        option subnet-mask              ${LAN1_MASK};

        option nis-domain               "domain.org";
        option domain-name              "domain.org";
        option domain-name-servers      ${DNS};

        range dynamic-bootp ${LAN1_R1} ${LAN1_R2};
        default-lease-time 21600;
        max-lease-time 43200;
}

subnet ${LAN2_NET} netmask ${LAN2_MASK} {
        option routers                  ${LAN2_ADDR%/*};
        option subnet-mask              ${LAN2_MASK};

        option nis-domain               "domain.org";
        option domain-name              "domain.org";
        option domain-name-servers      ${DNS};

        range dynamic-bootp ${LAN2_R1} ${LAN2_R2};
        default-lease-time 21600;
        max-lease-time 43200;
}
EOF
sleep 0.3

printf '\n\033[1;36m$ cat > /etc/sysconfig/dhcpd <<EOF ...\033[0m\n'
sleep 0.3
cat > /etc/sysconfig/dhcpd <<EOF
# ALT: аргументы запуска dhcpd, через пробел — интерфейсы раздачи
DHCPDARGS="${LAN1_IF} ${LAN2_IF}"
EOF
sleep 0.2

step "systemctl enable dhcpd"
step "systemctl restart dhcpd"
step "systemctl status dhcpd --no-pager --lines=15"

# =========================================================================
# 3. NAT — транзит трафика
# =========================================================================
step "grep -q '^net.ipv4.ip_forward = 1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
step "grep -q '^net.ipv4.ip_forward = 1' /etc/net/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf"
step "sysctl -p"
step "sysctl net.ipv4.ip_forward"

# =========================================================================
# 4. iptables: MASQUERADE + FORWARD (5 команд из методички)
# =========================================================================
only_once() {   # не дублировать правило при повторном запуске
    iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

printf '\n\033[1;36m$ iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\033[0m\n' "$EXT_IF"
sleep 0.4
only_once POSTROUTING -t nat -o "$EXT_IF" -j MASQUERADE

printf '\n\033[1;36m$ iptables -A FORWARD -i %s -o %s -j ACCEPT\033[0m\n' "$LAN1_IF" "$EXT_IF"
sleep 0.4
only_once FORWARD -i "$LAN1_IF" -o "$EXT_IF" -j ACCEPT

printf '\n\033[1;36m$ iptables -A FORWARD -i %s -o %s -j ACCEPT\033[0m\n' "$LAN2_IF" "$EXT_IF"
sleep 0.4
only_once FORWARD -i "$LAN2_IF" -o "$EXT_IF" -j ACCEPT

printf '\n\033[1;36m$ iptables -A FORWARD -i %s -o %s -m state --state ESTABLISHED,RELATED -j ACCEPT\033[0m\n' "$EXT_IF" "$LAN1_IF"
sleep 0.4
only_once FORWARD -i "$EXT_IF" -o "$LAN1_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

printf '\n\033[1;36m$ iptables -A FORWARD -i %s -o %s -m state --state ESTABLISHED,RELATED -j ACCEPT\033[0m\n' "$EXT_IF" "$LAN2_IF"
sleep 0.4
only_once FORWARD -i "$EXT_IF" -o "$LAN2_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

# =========================================================================
# 5. Сохранить iptables, чтобы не слетели после перезагрузки
# =========================================================================
printf '\n\033[1;36m$ iptables -A INPUT -p tcp --dport %s -j ACCEPT\033[0m\n' "$SSH_PORT"
sleep 0.4
only_once INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
step "iptables-save > /etc/sysconfig/iptables"
step "iptables -t nat -L POSTROUTING -n -v"
step "iptables -S"

# =========================================================================
# 6. sshd — порт по заданию
# =========================================================================
step "sed -i 's/^#*Port .*/Port ${SSH_PORT}/' /etc/openssh/sshd_config"
step "grep -E '^Port ' /etc/openssh/sshd_config"
step "systemctl restart sshd"

# =========================================================================
# 7. Проверки
# =========================================================================
step "ip -br a"
step "ss -lunp | grep ':67' || echo '(dhcpd не слушает 67/udp)'"
step "journalctl -u dhcpd -n 15 --no-pager"

printf '\n\033[1m=== Готово. На клиентах проверьте: ipconfig / ping 8.8.8.8 ===\033[0m\n'
