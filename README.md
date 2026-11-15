# OmniRoute v3.8.54 — KernelSU / Magisk / APatch 模块

把 [OmniRoute](https://github.com/cheaper-inference/OmniRoute) **release/v3.8.54**（`package.json`
`"version": "3.8.54"`）作为开机自启服务跑在手机上，浏览器打开
`http://127.0.0.1:20128` 就是 OmniRoute 面板。

> 版本说明：npm 上当前最新是 **3.8.53**，v3.8.54 尚未发布到 npm / GitHub Releases。
> 本模块里跑的代码是 `release/v3.8.54` 分支源码构建出来的 Next.js standalone 产物，
> 安装时会读取应用 `package.json` 里的 version 字段做核对，不是 3.8.54 就在安装日志里报错。

## 目录布局

容器根目录就是 `/data/local/omniroute` 本身（与参考模块的 `/data/local/daidai` 同一形态，
不套 `rootfs/` 子目录）：

```
/data/local/omniroute/                     ← chroot 根（ruri 直接 chroot 到这里）
├── bin/ etc/ usr/ lib/ …                  ← Ubuntu 24.04 base rootfs
└── opt/
    ├── node/                              ← Node v24.22.1
    └── omniroute/
        ├── app/                           ← OmniRoute 3.8.54 standalone（每次刷入覆盖）
        ├── data/                          ← 应用数据（数据库/密钥/.env），刷入时保留
        ├── boot.sh
        └── runtime.env

/data/adb/omniroute/                       ← 只放日志与配置（不进容器）
├── omniroute.conf   # 端口/绑定地址/堆上限
├── service.log      # 启停、守护、端口探测
├── app.log          # Next standalone stdout/stderr
├── install.log      # 安装过程
└── stopped          # 手动停止开关
/data/adb/modules/omniroute/               ← 模块本体（root 管理器管的目录）
```

## 组成

| 组件 | 说明 |
| --- | --- |
| `system/bin/rurima` | 静态 arm64 二进制，提供 `ruri` chroot（不依赖 rootfs 里的 libc） |
| `assets/rootfs-ubuntu-24.04-arm64.tar.gz` | Ubuntu 24.04.3 base rootfs，解到 `/data/local/omniroute` |
| `assets/node-linux-arm64-v24.tar.gz` | Node.js v24.22.1 官方 linux-arm64 构建 |
| `assets/omniroute-3.8.54-app.tar.gz` | 3.8.54 的 Next.js standalone 产物（node_modules / .next / migrations） |
| `customize.sh` | 解包上面三样 + 写 DNS/时区/启动脚本 + 版本自检 |
| `service.sh` | late_start 启动：`rurima ruri` 进容器跑 `dev/run-standalone.mjs` |
| `scripts/watchdog.sh` | 存活守护：进程掉了自动拉起，连续 5 次失败才放弃 |
| `action.sh` | 模块卡片「运行」按钮：停止 / 启动 切换 + 状态摘要 |
| `uninstall.sh` | 停进程 + 清目录（支持保留数据卸载） |

## 安装

1. KernelSU / Magisk / APatch 里刷入 `OmniRoute-3.8.54-ksu.zip`（arm64 设备）。
2. 刷完重启，或直接在模块卡片点「运行」。
3. 浏览器打开 `http://127.0.0.1:20128`。
   首次进入按面板引导设置登录密码；跳过就等于关掉面板登录。

安装会往 `/data/local/omniroute` 写约 1.3GB（rootfs + Node + 应用），`/data` 至少留 2GB。

## 配置

`/data/adb/omniroute/omniroute.conf`：

```sh
OMNIROUTE_PORT=20128          # 面板 + API 端口
OMNIROUTE_HOSTNAME=127.0.0.1  # 绑定地址，改 0.0.0.0 会暴露到局域网
OMNIROUTE_MEMORY_MB=1024      # V8 堆上限，小内存机可降到 768
OMNIROUTE_DATA=/opt/omniroute/data
```

改完重启手机，或点一次「运行」按钮（会按新配置重写容器内的 `runtime.env`）。

> 把 `OMNIROUTE_HOSTNAME` 改成 `0.0.0.0` 之前，先在面板里设好登录密码、并在
> `.env` 里开 `REQUIRE_API_KEY=true`。否则等于把 `/v1` 代理裸奔在局域网上，
> 谁都能拿你的 key 烧额度。

应用自己的 `.env`、数据库、密钥都在容器内 `/opt/omniroute/data`
（宿主路径 `/data/local/omniroute/rootfs/opt/omniroute/data`），刷入新版本会保留。

## 日志

| 文件 | 内容 |
| --- | --- |
| `/data/adb/omniroute/service.log` | 模块启停、守护、端口探测 |
| `/data/adb/omniroute/app.log` | Next standalone 的 stdout/stderr |
| `/data/adb/omniroute/install.log` | 安装过程（解包、版本自检、容器自检） |
| `/data/adb/omniroute/omniroute.pid` | 最近一次拉起的 ruri pid |

常用命令：

```sh
su -c 'tail -n 80 /data/adb/omniroute/app.log'
su -c 'cat /data/adb/omniroute/service.log'
su -c 'rm -f /data/adb/omniroute/stopped && sh /data/adb/modules/omniroute/service.sh'
```

## 升级（不丢数据）

新版本出来后，**直接刷新 zip 覆盖安装**，不用先卸载。安装脚本对每样东西的处理是分开的：

| 对象 | 刷入时的行为 |
| --- | --- |
| 容器根 `/data/local/omniroute`（bin/usr/lib…） | 已存在就复用，不重解 |
| `/opt/node` | 已存在就复用 |
| `/opt/omniroute/app` | **唯一的覆盖点**：删旧目录，解新版本 |
| `/opt/omniroute/data` | 完全不碰（数据库 / JWT_SECRET / STORAGE_ENCRYPTION_KEY / .env 都在这） |
| `/data/adb/omniroute/omniroute.conf` | 已存在则不覆盖，你的端口等自定义值保留 |
| `/data/adb/omniroute/*.log` | 追加，不删 |

想更稳一点，刷之前手动备一份：

```sh
su -c 'cp -a /data/local/omniroute/opt/omniroute/data \
         /data/local/omniroute-data-backup-$(date +%F-%H%M)'
```

从 3.8.54 升到 3.8.55 的完整动作：

1. 仓库 Actions → `Build OmniRoute KSU module` → **Run workflow**
   `version=3.8.55`、`branch=release/v3.8.55`、`commit` 留空（或填新分支的 SHA 钉死）
   —— 版本号对不上 `package.json` 的话构建会直接红掉，不会悄悄混淆版本
2. 等 Release 里的 `OmniRoute-3.8.55-ksu.zip` 生成（`module.prop` 的 version/versionCode 自动写对）
3. 手机下载 → KSU/面具里直接刷入覆盖 → 重启，或点模块卡片「运行」
4. 面板里账号密码、provider key、路由配置全部还在

**只有一种情况会丢数据**：改 rootfs 本身（换发行版、换 Ubuntu 大版本）时必须删容器根再刷
——删之前把 `/data/local/omniroute/opt/omniroute/data` 备份出来，刷完再拷回去。

## 停止 / 启动 / 卸载

- 停止/启动：模块卡片上的「运行」按钮（同一个按钮按状态切换）。
  停止状态写 `stopped` 开关，跨重启保持；守护看到开关会自退。
- 卸载：管理器里移除模块即可，会删掉 `/data/local/omniroute` 与 `/data/adb/omniroute`。
- 想保留数据卸载（数据库 / 密钥 / .env）：

```sh
su -c 'mkdir -p /data/adb/omniroute && touch /data/adb/omniroute/.keep_on_uninstall'
```

## 常见问题

**起不来 / 端口没监听**
看 `/data/adb/omniroute/app.log`。最常见是内存不足：把 `OMNIROUTE_MEMORY_MB` 降到 768，
或关掉手机上的省电限制（模块已经阻止休眠，但部分 ROM 的「后台冻结」会杀掉一切）。

**安装时提示版本自检不符**
说明 zip 里的应用包不是 3.8.54 构建的。重新用 `build-module.sh` 从
`release/v3.8.54` 分支构建，脚本会在打包前校验 `package.json` 的 version。

**换 rootfs / 强制重建**
删掉 `/data/local/omniroute/rootfs` 再刷模块。注意这会一起删掉应用数据。

**端口被占用**
改 `OMNIROUTE_PORT`，别改容器内的其他端口变量（`PORT` / `API_PORT` 都从它派生）。

## 构建

**推荐：交给 GitHub Actions**（`.github/workflows/build-ksu.yml`）

- runner：`ubuntu-24.04-arm`（公开仓库免费 arm64，原生编 arm64，避免原生模块架构错配）
- 流程：拉 `release/v3.8.54` → 校验 `package.json` version = 3.8.54 → `npm ci` →
  `npm run build`（webpack，与官方 Docker 一致）→ 下载 rootfs / Node 资产 →
  `build-module.sh` 打 zip → 传 artifact + 发 Release
- 触发：push 到 `main`（改脚本类文件）或在 Actions 页手动 `Run workflow`
- 产物：Release 里的 `OmniRoute-3.8.54-ksu.zip`，手机浏览器直接下载

本地手动构建（arm64 Linux，可选）：

```sh
git clone --depth 1 --branch release/v3.8.54 \
  https://github.com/cheaper-inference/OmniRoute.git omniroute
cd omniroute
npm ci --include=optional --no-audit --no-fund --legacy-peer-deps --ignore-scripts
OMNIROUTE_USE_TURBOPACK=0 NODE_OPTIONS=--max-old-space-size=6144 npm run build
# 产物：.build/next/standalone  →  打进 assets/omniroute-3.8.54-app.tar.gz
```

`build-module.sh` 会依次做：校验版本 → 打包 standalone → 汇总 assets → 生成
`OmniRoute-3.8.54-ksu.zip` 并打印 sha256。
