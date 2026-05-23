//! CSUST eportal 校园网自动登录工具（Rust 实现）
//!
//! 纯 Rust 重写，零 Python 依赖，编译为原生 macOS 二进制。
//! 功能与原 Python 脚本完全一致：
//! - 自动检测 SSID 是否为目标校园网
//! - 自动检测本机 IP
//! - 通过 GET 请求完成 eportal 认证
//! - 日志记录与自动清理
//! - macOS 原生通知

mod config;

use chrono::Local;
use config::*;
use reqwest::blocking::Client;
use std::fs;
use std::io::{self, Write};
use std::net::UdpSocket;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

// --------------- 工具函数 ---------------

/// 获取当前日期时间字符串，用于日志文件名
fn timestamp_str() -> String {
    Local::now().format("%Y%m%d%H%M%S%f").to_string()[..16].to_string()
}

/// macOS 原生通知（通过 osascript）
fn show_alert(message: &str, title: &str) {
    let safe_msg = message.replace('"', "\\\"");
    let script = format!(
        r#"display notification "{}" with title "{}""#,
        safe_msg, title
    );
    if let Err(e) = Command::new("osascript").arg("-e").arg(&script).output() {
        eprintln!("[{title}] {message} (通知发送失败: {e})");
    }
}

/// 清理过期日志文件
fn cleanup_old_logs(logs_dir: &PathBuf, max_age_hours: f64) {
    if !logs_dir.exists() {
        return;
    }
    let cutoff = Local::now().timestamp() as f64 - (max_age_hours * 3600.0);
    if let Ok(entries) = fs::read_dir(logs_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("log") {
                if let Ok(meta) = path.metadata() {
                    if let Ok(mtime) = meta.modified() {
                        if let Ok(duration) = mtime.duration_since(std::time::UNIX_EPOCH) {
                            if (duration.as_secs_f64()) < cutoff {
                                let _ = fs::remove_file(&path);
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 将内容写入日志文件
fn log_to_file(content: &str, filename_prefix: &str) {
    let logs_dir = project_dir().join("logs");
    if fs::create_dir_all(&logs_dir).is_err() {
        return;
    }
    let prefix = if filename_prefix.is_empty() {
        String::new()
    } else {
        format!("{}_", filename_prefix)
    };
    let log_path = logs_dir.join(format!("{}{}.log", prefix, timestamp_str()));
    let _ = fs::write(&log_path, content);

    // 清理旧日志
    cleanup_old_logs(&logs_dir, LOG_MAX_AGE_HOURS);
}

/// 获取当前 SSID（macOS）
fn get_current_ssid() -> Option<String> {
    for interface in &["en0", "en1", "en2"] {
        // 方案1：ipconfig getsummary (更快)
        if let Ok(output) = Command::new("ipconfig")
            .arg("getsummary")
            .arg(interface)
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    if let Some(val) = line.strip_prefix("SSID : ") {
                        let ssid = val.trim().to_string();
                        if !ssid.is_empty() {
                            return Some(ssid);
                        }
                    }
                }
            }
        }

        // 方案2：networksetup 备选
        if let Ok(output) = Command::new("networksetup")
            .arg("-getairportnetwork")
            .arg(interface)
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                if let Some(val) = stdout.trim().strip_prefix("Current Wi-Fi Network: ") {
                    let ssid = val.trim().to_string();
                    if !ssid.is_empty() {
                        return Some(ssid);
                    }
                }
            }
        }
    }
    None
}

/// 通过 UDP Socket 推断本机局域网出口 IP
fn detect_local_ip() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let ip = socket.local_addr().ok()?;
    Some(ip.ip().to_string())
}

/// 项目根目录
fn project_dir() -> PathBuf {
    let exe = std::env::current_exe()
        .unwrap_or_else(|_| PathBuf::from("."));
    let dir = exe.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| PathBuf::from("."));
    if dir.ends_with("target/debug") || dir.ends_with("target/release") {
        // target/{debug,release} -> 向上两级到项目根目录
        dir.parent()
            .and_then(|p| p.parent())
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| {
                std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
            })
    } else {
        dir
    }
}

/// 写入权限检测
fn check_writable() -> Result<(), String> {
    let test_path = project_dir().join(".write_test");
    fs::write(&test_path, "test")
        .map_err(|e| format!("当前目录缺少写入权限：{:?}\n{}", project_dir(), e))?;
    let _ = fs::remove_file(&test_path);
    Ok(())
}

// --------------- 登录逻辑 ---------------

/// 构建登录参数
fn build_params<'a>(username: &'a str, password: &'a str, wlan_ip: &'a str) -> Vec<(&'a str, String)> {
    let user_account = format!(",0,{}", username);
    vec![
        ("callback", "dr1003".to_string()),
        ("login_method", "1".to_string()),
        ("user_account", user_account),
        ("user_password", password.to_string()),
        ("wlan_user_ip", wlan_ip.to_string()),
        ("wlan_user_ipv6", String::new()),
        ("wlan_user_mac", "000000000000".to_string()),
        ("wlan_ac_ip", String::new()),
        ("wlan_ac_name", String::new()),
        ("jsVersion", "4.2.1".to_string()),
        ("terminal_type", "1".to_string()),
        ("lang", "zh-cn".to_string()),
        ("v", "8207".to_string()),
    ]
}

/// 检查登录响应是否表示成功
fn is_login_successful(text: &str) -> bool {
    text.contains("Dr.COMWebLoginID_3.htm")
        || text.contains("成功")
        || text.to_lowercase().contains("online")
        || text.contains("已经在线")
        || text.contains("认证成功")
}

/// 检查登录响应是否表示密码错误
fn is_login_failed(text: &str) -> bool {
    text.contains("Dr.COMWebLoginID_2.htm")
        || text.contains("密码错误")
        || text.contains("认证超时")
}

// --------------- 登录执行（单次尝试） ---------------

/// 执行单次登录尝试，返回 true 表示已连上网（成功/已在线），false 表示需要重试
fn try_login(on_target_ssid: bool) -> bool {
    // 检测本机 IP
    let detected_ip = detect_local_ip();

    // IP 段匹配 (10.161.*) —— 非目标 SSID 时用于判断是否在校园网环境
    let ip_match = detected_ip
        .as_ref()
        .map(|ip| ip.starts_with("10.161."))
        .unwrap_or(false);

    // 既不是目标 SSID 也不是校园网 IP 段 → 环境不匹配，无需重试
    if !on_target_ssid && !ip_match {
        return true;
    }

    // 连通性检测：如果能上网就不再执行登录
    if can_reach_internet() {
        return true;
    }

    // 获取密码
    let password = match PASSWORD {
        Some(pw) => pw.to_string(),
        None => {
            match std::env::var("CSUST_PASSWORD") {
                Ok(pw) => pw,
                Err(_) => {
                    print!("Password: ");
                    let _ = io::stdout().flush();
                    let mut pw = String::new();
                    if io::stdin().read_line(&mut pw).is_ok() {
                        pw.trim().to_string()
                    } else {
                        show_alert("无法读取密码输入。", "配置错误");
                        std::process::exit(2);
                    }
                }
            }
        }
    };

    // 自动检测 IP（每次重试重新检测，因为 IP 可能变化）
    let wlan_ip = if AUTO_DETECT_IP {
        match detect_local_ip() {
            Some(ip) => ip,
            None => {
                // IP 尚未就绪，重试
                return false;
            }
        }
    } else {
        WLAN_USER_IP.to_string()
    };

    // 构造 HTTP 客户端
    let client: Client = Client::builder()
        .danger_accept_invalid_certs(!VERIFY_SSL)
        .timeout(Duration::from_secs(TIMEOUT_SECS))
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36")
        .no_proxy()
        .referer(false)
        .build()
        .unwrap_or_else(|e| {
            show_alert(&format!("无法创建 HTTP 客户端: {e}"), "初始化失败");
            std::process::exit(3);
        });

    // 构造请求 URL
    let params = build_params(USERNAME, &password, &wlan_ip);
    let url = format!("{}://{}:{}{}", SCHEME, HOST, PORT, LOGIN_PATH);

    // 发送请求
    let referer = format!("{}://{}:{}/", SCHEME, HOST, PORT);
    match client
        .get(&url)
        .header("Referer", &referer)
        .query(&params)
        .send()
    {
        Ok(resp) => {
            let text = resp.text().unwrap_or_default();

            // 保存日志
            let log_content = format!(
                "Request URL: {}\nParams: {:?}\n{}\n{}",
                url,
                params,
                "-".repeat(40),
                text
            );
            log_to_file(&log_content, "RUN");

            // 判断登录结果
            if is_login_successful(&text) {
                println!("登录成功或已在线。");
                return true;
            }
            if is_login_failed(&text) {
                show_alert("登录失败: 账号密码有误或登录参数失效。", "登录失败");
            } else {
                let preview = if text.len() > 200 {
                    format!("{}...", &text[..200])
                } else {
                    text.to_string()
                };
                show_alert(&format!("无法确定登录结果。服务器返回：\n{}", preview), "状态未知");
            }

            // 登录失败，需要重试
            false
        }
        Err(e) => {
            show_alert(
                &format!("网络连接失败: {e:?}\n\n(提示: 请检查是否连上了校园网 WiFi)"),
                "网络异常",
            );
            // 网络异常，重试
            false
        }
    }
}

// --------------- 主流程 ---------------

fn main() {
    // 启动延时，等待网络栈稳定
    std::thread::sleep(Duration::from_secs(STARTUP_DELAY_SECS));

    // 写入权限检测
    if let Err(msg) = check_writable() {
        show_alert(&msg, "权限错误");
        std::process::exit(1);
    }

    // 启动时立即清理旧日志
    cleanup_old_logs(&project_dir().join("logs"), LOG_MAX_AGE_HOURS);

    // 检测 SSID，判断是否在目标校园网下
    let current_ssid = get_current_ssid();
    let on_target_ssid = current_ssid
        .as_ref()
        .map(|s| s.to_lowercase() == TARGET_SSID.to_lowercase())
        .unwrap_or(false);

    // 如果不是目标 SSID，尝试有限次数后退出
    let mut attempt: u32 = 0;
    loop {
        attempt += 1;

        if !on_target_ssid && attempt > RETRY_ATTEMPTS {
            // 非目标 SSID 有限重试耗尽，静默退出
            return;
        }

        if attempt > 1 {
            std::thread::sleep(Duration::from_secs(RETRY_INTERVAL_SECS));
        }

        if try_login(on_target_ssid) {
            return;
        }
    }
}

// --------------- 连通性检测 ---------------

/// 检查能否连通外网（204 探针方式）
fn can_reach_internet() -> bool {
    let probes = [
        "http://connect.rom.miui.com/generate_204",
        "http://www.gstatic.com/generate_204",
        "http://captive.apple.com/hotspot-detect.html",
    ];
    for url in &probes {
        match reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(3))
            .no_proxy()
            .danger_accept_invalid_certs(true)
            .build()
        {
            Ok(client) => match client.get(*url).send() {
                Ok(resp) => {
                    // 204 No Content = 确认在线
                    if resp.status() == reqwest::StatusCode::NO_CONTENT {
                        return true;
                    }
                    // Apple captive 探针，在线时返回 200 + "Success"
                    if resp.status().is_success() {
                        if let Ok(body) = resp.text() {
                            if body.contains("Success") {
                                return true;
                            }
                        }
                    }
                }
                Err(_) => continue,
            },
            Err(_) => continue,
        }
    }
    false
}