#!/usr/bin/env bash
# 兼容入口：DBeaver 21.0.0 的历史 Tycho/p2 构建已不可复现，改为取官方
# nojdk 发布包并植入固定版本的 Temurin JRE。详见 README.md。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHITECTURES="${ARCHITECTURES:-both}"

case "${ARCHITECTURES}" in
    both)  targets=(amd64 arm64) ;;
    amd64|x86_64) targets=(amd64) ;;
    arm64|aarch64) targets=(arm64) ;;
    *)
        echo "错误: ARCHITECTURES 必须是 both、amd64 或 arm64" >&2
        exit 2
        ;;
esac

for arch in "${targets[@]}"; do
    bash "${SCRIPT_DIR}/fetch-and-stage.sh" "${arch}"
done
