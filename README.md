# 校园网自动登录

macOS 15+ 原生 Swift 菜单栏 App。首次启动申请定位权限，之后通过 CoreWLAN Wi‑Fi 事件、NWPathMonitor 和 60 秒兜底检查监测网络；只有精确匹配目标 SSID 且取得校园 IPv4 后才自动认证。

## 安装与使用

```sh
bash install.sh
```

App 安装到 `~/Applications/CampusAutoLogin.app`，安装后自动启动并注册登录时启动。首次运行会打开设置页；填写账号、密码、SSID、认证地址和连接方式后保存。

若系统没有弹出定位权限提示，在菜单栏 App 中点击“申请定位权限”，或打开：

`系统设置 → 隐私与安全性 → 定位服务 → 系统服务 → 网络与无线`

菜单栏提供立即检查、诊断、设置、更新、登录时自动启动和退出。更新状态会在打开菜单时及每小时自动检查；自动发现新版本只更新菜单状态，点击“有最新版本可用”后才会确认并安装。卸载：

```sh
bash install.sh uninstall
```

卸载只移除 App、旧 LaunchAgent 和旧 CLI，保留配置与日志。

## 运行规则

- CoreWLAN 读取 SSID/BSSID；定位权限不可用或系统返回 `<redacted>` 时拒绝自动认证，不用 IP 前缀猜测 SSID。
- 只接受目标 SSID 的真实 Wi‑Fi 接口和配置中的校园 IPv4 前缀（默认 `10.161.`、`10.183.`）。
- 自动模式先直连，连接失败后尝试 HTTP/HTTPS 代理；也支持仅直连或仅代理。
- 默认只允许 HTTPS 且验证认证服务器证书；“允许不安全认证传输”必须由用户显式打开，并会显示 HTTP/证书校验警告。
- 每次请求前后重新确认网络；切换 SSID、接口或 IPv4 会停止当前认证轮次。
- 连接失败有限重试；连续失败满 2 分钟通知一次，账号密码错误立即暂停自动尝试，修改配置或点击立即检查后恢复。
- 日志写入 `~/Library/Logs/csust-auto-login`，保留 7 天；不保存原始响应、密码或认证查询串。

## 配置迁移

首次启动时，App 会将旧版 `~/Library/Application Support/csust-auto-login/config.json` 导入 UserDefaults，字段和默认值保持兼容；旧 JSON 不删除，便于回滚。`CSUST_PASSWORD` 环境变量仍优先于保存的密码。

## 开发与验证

需要 Xcode 26 或包含 macOS 15 SDK 的 Command Line Tools。项目不引入第三方 Swift 依赖：

```sh
bash build.sh
bash -n install.sh build.sh
plutil -lint Info.plist
codesign --verify --deep --strict target/CampusAutoLogin.app
```

`build.sh` 会编译 App、进行本机 ad-hoc 签名，并运行内置 self-test。`src/` 中的 Rust 实现保留作协议和迁移参考，不再参与 App 构建或后台运行。

验证还包括 Swift 6 严格并发检查、配置迁移/持久化、权限与引擎取消、跨进程运行锁、直连/代理请求，以及安装替换回滚：

```sh
bash install.sh self-test
cargo test --all-targets
```

每次推送会由 GitHub Actions 构建并更新 `autobuild` Release。更新器只接受
`CampusAutoLogin.app.tar`，会校验 GitHub SHA-256、归档路径、Bundle ID、可执行文件和提交版本；替换失败或新版本无法启动时自动恢复旧 App。
