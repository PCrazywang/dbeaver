# DBeaver 21.0.0 ARM64 打包

本项目通过 GitHub Actions 生成 DBeaver Community Edition 21.0.0 的 **ARM64** 绿色包和 Debian 包：

| 产物 | 文件名 |
| --- | --- |
| 绿色包 | `dbeaver-ce-21.0.0-linux-gtk-aarch64.tar.gz` |
| Debian 包 | `dbeaver-ce_21.0.0_arm64.deb` |

产物各有同名 `.sha256` 校验文件，且安装树内含 `BUILD-ENVIRONMENT.txt`。构建产物保留 14 天；推送 `v21.0.0` 标签时，只有构建与 Ubuntu 20.04 用户态冒烟均通过才会发布 Release。

## 构建策略与兼容性范围

DBeaver 21.0.0 的旧 Tycho 源码构建链已无法复现：其 p2 仓库已下线，旧 Tycho 也与当前 Maven 不兼容。官方仍提供 ARM64 `nojdk` 二进制，因此 CI 采用更可复现的流程：下载固定校验和的官方 `nojdk` 包，植入固定版本 Temurin 11 JRE，再打包为 `.tar.gz` 与 `.deb`。

所有外部输入都必须在 [checksums/inputs.sha256](checksums/inputs.sha256) 中预先固定；下载后校验失败或缺条目即停止。它是“验证并重新打包官方发布物”的流程，不是 DBeaver 源码编译流程。

UOS 20 兼容性由完整安装树的静态 ELF 版本需求门禁表示：`GLIBC_ <= 2.28`、`GLIBCXX_ <= 3.4.25`，并拒绝 `__libc_single_threaded`。CI 也会在 Ubuntu 20.04 ARM64 用户态中安装 `.deb`、检查动态链接和运行包内 Java；该容器检查不是 UOS 运行时验证。发布候选包仍须在真实 UOS 20 ARM64 环境实际安装、启动并完成业务冒烟后，才能声明运行时支持。

## CI 流程

[build-dbeaver.yml](.github/workflows/build-dbeaver.yml) 只构建 ARM64：

1. 在 `ubuntu-22.04-arm` runner 下载并校验官方 DBeaver 与 Temurin 输入。
2. 检查启动器、JRE、SWT 与 Eclipse launcher fragment 的 ARM64 身份。
3. 扫描完整装配树中每个 ELF 的版本需求，执行 UOS ABI 上限门禁。
4. 生成绿色包、gzip `control.tar.gz` / `data.tar.gz` 的 Debian 包及 SHA-256 文件。
5. 在 Ubuntu 20.04 ARM64 用户态安装 `.deb`，检查安装内容、包内 Java 和所有 ELF/JNI 动态链接。
6. `v*` 标签仅在版本匹配、构建和 Ubuntu 用户态冒烟通过时发布 Release。

## 本地生成

需要 Linux、`curl`、`tar`、`readelf`、`file`、`dpkg-deb` 和网络访问：

```bash
bash scripts/fetch-and-stage.sh arm64
bash scripts/package-deb.sh \
  output/dbeaver-ce-21.0.0-linux-gtk-aarch64.tar.gz \
  output
```

主要可覆盖变量：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DBEAVER_VERSION` | `21.0.0` | DBeaver 版本；升级时必须同步更新输入校验和 |
| `TEMURIN_RELEASE` | `11.0.32.1+1` | 植入的 Temurin 11 JRE 发布号 |
| `MAX_GLIBC` | `2.28` | 最大允许 GLIBC 版本需求 |
| `MAX_GLIBCXX` | `3.4.25` | 最大允许 GLIBCXX 版本需求 |
| `WORK_DIR` | `<repo>/build` | 下载缓存和装配目录 |
| `OUTPUT_DIR` | `<repo>/output` | 输出目录 |
| `INSTALL_PREFIX` | `/opt/dbeaver` | Debian 包内安装路径 |

## 安装与使用

```bash
sudo apt install ./dbeaver-ce_21.0.0_arm64.deb
dbeaver &
```

安装内容：应用及包内 JRE 在 `/opt/dbeaver/`，启动包装脚本位于 `/usr/bin/dbeaver`，桌面入口位于 `/usr/share/applications/dbeaver.desktop`。包装脚本会明确向 Eclipse 启动器传入 `/opt/dbeaver/jre/bin/java`，不依赖系统 Java。

绿色包同样包含 `dbeaver/jre/`：

```bash
tar -xzf dbeaver-ce-21.0.0-linux-gtk-aarch64.tar.gz
./dbeaver/dbeaver &
```

## 升级版本

升级至少需要：确认上游仍有 ARM64 `nojdk` 包；同步修改版本和固定 SHA-256；确认 DBeaver 支持所选 Java 主版本；在 CI 中通过架构、ABI、包布局和 Ubuntu 用户态验证；最后在真实 UOS 20 ARM64 环境完成安装及运行验证。

DBeaver 21.0.0 发布于 2021 年，已非常陈旧。除非必须兼容既有环境，否则应优先使用仍有安全修复的版本，并评估其中数据库驱动与第三方 bundle 的已知漏洞。
