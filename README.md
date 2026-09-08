# DBeaver 21.0.0 双架构打包

本项目用 GitHub Actions 生成适用于 **统信 UOS 20 / Debian 10 ABI（glibc 2.28）** 的 DBeaver Community Edition 21.0.0：

| 架构 | 绿色包 | Debian 包 |
| --- | --- | --- |
| amd64 / x86-64 | `dbeaver-ce-21.0.0-linux-gtk-x86_64.tar.gz` | `dbeaver-ce_21.0.0_amd64.deb` |
| arm64 / aarch64（鲲鹏、飞腾） | `dbeaver-ce-21.0.0-linux-gtk-aarch64.tar.gz` | `dbeaver-ce_21.0.0_arm64.deb` |

每个产物都有同名 `.sha256` 文件，包内包含 `BUILD-ENVIRONMENT.txt`。Actions artifact 保留 14 天；推送 `v21.0.0` 标签时，Debian 10 验证通过的双架构产物还会上传到 GitHub Release。

## 为什么不再用 Maven/Tycho 从源码构建

以前的流程会克隆 21.0.0 源码，再用 Tycho 2.0.0 交叉构建。这条链路现在不可复现：

1. 21.0.0 的 `local-p2-repo.url` 指向 `https://dbeaver.io/eclipse-repo`，该仓库已经下线（HTTP 404）。
2. 换成较新版本的 p2 仓库并不等价：其中的 bundle 版本无法满足 21.0.0 的 OSGi 约束，因此会连续出现目标平台依赖解析错误。
3. Tycho 2.0.0 与当前 GitHub runner 自带的 Maven 3.9.x 不兼容。
4. DBeaver 官方已经发布 21.0.0 的 `x86_64` 和 `aarch64` **nojdk** 二进制，不需要重新编译或交叉构建 SWT 原生部分。

现在的工作流直接下载两个官方 nojdk 包，校验仓库中固定的 SHA-256，然后植入固定版本的 Eclipse Temurin 11 JRE。这样既保留官方原生启动器和 SWT fragment，也保证两个架构使用相同 Java 版本。所有网络输入都列在 [checksums/inputs.sha256](checksums/inputs.sha256)，校验失败或缺少条目时立即停止。

> 这是一条“验证并重新打包官方发布物”的流水线，而不是源码编译流水线。

## CI 流程

[build-dbeaver.yml](.github/workflows/build-dbeaver.yml) 对 amd64 和 arm64 分别执行：

1. 在架构匹配的 GitHub runner 上下载并验证 DBeaver 与 Temurin JRE。
2. 验证 ELF 机器类型，以及 SWT、Eclipse launcher fragment 架构。
3. 生成绿色 tar.gz 和 Debian 包，并生成 SHA-256。
4. 在同架构 `debian:10-slim` 容器中安装 `.deb`：确认 glibc 恰为 2.28、运行包内 Java，并逐个检查所有 ELF/JNI 文件是否有 `ldd not found`。
5. `v*` 标签只在标签版本与 `DBEAVER_VERSION` 一致时发布 Release。

手动运行时，`architectures` 可选 `both`、`amd64` 或 `arm64`。普通 push、PR 和标签总是构建双架构。为避免未验证的产物，旧流程中的 tmate 调试和从 CI 直接 SSH 部署均不在主工作流内；需要部署时下载验证后的 artifact，再使用 `scripts/deploy-remote.sh`。

## 本地生成

需要 Linux、`curl`、`tar`、`file`/`readelf`、`dpkg-deb` 和网络访问：

```bash
# 单架构绿色包
bash scripts/fetch-and-stage.sh amd64
bash scripts/fetch-and-stage.sh arm64

# 转换为 Debian 包
bash scripts/package-deb.sh \
  output/dbeaver-ce-21.0.0-linux-gtk-x86_64.tar.gz
bash scripts/package-deb.sh \
  output/dbeaver-ce-21.0.0-linux-gtk-aarch64.tar.gz

# 兼容入口：默认生成双架构绿色包
bash scripts/build.sh
# 或 ARCHITECTURES=arm64 bash scripts/build.sh
```

可覆盖的主要环境变量：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DBEAVER_VERSION` | `21.0.0` | DBeaver 版本；升级时还必须更新校验和 |
| `TEMURIN_RELEASE` | `11.0.32.1+1` | 植入的 Temurin 11 JRE 发布号 |
| `WORK_DIR` | `<repo>/build` | 下载缓存和装配目录 |
| `OUTPUT_DIR` | `<repo>/output` | 输出目录 |
| `INSTALL_PREFIX` | `/opt/dbeaver` | Debian 包内安装路径 |
| `MAINTAINER` | `DBeaver Builder <builder@local>` | Debian 包维护者字段 |

## 安装与使用

```bash
# 按机器架构选择一个包
sudo apt install ./dbeaver-ce_21.0.0_amd64.deb
# 或
sudo apt install ./dbeaver-ce_21.0.0_arm64.deb

dbeaver &
```

安装内容：

- 应用与包内 JRE：`/opt/dbeaver/`
- 启动包装脚本：`/usr/bin/dbeaver`
- 桌面入口：`/usr/share/applications/dbeaver.desktop`

`/usr/bin/dbeaver` 会显式把 `/opt/dbeaver/jre/bin/java` 传给 Eclipse 启动器，不依赖机器上的系统 Java。`.deb` 的 Depends 包含启动器、SWT/GTK native 和 JRE 直接链接的系统库；WebKit、OpenGL/GLU 和 libsecret 属于特定功能所需的 Recommends。

绿色包解压后同样带有 `dbeaver/jre/`：

```bash
tar -xzf dbeaver-ce-21.0.0-linux-gtk-x86_64.tar.gz
./dbeaver/dbeaver &
```

## 升级版本

升级不能只改一个版本字符串，至少要同时完成：

1. 确认目标版本仍提供对应的 `*-nojdk.tar.gz` 双架构文件。
2. 修改 workflow 与脚本使用的 DBeaver/Temurin 版本。
3. 从可信上游核实四个输入文件的 SHA-256，并更新 `checksums/inputs.sha256`。
4. 确认目标 DBeaver 支持所选 Java 主版本。
5. 让双架构 Debian 10 runtime job 全部通过后再发布。

DBeaver 21.0.0 发布于 2021 年，已经很旧。若不是为了兼容既有环境，应优先使用仍获安全修复的新版本；继续使用此版本时，也应评估它所含数据库驱动和第三方 bundle 的已知漏洞。
