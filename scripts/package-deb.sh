#!/usr/bin/env bash
# =============================================================================
# DBeaver tar.gz -> .deb 打包脚本
# 兼容: UOS 20 (Debian 10 系) / Ubuntu 18.04+ / Debian 10+
# 架构: amd64 (x86_64) / arm64 (aarch64)
# =============================================================================
set -euo pipefail

DBEAVER_VERSION="${DBEAVER_VERSION:-21.0.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
MAINTAINER="${MAINTAINER:-DBeaver Builder <builder@local>}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/dbeaver}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEBIAN_TEMPLATE_DIR="${PROJECT_ROOT}/debian"

usage() {
    cat <<EOF
Usage: $0 <tarball-path> [output-dir]

  tarball-path : Path to dbeaver-ce-<version>-linux-gtk-<arch>.tar.gz
  output-dir   : Directory to place the .deb (default: ${OUTPUT_DIR})

Environment variables:
  DBEAVER_VERSION  - DBeaver version (default: 21.0.0)
  MAINTAINER       - Package maintainer string
  INSTALL_PREFIX   - Install location (default: /opt/dbeaver)
EOF
    exit 1
}

[ $# -lt 1 ] && usage
TARBALL="$(realpath "$1")"
OUTPUT_DIR="${2:-${OUTPUT_DIR}}"
mkdir -p "${OUTPUT_DIR}"

[ ! -f "${TARBALL}" ] && { echo "ERROR: Tarball not found: ${TARBALL}"; exit 1; }

# ---- 从文件名推断架构 ----
BASENAME="$(basename "${TARBALL}")"
if echo "${BASENAME}" | grep -qi "x86_64\|amd64"; then
    ARCH="amd64"
    ARCH_LONG="x86_64"
elif echo "${BASENAME}" | grep -qi "aarch64\|arm64"; then
    ARCH="arm64"
    ARCH_LONG="aarch64"
else
    echo "ERROR: Cannot determine architecture from filename: ${BASENAME}"
    exit 1
fi

echo "============================================================"
echo " Packaging DBeaver ${DBEAVER_VERSION} (${ARCH})"
echo " Tarball : ${TARBALL}"
echo " Output  : ${OUTPUT_DIR}"
echo " Prefix  : ${INSTALL_PREFIX}"
echo "============================================================"

# ---- 创建临时打包目录 ----
PKG_NAME="dbeaver-ce"
PKG_VERSION="${DBEAVER_VERSION}"
PKG_ARCH="${ARCH}"
STAGING_DIR="$(mktemp -d /tmp/dbeaver-deb-XXXXXX)"
trap "rm -rf ${STAGING_DIR}" EXIT

echo "[1/6] Creating directory skeleton..."
mkdir -p "${STAGING_DIR}/DEBIAN"
mkdir -p "${STAGING_DIR}${INSTALL_PREFIX}"
mkdir -p "${STAGING_DIR}/usr/bin"
mkdir -p "${STAGING_DIR}/usr/share/applications"
mkdir -p "${STAGING_DIR}/usr/share/icons/hicolor/128x128/apps"
mkdir -p "${STAGING_DIR}/usr/share/doc/${PKG_NAME}"

# ---- 解压 DBeaver ----
echo "[2/6] Extracting DBeaver to ${INSTALL_PREFIX}..."
tar -xzf "${TARBALL}" -C "${STAGING_DIR}${INSTALL_PREFIX}" --strip-components=1

# 验证可执行文件存在
if [ ! -f "${STAGING_DIR}${INSTALL_PREFIX}/dbeaver" ]; then
    echo "ERROR: dbeaver executable not found after extraction"
    ls -la "${STAGING_DIR}${INSTALL_PREFIX}/"
    exit 1
fi

# 确保可执行权限
chmod +x "${STAGING_DIR}${INSTALL_PREFIX}/dbeaver"
chmod +x "${STAGING_DIR}${INSTALL_PREFIX}/dbeaver.ini" 2>/dev/null || true

# ---- 创建 DEBIAN/control ----
echo "[3/6] Generating DEBIAN/control..."
INSTALLED_SIZE=$(du -sk "${STAGING_DIR}${INSTALL_PREFIX}" | cut -f1)

cat > "${STAGING_DIR}/DEBIAN/control" <<CTRL
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: ${PKG_ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0, libglib2.0-0, libpango-1.0-0, libcairo2, libxtst6, libxss1, libgtk2.0-0 | libgtk-3-0, default-jre | openjdk-11-jre | java11-runtime
Section: devel
Priority: optional
Homepage: https://dbeaver.io/
Description: Universal database manager and SQL client
 DBeaver is a free multi-platform database tool for developers,
 SQL programmers, analysts and DBAs. It supports all popular
 databases: MySQL, PostgreSQL, SQLite, Oracle, DB2, SQL Server,
 Sybase, MS Access, Teradata, Firebird, Apache Hive, Phoenix,
 Presto, etc.
 .
 This package is built for UOS 20 / Debian / Ubuntu (${ARCH}).
 Bundled with OpenJDK 11 runtime.
CTRL

# ---- 创建 postinst / postrm ----
echo "[4/6] Creating maintainer scripts..."

cat > "${STAGING_DIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

# 创建符号链接
if [ ! -e /usr/bin/dbeaver ]; then
    ln -sf /opt/dbeaver/dbeaver /usr/bin/dbeaver
fi

# 更新桌面数据库
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi

# 更新图标缓存
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

# UOS 20 兼容: 确保 mime 数据库更新
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime >/dev/null 2>&1 || true
fi

exit 0
POSTINST

cat > "${STAGING_DIR}/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    rm -f /usr/bin/dbeaver

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications || true
    fi

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
    fi
fi

exit 0
POSTRM

chmod 755 "${STAGING_DIR}/DEBIAN/postinst"
chmod 755 "${STAGING_DIR}/DEBIAN/postrm"

# ---- 桌面入口与图标 ----
echo "[5/6] Installing desktop entry and icons..."

# 从 DBeaver 安装目录提取图标
ICON_SRC="${STAGING_DIR}${INSTALL_PREFIX}/icon.xpm"
if [ -f "${ICON_SRC}" ]; then
    cp "${ICON_SRC}" "${STAGING_DIR}/usr/share/icons/hicolor/128x128/apps/dbeaver.xpm"
fi
# 尝试其他图标路径
for icon in "${STAGING_DIR}${INSTALL_PREFIX}/plugins/org.jkiss.dbeaver.core_"*/icons/dbeaver.png; do
    if [ -f "${icon}" ]; then
        cp "${icon}" "${STAGING_DIR}/usr/share/icons/hicolor/128x128/apps/dbeaver.png"
        break
    fi
done

cat > "${STAGING_DIR}/usr/share/applications/dbeaver.desktop" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=DBeaver
GenericName=Database Manager
Comment=Universal Database Manager and SQL Client
Exec=${INSTALL_PREFIX}/dbeaver %u
Icon=dbeaver
Terminal=false
Categories=Development;IDE;Database;
StartupNotify=true
StartupWMClass=DBeaver
MimeType=application/x-sql;text/x-sql;
Keywords=database;sql;ide;
DESKTOP

# ---- 版权说明 ----
cat > "${STAGING_DIR}/usr/share/doc/${PKG_NAME}/copyright" <<'COPYRIGHT'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DBeaver Community Edition
Upstream-Contact: https://github.com/dbeaver/dbeaver
Source: https://github.com/dbeaver/dbeaver

Files: *
Copyright: 2010-2021 Serge Rider (serge@dbeaver.com)
License: Apache-2.0

License: Apache-2.0
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 .
   http://www.apache.org/licenses/LICENSE-2.0
 .
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
COPYRIGHT

# ---- 打包 ----
echo "[6/6] Building .deb package..."
DEB_FILE="${OUTPUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"

# 修复权限
find "${STAGING_DIR}" -type d -exec chmod 755 {} \;
find "${STAGING_DIR}" -type f -exec chmod go-w {} \;

dpkg-deb --build --root-owner-group "${STAGING_DIR}" "${DEB_FILE}"

echo "============================================================"
echo " Package created: ${DEB_FILE}"
echo " Size: $(du -h "${DEB_FILE}" | cut -f1)"
echo "============================================================"

# 输出包信息
echo ""
echo "Package info:"
dpkg-deb --info "${DEB_FILE}" 2>/dev/null || echo "(dpkg-deb info not available)"
