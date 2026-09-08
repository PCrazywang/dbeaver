#!/usr/bin/env bash
# 将 scripts/fetch-and-stage.sh 产出的 tar.gz 转成 Debian 包。
set -euo pipefail

DBEAVER_VERSION="${DBEAVER_VERSION:-21.0.0}"
MAINTAINER="${MAINTAINER:-DBeaver Builder <builder@local>}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/dbeaver}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${PROJECT_ROOT}/debian"
DEFAULT_OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"

usage() {
    cat >&2 <<EOF
用法: $0 <tarball-path> [output-dir]

  tarball-path  dbeaver-ce-<版本>-linux-gtk-<x86_64|aarch64>.tar.gz
  output-dir    .deb 输出目录 (默认 <repo>/output)
EOF
    exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
TARBALL="$(realpath "$1")"
OUTPUT_DIR="${2:-${DEFAULT_OUTPUT_DIR}}"
[ -f "${TARBALL}" ] || { echo "错误: 找不到 ${TARBALL}" >&2; exit 1; }
case "${INSTALL_PREFIX}" in
    /*) ;;
    *) echo "错误: INSTALL_PREFIX 必须是绝对路径: ${INSTALL_PREFIX}" >&2; exit 1 ;;
esac
if [[ "${INSTALL_PREFIX}" == *"'"* ||
      "${INSTALL_PREFIX}" == *$'\n'* ||
      "${INSTALL_PREFIX}" == *$'\r'* ]]; then
    echo "错误: INSTALL_PREFIX 不能包含单引号或换行符" >&2
    exit 1
fi
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"

case "$(basename "${TARBALL}")" in
    "dbeaver-ce-${DBEAVER_VERSION}-linux-gtk-x86_64.tar.gz")
        DEB_ARCH=amd64; ELF_RE='x86-64|X86-64' ;;
    "dbeaver-ce-${DBEAVER_VERSION}-linux-gtk-aarch64.tar.gz")
        DEB_ARCH=arm64; ELF_RE='aarch64|AArch64' ;;
    *)
        echo "错误: 文件名必须与版本和目标架构完全匹配: $(basename "${TARBALL}")" >&2
        exit 1
        ;;
esac

for path in control.in dbeaver.wrapper.in dbeaver.desktop postinst postrm; do
    [ -f "${TEMPLATE_DIR}/${path}" ] || {
        echo "错误: 缺少 Debian 模板 ${TEMPLATE_DIR}/${path}" >&2
        exit 1
    }
done

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dbeaver-deb-XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

mkdir -p \
    "${STAGING_DIR}/DEBIAN" \
    "${STAGING_DIR}${INSTALL_PREFIX}" \
    "${STAGING_DIR}/usr/bin" \
    "${STAGING_DIR}/usr/share/applications" \
    "${STAGING_DIR}/usr/share/icons/hicolor/128x128/apps" \
    "${STAGING_DIR}/usr/share/doc/dbeaver-ce"

echo "[解包] $(basename "${TARBALL}") -> ${INSTALL_PREFIX}"
tar -xzf "${TARBALL}" -C "${STAGING_DIR}${INSTALL_PREFIX}" --strip-components=1
APP="${STAGING_DIR}${INSTALL_PREFIX}"

test -x "${APP}/dbeaver"
test -f "${APP}/dbeaver.ini"
test -d "${APP}/plugins"
test -d "${APP}/features"
test -x "${APP}/jre/bin/java"

if command -v readelf >/dev/null 2>&1; then
    if ! APP_ELF_DESC="$(readelf -h "${APP}/dbeaver" 2>&1)"; then
        echo "错误: DBeaver 启动器不是有效的 ELF 文件" >&2
        printf '%s\n' "${APP_ELF_DESC}" >&2
        exit 1
    fi
    if ! JRE_ELF_DESC="$(readelf -h "${APP}/jre/bin/java" 2>&1)"; then
        echo "错误: 包内 JRE 不是有效的 ELF 文件" >&2
        printf '%s\n' "${JRE_ELF_DESC}" >&2
        exit 1
    fi
    APP_ELF_DESC="$(printf '%s\n' "${APP_ELF_DESC}" | grep 'Machine:')"
    JRE_ELF_DESC="$(printf '%s\n' "${JRE_ELF_DESC}" | grep 'Machine:')"
elif command -v file >/dev/null 2>&1; then
    APP_ELF_DESC="$(file "${APP}/dbeaver")"
    JRE_ELF_DESC="$(file "${APP}/jre/bin/java")"
    for description in "${APP_ELF_DESC}" "${JRE_ELF_DESC}"; do
        if [[ "${description}" != *ELF* ]]; then
            echo "错误: 包内原生文件不是 ELF: ${description}" >&2
            exit 1
        fi
    done
else
    echo "错误: 需要 readelf 或 file 来确认包内架构" >&2
    exit 1
fi
for entry in "启动器:${APP_ELF_DESC}" "JRE:${JRE_ELF_DESC}"; do
    label="${entry%%:*}"
    description="${entry#*:}"
    printf '  %s: %s\n' "${label}" "${description}"
    if ! printf '%s\n' "${description}" | grep -qE "${ELF_RE}"; then
        echo "错误: ${label} 与目标架构 ${DEB_ARCH} 不一致" >&2
        exit 1
    fi
done

# /usr/bin/dbeaver 明确指定包内 JRE，桌面入口也调用这个包装脚本。
escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|]/\\&/g'
}
SED_INSTALL_PREFIX="$(escape_sed_replacement "${INSTALL_PREFIX}")"
sed "s|@INSTALL_PREFIX@|${SED_INSTALL_PREFIX}|g" \
    "${TEMPLATE_DIR}/dbeaver.wrapper.in" > "${STAGING_DIR}/usr/bin/dbeaver"
chmod 0755 "${STAGING_DIR}/usr/bin/dbeaver"

install -m 0644 "${TEMPLATE_DIR}/dbeaver.desktop" \
    "${STAGING_DIR}/usr/share/applications/dbeaver.desktop"
chmod 0644 "${STAGING_DIR}/usr/share/applications/dbeaver.desktop"

# 21.0.0 官方包的根目录通常有 icon.xpm。若没有，尝试 core plugin 的 PNG。
if [ -f "${APP}/icon.xpm" ]; then
    install -m 0644 "${APP}/icon.xpm" \
        "${STAGING_DIR}/usr/share/icons/hicolor/128x128/apps/dbeaver.xpm"
else
    ICON="$(find "${APP}/plugins" -path '*/icons/dbeaver.png' -print -quit)"
    if [ -n "${ICON}" ]; then
        install -m 0644 "${ICON}" \
            "${STAGING_DIR}/usr/share/icons/hicolor/128x128/apps/dbeaver.png"
    fi
fi

install -m 0755 "${TEMPLATE_DIR}/postinst" "${STAGING_DIR}/DEBIAN/postinst"
install -m 0755 "${TEMPLATE_DIR}/postrm" "${STAGING_DIR}/DEBIAN/postrm"

cat > "${STAGING_DIR}/usr/share/doc/dbeaver-ce/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DBeaver Community Edition
Source: https://github.com/dbeaver/dbeaver
Files: *
Copyright: 2010-2021 DBeaver Corp and contributors
License: Apache-2.0
 On Debian systems the complete Apache 2.0 license text is available at
 /usr/share/common-licenses/Apache-2.0.
EOF

INSTALLED_SIZE="$(du -sk "${STAGING_DIR}" | cut -f1)"
SED_VERSION="$(escape_sed_replacement "${DBEAVER_VERSION}")"
SED_MAINTAINER="$(escape_sed_replacement "${MAINTAINER}")"
sed \
    -e "s|@PACKAGE@|dbeaver-ce|g" \
    -e "s|@VERSION@|${SED_VERSION}|g" \
    -e "s|@ARCH@|${DEB_ARCH}|g" \
    -e "s|@MAINTAINER@|${SED_MAINTAINER}|g" \
    -e "s|@INSTALLED_SIZE@|${INSTALLED_SIZE}|g" \
    "${TEMPLATE_DIR}/control.in" > "${STAGING_DIR}/DEBIAN/control"

# Debian 控制文件拒绝组可写；应用文件保持上游的可执行位，不做全树 chmod +x。
find "${STAGING_DIR}" -type d -exec chmod 0755 {} +
find "${STAGING_DIR}" -type f -exec chmod go-w {} +

DEB_FILE="${OUTPUT_DIR}/dbeaver-ce_${DBEAVER_VERSION}_${DEB_ARCH}.deb"
echo "[打包] ${DEB_FILE}"
rm -f "${DEB_FILE}"
# Debian 10 的 dpkg-deb 不支持 control.tar.zst；显式使用 gzip，保证 UOS 20 /
# Debian 10 可以安装由新版 Ubuntu runner 构建的包。
dpkg-deb --build --root-owner-group --compression=gzip "${STAGING_DIR}" "${DEB_FILE}"
dpkg-deb --info "${DEB_FILE}" >/dev/null
CONTENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/dbeaver-contents-XXXXXX")"
ARCHIVE_FILE="$(mktemp "${TMPDIR:-/tmp}/dbeaver-archive-XXXXXX")"
dpkg-deb --contents "${DEB_FILE}" > "${CONTENTS_FILE}"
ar t "${DEB_FILE}" > "${ARCHIVE_FILE}"
grep -qx 'control.tar.gz' "${ARCHIVE_FILE}"
grep -qx 'data.tar.gz' "${ARCHIVE_FILE}"
grep -qE '^[-[:alnum:]]+[[:space:]].*[[:space:]][.]/usr/bin/dbeaver$' "${CONTENTS_FILE}"
rm -f "${CONTENTS_FILE}" "${ARCHIVE_FILE}"

echo "[完成] $(basename "${DEB_FILE}") ($(du -h "${DEB_FILE}" | cut -f1))"
