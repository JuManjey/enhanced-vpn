#!/bin/bash

# Enhanced WireGuard server installer with DPI bypass
# Based on https://github.com/angristan/wireguard-install
# Adds wstunnel-based HTTPS obfuscation for restrictive networks (Russia, etc.)

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
umask 077

WSTUNNEL_VERSION="10.1.6"

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
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
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
		echo "Installing curl..."
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
	echo "Downloading wstunnel v${WSTUNNEL_VERSION} for ${WSTUNNEL_ARCH}..."

	if ! curl -fsSL -o /tmp/wstunnel.tar.gz "${WSTUNNEL_URL}"; then
		echo -e "${RED}Failed to download wstunnel from:${NC}"
		echo "${WSTUNNEL_URL}"
		echo "Trying to detect latest version from GitHub API..."
		local LATEST_VER
		LATEST_VER=$(curl -fsSL https://api.github.com/repos/erebe/wstunnel/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
		if [[ -n ${LATEST_VER} ]]; then
			WSTUNNEL_VERSION="${LATEST_VER}"
			WSTUNNEL_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_${WSTUNNEL_ARCH}.tar.gz"
			echo "Trying v${WSTUNNEL_VERSION}..."
			if ! curl -fsSL -o /tmp/wstunnel.tar.gz "${WSTUNNEL_URL}"; then
				echo -e "${RED}Failed to download wstunnel. Please install manually.${NC}"
				echo "https://github.com/erebe/wstunnel/releases"
				exit 1
			fi
		else
			echo -e "${RED}Cannot reach GitHub API. Check internet connection.${NC}"
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
			echo -e "${RED}Could not extract wstunnel binary from archive.${NC}"
			exit 1
		fi
	}
	chmod +x /usr/local/bin/wstunnel
	rm -f /tmp/wstunnel.tar.gz

	if ! /usr/local/bin/wstunnel --version &>/dev/null; then
		echo -e "${RED}wstunnel installation verification failed.${NC}"
		exit 1
	fi
	echo -e "${GREEN}wstunnel installed: $(/usr/local/bin/wstunnel --version 2>&1 | head -1)${NC}"
}

function setupObfuscation() {
	echo -e "\n${GREEN}Configuring HTTPS obfuscation layer (wstunnel)...${NC}"

	mkdir -p /etc/wstunnel
	chmod 700 /etc/wstunnel

	if ! command -v openssl &>/dev/null; then
		echo "Installing openssl..."
		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get install -y openssl
		elif [[ ${OS} == 'fedora' ]] || [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]] || [[ ${OS} == 'oracle' ]]; then
			dnf install -y openssl 2>/dev/null || yum install -y openssl
		elif [[ ${OS} == 'arch' ]]; then
			pacman -S --noconfirm openssl
		elif [[ ${OS} == 'alpine' ]]; then
			apk add openssl
		fi
	fi

	local TLS_SAN="IP:${SERVER_PUB_IP}"
	if [[ ${SERVER_PUB_IP} =~ ^[a-zA-Z] ]]; then
		TLS_SAN="DNS:${SERVER_PUB_IP}"
	fi

	echo "Generating TLS certificate..."
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout /etc/wstunnel/key.pem -out /etc/wstunnel/cert.pem \
		-days 3650 -nodes -subj "/CN=${SERVER_PUB_IP}" \
		-addext "subjectAltName=${TLS_SAN}" 2>/dev/null

	chmod 600 /etc/wstunnel/key.pem /etc/wstunnel/cert.pem

	local WS_PATH
	WS_PATH=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
	echo "${WS_PATH}" >/etc/wstunnel/ws_path
	chmod 600 /etc/wstunnel/ws_path

	if [[ ${OS} == 'alpine' ]]; then
		cat >/etc/init.d/wstunnel <<ALPINEINIT
#!/sbin/openrc-run
name="wstunnel"
description="wstunnel HTTPS tunnel for WireGuard"
command="/usr/local/bin/wstunnel"
command_args="server wss://[::]:${OBFUSCATION_PORT} --tls-certificate /etc/wstunnel/cert.pem --tls-private-key /etc/wstunnel/key.pem --restrict-to 127.0.0.1:${SERVER_PORT} --http-upgrade-path-prefix ${WS_PATH}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    before wg-quick.${SERVER_WG_NIC}
}
ALPINEINIT
		chmod 755 /etc/init.d/wstunnel
		rc-service wstunnel start
		rc-update add wstunnel
	else
		cat >/etc/systemd/system/wstunnel-server.service <<SYSTEMDUNIT
[Unit]
Description=wstunnel HTTPS tunnel for WireGuard
After=network-online.target
Wants=network-online.target
Before=wg-quick@${SERVER_WG_NIC}.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wstunnel server wss://[::]:${OBFUSCATION_PORT} --tls-certificate /etc/wstunnel/cert.pem --tls-private-key /etc/wstunnel/key.pem --restrict-to 127.0.0.1:${SERVER_PORT} --http-upgrade-path-prefix ${WS_PATH}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDUNIT

		systemctl daemon-reload
		systemctl enable wstunnel-server
		systemctl start wstunnel-server
	fi

	echo -e "${GREEN}wstunnel server started on port ${OBFUSCATION_PORT}/tcp (HTTPS/WSS)${NC}"
	echo -e "${GREEN}WebSocket path: ${WS_PATH}${NC}"
	echo -e "${GREEN}WireGuard internal port: ${SERVER_PORT}/udp (localhost only)${NC}"
}

function generateClientHelper() {
	local CLIENT_NAME=$1
	local HOME_DIR=$2
	local HELPER_DIR="${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-tunnel"

	mkdir -p "${HELPER_DIR}"

	local WS_PATH
	WS_PATH=$(cat /etc/wstunnel/ws_path 2>/dev/null)

	# --- Linux/macOS connect script ---
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

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Run this script as root (sudo).${NC}"
    exit 1
fi

if ! command -v wstunnel &>/dev/null; then
    echo -e "${RED}wstunnel is not installed.${NC}"
    echo ""
    echo "Install from: https://github.com/erebe/wstunnel/releases"
    echo ""
    ARCH=$(uname -m)
    case ${ARCH} in
    x86_64|amd64) DL_ARCH="amd64" ;;
    aarch64|arm64) DL_ARCH="arm64" ;;
    armv7l) DL_ARCH="armv7" ;;
    *) DL_ARCH="amd64" ;;
    esac
    echo "Quick install:"
    echo "  curl -fsSL -o /tmp/wstunnel.tar.gz https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_\${DL_ARCH}.tar.gz"
    echo "  sudo tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin/ wstunnel"
    echo "  sudo chmod +x /usr/local/bin/wstunnel"
    exit 1
fi

if ! command -v wg-quick &>/dev/null; then
    echo -e "${RED}WireGuard tools not installed.${NC}"
    echo "Install: sudo apt install wireguard-tools  (Debian/Ubuntu)"
    echo "         sudo dnf install wireguard-tools  (Fedora)"
    exit 1
fi

if [ ! -f "${WG_CONF}" ]; then
    echo -e "${RED}WireGuard config not found: ${WG_CONF}${NC}"
    exit 1
fi

DEFAULT_GW=$(ip route show default 2>/dev/null | head -1 | awk '{print $3}')
DEFAULT_IF=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')

if [[ -z "${DEFAULT_GW}" || -z "${DEFAULT_IF}" ]]; then
    echo -e "${RED}Cannot detect default gateway. Are you connected to a network?${NC}"
    exit 1
fi

RESOLVED_IP="${SERVER}"
if ! [[ ${SERVER} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RESOLVED_IP=$(getent hosts "${SERVER}" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -z "${RESOLVED_IP}" ]]; then
        RESOLVED_IP=$(dig +short "${SERVER}" A 2>/dev/null | head -1)
    fi
    if [[ -z "${RESOLVED_IP}" ]]; then
        echo -e "${ORANGE}Cannot resolve ${SERVER}, using as-is${NC}"
        RESOLVED_IP="${SERVER}"
    fi
fi

WSTUNNEL_PID=""
ROUTE_ADDED=""
WG_UP=""

cleanup() {
    echo ""
    echo "Disconnecting..."
    if [[ -n "${WG_UP}" ]]; then
        wg-quick down "${WG_CONF}" 2>/dev/null || true
    fi
    if [[ -n "${WSTUNNEL_PID}" ]]; then
        kill "${WSTUNNEL_PID}" 2>/dev/null || true
        wait "${WSTUNNEL_PID}" 2>/dev/null || true
    fi
    if [[ -n "${ROUTE_ADDED}" ]]; then
        ip route del "${RESOLVED_IP}/32" via "${DEFAULT_GW}" dev "${DEFAULT_IF}" 2>/dev/null || true
    fi
    echo -e "${GREEN}Disconnected.${NC}"
}
trap cleanup EXIT INT TERM

echo -e "${GREEN}Starting obfuscated VPN tunnel to ${SERVER}...${NC}"
echo "  Server:    ${SERVER}:${TUNNEL_PORT} (HTTPS)"
echo "  Local WG:  127.0.0.1:${LOCAL_WG_PORT}"
echo ""

ip route add "${RESOLVED_IP}/32" via "${DEFAULT_GW}" dev "${DEFAULT_IF}" 2>/dev/null && ROUTE_ADDED="1" || {
    echo -e "${ORANGE}Static route already exists or cannot be added (may be OK).${NC}"
    ROUTE_ADDED="1"
}

wstunnel client \
    -L "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0" \
    "wss://${SERVER}:${TUNNEL_PORT}" \
    --tls-verify-certificate false \
    --http-upgrade-path-prefix "${WS_PATH}" &
WSTUNNEL_PID=$!
sleep 3

if ! kill -0 "${WSTUNNEL_PID}" 2>/dev/null; then
    echo -e "${RED}wstunnel failed to connect. Check:${NC}"
    echo "  - Server ${SERVER}:${TUNNEL_PORT} is reachable"
    echo "  - Port ${TUNNEL_PORT}/tcp is not blocked by your ISP"
    echo "  - Firewall allows outgoing HTTPS"
    WSTUNNEL_PID=""
    exit 1
fi
echo -e "${GREEN}HTTPS tunnel established.${NC}"

echo "Bringing up WireGuard..."
wg-quick up "${WG_CONF}" && WG_UP="1" || {
    echo -e "${RED}WireGuard failed to start.${NC}"
    exit 1
}

echo ""
echo -e "${GREEN}=== VPN is active! ===${NC}"
echo -e "${GREEN}All traffic is now routed through the encrypted HTTPS tunnel.${NC}"
echo -e "${GREEN}Press Ctrl+C to disconnect.${NC}"
echo ""

wait "${WSTUNNEL_PID}"
CONNECTBODY

	chmod 700 "${HELPER_DIR}/connect.sh"

	# --- Windows helper ---
	cat >"${HELPER_DIR}/connect.bat" <<BATEOF
@echo off
setlocal EnableDelayedExpansion
REM WireGuard + wstunnel obfuscated connection for ${CLIENT_NAME}
REM
REM Prerequisites:
REM   1. Install wstunnel: https://github.com/erebe/wstunnel/releases
REM      Place wstunnel.exe in the same folder as this script or in PATH
REM   2. Install WireGuard: https://www.wireguard.com/install/
REM   3. Import the .conf file into WireGuard client
REM
REM Usage:
REM   1. Run this script as Administrator
REM   2. After "Tunnel started", activate WireGuard in the WireGuard app
REM   3. Press any key in this window to stop the tunnel when done

set SERVER=${SERVER_PUB_IP}
set TUNNEL_PORT=${OBFUSCATION_PORT}
set LOCAL_WG_PORT=${SERVER_PORT}
set WS_PATH=${WS_PATH}

echo Adding route to VPN server...
for /f "tokens=3" %%g in ('route print 0.0.0.0 ^| findstr /C:"0.0.0.0" ^| findstr /V /C:"On-link"') do (
    set GW=%%g
    goto :found_gw
)
:found_gw
route add %SERVER% mask 255.255.255.255 %GW% >nul 2>&1

echo Starting HTTPS tunnel to %SERVER%:%TUNNEL_PORT%...
start /B wstunnel.exe client -L "udp://127.0.0.1:%LOCAL_WG_PORT%:127.0.0.1:%LOCAL_WG_PORT%?timeout_sec=0" "wss://%SERVER%:%TUNNEL_PORT%" --tls-verify-certificate false --http-upgrade-path-prefix "%WS_PATH%"
timeout /t 3 /nobreak >nul

echo.
echo Tunnel started. Now activate WireGuard in the WireGuard app.
echo Press any key to STOP the tunnel when you are done...
pause >nul

echo Stopping...
taskkill /IM wstunnel.exe /F 2>nul
route delete %SERVER% >nul 2>&1
echo Disconnected.
BATEOF
	chmod 600 "${HELPER_DIR}/connect.bat"

	# --- macOS connect script ---
	cat >"${HELPER_DIR}/connect-macos.sh" <<'MACOSEOF'
#!/bin/bash
set -euo pipefail

MACOSEOF

	cat >>"${HELPER_DIR}/connect-macos.sh" <<MACOSVARS
SERVER="${SERVER_PUB_IP}"
TUNNEL_PORT=${OBFUSCATION_PORT}
LOCAL_WG_PORT=${SERVER_PORT}
WS_PATH="${WS_PATH}"
WSTUNNEL_VERSION="${WSTUNNEL_VERSION}"
MACOSVARS

	cat >>"${HELPER_DIR}/connect-macos.sh" <<'MACOSBODY'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WG_CONF="${SCRIPT_DIR}/../$(ls "${SCRIPT_DIR}/../" | grep '\.conf$' | head -1)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Run: sudo $0${NC}"
    exit 1
fi

if ! command -v wstunnel &>/dev/null; then
    echo -e "${RED}Install wstunnel: brew install wstunnel${NC}"
    echo "Or download from: https://github.com/erebe/wstunnel/releases"
    exit 1
fi

DEFAULT_GW=$(route -n get default 2>/dev/null | grep 'gateway' | awk '{print $2}')
DEFAULT_IF=$(route -n get default 2>/dev/null | grep 'interface' | awk '{print $2}')

WSTUNNEL_PID=""
ROUTE_ADDED=""
WG_UP=""

cleanup() {
    echo "Disconnecting..."
    if [[ -n "${WG_UP}" ]]; then
        wg-quick down "${WG_CONF}" 2>/dev/null || true
    fi
    if [[ -n "${WSTUNNEL_PID}" ]]; then
        kill "${WSTUNNEL_PID}" 2>/dev/null || true
    fi
    if [[ -n "${ROUTE_ADDED}" ]]; then
        route delete "${SERVER}/32" "${DEFAULT_GW}" 2>/dev/null || true
    fi
    echo -e "${GREEN}Disconnected.${NC}"
}
trap cleanup EXIT INT TERM

route add "${SERVER}/32" "${DEFAULT_GW}" 2>/dev/null && ROUTE_ADDED="1" || ROUTE_ADDED="1"

wstunnel client \
    -L "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0" \
    "wss://${SERVER}:${TUNNEL_PORT}" \
    --tls-verify-certificate false \
    --http-upgrade-path-prefix "${WS_PATH}" &
WSTUNNEL_PID=$!
sleep 3

if ! kill -0 "${WSTUNNEL_PID}" 2>/dev/null; then
    echo -e "${RED}wstunnel failed to connect.${NC}"
    WSTUNNEL_PID=""
    exit 1
fi

echo -e "${GREEN}Tunnel established.${NC}"
wg-quick up "${WG_CONF}" && WG_UP="1"

echo -e "${GREEN}VPN is active! Press Ctrl+C to disconnect.${NC}"
wait "${WSTUNNEL_PID}"
MACOSBODY

	chmod 700 "${HELPER_DIR}/connect-macos.sh"

	# --- README ---
	cat >"${HELPER_DIR}/README.txt" <<READMEEOF
===============================================
  WireGuard VPN with HTTPS Traffic Obfuscation
===============================================

Client: ${CLIENT_NAME}
Server: ${SERVER_PUB_IP}:${OBFUSCATION_PORT} (HTTPS tunnel)
WireGuard port (internal): ${SERVER_PORT}

Your VPN traffic is wrapped in HTTPS — network observers and DPI
systems see regular HTTPS traffic to the server, not VPN packets.

=== REQUIREMENTS ===

  1. wstunnel — https://github.com/erebe/wstunnel/releases/tag/v${WSTUNNEL_VERSION}
  2. WireGuard — https://www.wireguard.com/install/

=== QUICK START ===

  --- Linux ---
    sudo ./connect.sh

  --- macOS ---
    sudo ./connect-macos.sh

  --- Windows ---
    1. Place wstunnel.exe in this folder (or in PATH)
    2. Run connect.bat as Administrator
    3. Activate WireGuard tunnel in the WireGuard app

  --- Android (recommended: AmneziaVPN) ---
    1. Install AmneziaVPN from Google Play / GitHub
    2. Import the .conf file
    3. AmneziaVPN has built-in obfuscation support

  --- Android (manual) ---
    1. Install WireGuard app + Termux from F-Droid
    2. In Termux: pkg install root-repo && pkg install wstunnel
    3. Run in Termux:
       wstunnel client \\
         -L 'udp://127.0.0.1:${SERVER_PORT}:127.0.0.1:${SERVER_PORT}?timeout_sec=0' \\
         'wss://${SERVER_PUB_IP}:${OBFUSCATION_PORT}' \\
         --tls-verify-certificate false \\
         --http-upgrade-path-prefix '${WS_PATH}'
    4. Activate WireGuard tunnel (Endpoint = 127.0.0.1:${SERVER_PORT})

  --- iOS ---
    Use AmneziaVPN from App Store. Import the .conf file.

=== MANUAL CONNECTION (any platform) ===

  Step 1: Add route to server (prevents routing loop):
    Linux:  ip route add ${SERVER_PUB_IP}/32 via <YOUR_GATEWAY> dev <YOUR_INTERFACE>
    macOS:  route add ${SERVER_PUB_IP}/32 <YOUR_GATEWAY>
    Win:    route add ${SERVER_PUB_IP} mask 255.255.255.255 <YOUR_GATEWAY>

  Step 2: Start wstunnel client:
    wstunnel client \\
      -L 'udp://127.0.0.1:${SERVER_PORT}:127.0.0.1:${SERVER_PORT}?timeout_sec=0' \\
      'wss://${SERVER_PUB_IP}:${OBFUSCATION_PORT}' \\
      --tls-verify-certificate false \\
      --http-upgrade-path-prefix '${WS_PATH}'

  Step 3: Activate WireGuard using the .conf file
    Endpoint in the config is already set to 127.0.0.1:${SERVER_PORT}

=== TROUBLESHOOTING ===

  - wstunnel won't connect:
      Check that port ${OBFUSCATION_PORT}/TCP is reachable from your network
      Some networks block non-standard HTTPS — try port 443 on server

  - Connected but no internet:
      Try lowering MTU in .conf (change to 1200, 1100, or even 1000)
      Check DNS: try 8.8.8.8, 1.1.1.1, or 77.88.8.8

  - Slow speed:
      Normal for HTTPS tunnel (adds ~10-15% overhead)
      Try a server geographically closer to you

  - WireGuard handshake fails:
      Restart wstunnel, wait 3 seconds, then reconnect WireGuard
READMEEOF
	chmod 644 "${HELPER_DIR}/README.txt"

	echo ""
	echo -e "${GREEN}=== Client Connection Files ===${NC}"
	echo -e "  Config:     ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	echo -e "  Scripts:    ${HELPER_DIR}/"
	echo ""
	echo -e "${BLUE}Linux:${NC}   sudo ${HELPER_DIR}/connect.sh"
	echo -e "${BLUE}macOS:${NC}   sudo ${HELPER_DIR}/connect-macos.sh"
	echo -e "${BLUE}Windows:${NC} Run connect.bat as Admin, then activate WireGuard"
	echo -e "${BLUE}Mobile:${NC}  Use AmneziaVPN app — import the .conf file"
	echo ""
	echo -e "Detailed instructions: ${HELPER_DIR}/README.txt"
}

function installQuestions() {
	echo "Welcome to the Enhanced WireGuard installer!"
	echo "https://github.com/angristan/wireguard-install"
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
		echo "Restrictive-network profile enabled: IPv4-first mode and resilient DNS defaults."
		echo ""
	fi

	until [[ ${ENABLE_OBFUSCATION} =~ ^[yn]$ ]]; do
		if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]]; then
			echo -e "${GREEN}Traffic obfuscation wraps WireGuard in HTTPS so DPI cannot detect VPN traffic.${NC}"
			echo -e "${GREEN}This is REQUIRED for Russia and other countries with active DPI blocking.${NC}"
			read -rp "Enable traffic obfuscation via HTTPS tunnel (wstunnel)? [Y/n]: " -e -i y ENABLE_OBFUSCATION
		else
			read -rp "Enable traffic obfuscation via HTTPS tunnel (wstunnel)? [y/N]: " -e -i n ENABLE_OBFUSCATION
		fi
		ENABLE_OBFUSCATION=$(normalizeYesNo "${ENABLE_OBFUSCATION}")
	done

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
				read -rp "Enable IPv6 for clients [y/N] (IPv4-only is usually more stable in restrictive networks): " -e -i n ENABLE_IPV6
			else
				read -rp "Enable IPv6 for clients [Y/n]: " -e -i y ENABLE_IPV6
			fi
		else
			read -rp "No global IPv6 detected. Enable IPv6 anyway? [y/N]: " -e -i n ENABLE_IPV6
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

	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		DEFAULT_WG_PORT=$(shuf -i 49152-65000 -n 1)
		while isUdpPortBusy "${DEFAULT_WG_PORT}"; do
			DEFAULT_WG_PORT=$(shuf -i 49152-65000 -n 1)
		done

		while true; do
			read -rp "WireGuard internal port (not exposed externally) [1-65535]: " -e -i "${DEFAULT_WG_PORT}" SERVER_PORT
			if ! [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
				echo -e "${ORANGE}Please enter a valid port in range 1-65535.${NC}"
				continue
			fi
			if isUdpPortBusy "${SERVER_PORT}"; then
				echo -e "${ORANGE}UDP port ${SERVER_PORT} is already in use. Pick another one.${NC}"
				continue
			fi
			break
		done

		DEFAULT_OBFS_PORT=443
		while true; do
			read -rp "HTTPS obfuscation port (public-facing, TCP) [1-65535]: " -e -i "${DEFAULT_OBFS_PORT}" OBFUSCATION_PORT
			if ! [[ ${OBFUSCATION_PORT} =~ ^[0-9]+$ ]] || [ "${OBFUSCATION_PORT}" -lt 1 ] || [ "${OBFUSCATION_PORT}" -gt 65535 ]; then
				echo -e "${ORANGE}Please enter a valid port in range 1-65535.${NC}"
				continue
			fi
			if isTcpPortBusy "${OBFUSCATION_PORT}"; then
				echo -e "${ORANGE}TCP port ${OBFUSCATION_PORT} is already in use (nginx? apache?). Pick another one.${NC}"
				continue
			fi
			break
		done
		echo -e "${GREEN}WireGuard: localhost:${SERVER_PORT}/udp | Public tunnel: 0.0.0.0:${OBFUSCATION_PORT}/tcp (HTTPS)${NC}"
	else
		OBFUSCATION_PORT=""
		RANDOM_PORT=443
		while true; do
			read -rp "Server WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
			if ! [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
				echo -e "${ORANGE}Please enter a valid port in range 1-65535.${NC}"
				continue
			fi
			if isUdpPortBusy "${SERVER_PORT}"; then
				echo -e "${ORANGE}UDP port ${SERVER_PORT} is already in use. Pick another one.${NC}"
				continue
			fi
			break
		done
	fi

	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the clients: " -e -i "${DNS_DEFAULT_1}" CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the clients (optional): " -e -i "${DNS_DEFAULT_2}" CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	CLIENT_MTU_MIN=1200
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		CLIENT_MTU_MIN=1280
	fi
	local DEFAULT_MTU=1280
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		DEFAULT_MTU=1200
	fi
	until [[ ${CLIENT_MTU} =~ ^[0-9]+$ ]] && [ "${CLIENT_MTU}" -ge "${CLIENT_MTU_MIN}" ] && [ "${CLIENT_MTU}" -le 1500 ]; do
		read -rp "Client MTU [${CLIENT_MTU_MIN}-1500] (${DEFAULT_MTU} recommended): " -e -i "${DEFAULT_MTU}" CLIENT_MTU
	done

	until [[ ${PERSISTENT_KEEPALIVE} =~ ^[0-9]+$ ]] && [ "${PERSISTENT_KEEPALIVE}" -ge 0 ] && [ "${PERSISTENT_KEEPALIVE}" -le 65535 ]; do
		read -rp "PersistentKeepalive for clients [0-65535] (25 recommended): " -e -i 25 PERSISTENT_KEEPALIVE
	done
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${PERSISTENT_KEEPALIVE} -eq 0 ]]; then
		echo -e "${ORANGE}PersistentKeepalive=0 can break connectivity in restrictive/NAT-heavy networks. Forcing 25.${NC}"
		PERSISTENT_KEEPALIVE=25
	fi

	until [[ ${ENABLE_MSS_CLAMP} =~ ^[yn]$ ]]; do
		read -rp "Enable TCP MSS clamping for unstable routes? [Y/n]: " -e -i y ENABLE_MSS_CLAMP
		ENABLE_MSS_CLAMP=$(normalizeYesNo "${ENABLE_MSS_CLAMP}")
	done

	until [[ ${ENABLE_NET_OPTIMIZATIONS} =~ ^[yn]$ ]]; do
		read -rp "Enable kernel network optimizations (PMTU probing + BBR if available)? [Y/n]: " -e -i y ENABLE_NET_OPTIMIZATIONS
		ENABLE_NET_OPTIMIZATIONS=$(normalizeYesNo "${ENABLE_NET_OPTIMIZATIONS}")
	done

	DEFAULT_ALLOWED_IPS="0.0.0.0/0"
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		DEFAULT_ALLOWED_IPS="0.0.0.0/0,::/0"
	fi

	until [[ ${ALLOWED_IPS} =~ ^[0-9a-fA-F:./,]+$ ]]; do
		echo -e "\nWireGuard uses a parameter called AllowedIPs to determine what is routed over the VPN."
		read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i "${DEFAULT_ALLOWED_IPS}" ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="${DEFAULT_ALLOWED_IPS}"
		fi
	done
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${ALLOWED_IPS} != *"0.0.0.0/0"* ]]; then
		echo -e "${ORANGE}WARNING:${NC} Restrictive profile works best when IPv4 default route is tunneled (0.0.0.0/0)."
	fi

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		echo -e "${GREEN}Traffic obfuscation via HTTPS tunnel (wstunnel) will be configured.${NC}"
	fi
	echo "You will be able to generate a client at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function runPostInstallChecks() {
	echo ""
	echo -e "${GREEN}Post-install verification:${NC}"

	if ip link show "${SERVER_WG_NIC}" &>/dev/null; then
		echo -e "${GREEN}[OK]${NC} WireGuard interface ${SERVER_WG_NIC} is present."
	else
		echo -e "${ORANGE}[WARN]${NC} WireGuard interface ${SERVER_WG_NIC} is missing."
	fi

	if command -v ss &>/dev/null && ss -Hlun "sport = :${SERVER_PORT}" | grep -q .; then
		echo -e "${GREEN}[OK]${NC} WireGuard UDP port ${SERVER_PORT} is listening."
	else
		echo -e "${ORANGE}[WARN]${NC} WireGuard UDP port ${SERVER_PORT} is not listening yet."
	fi

	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		if [[ ${OS} == 'alpine' ]]; then
			if rc-service --quiet wstunnel status 2>/dev/null; then
				echo -e "${GREEN}[OK]${NC} wstunnel service is running."
			else
				echo -e "${ORANGE}[WARN]${NC} wstunnel service is not running."
			fi
		else
			if systemctl is-active --quiet wstunnel-server 2>/dev/null; then
				echo -e "${GREEN}[OK]${NC} wstunnel service is running."
			else
				echo -e "${ORANGE}[WARN]${NC} wstunnel service is not running."
			fi
		fi

		if command -v ss &>/dev/null && ss -Hltn "sport = :${OBFUSCATION_PORT}" | grep -q .; then
			echo -e "${GREEN}[OK]${NC} HTTPS tunnel port ${OBFUSCATION_PORT}/tcp is listening."
		else
			echo -e "${ORANGE}[WARN]${NC} HTTPS tunnel port ${OBFUSCATION_PORT}/tcp is not listening."
		fi
	fi

	if [[ -n ${CLIENT_DNS_1} ]]; then
		if canReachDnsResolver "${CLIENT_DNS_1}"; then
			echo -e "${GREEN}[OK]${NC} DNS resolver ${CLIENT_DNS_1}:53 is reachable from server."
		else
			echo -e "${ORANGE}[WARN]${NC} DNS resolver ${CLIENT_DNS_1}:53 is not reachable. Clients may connect but fail to resolve domains."
		fi
	fi
	if [[ -n ${CLIENT_DNS_2} ]] && [[ ${CLIENT_DNS_2} != "${CLIENT_DNS_1}" ]]; then
		if canReachDnsResolver "${CLIENT_DNS_2}"; then
			echo -e "${GREEN}[OK]${NC} DNS resolver ${CLIENT_DNS_2}:53 is reachable from server."
		else
			echo -e "${ORANGE}[WARN]${NC} DNS resolver ${CLIENT_DNS_2}:53 is not reachable. Clients may connect but fail to resolve domains."
		fi
	fi

	IPV4_FORWARD_STATE=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
	if [[ ${IPV4_FORWARD_STATE} == "1" ]]; then
		echo -e "${GREEN}[OK]${NC} IPv4 forwarding is enabled."
	else
		echo -e "${ORANGE}[WARN]${NC} IPv4 forwarding is disabled."
	fi

	if [[ ${ENABLE_IPV6} == "y" ]]; then
		IPV6_FORWARD_STATE=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "0")
		if [[ ${IPV6_FORWARD_STATE} == "1" ]]; then
			echo -e "${GREEN}[OK]${NC} IPv6 forwarding is enabled."
		else
			echo -e "${ORANGE}[WARN]${NC} IPv6 forwarding is disabled."
		fi
	fi

	if [[ ${ENABLE_NET_OPTIMIZATIONS} == "y" ]]; then
		MTU_PROBING_STATE=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "0")
		if [[ ${MTU_PROBING_STATE} == "1" ]]; then
			echo -e "${GREEN}[OK]${NC} TCP MTU probing is enabled."
		else
			echo -e "${ORANGE}[WARN]${NC} TCP MTU probing is disabled."
		fi

		if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw "bbr"; then
			echo -e "${GREEN}[OK]${NC} BBR congestion control is active."
		elif sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
			echo -e "${ORANGE}[WARN]${NC} BBR is available but not active."
		else
			echo -e "${ORANGE}[WARN]${NC} BBR is not available on this kernel."
		fi
	fi
}

function installWireGuard() {
	installQuestions

	# Install WireGuard tools and module
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

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}WireGuard installation failed. The 'wg' command was not found.${NC}"
		echo "Please check the installation output above for errors."
		exit 1
	fi

	mkdir /etc/wireguard >/dev/null 2>&1
	chmod 700 /etc/wireguard/

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Install wstunnel if obfuscation is enabled
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		installWstunnel
	fi

	# Save WireGuard settings
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
ENABLE_IPV6=${ENABLE_IPV6}
RESTRICTIVE_NETWORK_MODE=${RESTRICTIVE_NETWORK_MODE}
ENABLE_OBFUSCATION=${ENABLE_OBFUSCATION}
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
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

	# Add server interface
	SERVER_INTERFACE_ADDRESSES="${SERVER_WG_IPV4}/24"
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		SERVER_INTERFACE_ADDRESSES="${SERVER_INTERFACE_ADDRESSES},${SERVER_WG_IPV6}/64"
	fi
	echo "[Interface]
Address = ${SERVER_INTERFACE_ADDRESSES}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = ${CLIENT_MTU}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"
	chmod 600 /etc/wireguard/params "/etc/wireguard/${SERVER_WG_NIC}.conf"

	if pgrep firewalld >/dev/null 2>&1; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
			echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${OBFUSCATION_PORT}/tcp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${OBFUSCATION_PORT}/tcp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		else
			echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		fi
		if [[ ${ENABLE_IPV6} == "y" ]]; then
			FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')
			echo "PostUp = firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/64 masquerade'
PostDown = firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/64 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		fi
	else
		if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
			# Obfuscation: expose TCP port for wstunnel, block external UDP to WG port
			echo "PostUp = iptables -I INPUT -p tcp --dport ${OBFUSCATION_PORT} -j ACCEPT
PostUp = iptables -I INPUT ! -i lo -p udp --dport ${SERVER_PORT} -j DROP
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p tcp --dport ${OBFUSCATION_PORT} -j ACCEPT
PostDown = iptables -D INPUT ! -i lo -p udp --dport ${SERVER_PORT} -j DROP
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		else
			# Standard: expose UDP port for WireGuard directly
			echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SERVER_WG_IPV4}/24 -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		fi
		if [[ ${ENABLE_MSS_CLAMP} == "y" ]]; then
			echo "PostUp = iptables -t mangle -A FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		fi
		if [[ ${ENABLE_IPV6} == "y" ]]; then
			echo "PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = ip6tables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = ip6tables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
			if [[ ${ENABLE_MSS_CLAMP} == "y" ]]; then
				echo "PostUp = ip6tables -t mangle -A FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = ip6tables -t mangle -A FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip6tables -t mangle -D FORWARD -i ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip6tables -t mangle -D FORWARD -o ${SERVER_WG_NIC} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
			fi
		fi
	fi

	# Enable routing on the server
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

	if [[ ${OS} == 'fedora' ]]; then
		chmod -v 700 /etc/wireguard
		chmod -v 600 /etc/wireguard/*
	fi

	if [[ ${OS} == 'alpine' ]]; then
		sysctl -p /etc/sysctl.d/wg.conf
		rc-update add sysctl
		ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
		rc-service "wg-quick.${SERVER_WG_NIC}" start
		rc-update add "wg-quick.${SERVER_WG_NIC}"
	else
		sysctl --system

		systemctl start "wg-quick@${SERVER_WG_NIC}"
		systemctl enable "wg-quick@${SERVER_WG_NIC}"
	fi

	# Setup obfuscation layer after WireGuard is running
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		setupObfuscation
	fi

	newClient
	echo -e "${GREEN}If you want to add more clients, you simply need to run this script another time!${NC}"

	# Check if WireGuard is running
	if [[ ${OS} == 'alpine' ]]; then
		rc-service --quiet "wg-quick.${SERVER_WG_NIC}" status
	else
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	fi
	WG_RUNNING=$?

	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${ORANGE}You can check if WireGuard is running with: rc-service wg-quick.${SERVER_WG_NIC} status${NC}"
		else
			echo -e "${ORANGE}You can check if WireGuard is running with: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		fi
		echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
	else
		echo -e "\n${GREEN}WireGuard is running.${NC}"
		if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
			echo -e "${GREEN}Traffic obfuscation (wstunnel) is active on port ${OBFUSCATION_PORT}/tcp.${NC}"
			echo -e "${GREEN}DPI systems will see HTTPS traffic instead of WireGuard.${NC}"
		fi
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${GREEN}You can check the status of WireGuard with: rc-service wg-quick.${SERVER_WG_NIC} status\n\n${NC}"
		else
			echo -e "${GREEN}You can check the status of WireGuard with: systemctl status wg-quick@${SERVER_WG_NIC}\n\n${NC}"
		fi
	fi

	runPostInstallChecks
}

function newClient() {
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		SERVER_ENDPOINT="127.0.0.1"
	else
		SERVER_ENDPOINT="${SERVER_PUB_IP}"
		if [[ ${SERVER_ENDPOINT} =~ .*:.* ]]; then
			if [[ ${SERVER_ENDPOINT} != *"["* ]] || [[ ${SERVER_ENDPOINT} != *"]"* ]]; then
				SERVER_ENDPOINT="[${SERVER_ENDPOINT}]"
			fi
		fi
	fi
	ENDPOINT="${SERVER_ENDPOINT}:${SERVER_PORT}"

	echo ""
	echo "Client configuration"
	echo ""
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		echo -e "${BLUE}Obfuscation is enabled. Client Endpoint will be 127.0.0.1:${SERVER_PORT}${NC}"
		echo -e "${BLUE}Clients must run wstunnel to connect (scripts will be generated).${NC}"
		echo ""
	fi
	echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."

	CLIENT_EXISTS=1
	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "Client name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${CLIENT_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
			echo ""
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo ""
		echo "The subnet configured supports only 253 clients."
		exit 1
	fi

	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	IPV4_EXISTS=1
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "Client WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${IPV4_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
			echo ""
		fi
	done

	CLIENT_WG_IPV6=""
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
		IPV6_EXISTS=1
		until [[ ${IPV6_EXISTS} == '0' ]]; do
			read -rp "Client WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
			CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
			IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf")

			if [[ ${IPV6_EXISTS} != 0 ]]; then
				echo ""
				echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
				echo ""
			fi
		done
	fi

	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	CLIENT_ADDRESSES="${CLIENT_WG_IPV4}/32"
	if [[ ${ENABLE_IPV6} == "y" ]]; then
		CLIENT_ADDRESSES="${CLIENT_ADDRESSES},${CLIENT_WG_IPV6}/128"
	fi
	CLIENT_DNS_LINE="${CLIENT_DNS_1}"
	if [[ -n ${CLIENT_DNS_2} ]] && [[ ${CLIENT_DNS_2} != "${CLIENT_DNS_1}" ]]; then
		CLIENT_DNS_LINE="${CLIENT_DNS_1},${CLIENT_DNS_2}"
	fi

	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESSES}
DNS = ${CLIENT_DNS_LINE}
MTU = ${CLIENT_MTU}

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
AllowedIPs = ${SERVER_PEER_ALLOWED_IPS}" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
		echo ""
	fi

	echo -e "${GREEN}Your client config file is in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"

	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		generateClientHelper "${CLIENT_NAME}" "${HOME_DIR}"
	fi
}

function listClients() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	echo ""
	echo "Select the existing client you want to revoke"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	rm -rf "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-tunnel"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
}

function uninstallWg() {
	echo ""
	echo -e "\n${RED}WARNING: This will uninstall WireGuard and remove all the configuration files!${NC}"
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		echo -e "${RED}This will also remove wstunnel and obfuscation configuration.${NC}"
	fi
	echo -e "${ORANGE}Please backup the /etc/wireguard directory if you want to keep your configuration files.\n${NC}"
	read -rp "Do you really want to remove WireGuard? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		if [[ ${OS} == 'alpine' ]]; then
			rc-service "wg-quick.${SERVER_WG_NIC}" stop
			rc-update del "wg-quick.${SERVER_WG_NIC}"
			unlink "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
			rc-update del sysctl
		else
			systemctl stop "wg-quick@${SERVER_WG_NIC}"
			systemctl disable "wg-quick@${SERVER_WG_NIC}"
		fi

		# Remove wstunnel if installed
		if [[ ${OS} == 'alpine' ]]; then
			if rc-service --exists wstunnel 2>/dev/null; then
				rc-service wstunnel stop 2>/dev/null || true
				rc-update del wstunnel 2>/dev/null || true
				rm -f /etc/init.d/wstunnel
			fi
		else
			if systemctl is-enabled wstunnel-server 2>/dev/null; then
				systemctl stop wstunnel-server 2>/dev/null || true
				systemctl disable wstunnel-server 2>/dev/null || true
				rm -f /etc/systemd/system/wstunnel-server.service
				systemctl daemon-reload
			fi
		fi
		rm -f /usr/local/bin/wstunnel
		rm -rf /etc/wstunnel

		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get remove -y wireguard wireguard-tools qrencode
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools qrencode
			if [[ ${VERSION_ID} -lt 32 ]]; then
				dnf remove -y --noautoremove wireguard-dkms
				dnf copr disable -y jdoss/wireguard
			fi
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools
			if [[ ${VERSION_ID} == 8* ]]; then
				yum remove --noautoremove kmod-wireguard qrencode
			fi
		elif [[ ${OS} == 'oracle' ]]; then
			yum remove --noautoremove wireguard-tools qrencode
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools qrencode
		elif [[ ${OS} == 'alpine' ]]; then
			(cd qrencode-4.1.1 || exit && make uninstall)
			rm -rf qrencode-* || exit
			apk del wireguard-tools libqrencode libqrencode-tools
		fi

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		if [[ ${OS} == 'alpine' ]]; then
			rc-service --quiet "wg-quick.${SERVER_WG_NIC}" status &>/dev/null
		else
			sysctl --system
			systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		fi
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo "WireGuard failed to uninstall properly."
			exit 1
		else
			echo "WireGuard uninstalled successfully."
			exit 0
		fi
	else
		echo ""
		echo "Removal aborted!"
	fi
}

function manageMenu() {
	echo "Welcome to WireGuard-install!"
	echo "The git repository is available at: https://github.com/angristan/wireguard-install"
	echo ""
	echo "It looks like WireGuard is already installed."
	echo ""
	if [[ ${ENABLE_OBFUSCATION} == "y" ]]; then
		echo -e "Traffic obfuscation: ${GREEN}ENABLED${NC} (HTTPS tunnel on port ${OBFUSCATION_PORT}/tcp)"
	else
		echo -e "Traffic obfuscation: ${ORANGE}DISABLED${NC}"
	fi
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
	1)
		newClient
		;;
	2)
		listClients
		;;
	3)
		revokeClient
		;;
	4)
		uninstallWg
		;;
	5)
		exit 0
		;;
	esac
}

# Check for root, virt, OS...
initialCheck

# Check if WireGuard is already installed and load params
if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
	ENABLE_IPV6=$(normalizeYesNo "${ENABLE_IPV6}")
	RESTRICTIVE_NETWORK_MODE=$(normalizeYesNo "${RESTRICTIVE_NETWORK_MODE}")
	if [[ -z ${RESTRICTIVE_NETWORK_MODE} ]]; then
		RESTRICTIVE_NETWORK_MODE="y"
	fi
	ENABLE_OBFUSCATION=$(normalizeYesNo "${ENABLE_OBFUSCATION}")
	if [[ -z ${ENABLE_OBFUSCATION} ]]; then
		ENABLE_OBFUSCATION="n"
	fi
	OBFUSCATION_PORT=${OBFUSCATION_PORT:-443}
	if [[ -z ${ENABLE_IPV6} ]]; then
		if [[ -n ${SERVER_WG_IPV6} ]]; then
			ENABLE_IPV6="y"
		else
			ENABLE_IPV6="n"
		fi
	fi
	CLIENT_MTU=${CLIENT_MTU:-1280}
	PERSISTENT_KEEPALIVE=${PERSISTENT_KEEPALIVE:-25}
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${PERSISTENT_KEEPALIVE} == "0" ]]; then
		PERSISTENT_KEEPALIVE=25
	fi
	ENABLE_MSS_CLAMP=$(normalizeYesNo "${ENABLE_MSS_CLAMP}")
	if [[ -z ${ENABLE_MSS_CLAMP} ]]; then
		ENABLE_MSS_CLAMP="y"
	fi
	ENABLE_NET_OPTIMIZATIONS=$(normalizeYesNo "${ENABLE_NET_OPTIMIZATIONS}")
	if [[ -z ${ENABLE_NET_OPTIMIZATIONS} ]]; then
		ENABLE_NET_OPTIMIZATIONS="y"
	fi
	if [[ -z ${ALLOWED_IPS} ]]; then
		if [[ ${ENABLE_IPV6} == "y" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		else
			ALLOWED_IPS="0.0.0.0/0"
		fi
	fi
	if [[ -n ${CLIENT_DNS_1} && -z ${CLIENT_DNS_2} ]]; then
		CLIENT_DNS_2="${CLIENT_DNS_1}"
	fi
	if [[ ${RESTRICTIVE_NETWORK_MODE} == "y" ]] && [[ ${CLIENT_DNS_1} == "1.1.1.1" && ${CLIENT_DNS_2} == "1.0.0.1" ]]; then
		CLIENT_DNS_1="9.9.9.9"
		CLIENT_DNS_2="8.8.8.8"
	fi
	manageMenu
else
	installWireGuard
fi
