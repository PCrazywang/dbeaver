#!/usr/bin/env bash
# =============================================================================
# DBeaver 取包与装配脚本 (取代原先的 Tycho 源码构建)
#
# 为什么不再从源码构建:
#   DBeaver 21.0.0 的 pom.xml 里 local-p2-repo.url 指向 https://dbeaver.io/
#   eclipse-repo, 该 p2 仓库已被官方下线 (HTTP 404), 里面是 21.0.0 需要的第三方
#   bundle。把它换成 repo.dbeaver.net/p2/ce/23.2.5/ 等于拿 2023 年的 bundle 去
#   满足 2021 年的版本约束, 于是 Tycho 目标平台解析报出各种依赖错误。
#   同时 Tycho 2.0.0 (2020) 不能在 GitHub runner 自带的 Maven 3.9.x 上运行。
#
#   而官方其实为 21.0.0 发布了 ARM64 二进制:
#     dbeaver-ce-21.0.0-linux.gtk.aarch64-nojdk.tar.gz
#   所以交叉构建根本没有必要。本脚本直接取官方两个架构的 nojdk 包 (校验和固定),
#   再植入固定版本的 Temurin 11 JRE, 两个架构因此拿到完全相同的 Java 版本。
#
# 用法: bash scripts/fetch-and-stage.sh <amd64|arm64>
# 产物: output/dbeaver-ce-<版本>-linux-gtk-<x86_64|aarch64>.tar.gz (内含 jre/)
# =============================================================================
set -euo pipefail

DBEAVER_VERSION="${DBEAVER_VERSION:-21.0.0}"
# Temurin 发布号。文件名里 '+' 写成 '_', release tag 里要 URL 编码成 %2B,
# 两种写法都从这一个变量派生, 不会出现两处版本号打架。
TEMURIN_RELEASE="${TEMURIN_RELEASE:-11.0.32.1+1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKSUM_FILE="${CHECKSUM_FILE:-${PROJECT_ROOT}/checksums/inputs.sha256}"
WORK_DIR="${WORK_DIR:-${PROJECT_ROOT}/build}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"
CACHE_DIR="${CACHE_DIR:-${WORK_DIR}/downloads}"

usage() {
    cat >&2 <<EOF
用法: $0 <amd64|arm64>

环境变量:
  DBEAVER_VERSION   DBeaver 版本 (默认 ${DBEAVER_VERSION})
  TEMURIN_RELEASE   Temurin JRE 发布号 (默认 ${TEMURIN_RELEASE})
  OUTPUT_DIR        产物目录 (默认 <repo>/output)
  WORK_DIR          工作目录 (默认 <repo>/build)
EOF
    exit 2
}

[ $# -eq 1 ] || usage

case "$1" in
    amd64|x86_64)  DEB_ARCH=amd64; DB_ARCH=x86_64;  JRE_ARCH=x64;     HOST_MACHINE=x86_64 ;;
    arm64|aarch64) DEB_ARCH=arm64; DB_ARCH=aarch64; JRE_ARCH=aarch64; HOST_MACHINE=aarch64 ;;
    *) echo "错误: 未知架构 '$1'" >&2; usage ;;
esac

DBEAVER_TARBALL="dbeaver-ce-${DBEAVER_VERSION}-linux.gtk.${DB_ARCH}-nojdk.tar.gz"
DBEAVER_URL="https://github.com/dbeaver/dbeaver/releases/download/${DBEAVER_VERSION}/${DBEAVER_TARBALL}"

# 文件名里的 '+' 是 '_', release tag 里要 URL 编码
JRE_TARBALL="OpenJDK11U-jre_${JRE_ARCH}_linux_hotspot_${TEMURIN_RELEASE//+/_}.tar.gz"
JRE_URL="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-${TEMURIN_RELEASE//+/%2B}/${JRE_TARBALL}"

echo "============================================================"
echo " DBeaver ${DBEAVER_VERSION} 装配 (${DEB_ARCH} / ${DB_ARCH})"
echo " JRE     : Temurin ${TEMURIN_RELEASE} (${JRE_ARCH})"
echo " 输出    : ${OUTPUT_DIR}"
echo "============================================================"

mkdir -p "${CACHE_DIR}" "${OUTPUT_DIR}"

[ -f "${CHECKSUM_FILE}" ] || { echo "错误: 找不到校验和文件 ${CHECKSUM_FILE}" >&2; exit 1; }

# 取包并对照 checksums/inputs.sha256 校验。校验和必须已经钉在文件里, 缺条目就
# 直接失败 —— 不允许"先下载再信任"。
fetch_verified() {
    local url="$1" name="$2" dest="${CACHE_DIR}/$2" expected actual

    expected="$(awk -v f="$name" '
        $0 !~ /^#/ {
            listed = $2
            sub(/^\*/, "", listed)
            if (listed == f) print $1
        }
    ' "${CHECKSUM_FILE}")"
    if [ -z "${expected}" ]; then
        echo "错误: ${CHECKSUM_FILE} 里没有 ${name} 的校验和条目。" >&2
        echo "      升级版本时请先把新文件的 sha256 写进该文件。" >&2
        exit 1
    fi

    if [ -f "${dest}" ] && [ "$(sha256sum "${dest}" | cut -d' ' -f1)" = "${expected}" ]; then
        echo "[缓存] ${name}"
        return 0
    fi

    echo "[下载] ${name}"
    rm -f "${dest}"
    curl --fail --location --retry 5 --retry-delay 5 --retry-connrefused \
        --connect-timeout 30 --output "${dest}" "${url}"

    actual="$(sha256sum "${dest}" | cut -d' ' -f1)"
    if [ "${actual}" != "${expected}" ]; then
        echo "错误: ${name} 校验和不符" >&2
        echo "      期望: ${expected}" >&2
        echo "      实际: ${actual}" >&2
        exit 1
    fi
    echo "[校验] ${name} sha256 通过"
}

fetch_verified "${DBEAVER_URL}" "${DBEAVER_TARBALL}"
fetch_verified "${JRE_URL}" "${JRE_TARBALL}"

STAGE="${WORK_DIR}/stage-${DEB_ARCH}"
APP="${STAGE}/dbeaver"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"

echo "[装配] 解包 DBeaver ..."
tar -xzf "${CACHE_DIR}/${DBEAVER_TARBALL}" -C "${STAGE}"

# 固定的官方输入应当只有 dbeaver/ 一个顶层目录；布局变化必须显式处理，
# 不能猜测并移动 find 返回的第一个目录。
TOP_LEVEL="$(find "${STAGE}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"
if [ "${TOP_LEVEL}" != "dbeaver" ] || [ ! -d "${APP}" ]; then
    echo "错误: DBeaver 包应当只包含一个 dbeaver/ 顶层目录，实际为:" >&2
    printf '%s\n' "${TOP_LEVEL}" >&2
    exit 1
fi

# Eclipse 启动器在自身所在目录下找 jre/ 作为 JVM (在 -vm 与 PATH 之间的那一步),
# 所以 JRE 放到这里, dbeaver.ini 一行都不用改。
echo "[装配] 植入 Temurin JRE ..."
mkdir -p "${APP}/jre"
tar -xzf "${CACHE_DIR}/${JRE_TARBALL}" -C "${APP}/jre" --strip-components=1

echo "[检查] 结构与架构 ..."
test -f "${APP}/dbeaver"
test -f "${APP}/dbeaver.ini"
test -d "${APP}/plugins"
test -d "${APP}/features"
test -x "${APP}/jre/bin/java"
chmod +x "${APP}/dbeaver"

# 确认取到的确实是本架构的包: 启动器 ELF 机器类型 + 对应架构的 SWT/启动器 fragment
case "${DB_ARCH}" in
    x86_64)  ELF_RE='x86-64|X86-64' ;;
    aarch64) ELF_RE='aarch64|AArch64' ;;
esac
if command -v readelf >/dev/null 2>&1; then
    if ! ELF_DESC="$(readelf -h "${APP}/dbeaver" 2>&1)"; then
        echo "错误: DBeaver 启动器不是有效的 ELF 文件" >&2
        printf '%s\n' "${ELF_DESC}" >&2
        exit 1
    fi
    ELF_DESC="$(printf '%s\n' "${ELF_DESC}" | grep 'Machine:')"
elif command -v file >/dev/null 2>&1; then
    ELF_DESC="$(file "${APP}/dbeaver")"
    if [[ "${ELF_DESC}" != *ELF* ]]; then
        echo "错误: DBeaver 启动器不是 ELF 文件: ${ELF_DESC}" >&2
        exit 1
    fi
else
    echo "错误: 需要 readelf 或 file 来确认启动器架构" >&2
    exit 1
fi
if ! printf '%s\n' "${ELF_DESC}" | grep -qE "${ELF_RE}"; then
    echo "错误: 启动器架构与 ${DB_ARCH} 不符: ${ELF_DESC}" >&2
    exit 1
fi
echo "  启动器: ${ELF_DESC}"

for frag in "org.eclipse.swt.gtk.linux.${DB_ARCH}_" "org.eclipse.equinox.launcher.gtk.linux.${DB_ARCH}_"; do
    if [ -z "$(find "${APP}/plugins" -maxdepth 1 -name "${frag}*" -print -quit)" ]; then
        echo "错误: 缺少 ${DB_ARCH} 的 fragment ${frag}*" >&2
        exit 1
    fi
done
echo "  SWT / 启动器 fragment: ${DB_ARCH} 已就位"

JRE_VERSION_LINE="openjdk version \"${TEMURIN_RELEASE%%+*}\""
# 只有在本机架构与目标一致时才执行 JRE，确认固定版本确实可启动；写入溯源文件的
# 版本字符串由 TEMURIN_RELEASE 派生，避免不同构建主机造成内容差异。
case "$(uname -m)" in
    x86_64|amd64) HOST_ARCH=x86_64 ;;
    aarch64|arm64) HOST_ARCH=aarch64 ;;
    *) HOST_ARCH="$(uname -m)" ;;
esac
if [ "${HOST_ARCH}" = "${HOST_MACHINE}" ]; then
    if ! ACTUAL_JRE_OUTPUT="$("${APP}/jre/bin/java" -version 2>&1)"; then
        echo "错误: 包内 JRE 无法执行" >&2
        printf '%s\n' "${ACTUAL_JRE_OUTPUT}" >&2
        exit 1
    fi
    ACTUAL_JRE_VERSION_LINE="$(printf '%s\n' "${ACTUAL_JRE_OUTPUT}" | sed -n '1p')"
    if [[ "${ACTUAL_JRE_VERSION_LINE}" != *"${TEMURIN_RELEASE%%+*}"* ]]; then
        echo "错误: JRE 版本与 ${TEMURIN_RELEASE} 不符: ${ACTUAL_JRE_VERSION_LINE}" >&2
        exit 1
    fi
    echo "  JRE: ${ACTUAL_JRE_VERSION_LINE}"
fi

# 产物自带一份构建溯源；只写入由固定输入和提交决定的内容，避免构建时间、
# runner 内核等环境噪声让相同源码产生不同的包内元数据。
cat > "${APP}/BUILD-ENVIRONMENT.txt" <<EOF
package_platform=linux-${DEB_ARCH}
dbeaver_version=${DBEAVER_VERSION}
dbeaver_source=${DBEAVER_TARBALL} (官方发布, sha256 已固定)
dbeaver_source_url=${DBEAVER_URL}
jre=Temurin ${TEMURIN_RELEASE} (${JRE_ARCH}, sha256 已固定)
jre_source_url=${JRE_URL}
jre_version=${JRE_VERSION_LINE}
target_arch=${DB_ARCH}
install_prefix=${INSTALL_PREFIX:-/opt/dbeaver}
git_commit=${GITHUB_SHA:-$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)}
EOF

TARBALL="${OUTPUT_DIR}/dbeaver-ce-${DBEAVER_VERSION}-linux-gtk-${DB_ARCH}.tar.gz"
echo "[打包] ${TARBALL}"
rm -f "${TARBALL}"
tar -czf "${TARBALL}" -C "${STAGE}" dbeaver
tar -tzf "${TARBALL}" >/dev/null

echo "============================================================"
echo " 装配完成: $(basename "${TARBALL}") ($(du -h "${TARBALL}" | cut -f1))"
echo " 安装树:   ${APP}"
echo "============================================================"
cat "${APP}/BUILD-ENVIRONMENT.txt"
