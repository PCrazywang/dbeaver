# DBeaver 21.0.0 多架构 CI 构建

基于 GitHub Actions 的 DBeaver 21.0.0 自动化构建方案，支持 **x86_64 (amd64)** 和 **ARM64 (aarch64)** 双架构，产出兼容 **统信 UOS 20 / Ubuntu / Debian** 的 `.deb` 安装包。

---

## 目录结构

```
dbeaver/
├── .github/
│   └── workflows/
│       └── build-dbeaver.yml    # GitHub Actions 主工作流
├── scripts/
│   ├── build.sh                  # 源码构建脚本 (Maven + Tycho)
│   ├── package-deb.sh            # tar.gz -> .deb 打包脚本
│   └── deploy-remote.sh          # SSH 远程部署脚本
├── debian/                       # deb 包模板与桌面入口
├── patches/                      # 构建补丁 (预留)
├── output/                       # 构建产物输出目录
└── README.md
```

---

## 快速开始

### 1. Fork / 上传本仓库到 GitHub

将本项目推送到你的 GitHub 仓库。

### 2. 触发构建

进入仓库的 **Actions** 标签页 → 选择 **Build DBeaver 21.0.0 (Multi-Arch)** → 点击 **Run workflow**：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `ssh_debug` | 构建前启动 tmate SSH 调试会话 | `false` |
| `architectures` | 目标架构：双架构 / 仅 amd64 / 仅 arm64 | `both` |
| `skip_tests` | 跳过单元测试 | `true` |
| `deploy_enabled` | 构建完成后自动远程部署 | `false` |

### 3. 下载产物

构建完成后，在工作流运行页面底部的 **Artifacts** 区域下载：

- `dbeaver-ce-21.0.0-deb-packages` — `.deb` 安装包（推荐）
- `dbeaver-ce-21.0.0-tarballs` — `.tar.gz` 绿色版

---

## 安装到目标系统

### UOS 20 / Ubuntu / Debian

```bash
# x86_64 (amd64)
sudo dpkg -i dbeaver-ce_21.0.0_amd64.deb
sudo apt-get install -f -y    # 自动修复缺失依赖

# ARM64 (aarch64 / 鲲鹏 / 飞腾)
sudo dpkg -i dbeaver-ce_21.0.0_arm64.deb
sudo apt-get install -f -y
```

安装后：
- 可执行文件：`/opt/dbeaver/dbeaver`
- 命令行启动：`dbeaver &`
- 桌面入口：应用菜单 → 开发 → DBeaver

### tar.gz 绿色版（无需安装）

```bash
tar -xzf dbeaver-ce-21.0.0-linux-gtk-x86_64.tar.gz
cd dbeaver
./dbeaver &
```

---

## 本地构建

如需在本地 Linux 环境构建：

### 前置依赖

```bash
# Ubuntu / Debian
sudo apt-get install -y openjdk-11-jdk maven git dpkg-dev fakeroot python3

# 验证
java -version    # 需要 11+
mvn -version
```

### 执行构建

```bash
# 1. 构建 (产出 tar.gz)
bash scripts/build.sh

# 2. 打包成 .deb
bash scripts/package-deb.sh output/dbeaver-ce-21.0.0-linux-gtk-x86_64.tar.gz
bash scripts/package-deb.sh output/dbeaver-ce-21.0.0-linux-gtk-aarch64.tar.gz

# 产物在 output/ 目录
ls -lh output/*.deb
```

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DBEAVER_VERSION` | 构建版本 | `21.0.0` |
| `WORK_DIR` | 构建工作目录 | `./build` |
| `OUTPUT_DIR` | 产物输出目录 | `./output` |
| `MAVEN_OPTS` | Maven JVM 参数 | `-Xmx2g` |
| `SKIP_TESTS` | 跳过测试 | `true` |

---

## SSH 调试

当 CI 构建失败或需要排查环境问题时，可通过 **tmate** 接入构建容器：

### 使用方式

1. 手动触发工作流时勾选 `ssh_debug: true`
2. 构建开始后，在 **Setup SSH debug session** 步骤的日志中找到 SSH 连接信息：
   ```
   SSH: ssh <random-string>@nyc1.tmate.io
   ```
3. 在本地终端执行该 SSH 命令接入
4. 接入后可查看源码、执行命令、检查环境
5. 调试完成后创建文件 `continue` 继续构建，或 `kill` 终止：
   ```bash
   touch continue    # 继续构建
   # 或
   touch kill        # 终止会话
   ```

### 注意事项

- 调试会话最长保留 60 分钟
- 仅限触发者（GitHub 账号）可接入
- 调试期间工作流处于暂停状态

---

## 远程部署

构建完成后可通过 SSH 一键部署到目标 UOS 20 / Ubuntu 机器。

### 方式一：CI 自动部署（需配置 Secrets）

在仓库 **Settings → Secrets and variables → Actions** 中添加：

| Secret 名称 | 说明 | 示例 |
|-------------|------|------|
| `DEPLOY_SSH_HOST` | 目标主机地址 | `192.168.1.100` |
| `DEPLOY_SSH_USER` | SSH 用户名 | `uos` |
| `DEPLOY_SSH_PORT` | SSH 端口 | `22` |
| `DEPLOY_SSH_KEY` | SSH 私钥（PEM 格式） | `-----BEGIN RSA PRIVATE KEY-----...` |

配置后，手动触发工作流时勾选 `deploy_enabled: true`，CI 会自动：
1. 检测目标机器架构 (amd64 / arm64)
2. 上传对应架构的 .deb 包
3. 执行 `dpkg -i` + `apt-get install -f` 安装
4. 验证安装结果

### 方式二：本地手动部署

```bash
# 部署到指定主机
bash scripts/deploy-remote.sh \
  --host 192.168.1.100 \
  --user uos \
  --port 22 \
  --key ~/.ssh/id_rsa \
  output/dbeaver-ce_21.0.0_amd64.deb

# 使用环境变量
SSH_HOST=10.0.0.5 SSH_USER=admin SSH_PORT=2222 \
  bash scripts/deploy-remote.sh output/dbeaver-ce_21.0.0_arm64.deb
```

部署脚本会自动：
- 检测远程系统版本和架构
- 上传 .deb 包
- 安装并自动修复依赖
- 验证安装（包状态、二进制路径、安装大小）
- 清理临时文件

---

## UOS 20 兼容性说明

| 项目 | 说明 |
|------|------|
| UOS 20 桌面版 | 基于 Debian 10，glibc 2.28，完全兼容 |
| UOS 20 服务器版 | 基于 openEuler，使用 rpm，需另行打包 |
| 支持架构 | x86_64 (Intel/AMD)、ARM64 (鲲鹏/飞腾) |
| Java 运行时 | 包内自带 OpenJDK 11，不依赖系统 Java |
| 系统依赖 | GTK3、glib2.0、pango、cairo、libxtst6 |
| 安装路径 | `/opt/dbeaver/` |
| 命令链接 | `/usr/bin/dbeaver -> /opt/dbeaver/dbeaver` |

### UOS 20 上可能遇到的问题

**1. 依赖缺失**
```bash
sudo apt-get update
sudo apt-get install -f -y
```

**2. 无法启动（GTK 报错）**
```bash
# 安装 GTK 运行库
sudo apt-get install -y libgtk-3-0 libglib2.0-0 libpango-1.0-0 libcairo2
```

**3. ARM64 设备上架构不匹配**
确保下载的是 `arm64` 版本的 deb 包，而非 `amd64`。

---

## 构建原理

### 技术栈

- **构建工具**: Apache Maven + Eclipse Tycho 2.0.0
- **目标平台**: Eclipse 2020-12
- **编译级别**: Java 1.8 (源码) / Java 11 (运行时)
- **交叉构建**: Tycho 在 x86_64 主机上同时构建 aarch64 产物（下载对应架构的 Eclipse fragment 和 JRE）

### 构建流程

```
克隆 DBeaver 21.0.0 源码
        │
        ▼
修改 pom.xml: 仅保留 linux.gtk.x86_64 + linux.gtk.aarch64
        │
        ▼
mvn package (Tycho materialize-products)
        │
        ├─► product/standalone/target/products/.../linux/gtk/x86_64/
        └─► product/standalone/target/products/.../linux/gtk/aarch64/
        │
        ▼
分别打包为 tar.gz
        │
        ▼
package-deb.sh: tar.gz → .deb (含 postinst/postrm/desktop/icon)
        │
        ▼
output/dbeaver-ce_21.0.0_amd64.deb
output/dbeaver-ce_21.0.0_arm64.deb
```

### 为什么不用官方 deb 包？

官方仅提供 `dbeaver-ce_21.0.0_amd64.deb`，**不提供 ARM64 版本**。本方案通过 Tycho 的 `all-platforms` 能力交叉构建出 ARM64 产物，并自行打包为兼容 UOS 20 的 deb 包。

---

## 常见问题

### Q: 构建时间大概多久？
A: 首次构建约 20-40 分钟（需下载大量 Eclipse 插件和 Maven 依赖）。启用 Maven 缓存后后续构建约 10-20 分钟。

### Q: arm64 构建是否需要 ARM 机器？
A: 不需要。Tycho 支持在 x86_64 上交叉构建 aarch64 产物，它只是下载对应架构的原生库（SWT、JRE 等），不涉及本地编译 C/C++ 代码。

### Q: 构建失败如何排查？
A: 
1. 勾选 `ssh_debug: true` 重新触发，接入容器查看日志
2. 查看工作流中的 `Upload build logs` artifact（失败时自动上传）
3. 常见失败原因：网络超时（Maven 下载依赖）、磁盘空间不足、OOM（调大 `MAVEN_OPTS`）

### Q: 如何升级到其他 DBeaver 版本？
A: 修改工作流中的 `DBEAVER_VERSION` 环境变量，以及 `scripts/build.sh` 中的默认版本。注意：21.x 版本使用 Eclipse 2020-12 + Tycho 2.0.0，更高版本可能需要调整构建配置。

### Q: 支持 MIPS64 / LoongArch 架构吗？
A: DBeaver 21.0.0 的 Tycho 配置仅支持 x86_64 和 aarch64。MIPS64 / LoongArch 需要额外适配 Eclipse 目标平台，超出本方案范围。

---

## 许可证

本构建脚本基于 Apache License 2.0 开源。DBeaver Community Edition 本身也采用 Apache License 2.0。
