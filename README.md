# 校园网自动登录

macOS 上的 CSUST 校园网后台认证工具。登录 macOS 后每 15 秒检查一次，连接校园 Wi-Fi 或取得校园网 IP 后自动认证。SSID 被系统隐藏时，通过真实物理网卡的校园 IP 判断网络，不使用 TUN 虚拟地址作为认证 IP。

## 安装与使用

需要 macOS 和 Rust 1.89 或更新版本。首次安装没有配置时会进入终端向导；更新安装保留已有配置。

```sh
bash install.sh

csust-auto-login configure  # 修改账号、密码和连接方式，无需重新编译
csust-auto-login login      # 立即尝试，也可手动重试被拒绝的凭据
csust-auto-login status     # 后台服务、最近检查、最近在线、日志位置
csust-auto-login doctor     # 查看网卡并探测服务器，不提交认证

bash install.sh uninstall   # 移除安装的程序和后台任务，保留配置与日志
```

程序安装到 `~/.local/bin/csust-auto-login`，移动或删除源码目录不影响后台运行。若 `~/.local/bin` 不在 PATH 中，使用该完整路径运行命令。重新执行安装脚本即可更新；安装失败会尝试恢复此前的程序和后台配置。

## 配置

配置文件：`~/Library/Application Support/csust-auto-login/config.json`。向导留空保留现值，密码输入隐藏；配置以 `600` 权限原子保存。后台只读取配置，不会等待键盘输入。

除向导中的账号、密码、SSID、认证地址和代理设置外，还可直接编辑以下字段：

| 字段 | 默认值与用途 |
| --- | --- |
| `proxy_mode` | `auto`：先直连，仅连接失败时尝试代理；`direct`：只直连；`proxy`：只用代理 |
| `proxy_url` | `http://127.0.0.1:7890` |
| `ip_prefixes` | `["10.161.", "10.183."]`，SSID 不可读时的校园网判断依据 |
| `auto_detect_ip` | `true`，使用选中物理网卡的 IPv4 |
| `wlan_user_ip` | 手动 IPv4；仅在 `auto_detect_ip` 为 `false` 时使用，仍须检测到校园网络 |
| `verify_ssl` | `false`，保留校园认证服务器的证书兼容设置 |
| `timeout_secs` | `15`，单次请求总超时；建立连接最多等待 3 秒 |
| `retry_attempts` | `3`，一轮最多尝试次数 |
| `retry_interval_secs` | `5`，两次尝试之间的等待时间 |

非空账号、密码、SSID 和合法 HTTP/HTTPS 认证地址是必填项；时间配置范围为 1–3600 秒，重试次数须大于 0。省略其他字段会使用默认值，未知字段会报配置错误。

`CSUST_PASSWORD` 环境变量优先于保存的密码。终端的临时环境变量只影响从该终端启动的命令，不会自动传给 launchd；日常后台使用向导保存的配置即可。

## 自动恢复与通知

- 正常认证和“已经在线”保持静默；在线状态表示认证服务器确认，不额外使用外网探针推断校园认证状态。
- 暂时断网按配置有限重试，下个调度周期继续；持续失败满 2 分钟提醒一次，恢复后结束该失败事件。
- 明确的账号、密码错误或欠费提示只提醒一次，暂停使用相同配置自动认证；修改有效配置或运行 `login` 后恢复尝试。认证超时属于可重试故障。
- 每次请求前重新判断当前网卡；离开校园网立即停止该轮认证。手动运行与后台任务通过同一个文件锁互斥。
- 睡眠时不唤醒电脑；恢复后由下一次 15 秒检查发现网络。睡眠期间错过的检查不补跑。

日志目录：`~/Library/Logs/csust-auto-login`。每日事件日志记录状态变化与错误，保留 7 天，不保存原始响应、密码或认证查询串。`launchd.stderr.log` 用于程序启动及本地文件写入问题诊断。日志写入失败不会阻止认证。

## 开发与验证

```sh
cargo test --locked
cargo build --release --locked
bash -n install.sh build.sh
plutil -lint com.nowaywastaken.csustautologin.plist
```

测试使用本地 HTTP 服务与临时用户数据目录，覆盖代理回退、请求编码、错误分类、重试上限、网络变化、通知去重和并发互斥，不发送真实校园认证请求。真实校园网下还需检查首次连接、唤醒、掉线恢复及代理开关四种情况。

仓库中的 plist 是安装模板，请通过安装脚本加载，不要直接复制到 LaunchAgents。
