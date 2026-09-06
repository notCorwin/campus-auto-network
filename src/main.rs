mod config;
#[cfg(test)]
mod tests;

use chrono::Local;
use config::{private_dir, save_json, Config, Paths, ProxyMode};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::net::Ipv4Addr;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, SystemTime};

const LABEL: &str = "com.nowaywastaken.csustautologin";

fn command(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn parse_ssid_line(line: &str) -> Option<String> {
    let (label, value) = line.trim().split_once(':')?;
    let value = value.trim();
    (matches!(label.trim(), "SSID" | "Current Wi-Fi Network")
        && !value.is_empty()
        && !matches!(value, "<redacted>" | "<unknown>" | "(null)"))
    .then(|| value.to_owned())
}

fn parse_wifi_interface_blocks(text: &str) -> Vec<String> {
    let mut is_wifi = false;
    let mut interfaces = Vec::new();
    for line in text.lines().map(str::trim) {
        if let Some(port) = line.strip_prefix("Hardware Port: ") {
            is_wifi = matches!(port, "Wi-Fi" | "AirPort");
        } else if is_wifi {
            if let Some(device) = line.strip_prefix("Device: ") {
                interfaces.push(device.to_owned());
            }
        }
    }
    interfaces
}

fn usable_ip(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    !(ip.is_loopback()
        || ip.is_link_local()
        || octets[0] >= 224
        || octets[0] == 0
        || octets[0] == 198 && matches!(octets[1], 18 | 19))
}

#[derive(Clone)]
struct Network {
    interface: String,
    ssid: Option<String>,
    ip: Option<Ipv4Addr>,
}

impl Network {
    fn key(&self) -> String {
        format!(
            "{} / {}",
            self.interface,
            self.ip
                .map(|ip| ip.to_string())
                .unwrap_or_else(|| "等待 IPv4".into())
        )
    }
}

fn scan_networks() -> Vec<Network> {
    let hardware =
        command("/usr/sbin/networksetup", &["-listallhardwareports"]).unwrap_or_default();
    let interfaces = parse_wifi_interface_blocks(&hardware);
    interfaces
        .into_iter()
        .map(|interface| {
            let summary =
                command("/usr/sbin/ipconfig", &["getsummary", &interface]).unwrap_or_default();
            let ssid = summary.lines().find_map(parse_ssid_line).or_else(|| {
                command(
                    "/usr/sbin/networksetup",
                    &["-getairportnetwork", &interface],
                )
                .and_then(|text| text.lines().find_map(parse_ssid_line))
            });
            let ip = command("/usr/sbin/ipconfig", &["getifaddr", &interface])
                .and_then(|text| text.parse().ok())
                .filter(|ip| usable_ip(*ip));
            Network {
                interface,
                ssid,
                ip,
            }
        })
        .collect()
}

fn campus_ip(config: &Config, ip: Ipv4Addr) -> bool {
    usable_ip(ip)
        && config
            .ip_prefixes
            .iter()
            .any(|prefix| ip.to_string().starts_with(prefix))
}

fn select_network(config: &Config, networks: &[Network]) -> Option<Network> {
    let target_ssid = |network: &&Network| {
        network
            .ssid
            .as_deref()
            .is_some_and(|ssid| ssid == config.ssid)
    };
    networks
        .iter()
        .filter(target_ssid)
        .find(|network| network.ip.is_some_and(|ip| campus_ip(config, ip)))
        .or_else(|| networks.iter().filter(target_ssid).find(|n| n.ip.is_none()))
        .cloned()
}

#[derive(Debug, PartialEq, Eq)]
enum Outcome {
    Online,
    Credentials,
    Retry(String),
    NetworkChanged,
}

fn parse_response(text: &str) -> Outcome {
    let text = text.trim();
    let json = text
        .split_once('(')
        .filter(|(callback, _)| callback.trim() == "dr1003")
        .and_then(|(_, body)| body.trim_end_matches(';').trim().strip_suffix(')'))
        .unwrap_or(text);
    let value = serde_json::from_str::<serde_json::Value>(json).ok();
    let message = value
        .as_ref()
        .and_then(|v| v.get("msg"))
        .and_then(|v| v.as_str())
        .unwrap_or(text);
    let message = message.trim();
    if [
        "密码错误",
        "账号错误",
        "帐号错误",
        "账号不存在",
        "用户不存在",
        "用户名或密码错误",
        "账号已欠费",
    ]
    .iter()
    .any(|word| message.contains(word))
        || matches!(
            message.to_ascii_lowercase().as_str(),
            "invalid password" | "invalid credentials"
        )
    {
        return Outcome::Credentials;
    }
    let already_online = message.contains("已经在线")
        || message.contains("已在线")
        || matches!(
            message
                .trim_end_matches(['!', '.', '！'])
                .to_ascii_lowercase()
                .as_str(),
            "already online" | "user already online" | "user is already online"
        );
    let success = value
        .as_ref()
        .is_some_and(|v| v.get("result").is_some_and(|r| r == 1 || r == "1"));
    if success || already_online || text.contains("Dr.COMWebLoginID_3.htm") {
        Outcome::Online
    } else if text.contains("认证超时") {
        Outcome::Retry("认证超时，将自动重试。".into())
    } else if text.contains("Dr.COMWebLoginID_2.htm") {
        Outcome::Retry("认证被拒绝，请检查认证参数。".into())
    } else {
        // 不输出原始响应：门户可能在 HTML/JSON 中回显账号、密码或请求 URL。
        Outcome::Retry("未收到可确认的认证结果，可运行 csust-auto-login doctor 检查连接。".into())
    }
}

fn routes(config: &Config) -> &[&str] {
    match config.proxy_mode {
        ProxyMode::Auto => &["direct", "proxy"],
        ProxyMode::Direct => &["direct"],
        ProxyMode::Proxy => &["proxy"],
    }
}

fn client(config: &Config, route: &str) -> Result<Client, String> {
    let mut builder = Client::builder()
        .no_proxy()
        .danger_accept_invalid_certs(!config.verify_ssl)
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(config.timeout_secs))
        .redirect(reqwest::redirect::Policy::none())
        .http1_only()
        .referer(false)
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36");
    if route == "proxy" {
        builder =
            builder.proxy(reqwest::Proxy::all(&config.proxy_url).map_err(|_| "代理地址无效。")?);
    }
    builder.build().map_err(|_| "无法创建 HTTP 客户端。".into())
}

fn connection_error(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "连接超时"
    } else if error.is_connect() {
        "无法建立连接（请检查网络或代理是否启动）"
    } else {
        "连接中断"
    }
}

fn route_label(route: &str) -> &str {
    match route {
        "direct" => "直连",
        "proxy" => "本地代理",
        _ => "尚未选择",
    }
}

fn login(
    config: &Config,
    ip: &str,
    mut still_connected: impl FnMut() -> bool,
) -> (Outcome, String) {
    if let Err(error) = config.validate() {
        return (Outcome::Retry(error), String::new());
    }
    let account = format!(",0,{}", config.username);
    let params = [
        ("callback", "dr1003"),
        ("login_method", "1"),
        ("user_account", &account),
        ("user_password", &config.password),
        ("wlan_user_ip", ip),
        ("wlan_user_ipv6", ""),
        ("wlan_user_mac", "000000000000"),
        ("wlan_ac_ip", ""),
        ("wlan_ac_name", ""),
        ("jsVersion", "4.2.1"),
        ("terminal_type", "1"),
        ("lang", "zh-cn"),
        ("v", "8207"),
    ];
    let referer = reqwest::Url::parse(&config.server_url)
        .ok()
        .map(|url| format!("{}/", url.origin().ascii_serialization()))
        .unwrap_or_default();
    let mut errors = Vec::new();
    let mut last_route = String::new();
    for &route in routes(config) {
        if !still_connected() {
            return (Outcome::NetworkChanged, last_route);
        }
        last_route = route.to_owned();
        let client = match client(config, route) {
            Ok(client) => client,
            Err(error) => {
                errors.push(error);
                continue;
            }
        };
        let response = client
            .get(&config.server_url)
            .header("Referer", &referer)
            .query(&params)
            .send();
        match response {
            Ok(response) => {
                if !still_connected() {
                    return (Outcome::NetworkChanged, last_route);
                }
                let status = response.status();
                if status.is_redirection() {
                    let location = response
                        .headers()
                        .get("location")
                        .and_then(|h| h.to_str().ok())
                        .unwrap_or("");
                    return (parse_response(location), last_route);
                }
                if !status.is_success() {
                    return (
                        Outcome::Retry(format!(
                            "认证服务器返回 HTTP {}，将自动重试。",
                            status.as_u16()
                        )),
                        last_route,
                    );
                }
                match response.text() {
                    Ok(text) => {
                        if !still_connected() {
                            return (Outcome::NetworkChanged, last_route);
                        }
                        return (parse_response(&text), last_route);
                    }
                    Err(_) => errors.push(format!("{}：响应读取失败", route_label(route))),
                }
            }
            Err(error) => errors.push(format!(
                "{}：{}",
                route_label(route),
                connection_error(&error)
            )),
        }
    }
    (Outcome::Retry(errors.join("；")), last_route)
}

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
struct State {
    phase: String,
    detail: String,
    network: String,
    route: String,
    checked_at: i64,
    checking: bool,
    last_success: Option<i64>,
    failure_since: Option<i64>,
    notified: bool,
    credentials_blocked: bool,
    config_key: u64,
    attempt: u32,
}

impl State {
    fn read(paths: &Paths) -> Self {
        fs::read(&paths.state)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn transition(&mut self, phase: &str, detail: &str, now: i64) -> (bool, bool) {
        let changed = self.phase != phase || self.detail != detail;
        let needs_action = matches!(phase, "credentials" | "config_error");
        if needs_action && self.phase != phase {
            self.notified = false;
        }
        self.phase = phase.into();
        self.detail = detail.into();
        self.checked_at = now;
        self.checking = false;
        if matches!(phase, "online" | "outside") {
            self.failure_since = None;
            self.notified = false;
        }
        if phase == "online" {
            self.last_success = Some(now);
        }
        let mut notify = false;
        if matches!(
            phase,
            "credentials" | "config_error" | "retry" | "waiting_ip"
        ) {
            let since = *self.failure_since.get_or_insert(now);
            notify = !self.notified && (needs_action || now.saturating_sub(since) >= 120);
            self.notified |= notify;
        }
        (changed, notify)
    }
}

#[cfg(not(test))]
fn show_alert(message: &str) {
    // argv 避免把通知内容拼接为 AppleScript 源码。
    let script = "on run argv\n display notification (item 1 of argv) with title \"校园网自动登录\"\nend run";
    if !Command::new("/usr/bin/osascript")
        .args(["-e", script, message])
        .output()
        .is_ok_and(|output| output.status.success())
    {
        eprintln!("系统通知未送达，请运行 csust-auto-login status 查看详情。");
    }
}

#[cfg(test)]
fn show_alert(_: &str) {}

fn cleanup_logs(paths: &Paths) {
    let Ok(entries) = fs::read_dir(&paths.logs) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if chrono::NaiveDate::parse_from_str(&name, "%Y-%m-%d.log").is_ok()
            && entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|time| SystemTime::now().duration_since(time).ok())
                .is_some_and(|age| age > Duration::from_secs(7 * 86400))
        {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn log_event(paths: &Paths, state: &State) -> std::io::Result<()> {
    private_dir(&paths.logs)?;
    let path = paths
        .logs
        .join(format!("{}.log", Local::now().format("%Y-%m-%d")));
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    writeln!(
        log,
        "{} [{}] {} / {}",
        Local::now().format("%F %T"),
        state.phase,
        route_label(&state.route),
        state.detail
    )
}

fn record(paths: &Paths, state: &mut State, phase: &str, message: &str) {
    let (changed, notify) = state.transition(phase, message, Local::now().timestamp());
    if changed || phase == "retry" {
        if let Err(error) = log_event(paths, state) {
            eprintln!("日志写入失败：{error}");
        }
    }
    // 先持久化通知去重；状态无法保存时不反复弹窗，认证仍继续。
    match save_json(&paths.state, state) {
        Ok(()) if notify => show_alert(&format!("{message}\n详情：csust-auto-login status")),
        Err(error) => eprintln!("状态保存失败：{error}"),
        _ => {}
    }
}

fn run_cycle(
    paths: &Paths,
    manual: bool,
    mut scan: impl FnMut() -> Vec<Network>,
    mut sleep: impl FnMut(Duration),
) -> Result<(), String> {
    private_dir(&paths.data).map_err(|e| format!("无法打开运行目录：{e}"))?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(paths.data.join("run.lock"))
        .map_err(|e| e.to_string())?;
    match lock.try_lock() {
        Ok(()) => {}
        Err(std::fs::TryLockError::WouldBlock) => {
            if manual {
                println!("后台正在检查网络，请运行 csust-auto-login status 查看进度。");
            }
            return Ok(());
        }
        Err(error) => return Err(format!("无法取得运行锁：{error}")),
    }
    cleanup_logs(paths);
    let mut state = State::read(paths);
    if manual {
        state.credentials_blocked = false;
        state.failure_since = None;
        state.notified = false;
    }
    let mut attempt = 0;
    loop {
        let config = match Config::effective(&paths.config) {
            Ok(config) => config,
            Err(error) => {
                record(paths, &mut state, "config_error", &error);
                return if manual { Err(error) } else { Ok(()) };
            }
        };
        let mut hash = DefaultHasher::new();
        // 仅作本地配置变更检测；状态文件与含密码的配置文件均限当前用户读取。
        serde_json::to_vec(&config)
            .map_err(|e| e.to_string())?
            .hash(&mut hash);
        let config_key = hash.finish();
        if config_key != state.config_key {
            state.config_key = config_key;
            state.credentials_blocked = false;
            state.failure_since = None;
            state.notified = false;
        }
        let Some(network) = select_network(&config, &scan()) else {
            state.network.clear();
            state.route.clear();
            state.attempt = 0;
            record(paths, &mut state, "outside", "未连接校园网，等待网络变化。");
            if manual {
                println!("{}", state.detail);
            }
            return Ok(());
        };
        let key = network.key();
        if state.network != key {
            state.network = key.clone();
            state.failure_since = None;
            state.notified = false;
        }
        if state.credentials_blocked {
            record(
                paths,
                &mut state,
                "credentials",
                "认证信息被拒绝，请运行 configure 修改配置，或运行 login 手动重试。",
            );
            return Ok(());
        }
        if attempt >= config.retry_attempts {
            return if manual { Err(state.detail) } else { Ok(()) };
        }
        attempt += 1;
        state.attempt = attempt;
        let ip = if config.auto_detect_ip {
            network
                .ip
                .filter(|ip| campus_ip(&config, *ip))
                .map(|ip| ip.to_string())
        } else {
            network
                .ip
                .filter(|ip| campus_ip(&config, *ip))
                .map(|_| config.wlan_user_ip.clone())
        };
        if let Some(ip) = ip {
            // 检查时间用于 status；不把每轮 checking 写入事件日志，以免重复认证刷屏。
            state.checked_at = Local::now().timestamp();
            state.checking = true;
            let _ = save_json(&paths.state, &state);
            let (outcome, route) = login(&config, &ip, || {
                select_network(&config, &scan()).is_some_and(|current| current.key() == key)
            });
            state.route = route;
            match outcome {
                Outcome::Online => {
                    record(paths, &mut state, "online", "登录成功或已经在线。");
                    if manual {
                        println!("{}（{}）", state.detail, route_label(&state.route));
                    }
                    return Ok(());
                }
                Outcome::Credentials => {
                    state.credentials_blocked = true;
                    record(
                        paths,
                        &mut state,
                        "credentials",
                        "认证信息被拒绝，请运行 configure 修改配置，或运行 login 手动重试。",
                    );
                    return if manual { Err(state.detail) } else { Ok(()) };
                }
                Outcome::Retry(error) => record(paths, &mut state, "retry", &error),
                Outcome::NetworkChanged => {
                    record(paths, &mut state, "retry", "网络已变化，重新检查。");
                    continue;
                }
            }
        } else {
            state.route.clear();
            record(
                paths,
                &mut state,
                "waiting_ip",
                "已连接校园 Wi-Fi，等待系统分配 IPv4 地址。",
            );
        }
        if attempt >= config.retry_attempts {
            return if manual { Err(state.detail) } else { Ok(()) };
        }
        sleep(Duration::from_secs(config.retry_interval_secs));
    }
}

fn display_time(timestamp: i64) -> String {
    chrono::DateTime::from_timestamp(timestamp, 0)
        .map(|time| time.with_timezone(&Local).format("%F %T").to_string())
        .unwrap_or_else(|| "未知".into())
}

fn status(paths: &Paths) {
    let uid = command("/usr/bin/id", &["-u"]).unwrap_or_default();
    let service = command("/bin/launchctl", &["print", &format!("gui/{uid}/{LABEL}")]);
    println!(
        "后台服务：{}",
        if service.is_some() {
            "已启用，网络事件触发、每 60 秒兜底检查"
        } else {
            "未启用，请运行 bash install.sh"
        }
    );
    if let Some(service) = service {
        for line in service
            .lines()
            .filter(|line| line.trim().starts_with("last exit code ="))
        {
            println!("launchd：{}", line.trim());
        }
    }
    let state = State::read(paths);
    if state.checked_at == 0 {
        println!("尚无检查记录。");
    } else {
        println!(
            "当前状态：{}\n最近检查：{}",
            if state.checking {
                "正在检查认证状态…"
            } else {
                &state.detail
            },
            display_time(state.checked_at)
        );
        if Local::now().timestamp().saturating_sub(state.checked_at) > 120 {
            println!("检查记录已过期；可运行 login 或 doctor 检查后台和网络。");
        }
        if !state.network.is_empty() {
            println!("网络：{}", state.network);
        }
        println!(
            "连接方式：{}；本轮尝试：{}",
            route_label(&state.route),
            state.attempt
        );
    }
    if let Some(time) = state.last_success {
        println!("最近在线：{}", display_time(time));
    }
    match Config::effective(&paths.config) {
        Ok(_) => println!("配置：有效"),
        Err(error) => println!("配置：{error}"),
    }
    println!(
        "配置文件：{}\n日志目录：{}",
        paths.config.display(),
        paths.logs.display()
    );
}

fn doctor(paths: &Paths) -> Result<(), String> {
    status(paths);
    let config = Config::effective(&paths.config)?;
    let networks = scan_networks();
    for network in &networks {
        println!(
            "网卡 {}：IPv4={}，SSID={}",
            network.interface,
            network
                .ip
                .map(|ip| ip.to_string())
                .unwrap_or_else(|| "未分配".into()),
            network.ssid.as_deref().unwrap_or("不可读取")
        );
    }
    if select_network(&config, &networks).is_none() {
        println!("当前不在配置的校园网络，跳过校园服务器探测；未发送认证请求。");
        return Ok(());
    }
    let server = reqwest::Url::parse(&config.server_url).map_err(|_| "认证地址无效。")?;
    let root = format!("{}/", server.origin().ascii_serialization());
    for &route in routes(&config) {
        match client(&config, route)?.get(&root).send() {
            Ok(response) => println!(
                "{}：服务器可达，HTTP {}",
                route_label(route),
                response.status().as_u16()
            ),
            Err(error) => println!("{}：{}", route_label(route), connection_error(&error)),
        }
    }
    println!("诊断结束，仅探测服务器根路径，未发送账号密码或认证请求。");
    Ok(())
}

fn entry() -> Result<(), String> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let action = args.first().map(String::as_str).unwrap_or("run");
    if args.len() > 1 {
        return Err("仅接受一个命令；运行 csust-auto-login --help 查看用法。".into());
    }
    if matches!(action, "--help" | "-h" | "help") {
        println!("校园网自动登录\n  configure  配置账号、密码与连接方式\n  login      立即尝试登录\n  status     查看后台和最近登录状态\n  doctor     检查网络连接，不提交认证\n  run        后台检查一轮（默认）\n安装/更新：bash install.sh\n卸载：bash install.sh uninstall（保留配置和日志）");
        return Ok(());
    }
    let home = std::env::var_os("HOME").ok_or("无法确定用户目录。")?;
    let paths = Paths::for_home(Path::new(&home));
    match action {
        "configure" => config::configure(&paths),
        "login" | "run" => run_cycle(&paths, action == "login", scan_networks, std::thread::sleep),
        "status" => {
            status(&paths);
            Ok(())
        }
        "doctor" => doctor(&paths),
        _ => Err("未知命令；运行 csust-auto-login --help 查看用法。".into()),
    }
}

fn main() {
    if let Err(error) = entry() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
