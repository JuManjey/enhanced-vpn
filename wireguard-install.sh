#!/bin/bash

# Enhanced WireGuard server installer with DPI bypass
# Based on https://github.com/angristan/wireguard-install
#
# Obfuscation methods:
#   amneziawg — protocol-level obfuscation (AmneziaVPN app on all platforms, no extra software)
#   wstunnel  — HTTPS tunnel wrapping (requires wstunnel client binary)
#   none      — standard WireGuard (blocked by DPI in Russia)

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
umask 077

WSTUNNEL_VERSION="10.1.6"

# WG tool/path variables — set by setWgVars() based on OBFUSCATION_METHOD
WG_CMD="wg"
WG_QUICK="wg-quick"
WG_DIR="/etc/wireguard"
WG_SVC="wg-quick"

function setWgVars() {
	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		WG_CMD="awg"
		WG_QUICK="awg-quick"
		WG_DIR="/etc/amnezia/amneziawg"
		WG_SVC="awg-quick"
	else
		WG_CMD="wg"
		WG_QUICK="wg-quick"
		WG_DIR="/etc/wireguard"
		WG_SVC="wg-quick"
	fi
}

function installPackages() {
	if ! "$@"; then
		echo -e "${RED}Failed to install packages.${NC}"
		echo "Please check your internet connection and package sources."
		exit 1
	fi
}

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt)
	fi
	if [[ ${VIRT} == "openvz" ]]; then
		echo "OpenVZ is not supported"
		exit 1
	fi
	if [[ ${VIRT} == "lxc" ]]; then
		echo "LXC is not supported (yet)."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
			exit 1
		fi
		OS=debian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo "Your version of Fedora (${VERSION_ID}) is not supported. Please use Fedora 32 or later"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			echo "Your version of CentOS (${VERSION_ID}) is not supported. Please use CentOS 8 or later"
			exit 1
		fi
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	elif [[ -e /etc/alpine-release ]]; then
		OS=alpine
		if ! command -v virt-what &>/dev/null; then
			if ! (apk update && apk add virt-what); then
				echo -e "${RED}Failed to install virt-what. Continuing without virtualization check.${NC}"
			fi
		fi
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Oracle or Arch Linux system"
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1
	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: getHomeDirForClient() requires a client name as argument"
		exit 1
	fi
	if [ -e "/home/${CLIENT_NAME}" ]; then
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		if [ "${SUDO_USER}" == "root" ]; then
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		HOME_DIR="/root"
	fi
	echo "$HOME_DIR"
}

function normalizeYesNo() {
	local VALUE="${1,,}"
	case "${VALUE}" in
	y | yes | true | 1) echo "y" ;;
	n | no | false | 0) echo "n" ;;
	*) echo "" ;;
	esac
}

function isUdpPortBusy() {
	local PORT=$1
	if ! [[ ${PORT} =~ ^[0-9]+$ ]]; then return 1; fi
	if command -v ss &>/dev/null; then
		if ss -Hlun "sport = :${PORT}" | grep -q .; then return 0; fi
	fi
	return 1
}

function isTcpPortBusy() {
	local PORT=$1
	if ! [[ ${PORT} =~ ^[0-9]+$ ]]; then return 1; fi
	if command -v ss &>/dev/null; then
		if ss -Hltn "sport = :${PORT}" | grep -q .; then return 0; fi
	fi
	return 1
}

function canReachDnsResolver() {
	local RESOLVER=$1
	if ! [[ ${RESOLVER} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; then
		return 1
	fi
	if command -v timeout &>/dev/null; then
		timeout 2 bash -c "echo > /dev/udp/${RESOLVER}/53" &>/dev/null
	else
		bash -c "echo > /dev/udp/${RESOLVER}/53" &>/dev/null
	fi
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

function generateAWGParams() {
	AWG_JC=$(shuf -i 3-10 -n 1)
	AWG_JMIN=$(shuf -i 50-100 -n 1)
	AWG_JMAX=$(shuf -i 500-1000 -n 1)
	AWG_S1=$(shuf -i 15-150 -n 1)
	AWG_S2=$(shuf -i 15-150 -n 1)
	AWG_H1=$(shuf -i 1-2147483647 -n 1)
	AWG_H2=$(shuf -i 1-2147483647 -n 1)
	AWG_H3=$(shuf -i 1-2147483647 -n 1)
	AWG_H4=$(shuf -i 1-2147483647 -n 1)
}

function installAmneziaWG() {
	echo -e "\n${GREEN}Installing AmneziaWG (obfuscated WireGuard)...${NC}"

	# Install build dependencies
	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
		apt-get update
		apt-get install -y git build-essential pkg-config iptables qrencode \
			linux-headers-"$(uname -r)" || {
			echo -e "${ORANGE}linux-headers-$(uname -r) not found, trying linux-headers-generic...${NC}"
			apt-get install -y linux-headers-generic
		}
	elif [[ ${OS} == 'fedora' ]]; then
		dnf install -y git gcc make kernel-devel kernel-headers pkg-config iptables qrencode
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		yum install -y git gcc make kernel-devel kernel-headers pkg-config iptables
		yum install -y qrencode || true
	else
		echo -e "${RED}AmneziaWG build from source requires Ubuntu, Debian, Fedora, or CentOS.${NC}"
		echo "Your OS: ${OS}"
		echo "Use wstunnel obfuscation method instead."
		exit 1
	fi

	echo -e "${GREEN}Building AmneziaWG kernel module from source...${NC}"
	rm -rf /tmp/amneziawg-kernel /tmp/amneziawg-tools

	if ! git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git /tmp/amneziawg-kernel; then
		echo -e "${RED}Failed to clone amneziawg-linux-kernel-module. Check internet connection.${NC}"
		exit 1
	fi

	if ! make -C /tmp/amneziawg-kernel/src -j"$(nproc)"; then
		echo -e "${RED}Failed to build AmneziaWG kernel module.${NC}"
		echo "Make sure kernel headers are installed: apt install linux-headers-$(uname -r)"
		exit 1
	fi
	make -C /tmp/amneziawg-kernel/src install
	depmod -a

	echo -e "${GREEN}Building AmneziaWG tools...${NC}"
	if ! git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools; then
		echo -e "${RED}Failed to clone amneziawg-tools.${NC}"
		exit 1
	fi

	if ! make -C /tmp/amneziawg-tools/src -j"$(nproc)"; then
		echo -e "${RED}Failed to build amneziawg-tools.${NC}"
		exit 1
	fi
	make -C /tmp/amneziawg-tools/src install

	# Load kernel module
	modprobe amneziawg || {
		echo -e "${RED}Failed to load amneziawg kernel module.${NC}"
		echo "Try rebooting the server and running the script again."
		exit 1
	}

	# Ensure module loads on boot
	echo "amneziawg" >/etc/modules-load.d/amneziawg.conf

	# Cleanup build files
	rm -rf /tmp/amneziawg-kernel /tmp/amneziawg-tools

	if ! command -v awg &>/dev/null; then
		echo -e "${RED}AmneziaWG installation failed. 'awg' command not found.${NC}"
		exit 1
	fi
	echo -e "${GREEN}AmneziaWG installed successfully: kernel module loaded, awg/awg-quick ready.${NC}"
}

function installWstunnel() {
	echo -e "\n${GREEN}Installing wstunnel for traffic obfuscation...${NC}"

	local ARCH
	ARCH=$(uname -m)
	local WSTUNNEL_ARCH
	case ${ARCH} in
	x86_64 | amd64) WSTUNNEL_ARCH="amd64" ;;
	aarch64 | arm64) WSTUNNEL_ARCH="arm64" ;;
	armv7l) WSTUNNEL_ARCH="armv7" ;;
	*)
		echo -e "${RED}Unsupported architecture for wstunnel: ${ARCH}${NC}"
		exit 1
		;;
	esac

	if ! command -v curl &>/dev/null; then
		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get install -y curl
		elif [[ ${OS} == 'fedora' ]] || [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]] || [[ ${OS} == 'oracle' ]]; then
			dnf install -y curl 2>/dev/null || yum install -y curl
		elif [[ ${OS} == 'arch' ]]; then
			pacman -S --noconfirm curl
		elif [[ ${OS} == 'alpine' ]]; then
			apk add curl
		fi
	fi

	local WSTUNNEL_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_${WSTUNNEL_ARCH}.tar.gz"
	echo "Downloading wstunnel v${WSTUNNEL_VERSION}..."

	if ! curl -fsSL -o /tmp/wstunnel.tar.gz "${WSTUNNEL_URL}"; then
		local LATEST_VER
		LATEST_VER=$(curl -fsSL https://api.github.com/repos/erebe/wstunnel/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
		if [[ -n ${LATEST_VER} ]]; then
			WSTUNNEL_VERSION="${LATEST_VER}"
			WSTUNNEL_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_${WSTUNNEL_ARCH}.tar.gz"
			if ! curl -fsSL -o /tmp/wstunnel.tar.gz "${WSTUNNEL_URL}"; then
				echo -e "${RED}Failed to download wstunnel.${NC}"
				exit 1
			fi
		else
			echo -e "${RED}Cannot reach GitHub. Check internet connection.${NC}"
			exit 1
		fi
	fi

	tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin/ wstunnel 2>/dev/null || {
		tar -xzf /tmp/wstunnel.tar.gz -C /tmp/ 2>/dev/null
		local WSTUNNEL_BIN
		WSTUNNEL_BIN=$(find /tmp -maxdepth 2 -name 'wstunnel' -type f 2>/dev/null | head -1)
		if [[ -n ${WSTUNNEL_BIN} ]]; then
			mv "${WSTUNNEL_BIN}" /usr/local/bin/wstunnel
		else
			echo -e "${RED}Could not extract wstunnel binary.${NC}"
			exit 1
		fi
	}
	chmod +x /usr/local/bin/wstunnel
	rm -f /tmp/wstunnel.tar.gz
	echo -e "${GREEN}wstunnel installed: $(/usr/local/bin/wstunnel --version 2>&1 | head -1)${NC}"
}

function setupObfuscation() {
	echo -e "\n${GREEN}Configuring HTTPS obfuscation (wstunnel)...${NC}"

	mkdir -p /etc/wstunnel
	chmod 700 /etc/wstunnel

	if ! command -v openssl &>/dev/null; then
		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get install -y openssl
		fi
	fi

	local TLS_SAN="IP:${SERVER_PUB_IP}"
	if [[ ${SERVER_PUB_IP} =~ ^[a-zA-Z] ]]; then
		TLS_SAN="DNS:${SERVER_PUB_IP}"
	fi

	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout /etc/wstunnel/key.pem -out /etc/wstunnel/cert.pem \
		-days 3650 -nodes -subj "/CN=${SERVER_PUB_IP}" \
		-addext "subjectAltName=${TLS_SAN}" 2>/dev/null
	chmod 600 /etc/wstunnel/key.pem /etc/wstunnel/cert.pem

	local WS_PATH
	WS_PATH=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
	echo "${WS_PATH}" >/etc/wstunnel/ws_path
	chmod 600 /etc/wstunnel/ws_path

	cat >/etc/systemd/system/wstunnel-server.service <<WSTEOF
[Unit]
Description=wstunnel HTTPS tunnel for WireGuard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wstunnel server wss://[::]:${OBFUSCATION_PORT} --tls-certificate /etc/wstunnel/cert.pem --tls-private-key /etc/wstunnel/key.pem --restrict-to 127.0.0.1:${SERVER_PORT} --http-upgrade-path-prefix ${WS_PATH}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
WSTEOF

	systemctl daemon-reload
	systemctl enable wstunnel-server
	systemctl start wstunnel-server
	echo -e "${GREEN}wstunnel running on port ${OBFUSCATION_PORT}/tcp${NC}"
}

function generateClientHelper() {
	local CLIENT_NAME=$1
	local HOME_DIR=$2
	local HELPER_DIR="${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-tunnel"
	mkdir -p "${HELPER_DIR}"

	local WS_PATH
	WS_PATH=$(cat /etc/wstunnel/ws_path 2>/dev/null)

	cat >"${HELPER_DIR}/connect.sh" <<'CONNECTEOF'
#!/bin/bash
set -euo pipefail
CONNECTEOF

	cat >>"${HELPER_DIR}/connect.sh" <<CONNECTVARS
SERVER="${SERVER_PUB_IP}"
TUNNEL_PORT=${OBFUSCATION_PORT}
LOCAL_WG_PORT=${SERVER_PORT}
WS_PATH="${WS_PATH}"
WSTUNNEL_VERSION="${WSTUNNEL_VERSION}"
CONNECTVARS

	cat >>"${HELPER_DIR}/connect.sh" <<'CONNECTBODY'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WG_CONF="${SCRIPT_DIR}/../$(ls "${SCRIPT_DIR}/../" | grep '\.conf$' | head -1)"
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}Run as root (sudo).${NC}"; exit 1; fi
if ! command -v wstunnel &>/dev/null; then
    echo -e "${RED}wstunnel not installed. Get it from: https://github.com/erebe/wstunnel/releases${NC}"; exit 1
fi
if ! command -v wg-quick &>/dev/null; then
    echo -e "${RED}wireguard-tools not installed.${NC}"; exit 1
fi
[ ! -f "${WG_CONF}" ] && echo -e "${RED}Config not found: ${WG_CONF}${NC}" && exit 1

DEFAULT_GW=$(ip route show default 2>/dev/null | head -1 | awk '{print $3}')
DEFAULT_IF=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
[[ -z "${DEFAULT_GW}" || -z "${DEFAULT_IF}" ]] && echo -e "${RED}Cannot detect gateway.${NC}" && exit 1

RESOLVED_IP="${SERVER}"
if ! [[ ${SERVER} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RESOLVED_IP=$(getent hosts "${SERVER}" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z "${RESOLVED_IP}" ]] && RESOLVED_IP="${SERVER}"
fi

WSTUNNEL_PID=""; ROUTE_ADDED=""; WG_UP=""
cleanup() {
    [[ -n "${WG_UP}" ]] && wg-quick down "${WG_CONF}" 2>/dev/null || true
    [[ -n "${WSTUNNEL_PID}" ]] && kill "${WSTUNNEL_PID}" 2>/dev/null; wait "${WSTUNNEL_PID}" 2>/dev/null || true
    [[ -n "${ROUTE_ADDED}" ]] && ip route del "${RESOLVED_IP}/32" via "${DEFAULT_GW}" dev "${DEFAULT_IF}" 2>/dev/null || true
    echo -e "${GREEN}Disconnected.${NC}"
}
trap cleanup EXIT INT TERM

echo -e "${GREEN}Starting tunnel to ${SERVER}:${TUNNEL_PORT}...${NC}"
ip route add "${RESOLVED_IP}/32" via "${DEFAULT_GW}" dev "${DEFAULT_IF}" 2>/dev/null && ROUTE_ADDED="1" || ROUTE_ADDED="1"

wstunnel client \
    -L "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0" \
    "wss://${SERVER}:${TUNNEL_PORT}" \
    --tls-verify-certificate false \
    --http-upgrade-path-prefix "${WS_PATH}" &
WSTUNNEL_PID=$!
sleep 3
if ! kill -0 "${WSTUNNEL_PID}" 2>/dev/null; then
    echo -e "${RED}Tunnel failed. Check server connectivity.${NC}"; WSTUNNEL_PID=""; exit 1
fi
echo -e "${GREEN}Tunnel OK.${NC}"
wg-quick up "${WG_CONF}" && WG_UP="1" || exit 1
echo -e "${GREEN}VPN active! Ctrl+C to disconnect.${NC}"
wait "${WSTUNNEL_PID}"
CONNECTBODY

	chmod 700 "${HELPER_DIR}/connect.sh"

	cat >"${HELPER_DIR}/connect.bat" <<BATEOF
@echo off
set SERVER=${SERVER_PUB_IP}
set TUNNEL_PORT=${OBFUSCATION_PORT}
set LOCAL_WG_PORT=${SERVER_PORT}
set WS_PATH=${WS_PATH}
for /f "tokens=3" %%g in ('route print 0.0.0.0 ^| findstr /C:"0.0.0.0" ^| findstr /V /C:"On-link"') do (set GW=%%g& goto :go)
:go
route add %SERVER% mask 255.255.255.255 %GW% >nul 2>&1
echo Starting tunnel...
start /B wstunnel.exe client -L "udp://127.0.0.1:%LOCAL_WG_PORT%:127.0.0.1:%LOCAL_WG_PORT%?timeout_sec=0" "wss://%SERVER%:%TUNNEL_PORT%" --tls-verify-certificate false --http-upgrade-path-prefix "%WS_PATH%"
timeout /t 3 /nobreak >nul
echo Tunnel started. Activate WireGuard now. Press any key to stop...
pause >nul
taskkill /IM wstunnel.exe /F 2>nul
route delete %SERVER% >nul 2>&1
BATEOF
	chmod 600 "${HELPER_DIR}/connect.bat"

	echo -e "${GREEN}Tunnel scripts: ${HELPER_DIR}/${NC}"
	echo -e "${BLUE}Linux:${NC}   sudo ${HELPER_DIR}/connect.sh"
	echo -e "${BLUE}Windows:${NC} Run connect.bat as Admin, then activate WireGuard"
}

function installQuestions() {
	echo "Welcome to the Enhanced WireGuard installer!"
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""

	until [[ ${RESTRICTIVE_NETWORK_MODE} =~ ^[yn]$ ]]; do
		read -rp "Enable restrictive-network profile (recommended for Russia)? [Y/n]: " -e -i y RESTRICTIVE_NETWORK_MODE
		RESTRICTIVE_NETWORK_MODE=$(normalizeYesNo "${RESTRICTIVE_NETWORK_MODE}")
	done

	DNS_DEFAULT_1="1.1.1.1"
	DNS_DEFAULT_2="1.0.0.1"
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]]; then
		DNS_DEFAULT_1="9.9.9.9"
		DNS_DEFAULT_2="8.8.8.8"
		echo "Restrictive-network profile enabled."
		echo ""
	fi

	echo -e "${GREEN}=== Obfuscation Method ===${NC}"
	echo ""
	echo "  1) AmneziaWG  — modifies WireGuard packet headers to evade DPI"
	echo "                  Works natively with AmneziaVPN app (Android, iOS, Windows, macOS, Linux)"
	echo -e "                  ${GREEN}Recommended for mobile users. No extra software needed.${NC}"
	echo ""
	echo "  2) wstunnel   — wraps WireGuard in HTTPS/WebSocket tunnel"
	echo "                  Requires wstunnel binary on client. Desktop-friendly (connect.sh scripts)."
	echo ""
	echo "  3) None       — standard WireGuard (will be blocked by DPI in Russia)"
	echo ""
	local OBF_DEFAULT=1
	if [[ ${RESTRICTIVE_NETWORK_MODE} != "y" ]]; then
		OBF_DEFAULT=3
	fi
	until [[ ${OBF_CHOICE} =~ ^[1-3]$ ]]; do
		read -rp "Select obfuscation method [1-3]: " -e -i "${OBF_DEFAULT}" OBF_CHOICE
	done
	case "${OBF_CHOICE}" in
	1) OBFUSCATION_METHOD="amneziawg" ;;
	2) OBFUSCATION_METHOD="wstunnel" ;;
	3) OBFUSCATION_METHOD="none" ;;
	esac
	setWgVars

	# Detect public endpoint
	SERVER_PUB_IPV4=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	SERVER_PUB_IPV6=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	SERVER_PUB_IP=${SERVER_PUB_IPV4}
	if [[ -z ${SERVER_PUB_IP} ]]; then
		SERVER_PUB_IP=${SERVER_PUB_IPV6}
	fi
	read -rp "Public endpoint (IPv4/IPv6 or DNS name): " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP
	until [[ -n ${SERVER_PUB_IP} ]]; do
		read -rp "Public endpoint (IPv4/IPv6 or DNS name): " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP
	done

	SERVER_NIC="$(ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	if [[ -z ${SERVER_NIC} ]]; then
		SERVER_NIC="$(ip -6 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	fi
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i wg0 SERVER_WG_NIC
	done

	until [[ ${SERVER_WG_IPV4} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Server WireGuard IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
	done

	SERVER_HAS_PUBLIC_IPV6="n"
	if ip -6 route show default >/dev/null 2>&1 && ip -6 addr show scope global | grep -q "inet6"; then
		SERVER_HAS_PUBLIC_IPV6="y"
	fi
	ENABLE_IPV6=""
	until [[ ${ENABLE_IPV6} =~ ^[yn]$ ]]; do
		if [[ ${SERVER_HAS_PUBLIC_IPV6} == "y" ]]; then
			if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]]; then
				read -rp "Enable IPv6 for clients [y/N]: " -e -i n ENABLE_IPV6
			else
				read -rp "Enable IPv6 for clients [Y/n]: " -e -i y ENABLE_IPV6
			fi
		else
			read -rp "No global IPv6. Enable anyway? [y/N]: " -e -i n ENABLE_IPV6
		fi
		ENABLE_IPV6=$(normalizeYesNo "${ENABLE_IPV6}")
	done
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
			read -rp "Server WireGuard IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
		done
	else
		SERVER_WG_IPV6=""
	fi

	# Port selection depends on obfuscation method
	if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
		local DEFAULT_WG_PORT
		DEFAULT_WG_PORT=$(shuf -i 49152-65000 -n 1)
		while isUdpPortBusy "${DEFAULT_WG_PORT}"; do
			DEFAULT_WG_PORT=$(shuf -i 49152-65000 -n 1)
		done
		while true; do
			read -rp "WireGuard internal port (localhost only) [1-65535]: " -e -i "${DEFAULT_WG_PORT}" SERVER_PORT
			if ! [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
				echo -e "${ORANGE}Invalid port.${NC}"; continue
			fi
			if isUdpPortBusy "${SERVER_PORT}"; then
				echo -e "${ORANGE}Port ${SERVER_PORT}/udp busy.${NC}"; continue
			fi
			break
		done
		while true; do
			read -rp "HTTPS tunnel port (public, TCP) [1-65535]: " -e -i 443 OBFUSCATION_PORT
			if ! [[ ${OBFUSCATION_PORT} =~ ^[0-9]+$ ]] || [ "${OBFUSCATION_PORT}" -lt 1 ] || [ "${OBFUSCATION_PORT}" -gt 65535 ]; then
				echo -e "${ORANGE}Invalid port.${NC}"; continue
			fi
			if isTcpPortBusy "${OBFUSCATION_PORT}"; then
				echo -e "${ORANGE}Port ${OBFUSCATION_PORT}/tcp busy.${NC}"; continue
			fi
			break
		done
	else
		OBFUSCATION_PORT=""
		local DEFAULT_PORT=443
		if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
			DEFAULT_PORT=443
		fi
		while true; do
			read -rp "Server port [1-65535]: " -e -i "${DEFAULT_PORT}" SERVER_PORT
			if ! [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
				echo -e "${ORANGE}Invalid port.${NC}"; continue
			fi
			if isUdpPortBusy "${SERVER_PORT}"; then
				echo -e "${ORANGE}Port ${SERVER_PORT}/udp busy.${NC}"; continue
			fi
			break
		done
	fi

	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver: " -e -i "${DNS_DEFAULT_1}" CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver: " -e -i "${DNS_DEFAULT_2}" CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then CLIENT_DNS_2="${CLIENT_DNS_1}"; fi
	done

	CLIENT_MTU_MIN=1200
	if [[ ${ENABLE_IPV6} == "y" ]]; then CLIENT_MTU_MIN=1280; fi
	local DEFAULT_MTU=1280
	if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then DEFAULT_MTU=1200; fi
	until [[ ${CLIENT_MTU} =~ ^[0-9]+$ ]] && [ "${CLIENT_MTU}" -ge "${CLIENT_MTU_MIN}" ] && [ "${CLIENT_MTU}" -le 1500 ]; do
		read -rp "Client MTU [${CLIENT_MTU_MIN}-1500]: " -e -i "${DEFAULT_MTU}" CLIENT_MTU
	done

	until [[ ${PERSISTENT_KEEPALIVE} =~ ^[0-9]+$ ]] && [ "${PERSISTENT_KEEPALIVE}" -ge 0 ] && [ "${PERSISTENT_KEEPALIVE}" -le 65535 ]; do
		read -rp "PersistentKeepalive [0-65535]: " -e -i 25 PERSISTENT_KEEPALIVE
	done
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${PERSISTENT_KEEPALIVE} -eq 0 ]]; then
		echo -e "${ORANGE}Forcing PersistentKeepalive=25 for restrictive networks.${NC}"
		PERSISTENT_KEEPALIVE=25
	fi

	until [[ ${ENABLE_MSS_CLAMP} =~ ^[yn]$ ]]; do
		read -rp "Enable TCP MSS clamping? [Y/n]: " -e -i y ENABLE_MSS_CLAMP
		ENABLE_MSS_CLAMP=$(normalizeYesNo "${ENABLE_MSS_CLAMP}")
	done

	until [[ ${ENABLE_NET_OPTIMIZATIONS} =~ ^[yn]$ ]]; do
		read -rp "Enable kernel network optimizations (BBR)? [Y/n]: " -e -i y ENABLE_NET_OPTIMIZATIONS
		ENABLE_NET_OPTIMIZATIONS=$(normalizeYesNo "${ENABLE_NET_OPTIMIZATIONS}")
	done

	DEFAULT_ALLOWED_IPS="0.0.0.0/0"
	if [[ ${ENABLE_IPV6} == "y" ]]; then DEFAULT_ALLOWED_IPS="0.0.0.0/0,::/0"; fi

	until [[ ${ALLOWED_IPS} =~ ^[0-9a-fA-F:./,]+$ ]]; do
		read -rp "Allowed IPs (route everything = 0.0.0.0/0): " -e -i "${DEFAULT_ALLOWED_IPS}" ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then ALLOWED_IPS="${DEFAULT_ALLOWED_IPS}"; fi
	done

	echo ""
	echo "Ready to install. Method: ${OBFUSCATION_METHOD}"
	read -n1 -r -p "Press any key to continue..."
}

function runPostInstallChecks() {
	echo ""
	echo -e "${GREEN}Post-install verification:${NC}"

	if ip link show "${SERVER_WG_NIC}" &>/dev/null; then
		echo -e "${GREEN}[OK]${NC} Interface ${SERVER_WG_NIC} is present."
	else
		echo -e "${ORANGE}[WARN]${NC} Interface ${SERVER_WG_NIC} is missing."
	fi

	if command -v ss &>/dev/null && ss -Hlun "sport = :${SERVER_PORT}" | grep -q .; then
		echo -e "${GREEN}[OK]${NC} UDP port ${SERVER_PORT} is listening."
	else
		echo -e "${ORANGE}[WARN]${NC} UDP port ${SERVER_PORT} is not listening."
	fi

	if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
		if systemctl is-active --quiet wstunnel-server 2>/dev/null; then
			echo -e "${GREEN}[OK]${NC} wstunnel service is running."
		else
			echo -e "${ORANGE}[WARN]${NC} wstunnel service is not running."
		fi
		if command -v ss &>/dev/null && ss -Hltn "sport = :${OBFUSCATION_PORT}" | grep -q .; then
			echo -e "${GREEN}[OK]${NC} HTTPS tunnel port ${OBFUSCATION_PORT}/tcp is listening."
		else
			echo -e "${ORANGE}[WARN]${NC} HTTPS tunnel port ${OBFUSCATION_PORT}/tcp is not listening."
		fi
	fi

	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		echo -e "${GREEN}[OK]${NC} AmneziaWG obfuscation: Jc=${AWG_JC} Jmin=${AWG_JMIN} Jmax=${AWG_JMAX}"
	fi

	if [[ -n ${CLIENT_DNS_1} ]]; then
		if canReachDnsResolver "${CLIENT_DNS_1}"; then
			echo -e "${GREEN}[OK]${NC} DNS ${CLIENT_DNS_1} reachable."
		else
			echo -e "${ORANGE}[WARN]${NC} DNS ${CLIENT_DNS_1} not reachable."
		fi
	fi

	local IPV4_FWD
	IPV4_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
	if [[ ${IPV4_FWD} == "1" ]]; then
		echo -e "${GREEN}[OK]${NC} IPv4 forwarding enabled."
	else
		echo -e "${ORANGE}[WARN]${NC} IPv4 forwarding disabled."
	fi

	if [[ ${ENABLE_NET_OPTIMIZATIONS} == "y" ]]; then
		if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw "bbr"; then
			echo -e "${GREEN}[OK]${NC} BBR congestion control active."
		fi
	fi
}

function installWireGuard() {
	installQuestions

	# Install packages based on obfuscation method
	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		installAmneziaWG
		# Also install standard wireguard-tools for iptables/resolvconf
		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get install -y iptables resolvconf qrencode 2>/dev/null || true
		fi
	else
		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
			apt-get update
			installPackages apt-get install -y wireguard iptables resolvconf qrencode
		elif [[ ${OS} == 'debian' ]]; then
			if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
				echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
				apt-get update
			fi
			apt-get update
			installPackages apt-get install -y iptables resolvconf qrencode
			installPackages apt-get install -y -t buster-backports wireguard
		elif [[ ${OS} == 'fedora' ]]; then
			if [[ ${VERSION_ID} -lt 32 ]]; then
				installPackages dnf install -y dnf-plugins-core
				dnf copr enable -y jdoss/wireguard
				installPackages dnf install -y wireguard-dkms
			fi
			installPackages dnf install -y wireguard-tools iptables qrencode
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			if [[ ${VERSION_ID} == 8* ]]; then
				installPackages yum install -y epel-release elrepo-release
				installPackages yum install -y kmod-wireguard
				yum install -y qrencode || true
			fi
			installPackages yum install -y wireguard-tools iptables
		elif [[ ${OS} == 'oracle' ]]; then
			installPackages dnf install -y oraclelinux-developer-release-el8
			dnf config-manager --disable -y ol8_developer
			dnf config-manager --enable -y ol8_developer_UEKR6
			dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
			installPackages dnf install -y wireguard-tools qrencode iptables
		elif [[ ${OS} == 'arch' ]]; then
			installPackages pacman -S --needed --noconfirm wireguard-tools qrencode
		elif [[ ${OS} == 'alpine' ]]; then
			apk update
			installPackages apk add wireguard-tools iptables libqrencode-tools
		fi
	fi

	if ! command -v ${WG_CMD} &>/dev/null; then
		echo -e "${RED}Installation failed. '${WG_CMD}' command not found.${NC}"
		exit 1
	fi

	# Install wstunnel if needed
	if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
		installWstunnel
	fi

	# Generate AmneziaWG obfuscation parameters
	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		generateAWGParams
	fi

	mkdir -p "${WG_DIR}" /etc/wireguard >/dev/null 2>&1
	chmod 700 "${WG_DIR}"

	SERVER_PRIV_KEY=$(${WG_CMD} genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | ${WG_CMD} pubkey)

	# Save params (always in /etc/wireguard/params for backward compat)
	cat >/etc/wireguard/params <<PARAMSEOF
SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
ENABLE_IPV6=${ENABLE_IPV6}
RESTRICTIVE_NETWORK_MODE=${RESTRICTIVE_NETWORK_MODE}
OBFUSCATION_METHOD=${OBFUSCATION_METHOD}
OBFUSCATION_PORT=${OBFUSCATION_PORT}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
CLIENT_MTU=${CLIENT_MTU}
PERSISTENT_KEEPALIVE=${PERSISTENT_KEEPALIVE}
ENABLE_MSS_CLAMP=${ENABLE_MSS_CLAMP}
ENABLE_NET_OPTIMIZATIONS=${ENABLE_NET_OPTIMIZATIONS}
ALLOWED_IPS=${ALLOWED_IPS}
AWG_JC=${AWG_JC}
AWG_JMIN=${AWG_JMIN}
AWG_JMAX=${AWG_JMAX}
AWG_S1=${AWG_S1}
AWG_S2=${AWG_S2}
AWG_H1=${AWG_H1}
AWG_H2=${AWG_H2}
AWG_H3=${AWG_H3}
AWG_H4=${AWG_H4}
PARAMSEOF
	chmod 600 /etc/wireguard/params

	# Build server config
	SERVER_INTERFACE_ADDRESSES="${SERVER_WG_IPV4}/24"
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		SERVER_INTERFACE_ADDRESSES="${SERVER_INTERFACE_ADDRESSES},${SERVER_WG_IPV6}/64"
	fi

	local AWG_CONFIG_BLOCK=""
	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		AWG_CONFIG_BLOCK="Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}"
	fi

	echo "[Interface]
Address = ${SERVER_INTERFACE_ADDRESSES}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = ${CLIENT_MTU}
${AWG_CONFIG_BLOCK}" >"${WG_DIR}/${SERVER_WG_NIC}.conf"
	chmod 600 "${WG_DIR}/${SERVER_WG_NIC}.conf"

	# Firewall rules
	if pgrep firewalld >/dev/null 2>&1; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
			echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${OBFUSCATION_PORT}/tcp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${OBFUSCATION_PORT}/tcp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
		else
			echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
		fi
		if [[ ${ENABLE_IPV6} == "y" ]]; then
			FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')
			echo "PostUp = firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/64 masquerade'
PostDown = firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/64 masquerade'" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
		fi
	else
		if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
			echo "PostUp = iptables -I INPUT -p tcp --dport ${OBFUSCATION_PORT} -j ACCEPT
PostUp = iptables -I INPUT ! -i lo -p udp --dport ${SERVER_PORT} -j DROP
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p tcp --dport ${OBFUSCATION_PORT} -j ACCEPT
PostDown = iptables -D INPUT ! -i lo -p udp --dport ${SERVER_PORT} -j DROP
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
		else
			echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
		fi
		if [[ ${ENABLE_MSS_CLAMP} == "y" ]]; then
			echo "PostUp = iptables -t mangle -A FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
		fi
		if [[ ${ENABLE_IPV6} == "y" ]]; then
			echo "PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = ip6tables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = ip6tables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
			if [[ ${ENABLE_MSS_CLAMP} == "y" ]]; then
				echo "PostUp = ip6tables -t mangle -A FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = ip6tables -t mangle -A FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip6tables -t mangle -D FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip6tables -t mangle -D FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"
			fi
		fi
	fi

	# Sysctl
	echo "net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2" >/etc/sysctl.d/wg.conf
	if [[ ${ENABLE_NET_OPTIMIZATIONS} == "y" ]]; then
		echo "net.ipv4.tcp_mtu_probing = 1" >>/etc/sysctl.d/wg.conf
		if [[ -e /proc/sys/net/core/default_qdisc ]]; then
			echo "net.core.default_qdisc = fq" >>/etc/sysctl.d/wg.conf
		fi
		if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
			echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.d/wg.conf
		fi
	fi
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		echo "net.ipv6.conf.all.forwarding = 1" >>/etc/sysctl.d/wg.conf
	fi

	sysctl --system

	# Start service
	systemctl start "${WG_SVC}@${SERVER_WG_NIC}"
	systemctl enable "${WG_SVC}@${SERVER_WG_NIC}"

	# Setup wstunnel after WireGuard is running
	if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
		setupObfuscation
	fi

	newClient
	echo -e "${GREEN}If you want to add more clients, run this script again!${NC}"

	systemctl is-active --quiet "${WG_SVC}@${SERVER_WG_NIC}"
	WG_RUNNING=$?

	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: Service not running. Try rebooting.${NC}"
		echo -e "${ORANGE}Check: systemctl status ${WG_SVC}@${SERVER_WG_NIC}${NC}"
	else
		echo -e "\n${GREEN}VPN is running.${NC}"
		case "${OBFUSCATION_METHOD}" in
		amneziawg)
			echo -e "${GREEN}Obfuscation: AmneziaWG (protocol-level). Clients use AmneziaVPN app.${NC}"
			;;
		wstunnel)
			echo -e "${GREEN}Obfuscation: wstunnel (HTTPS tunnel on port ${OBFUSCATION_PORT}/tcp).${NC}"
			;;
		*)
			echo -e "${ORANGE}No obfuscation. Standard WireGuard.${NC}"
			;;
		esac
	fi

	runPostInstallChecks
}

function newClient() {
	# Set endpoint based on obfuscation method
	if [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
		ENDPOINT="127.0.0.1:${SERVER_PORT}"
	else
		SERVER_ENDPOINT="${SERVER_PUB_IP}"
		if [[ ${SERVER_ENDPOINT} =~ .*:.* ]]; then
			if [[ ${SERVER_ENDPOINT} != *"["* ]] || [[ ${SERVER_ENDPOINT} != *"]"* ]]; then
				SERVER_ENDPOINT="[${SERVER_ENDPOINT}]"
			fi
		fi
		ENDPOINT="${SERVER_ENDPOINT}:${SERVER_PORT}"
	fi

	echo ""
	echo "Client configuration"
	echo ""
	case "${OBFUSCATION_METHOD}" in
	amneziawg)
		echo -e "${GREEN}AmneziaWG mode. Import .conf into AmneziaVPN app (Android/iOS/Windows/macOS/Linux).${NC}"
		;;
	wstunnel)
		echo -e "${BLUE}wstunnel mode. Endpoint = 127.0.0.1:${SERVER_PORT}. Client needs wstunnel.${NC}"
		;;
	esac
	echo ""
	echo "The client name must consist of alphanumeric character(s), underscores or dashes (max 15 chars)."

	CLIENT_EXISTS=1
	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "Client name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "${WG_DIR}/${SERVER_WG_NIC}.conf")
		if [[ ${CLIENT_EXISTS} != 0 ]]; then
			echo -e "${ORANGE}Name already taken.${NC}"
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "${WG_DIR}/${SERVER_WG_NIC}.conf")
		if [[ ${DOT_EXISTS} == '0' ]]; then break; fi
	done
	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo "Max 253 clients reached."; exit 1
	fi

	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	IPV4_EXISTS=1
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "Client IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "${WG_DIR}/${SERVER_WG_NIC}.conf")
		if [[ ${IPV4_EXISTS} != 0 ]]; then
			echo -e "${ORANGE}IPv4 already taken.${NC}"
		fi
	done

	CLIENT_WG_IPV6=""
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
		IPV6_EXISTS=1
		until [[ ${IPV6_EXISTS} == '0' ]]; do
			read -rp "Client IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
			CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
			IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/128" "${WG_DIR}/${SERVER_WG_NIC}.conf")
			if [[ ${IPV6_EXISTS} != 0 ]]; then
				echo -e "${ORANGE}IPv6 already taken.${NC}"
			fi
		done
	fi

	CLIENT_PRIV_KEY=$(${WG_CMD} genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | ${WG_CMD} pubkey)
	CLIENT_PRE_SHARED_KEY=$(${WG_CMD} genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	CLIENT_ADDRESSES="${CLIENT_WG_IPV4}/32"
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		CLIENT_ADDRESSES="${CLIENT_ADDRESSES},${CLIENT_WG_IPV6}/128"
	fi
	CLIENT_DNS_LINE="${CLIENT_DNS_1}"
	if [[ -n ${CLIENT_DNS_2} ]] && [[ ${CLIENT_DNS_2} != "${CLIENT_DNS_1}" ]]; then
		CLIENT_DNS_LINE="${CLIENT_DNS_1},${CLIENT_DNS_2}"
	fi

	# Build client config
	local AWG_CLIENT_BLOCK=""
	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		AWG_CLIENT_BLOCK="Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}"
	fi

	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESSES}
DNS = ${CLIENT_DNS_LINE}
MTU = ${CLIENT_MTU}
${AWG_CLIENT_BLOCK}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = ${PERSISTENT_KEEPALIVE}" >"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	chmod 600 "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	SERVER_PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32"
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		SERVER_PEER_ALLOWED_IPS="${SERVER_PEER_ALLOWED_IPS},${CLIENT_WG_IPV6}/128"
	fi

	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${SERVER_PEER_ALLOWED_IPS}" >>"${WG_DIR}/${SERVER_WG_NIC}.conf"

	${WG_CMD} syncconf "${SERVER_WG_NIC}" <(${WG_QUICK} strip "${SERVER_WG_NIC}")

	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nQR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
		echo ""
	fi

	echo -e "${GREEN}Config: ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"

	if [[ ${OBFUSCATION_METHOD} == "amneziawg" ]]; then
		echo ""
		echo -e "${GREEN}=== How to connect ===${NC}"
		echo -e "${BLUE}Android/iOS:${NC} Install AmneziaVPN → import .conf file → connect"
		echo -e "${BLUE}Windows:${NC}    Install AmneziaVPN → import .conf file → connect"
		echo -e "${BLUE}macOS:${NC}      Install AmneziaVPN → import .conf file → connect"
		echo -e "${BLUE}Linux:${NC}      Install amneziawg-tools → awg-quick up <conf>"
		echo ""
		echo -e "AmneziaVPN: ${GREEN}https://amnezia.org${NC}"
	elif [[ ${OBFUSCATION_METHOD} == "wstunnel" ]]; then
		generateClientHelper "${CLIENT_NAME}" "${HOME_DIR}"
	fi
}

function listClients() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${WG_DIR}/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo "You have no existing clients!"; exit 1
	fi
	grep -E "^### Client" "${WG_DIR}/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${WG_DIR}/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo "You have no existing clients!"; exit 1
	fi

	echo ""
	echo "Select the client to revoke"
	grep -E "^### Client" "${WG_DIR}/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	CLIENT_NAME=$(grep -E "^### Client" "${WG_DIR}/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
	sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "${WG_DIR}/${SERVER_WG_NIC}.conf"

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	rm -rf "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-tunnel"

	${WG_CMD} syncconf "${SERVER_WG_NIC}" <(${WG_QUICK} strip "${SERVER_WG_NIC}")
}

function uninstallWg() {
	echo ""
	echo -e "${RED}WARNING: This will uninstall WireGuard and remove all configuration!${NC}"
	read -rp "Do you really want to remove WireGuard? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		systemctl stop "${WG_SVC}@${SERVER_WG_NIC}" 2>/dev/null || true
		systemctl disable "${WG_SVC}@${SERVER_WG_NIC}" 2>/dev/null || true

		# Remove wstunnel
		if systemctl is-enabled wstunnel-server 2>/dev/null; then
			systemctl stop wstunnel-server 2>/dev/null || true
			systemctl disable wstunnel-server 2>/dev/null || true
			rm -f /etc/systemd/system/wstunnel-server.service
			systemctl daemon-reload
		fi
		rm -f /usr/local/bin/wstunnel
		rm -rf /etc/wstunnel

		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get remove -y wireguard wireguard-tools amneziawg amneziawg-tools qrencode 2>/dev/null || true
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools qrencode 2>/dev/null || true
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools 2>/dev/null || true
		elif [[ ${OS} == 'oracle' ]]; then
			yum remove --noautoremove wireguard-tools qrencode 2>/dev/null || true
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools qrencode 2>/dev/null || true
		elif [[ ${OS} == 'alpine' ]]; then
			apk del wireguard-tools libqrencode libqrencode-tools 2>/dev/null || true
		fi

		rm -rf /etc/wireguard
		rm -rf /etc/amnezia/amneziawg
		rm -f /etc/sysctl.d/wg.conf
		sysctl --system

		echo "WireGuard uninstalled successfully."
		exit 0
	else
		echo "Removal aborted!"
	fi
}

function manageMenu() {
	echo "Welcome to WireGuard-install!"
	echo ""
	echo "WireGuard is already installed."
	echo ""
	case "${OBFUSCATION_METHOD}" in
	amneziawg)
		echo -e "Obfuscation: ${GREEN}AmneziaWG${NC} (protocol-level, use AmneziaVPN app)"
		;;
	wstunnel)
		echo -e "Obfuscation: ${GREEN}wstunnel${NC} (HTTPS tunnel on port ${OBFUSCATION_PORT}/tcp)"
		;;
	*)
		echo -e "Obfuscation: ${ORANGE}NONE${NC} (standard WireGuard)"
		;;
	esac
	echo ""
	echo "What do you want to do?"
	echo "   1) Add a new user"
	echo "   2) List all users"
	echo "   3) Revoke existing user"
	echo "   4) Uninstall WireGuard"
	echo "   5) Exit"
	until [[ ${MENU_OPTION} =~ ^[1-5]$ ]]; do
		read -rp "Select an option [1-5]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1) newClient ;;
	2) listClients ;;
	3) revokeClient ;;
	4) uninstallWg ;;
	5) exit 0 ;;
	esac
}

# --- Entry point ---
initialCheck

if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params

	# Backward compat: old ENABLE_OBFUSCATION → new OBFUSCATION_METHOD
	if [[ -z ${OBFUSCATION_METHOD} ]]; then
		OLD_OBFS=$(normalizeYesNo "${ENABLE_OBFUSCATION}")
		if [[ ${OLD_OBFS} == "y" ]]; then
			OBFUSCATION_METHOD="wstunnel"
		else
			OBFUSCATION_METHOD="none"
		fi
	fi

	ENABLE_IPV6=$(normalizeYesNo "${ENABLE_IPV6}")
	RESTRICTIVE_NETWORK_MODE=$(normalizeYesNo "${RESTRICTIVE_NETWORK_MODE}")
	if [[ -z ${RESTRICTIVE_NETWORK_MODE} ]]; then RESTRICTIVE_NETWORK_MODE="y"; fi
	if [[ -z ${ENABLE_IPV6} ]]; then
		if [[ -n ${SERVER_WG_IPV6} ]]; then ENABLE_IPV6="y"; else ENABLE_IPV6="n"; fi
	fi
	OBFUSCATION_PORT=${OBFUSCATION_PORT:-443}
	CLIENT_MTU=${CLIENT_MTU:-1280}
	PERSISTENT_KEEPALIVE=${PERSISTENT_KEEPALIVE:-25}
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${PERSISTENT_KEEPALIVE} == "0" ]]; then
		PERSISTENT_KEEPALIVE=25
	fi
	ENABLE_MSS_CLAMP=$(normalizeYesNo "${ENABLE_MSS_CLAMP}")
	if [[ -z ${ENABLE_MSS_CLAMP} ]]; then ENABLE_MSS_CLAMP="y"; fi
	ENABLE_NET_OPTIMIZATIONS=$(normalizeYesNo "${ENABLE_NET_OPTIMIZATIONS}")
	if [[ -z ${ENABLE_NET_OPTIMIZATIONS} ]]; then ENABLE_NET_OPTIMIZATIONS="y"; fi
	if [[ -z ${ALLOWED_IPS} ]]; then
		if [[ ${ENABLE_IPV6} == "y" ]]; then ALLOWED_IPS="0.0.0.0/0,::/0"; else ALLOWED_IPS="0.0.0.0/0"; fi
	fi
	if [[ -n ${CLIENT_DNS_1} && -z ${CLIENT_DNS_2} ]]; then CLIENT_DNS_2="${CLIENT_DNS_1}"; fi
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${CLIENT_DNS_1} == "1.1.1.1" && ${CLIENT_DNS_2} == "1.0.0.1" ]]; then
		CLIENT_DNS_1="9.9.9.9"
		CLIENT_DNS_2="8.8.8.8"
	fi

	setWgVars
	manageMenu
else
	installWireGuard
fi
