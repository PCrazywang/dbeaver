#!/usr/bin/env bash
# =============================================================================
# DBeaver .deb 远程部署脚本 (SSH)
# 用于将构建好的 deb 包通过 SSH 部署到 UOS 20 / Ubuntu / Debian 目标机
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"

# ---- 默认配置 ----
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_HOST="${SSH_HOST:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=15}"
REMOTE_TMP="${REMOTE_TMP:-/tmp/dbeaver-deploy}"
INSTALL_ONLY="${INSTALL_ONLY:-false}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
    cat <<EOF
Usage: $0 [options] <deb-file>

Deploy DBeaver .deb package to remote host via SSH.

Options:
  -h, --host <host>        Target hostname or IP (required)
  -u, --user <user>        SSH username (default: root)
  -p, --port <port>        SSH port (default: 22)
  -i, --key <path>         SSH private key path
  -t, --tmp <path>         Remote temp directory (default: /tmp/dbeaver-deploy)
  --install-only           Skip upload, install already-uploaded deb
  --dry-run                Print commands without executing
  -h, --help               Show this help

Environment variables:
  SSH_HOST, SSH_USER, SSH_PORT, SSH_KEY can also be set via env.

Examples:
  # Deploy amd64 package to UOS 20 server
  $0 --host 192.168.1.100 --user uos output/dbeaver-ce_21.0.0_amd64.deb

  # Deploy arm64 package with key auth
  $0 --host arm-server.local -i ~/.ssh/id_rsa output/dbeaver-ce_21.0.0_arm64.deb

  # Use environment variables
  SSH_HOST=10.0.0.5 SSH_USER=admin SSH_PORT=2222 $0 output/dbeaver-ce_21.0.0_amd64.deb
EOF
    exit 0
}

# ---- 解析参数 ----
DEB_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host)   SSH_HOST="$2"; shift 2 ;;
        -u|--user)   SSH_USER="$2"; shift 2 ;;
        -p|--port)   SSH_PORT="$2"; shift 2 ;;
        -i|--key)    SSH_KEY="$2"; shift 2 ;;
        -t|--tmp)    REMOTE_TMP="$2"; shift 2 ;;
        --install-only) INSTALL_ONLY="true"; shift ;;
        --dry-run)   DRY_RUN="true"; shift ;;
        --help)      usage ;;
        -*)          echo "Unknown option: $1"; usage ;;
        *)           DEB_FILE="$1"; shift ;;
    esac
done

if [ -z "${SSH_HOST}" ]; then
    echo "ERROR: Target host is required. Use --host or set SSH_HOST."
    exit 1
fi

if [ "${INSTALL_ONLY}" != "true" ]; then
    if [ -z "${DEB_FILE}" ]; then
        echo "ERROR: .deb file path is required (or use --install-only)"
        exit 1
    fi
    if [ ! -f "${DEB_FILE}" ]; then
        # 尝试在 output 目录查找
        if [ -f "${OUTPUT_DIR}/${DEB_FILE}" ]; then
            DEB_FILE="${OUTPUT_DIR}/${DEB_FILE}"
        else
            echo "ERROR: .deb file not found: ${DEB_FILE}"
            exit 1
        fi
    fi
fi

# 构建 SSH 命令前缀
SSH_CMD="ssh ${SSH_OPTS} -p ${SSH_PORT}"
if [ -n "${SSH_KEY}" ]; then
    SSH_CMD="${SSH_CMD} -i ${SSH_KEY}"
fi
SSH_TARGET="${SSH_USER}@${SSH_HOST}"

SCP_CMD="scp ${SSH_OPTS} -P ${SSH_PORT}"
if [ -n "${SSH_KEY}" ]; then
    SCP_CMD="${SCP_CMD} -i ${SSH_KEY}"
fi

run_remote() {
    local desc="$1"; shift
    echo "[REMOTE] ${desc}"
    echo "         \$ $*"
    if [ "${DRY_RUN}" != "true" ]; then
        ${SSH_CMD} "${SSH_TARGET}" "$@"
    fi
}

echo "============================================================"
echo " DBeaver Remote Deployment"
echo " Target : ${SSH_TARGET} (port ${SSH_PORT})"
echo " Package: ${DEB_FILE:-<install-only>}"
echo " Mode   : $([ "${DRY_RUN}" = "true" ] && echo 'DRY-RUN' || echo 'LIVE')"
echo "============================================================"

# ---- 1. 检测远程系统 ----
echo ""
echo "[1/5] Detecting remote system..."
OS_INFO=$(run_remote "Detect OS" "cat /etc/os-release 2>/dev/null | grep -E '^(NAME|VERSION|ID)=' || echo 'unknown'")
echo "${OS_INFO}"

ARCH_INFO=$(run_remote "Detect architecture" "dpkg --print-architecture 2>/dev/null || uname -m")
echo "Remote arch: ${ARCH_INFO}"

# ---- 2. 上传 deb 包 ----
if [ "${INSTALL_ONLY}" != "true" ]; then
    echo ""
    echo "[2/5] Uploading package to remote..."
    run_remote "Create temp dir" "mkdir -p ${REMOTE_TMP}"

    REMOTE_DEB="${REMOTE_TMP}/$(basename "${DEB_FILE}")"
    echo "[UPLOAD] scp ${DEB_FILE} -> ${SSH_TARGET}:${REMOTE_DEB}"
    if [ "${DRY_RUN}" != "true" ]; then
        ${SCP_CMD} "${DEB_FILE}" "${SSH_TARGET}:${REMOTE_DEB}"
    fi
    echo "[OK] Upload complete"
else
    REMOTE_DEB="${REMOTE_TMP}/$(basename "${DEB_FILE:-dbeaver-ce.deb}")"
    echo ""
    echo "[2/5] Install-only mode, skipping upload"
    echo "       Expected remote path: ${REMOTE_DEB}"
fi

# ---- 3. 安装 deb 包 ----
echo ""
echo "[3/5] Installing DBeaver on remote..."

INSTALL_SCRIPT=$(cat <<REMOTE_EOF
set -e
echo "  -> Installing ${REMOTE_DEB}"
sudo dpkg -i "${REMOTE_DEB}" || {
    echo "  -> dpkg reported missing dependencies, fixing..."
    sudo apt-get update -qq
    sudo apt-get install -f -y
    sudo dpkg -i "${REMOTE_DEB}"
}
echo "  -> Installation complete"
REMOTE_EOF
)
run_remote "Install .deb (with dependency fix)" "${INSTALL_SCRIPT}"

# ---- 4. 验证安装 ----
echo ""
echo "[4/5] Verifying installation..."

VERIFY_SCRIPT=$(cat <<REMOTE_EOF
echo "  -> Package status:"
dpkg -l dbeaver-ce 2>/dev/null | tail -1 || echo "     (not found in dpkg)"
echo "  -> Binary location:"
which dbeaver 2>/dev/null || ls -la /opt/dbeaver/dbeaver 2>/dev/null || echo "     (not found)"
echo "  -> Version check:"
/opt/dbeaver/dbeaver --version 2>/dev/null || echo "     (version check skipped - GUI app)"
echo "  -> Installed size:"
du -sh /opt/dbeaver 2>/dev/null || echo "     (unknown)"
REMOTE_EOF
)
run_remote "Verify DBeaver installation" "${VERIFY_SCRIPT}"

# ---- 5. 清理 ----
echo ""
echo "[5/5] Cleaning up remote temp files..."
run_remote "Remove temp directory" "rm -rf ${REMOTE_TMP}"

echo ""
echo "============================================================"
echo " Deployment complete!"
echo " Target: ${SSH_TARGET}"
echo " DBeaver installed at: /opt/dbeaver"
echo " Launch command: dbeaver &"
echo "============================================================"
