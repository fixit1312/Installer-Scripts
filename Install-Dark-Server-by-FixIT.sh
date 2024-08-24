#!/bin/bash

# Запрос пароля от текущего пользователя и пароля для root
echo "Введите пароль текущего пользователя:"
read -s current_user_password

echo "Введите желаемый пароль для пользователя root:"
read -s root_password
echo "Повторите пароль для пользователя root:"
read -s root_password_confirm

if [ "$root_password" != "$root_password_confirm" ]; then
  echo "Пароли не совпадают. Попробуйте снова."
  exit 1
fi

# Смена пароля root
echo $current_user_password | sudo -S passwd root <<EOF
$root_password
$root_password
EOF

# Входим под root
sudo -i

# Установка необходимых пакетов
apt-get update
apt-get upgrade -y
apt-get install -y htop net-tools mtr network-manager isc-dhcp-server openvpn

# Вывод информации о сетевых интерфейсах
echo "Информация о сетевых интерфейсах:"
ifconfig

# Запрос входного и выходного интерфейсов
echo "Введите номер входного интерфейса из списка выше:"
read in_interface
echo "Введите номер выходного интерфейса из списка выше:"
read out_interface

# Запрос типа подключения
echo "Выберите тип подключения к интернету:"
echo "1. DHCP (Автоматическое получение IP)"
echo "2. Статический IP (Ручная настройка IP)"
read connection_type

if [ "$connection_type" == "2" ]; then
  echo "Введите IP-адрес, который предоставляет провайдер:"
  read provider_ip
  echo "Введите маску подсети:"
  read provider_netmask
  echo "Введите основной шлюз (gateway):"
  read provider_gateway
  echo "Введите DNS-сервера (например, 8.8.8.8, 8.8.4.4):"
  read provider_dns
fi

# Запрос IP-адреса сервера для локальной сети
echo "Введите IP-адрес для сервера (например, 192.168.1.1):"
read server_ip

# Запрос количества IP-адресов для локальной сети
echo "Сколько IP-адресов вам нужно в локальной сети?"
echo "1. До 250 адресов (маска /24)"
echo "2. До 500 адресов (маска /23)"
echo "3. До 750 адресов (маска /22)"
echo "4. До 1000 адресов (маска /22)"
read ip_range_choice

# Определение маски подсети на основании выбора пользователя
case $ip_range_choice in
    1)
        subnet_mask="255.255.255.0"
        cidr="/24"
        ;;
    2)
        subnet_mask="255.255.254.0"
        cidr="/23"
        ;;
    3)
        subnet_mask="255.255.252.0"
        cidr="/22"
        ;;
    4)
        subnet_mask="255.255.252.0"
        cidr="/22"
        ;;
    *)
        echo "Неправильный выбор. Использую маску по умолчанию /24."
        subnet_mask="255.255.255.0"
        cidr="/24"
        ;;
esac

# Настройка сети в зависимости от типа подключения
if [ "$connection_type" == "1" ]; then
  # DHCP
  cat <<EOL > /etc/netplan/00-installer-config.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $out_interface:
      dhcp4: false
      addresses: [ $server_ip$cidr ]
      nameservers: 
        addresses: [ $server_ip ]
      optional: true   
    $in_interface:
      dhcp4: true
EOL
else
  # Статический IP
  cat <<EOL > /etc/netplan/00-installer-config.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $out_interface:
      dhcp4: false
      addresses: [ $server_ip$cidr ]
      nameservers: 
        addresses: [ $server_ip ]
      optional: true   
    $in_interface:
      dhcp4: false
      addresses: [ $provider_ip$cidr ]
      gateway4: $provider_gateway
      nameservers: 
        addresses: [$provider_dns]
EOL
fi

# Применение сетевой конфигурации
netplan apply

# Настройка DHCP сервера
cat <<EOL > /etc/default/isc-dhcp-server
INTERFACESv4="$out_interface"
EOL

cat <<EOL > /etc/dhcp/dhcpd.conf
option domain-name "server.dark";
option domain-name-servers 8.8.8.8, 8.8.4.4;

default-lease-time 600;
max-lease-time 7200;

ddns-update-style none;

authoritative;

subnet $server_ip netmask $subnet_mask {
  range $server_ip.2 $server_ip.254;
  option routers $server_ip;
  option broadcast-address $server_ip.255;
  option domain-name-servers 8.8.8.8, 8.8.4.4;
  default-lease-time 43200;
  max-lease-time 86400;
}
EOL

# Перезапуск DHCP сервера
systemctl restart isc-dhcp-server

# Настройка UFW и NAT для раздачи VPN
echo "net/ipv4/ip_forward=1" >> /etc/ufw/sysctl.conf

ufw allow ssh
ufw enable
ufw status verbose
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed
ufw allow in on $out_interface to any

cat <<EOL > /etc/ufw/before.rules
*nat
:POSTROUTING ACCEPT [0:0]
#local
-A POSTROUTING -s $server_ip$cidr -o tun0 -j MASQUERADE
COMMIT
EOL

ufw disable
ufw enable

echo "Настройка завершена. Сервер настроен и готов к использованию."
