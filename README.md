# 校园网自动登录

macOS 13+ 原生 Swift 菜单栏 App。首次启动申请定位权限，之后通过 CoreWLAN Wi‑Fi 事件和 NWPathMonitor 监测网络；只有精确匹配 `CSUST-Student` 时才自动认证。

## 安装与使用

```sh
bash install.sh
```

App 安装到 `~/Applications/CampusAutoLogin.app`，安装后自动启动并注册登录时启动。首次运行会打开设置页；填写账号和密码后保存。
安装器会先停止同 Bundle ID 的其他运行副本；日常请从 `~/Applications/CampusAutoLogin.app` 启动，避免打开旧下载副本。

若系统没有弹出定位权限提示，在菜单栏 App 中点击“申请定位权限”，或打开：

`系统设置 → 隐私与安全性 → 定位服务 → 系统服务 → 网络与无线`

菜单栏提供立即检查、诊断、设置、更新和退出；App 始终注册登录时自动启动。更新状态会在打开菜单时及每 3 分钟自动检查；后台发现新版本后会自动下载、校验并安装，手动检查仍可在确认后安装。卸载：

```sh
bash install.sh uninstall
```

卸载只移除 App 和旧登录启动配置，保留配置与日志。

## 运行规则

- CoreWLAN 读取 SSID/BSSID；定位权限不可用或系统返回 `<redacted>` 时拒绝自动认证。
- 仅将精确匹配 `CSUST-Student` 作为切换到校园网的证据，暂不使用 IPv4 地址段判断。
- CoreWLAN 和 NWPathMonitor 都使用系统事件；校园网仍连接但互联网路径失效时暂停请求，路径恢复事件到达后立即重新认证。
- 先直连；直连失败后由 `URLSession` 使用 macOS 系统代理/PAC，兼容有无代理的机器。
- 认证地址固定为 `https://login.csust.edu.cn:802/eportal/portal/login`，使用系统 TLS 证书校验，避免可配置地址带来的误认证风险。
- 认证请求成功且 `NWPathMonitor` 报告互联网路径可用即视为登录成功；不发送 Cloudflare、Google 或 `204` 探测请求。
- 每次请求前后重新确认网络；切换 SSID、接口或 IPv4 会停止当前认证轮次。
- 认证失败会在收到结果后立即重试直到成功；账号密码错误立即暂停自动尝试，修改配置或点击立即检查后恢复。
- 账号、密码和运行状态写入 UserDefaults，不使用 Keychain；请求超时和网络规则固定在代码中。

## 配置迁移

首次启动时，App 会将旧版 `~/Library/Application Support/csust-auto-login/config.json` 和旧密码文件一次性导入 UserDefaults，成功后移除旧配置文件。

## 开发与验证

需要 Xcode 26 或包含 macOS 15 SDK 的 Command Line Tools。项目不引入第三方 Swift 依赖：

```sh
bash build.sh
bash -n install.sh build.sh
plutil -lint Info.plist
codesign --verify --deep --strict target/CampusAutoLogin.app
```

`build.sh` 会编译 App、进行本机 ad-hoc 签名，并运行内置 self-test。项目运行时只包含 Swift App，不再依赖旧 CLI 或后台守护进程。

验证还包括 Swift 6 严格并发检查、配置迁移/持久化、权限与引擎取消、跨进程运行锁、直连/代理请求，以及安装替换回滚：

```sh
bash install.sh self-test
```

每次推送会由 GitHub Actions 构建并更新 `autobuild` Release。更新器只接受
`CampusAutoLogin.app.tar`，会校验 GitHub SHA-256、归档路径、Bundle ID、可执行文件和提交版本；替换失败或新版本无法启动时自动恢复旧 App。
