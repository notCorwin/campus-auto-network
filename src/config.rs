use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProxyMode {
    #[default]
    Auto,
    Direct,
    Proxy,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub username: String,
    pub password: String,
    pub ssid: String,
    pub server_url: String,
    pub ip_prefixes: Vec<String>,
    pub auto_detect_ip: bool,
    pub wlan_user_ip: String,
    pub verify_ssl: bool,
    pub allow_insecure_transport: bool,
    pub proxy_mode: ProxyMode,
    pub proxy_url: String,
    pub timeout_secs: u64,
    pub retry_attempts: u32,
    pub retry_interval_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            username: String::new(),
            password: String::new(),
            ssid: "CSUST-Student".into(),
            server_url: "https://login.csust.edu.cn:802/eportal/portal/login".into(),
            ip_prefixes: vec!["10.161.".into(), "10.183.".into()],
            auto_detect_ip: true,
            wlan_user_ip: String::new(),
            verify_ssl: true,
            allow_insecure_transport: false,
            proxy_mode: ProxyMode::Auto,
            proxy_url: "http://127.0.0.1:7890".into(),
            timeout_secs: 15,
            retry_attempts: 3,
            retry_interval_secs: 5,
        }
    }
}

impl Config {
    pub fn read(path: &Path) -> Result<Self, String> {
        let bytes = fs::read(path).map_err(|e| {
            if e.kind() == io::ErrorKind::NotFound {
                "尚未配置，请运行 csust-auto-login configure。".into()
            } else {
                format!("无法读取配置文件：{e}")
            }
        })?;
        serde_json::from_slice(&bytes)
            .map_err(|e| format!("配置格式错误（第 {} 行、第 {} 列）。", e.line(), e.column()))
    }

    pub fn effective(path: &Path) -> Result<Self, String> {
        let mut config = Self::read(path)?;
        if let Ok(password) = std::env::var("CSUST_PASSWORD") {
            config.password = password;
        }
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.username.trim().is_empty() || self.password.is_empty() {
            return Err("账号或密码为空，请运行 csust-auto-login configure。".into());
        }
        let server = reqwest::Url::parse(&self.server_url)
            .map_err(|_| "server_url 必须是完整的 HTTP/HTTPS 认证地址。")?;
        if !matches!(server.scheme(), "http" | "https")
            || server.host_str().is_none()
            || !server.username().is_empty()
            || server.password().is_some()
            || server.query().is_some()
            || server.fragment().is_some()
        {
            return Err("server_url 只允许 HTTP/HTTPS 地址，不含凭据、查询串或片段。".into());
        }
        if (server.scheme() != "https" || !self.verify_ssl) && !self.allow_insecure_transport {
            return Err(
                "认证地址必须使用 HTTPS 并验证服务器证书；如确有兼容需求，请明确允许不安全传输。"
                    .into(),
            );
        }
        if self.ssid.trim().is_empty() {
            return Err("ssid 不能为空。".into());
        }
        for prefix in &self.ip_prefixes {
            let parts: Vec<_> = prefix
                .strip_suffix('.')
                .unwrap_or(prefix)
                .split('.')
                .collect();
            if !prefix.ends_with('.')
                || !(1..=3).contains(&parts.len())
                || parts.iter().any(|part| part.parse::<u8>().is_err())
            {
                return Err("ip_prefixes 必须是以点结尾的 IPv4 前缀，例如 10.161.。".into());
            }
        }
        if !self.auto_detect_ip && !self.wlan_user_ip.parse().is_ok_and(crate::usable_ip) {
            return Err("手动 wlan_user_ip 必须是有效的非虚拟 IPv4 地址。".into());
        }
        if self.proxy_mode != ProxyMode::Direct {
            let proxy = reqwest::Url::parse(&self.proxy_url)
                .map_err(|_| "proxy_url 必须是完整的 HTTP/HTTPS 代理地址。")?;
            if !matches!(proxy.scheme(), "http" | "https") || proxy.host_str().is_none() {
                return Err("proxy_url 必须是完整的 HTTP/HTTPS 代理地址。".into());
            }
        }
        if !(1..=3600).contains(&self.timeout_secs)
            || self.retry_attempts == 0
            || !(1..=3600).contains(&self.retry_interval_secs)
        {
            return Err("超时和重试间隔须为 1–3600 秒，重试次数须大于 0。".into());
        }
        Ok(())
    }
}

pub struct Paths {
    pub data: PathBuf,
    pub config: PathBuf,
    pub state: PathBuf,
    pub logs: PathBuf,
}

impl Paths {
    pub fn for_home(home: &Path) -> Self {
        let data = home.join("Library/Application Support/csust-auto-login");
        Self {
            config: data.join("config.json"),
            state: data.join("state.json"),
            data,
            logs: home.join("Library/Logs/csust-auto-login"),
        }
    }
}

pub fn private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

pub fn save_json(path: &Path, value: &impl Serialize) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("缺少父目录"))?;
    private_dir(parent)?;
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let result = (|| {
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn prompt(label: &str, current: &str) -> Result<String, String> {
    print!("{label} [{current}]：");
    io::stdout().flush().map_err(|e| e.to_string())?;
    let mut input = String::new();
    if io::stdin()
        .read_line(&mut input)
        .map_err(|e| e.to_string())?
        == 0
    {
        return Err("配置已取消，原配置未改动。".into());
    }
    let value = input.trim();
    Ok(if value.is_empty() {
        current.to_owned()
    } else {
        value.to_owned()
    })
}

pub fn configure(paths: &Paths) -> Result<(), String> {
    if !io::stdin().is_terminal() {
        return Err("请在交互式终端运行 configure，或直接编辑配置文件。".into());
    }
    let mut config = if paths.config.exists() {
        Config::read(&paths.config)?
    } else {
        Config::default()
    };
    println!(
        "留空保留现值；密码不会显示。完成全部输入后才保存。\n配置：{}",
        paths.config.display()
    );
    config.username = prompt("账号", &config.username)?;
    print!("密码（留空保留）：");
    io::stdout().flush().map_err(|e| e.to_string())?;
    // 原生 read -s 会在读取结束或中断时恢复终端，密码不进入命令参数。
    let output = Command::new("/bin/bash")
        .args([
            "-c",
            r#"IFS= read -r -s task_password || exit 1; printf '%s' "$task_password""#,
        ])
        .stdin(Stdio::inherit())
        .output()
        .map_err(|e| e.to_string())?;
    println!();
    if !output.status.success() {
        return Err("配置已取消，原配置未改动。".into());
    }
    let password = String::from_utf8(output.stdout).map_err(|_| "密码必须是 UTF-8 文本。")?;
    if !password.is_empty() {
        config.password = password;
    }
    config.ssid = prompt("校园 Wi-Fi 名称", &config.ssid)?;
    config.server_url = prompt("认证地址", &config.server_url)?;
    let current = match config.proxy_mode {
        ProxyMode::Auto => "auto",
        ProxyMode::Direct => "direct",
        ProxyMode::Proxy => "proxy",
    };
    config.proxy_mode = match prompt("连接方式 auto / direct / proxy", current)?.as_str() {
        "auto" => ProxyMode::Auto,
        "direct" => ProxyMode::Direct,
        "proxy" => ProxyMode::Proxy,
        _ => return Err("连接方式须为 auto、direct 或 proxy；原配置未改动。".into()),
    };
    if config.proxy_mode != ProxyMode::Direct {
        config.proxy_url = prompt("本地代理地址", &config.proxy_url)?;
    }
    let mut effective = config.clone();
    if let Ok(password) = std::env::var("CSUST_PASSWORD") {
        effective.password = password;
        println!("CSUST_PASSWORD 已设置，运行时优先使用环境变量中的密码。");
    }
    effective.validate()?;
    save_json(&paths.config, &config).map_err(|e| format!("保存失败，原配置未替换：{e}"))?;
    println!("配置已保存，下次后台检查自动生效。立即尝试：csust-auto-login login");
    Ok(())
}
