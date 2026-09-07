#!/usr/bin/env bash
# =============================================================================
# DBeaver 21.0.0 多架构构建脚本
# 支持架构: linux.gtk.x86_64 (amd64) / linux.gtk.aarch64 (arm64)
# 目标系统: UOS 20 (Debian 10 系) / Ubuntu 18.04+
# =============================================================================
set -euo pipefail

# ---- 可配置变量 ----
DBEAVER_VERSION="${DBEAVER_VERSION:-21.0.0}"
DBEAVER_REPO="${DBEAVER_REPO:-https://github.com/dbeaver/dbeaver.git}"
WORK_DIR="${WORK_DIR:-$(pwd)/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
MAVEN_OPTS="${MAVEN_OPTS:--Xmx2g -XX:+UseG1GC}"
SKIP_TESTS="${SKIP_TESTS:-true}"
# --------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "============================================================"
echo " DBeaver ${DBEAVER_VERSION} Multi-Arch Build"
echo " WorkDir : ${WORK_DIR}"
echo " Output  : ${OUTPUT_DIR}"
echo "============================================================"

# ---- 前置检查 ----
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found"; exit 1; }
command -v mvn >/dev/null 2>&1 || { echo "ERROR: maven not found"; exit 1; }
command -v java >/dev/null 2>&1 || { echo "ERROR: java not found"; exit 1; }

JAVA_VER=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
echo "[INFO] Java version: ${JAVA_VER}"
if [ "${JAVA_VER}" -lt 11 ]; then
    echo "ERROR: DBeaver 21.x requires Java 11+ to build. Current: ${JAVA_VER}"
    exit 1
fi

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

# ---- 1. 克隆源码 ----
SRC_DIR="${WORK_DIR}/dbeaver-src"
if [ -d "${SRC_DIR}/.git" ]; then
    echo "[1/5] Source already exists, fetching latest tag..."
    cd "${SRC_DIR}"
    git fetch --tags --depth 1 origin "refs/tags/${DBEAVER_VERSION}:refs/tags/${DBEAVER_VERSION}" 2>/dev/null || true
    git checkout -f "${DBEAVER_VERSION}"
else
    echo "[1/5] Cloning DBeaver ${DBEAVER_VERSION}..."
    git clone --branch "${DBEAVER_VERSION}" --depth 1 "${DBEAVER_REPO}" "${SRC_DIR}"
fi

# ---- 2. 修改 pom.xml: 仅保留 Linux x86_64 + aarch64 目标环境 ----
echo "[2/5] Patching pom.xml for Linux-only dual-arch build..."
cd "${SRC_DIR}"

python3 - <<'PYEOF'
import re, sys

with open("pom.xml", "r", encoding="utf-8") as f:
    content = f.read()

# 替换默认 build 段中的 environments (3 平台 -> Linux 双架构)
old_envs = """<environments>
<environment>
<os>win32</os>
<ws>win32</ws>
<arch>x86_64</arch>
</environment>
<environment>
<os>linux</os>
<ws>gtk</ws>
<arch>x86_64</arch>
</environment>
<environment>
<os>macosx</os>
<ws>cocoa</ws>
<arch>x86_64</arch>
</environment>
</environments>"""

new_envs = """<environments>
<environment>
<os>linux</os>
<ws>gtk</ws>
<arch>x86_64</arch>
</environment>
<environment>
<os>linux</os>
<ws>gtk</ws>
<arch>aarch64</arch>
</environment>
</environments>"""

if old_envs in content:
    content = content.replace(old_envs, new_envs)
    print("[PATCH] Replaced default environments -> Linux x86_64 + aarch64")
else:
    # 尝试更宽松的匹配 (可能有空格差异)
    pattern = r"<environments>.*?</environments>"
    match = re.search(pattern, content, re.DOTALL)
    if match:
        content = content[:match.start()] + new_envs + content[match.end():]
        print("[PATCH] Replaced environments via regex -> Linux x86_64 + aarch64")
    else:
        print("[WARN] Could not find environments block, keeping original")

# 替换已失效的 DBeaver p2 仓库地址
# 21.0.0 时代的 https://dbeaver.io/eclipse-repo 已被官方下线
# 替代方案: 使用 dbeaver-deps-ce 构建的版本化 p2仓库
# 注意: 23.2.5 的依赖版本比 21.0.0 新, 但第三方库通常向后兼容
OLD_P2_REPO = "https://dbeaver.io/eclipse-repo"
NEW_P2_REPO = "https://repo.dbeaver.net/p2/ce/23.2.5/"
if OLD_P2_REPO in content:
    content = content.replace(OLD_P2_REPO, NEW_P2_REPO)
    print("[PATCH] Replaced p2 repo URL: {} -> {}".format(OLD_P2_REPO, NEW_P2_REPO))
else:
    print("[WARN] Could not find old p2 repo URL: {}".format(OLD_P2_REPO))

with open("pom.xml", "w", encoding="utf-8") as f:
    f.write(content)
print("[PATCH] pom.xml updated successfully")
PYEOF

# ---- 2.5. 注入第三方 bundle (从官方 x86_64 二进制包提取) ----
# 23.2.5 的 p2 仓库不包含 21.0.0 需要的旧版第三方依赖 (如 net.sf.opencsv)
# 从官方二进制包中提取所有第三方 bundle, 解压到源码 plugins/ 并加入 reactor,
# 这样 Tycho 从本地 reactor 解析依赖, 不再依赖已失效的旧 p2 仓库
echo "[2.5/5] Injecting third-party bundles from official binary..."
OFFICIAL_TARBALL="${WORK_DIR}/dbeaver-official.tar.gz"
OFFICIAL_EXTRACT="${WORK_DIR}/official-extract"

if [ ! -f "${OFFICIAL_TARBALL}" ]; then
    echo "  Downloading official x86_64 binary (for third-party bundles)..."
    curl -fL --retry 3 --retry-delay 5 --retry-connrefused \
        -o "${OFFICIAL_TARBALL}" \
        "https://dbeaver.io/files/${DBEAVER_VERSION}/dbeaver-ce-${DBEAVER_VERSION}-linux.gtk.x86_64.tar.gz"
fi

rm -rf "${OFFICIAL_EXTRACT}"
mkdir -p "${OFFICIAL_EXTRACT}"
tar -xzf "${OFFICIAL_TARBALL}" -C "${OFFICIAL_EXTRACT}"

OFFICIAL_PLUGINS_DIR=$(find "${OFFICIAL_EXTRACT}" -maxdepth 3 -type d -name plugins | head -1)
if [ -z "${OFFICIAL_PLUGINS_DIR}" ]; then
    echo "  WARN: Could not find plugins dir in official binary"
    find "${OFFICIAL_EXTRACT}" -maxdepth 3 -type d | head -20
else
    echo "  Official plugins dir: ${OFFICIAL_PLUGINS_DIR}"
    INJECTED_COUNT=0
    NEW_MODULES=""

    for jar in "${OFFICIAL_PLUGINS_DIR}"/*.jar; do
        [ -f "${jar}" ] || continue
        JAR_NAME=$(basename "${jar}")

        # 跳过 DBeaver 自己的 bundle (它们已在源码 reactor 中)
        if echo "${JAR_NAME}" | grep -q "^org.jkiss.dbeaver"; then
            continue
        fi

        # 从 jar 文件名提取 bundle 名称: 第一个 _数字. 之前的部分
        # 例如 net.sf.opencsv_2.3.0.jar -> net.sf.opencsv
        BUNDLE_NAME=$(echo "${JAR_NAME}" | sed -E 's/^(.+?)_[0-9]+\..*\.jar$/\1/')
        if [ -z "${BUNDLE_NAME}" ] || [ "${BUNDLE_NAME}" = "${JAR_NAME}" ]; then
            echo "  WARN: Could not parse bundle name from ${JAR_NAME}, skipping"
            continue
        fi

        # 检查源码中是否已存在该 bundle
        TARGET_DIR="${SRC_DIR}/plugins/${BUNDLE_NAME}"
        if [ -d "${TARGET_DIR}" ]; then
            continue
        fi

        # 解压 jar 到源码 plugins 目录 (Tycho eclipse-plugin 打包需要目录结构)
        mkdir -p "${TARGET_DIR}"
        (cd "${TARGET_DIR}" && jar -xf "${jar}")

        # 为第三方 bundle 创建 pom.xml
        cat > "${TARGET_DIR}/pom.xml" <<BUNDLEPOM
<?xml version="1.0" encoding="UTF-8"?>
<project xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd"
  xmlns="http://maven.apache.org/POM/4.0.0"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.jkiss.dbeaver</groupId>
    <artifactId>dbeaver</artifactId>
    <version>1.0.0-SNAPSHOT</version>
    <relativePath>../../</relativePath>
  </parent>
  <artifactId>${BUNDLE_NAME}</artifactId>
  <packaging>eclipse-plugin</packaging>
</project>
BUNDLEPOM

        NEW_MODULES="${NEW_MODULES} ${BUNDLE_NAME}"
        INJECTED_COUNT=$((INJECTED_COUNT + 1))
        echo "  INJECTED: ${BUNDLE_NAME}"
    done

    echo "  Total injected: ${INJECTED_COUNT} third-party bundles"

    # 将新模块添加到 plugins/pom.xml 的默认 modules 段 (第一个 </modules> 之前)
    if [ "${INJECTED_COUNT}" -gt 0 ]; then
        echo "  Registering new modules in plugins/pom.xml..."
        python3 - "${SRC_DIR}/plugins/pom.xml" ${NEW_MODULES} <<'PYEOF'
import sys

pom_path = sys.argv[1]
new_modules = sys.argv[2:]

with open(pom_path, "r", encoding="utf-8") as f:
    content = f.read()

modules_xml = ""
for m in new_modules:
    modules_xml += "<module>{}</module>\n".format(m)

# 插入到第一个 </modules> 之前 (默认 modules 段, 非 desktop profile 中的)
first_close = content.find("</modules>")
if first_close > 0:
    content = content[:first_close] + modules_xml + content[first_close:]
    with open(pom_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("  Registered {} modules".format(len(new_modules)))
else:
    print("  WARN: Could not find </modules> in plugins/pom.xml")
PYEOF
    fi
fi

# ---- 3. Maven 构建 ----
echo "[3/5] Running Maven build (Tycho)..."
MVN_ARGS="package -DskipTests=${SKIP_TESTS} -Dmaven.javadoc.skip=true -Dtycho.localArtifacts=ignore"
echo "[CMD] mvn ${MVN_ARGS}"
mvn ${MVN_ARGS}

# ---- 4. 定位并打包产物 ----
echo "[4/5] Locating build artifacts..."
PRODUCTS_DIR="${SRC_DIR}/product/standalone/target/products"
if [ ! -d "${PRODUCTS_DIR}" ]; then
    echo "ERROR: Products directory not found: ${PRODUCTS_DIR}"
    echo "Available target dirs:"
    find "${SRC_DIR}/product" -name "products" -type d 2>/dev/null || true
    exit 1
fi

echo "[INFO] Products directory contents:"
ls -la "${PRODUCTS_DIR}/"

# Tycho materialize-products 生成的目录结构:
#   org.jkiss.dbeaver.core.product/linux/gtk/x86_64/
#   org.jkiss.dbeaver.core.product/linux/gtk/aarch64/
PRODUCT_ID="org.jkiss.dbeaver.core.product"

for ARCH in x86_64 aarch64; do
    ARCH_DIR="${PRODUCTS_DIR}/${PRODUCT_ID}/linux/gtk/${ARCH}"
    if [ ! -d "${ARCH_DIR}" ]; then
        echo "[WARN] Artifact dir not found for ${ARCH}: ${ARCH_DIR}"
        # 尝试查找替代路径
        find "${PRODUCTS_DIR}" -maxdepth 4 -type d -name "${ARCH}" 2>/dev/null || true
        continue
    fi

    # 映射架构名
    case "${ARCH}" in
        x86_64)  DEB_ARCH="amd64" ;;
        aarch64) DEB_ARCH="arm64" ;;
        *)       DEB_ARCH="${ARCH}" ;;
    esac

    TARBALL="${OUTPUT_DIR}/dbeaver-ce-${DBEAVER_VERSION}-linux-gtk-${ARCH}.tar.gz"
    echo "[INFO] Packaging ${ARCH} -> ${TARBALL}"

    # 进入父目录打包，保持顶层目录为 dbeaver/
    PARENT_DIR="$(dirname "${ARCH_DIR}")"
    # 重命名顶层目录为 dbeaver (Tycho 默认可能是 eclipse/ 或产品名)
    TOP_DIRNAME="$(ls -1 "${ARCH_DIR}/" | head -1)"
    if [ "${TOP_DIRNAME}" != "dbeaver" ]; then
        mv "${ARCH_DIR}/${TOP_DIRNAME}" "${ARCH_DIR}/dbeaver"
    fi

    tar -czf "${TARBALL}" -C "${ARCH_DIR}" dbeaver
    echo "[OK] Created: ${TARBALL} ($(du -h "${TARBALL}" | cut -f1))"
done

# ---- 5. 汇总 ----
echo "[5/5] Build complete!"
echo "============================================================"
echo " Artifacts in: ${OUTPUT_DIR}"
ls -lh "${OUTPUT_DIR}/"*.tar.gz 2>/dev/null || echo "(no tarballs found)"
echo "============================================================"
