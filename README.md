# OmniRoute v3.8.54 — KernelSU / Magisk / APatch 模块

把 [OmniRoute](https://github.com/cheaper-inference/OmniRoute) **release/v3.8.54**（`package.json`
`"version": "3.8.54"`）作为开机自启服务跑在手机上，浏览器打开
`http://127.0.0.1:20128` 就是 OmniRoute 面板。

> 版本说明：npm 上当前最新是 **3.8.53**，v3.8.54 尚未发布到 npm / GitHub Releases。
> 本模块里跑的代码是 `release/v3.8.54` 分支源码构建出来的 Next.js standalone 产物，
> 安装时会读取应用 `package.json` 里的 version 字段做核对，不是 3.8.54 就在安装日志里报错。

## 组成

| 组件 | 说明 |
| --- | --- |
| `system/bin/rurima` | 静态 arm64 二进制，提供 `ruri` chroot（不需要 proot / rootfs 里的 libc） |
| `assets/rootfs-ubuntu-24.04-arm64.tar.gz` | Ubuntu 24.04.3 base rootfs（glibc，与构建机 ABI 一致） |
| `assets/node-linux-arm64-v24.tar.gz` | Node.js v24.22.1 官方 linux-arm64 构建 |
| `assets/omniroute-3.8.54-app.tar.gz` | 3.8.54 的 Next.js standalone 产物（含 node_modules / .next / migrations） |
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

安装会往 `/data/local/omniroute` 写约 1.1GB（rootfs + Node + 应用），`/data` 至少留 2GB。

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

## 构建（在 arm64 Linux 上）

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
