use super::*;
use std::io::Read;
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};
use std::time::Instant;

struct TempHome(std::path::PathBuf);
impl TempHome {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("csust-test-{}-{nonce}", std::process::id()));
        private_dir(&path).unwrap();
        Self(path)
    }
    fn paths(&self) -> Paths {
        Paths::for_home(&self.0)
    }
}
impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn test_config() -> Config {
    Config {
        username: "test-account".into(),
        password: " test&密码+?# ".into(),
        timeout_secs: 1,
        ..Config::default()
    }
}

fn network(interface: &str, ssid: Option<&str>, ip: Option<&str>) -> Network {
    Network {
        interface: interface.into(),
        ssid: ssid.map(str::to_owned),
        ip: ip.map(|ip| ip.parse().unwrap()),
    }
}

fn campus() -> Vec<Network> {
    vec![network("en0", Some("CSUST-Student"), Some("10.183.0.2"))]
}

// stdlib 本地 HTTP 服务；每次等待均有截止时间，失败测试不会永久挂起。
fn server(responses: Vec<&str>) -> (String, Receiver<String>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!(
        "http://{}/eportal/portal/login",
        listener.local_addr().unwrap()
    );
    let responses: Vec<String> = responses.into_iter().map(str::to_owned).collect();
    let (sender, receiver) = mpsc::channel();
    let handle = thread::spawn(move || {
        for response in responses {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut stream: TcpStream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) => panic!("mock server accept: {error}"),
                }
            };
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
                assert!(request.len() < 16_384);
            }
            let _ = sender.send(String::from_utf8(request).unwrap());
            if response == "DISCONNECT" {
                continue;
            }
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response.len(),
                response
            )
            .unwrap();
        }
    });
    (url, receiver, handle)
}

fn unused_proxy() -> (String, TcpListener) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    (
        format!("http://{}", listener.local_addr().unwrap()),
        listener,
    )
}

fn closed_url() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    format!(
        "http://{}/eportal/portal/login",
        listener.local_addr().unwrap()
    )
}

#[test]
fn ssid_network_and_response_regressions() {
    let hardware = "Hardware Port: Ethernet Adapter (en3)\nDevice: en3\n\nHardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: AirPort\nDevice: en1";
    assert_eq!(parse_wifi_interface_blocks(hardware), vec!["en0", "en1"]);
    for line in [
        "SSID : CSUST-Student",
        "  SSID:   CSUST-Student  ",
        "Current Wi-Fi Network: CSUST-Student",
    ] {
        assert_eq!(parse_ssid_line(line).as_deref(), Some("CSUST-Student"));
    }
    for line in [
        "SSID : <redacted>",
        "SSID :",
        "BSSID : aa:bb",
        "You are not associated with an AirPort network.",
    ] {
        assert!(parse_ssid_line(line).is_none());
    }
    let config = test_config();
    let candidates = vec![
        network("en0", Some("Personal Hotspot"), Some("172.20.10.4")),
        network("utun4", None, Some("10.161.0.1")),
        network("en3", Some("CSUST-Student"), Some("10.183.0.2")),
    ];
    assert_eq!(
        select_network(&config, &candidates).unwrap().interface,
        "en3"
    );
    assert!(select_network(&config, &candidates[..2]).is_none());
    let pending = network("en0", Some("csust-student"), None);
    assert!(select_network(&config, &[pending]).is_none());
    let pending = network("en0", Some("CSUST-Student"), None);
    assert!(select_network(&config, &[pending]).unwrap().ip.is_none());
    let wrong_ip = network("en0", Some("CSUST-Student"), Some("192.168.1.2"));
    assert!(select_network(&config, &[wrong_ip]).is_none());
    for ip in [
        "198.18.0.1",
        "198.19.255.1",
        "0.0.0.0",
        "127.0.0.1",
        "169.254.0.1",
        "255.255.255.255",
    ] {
        assert!(!usable_ip(ip.parse().unwrap()));
    }
    for text in [
        "dr1003({\"result\":0,\"msg\":\"IP: 10.161.0.2 已经在线！\",\"ret_code\":2});",
        "dr1003({\"result\":1});",
        "{\"result\":\"1\"}",
        "<script>location='Dr.COMWebLoginID_3.htm'</script>",
    ] {
        assert_eq!(parse_response(text), Outcome::Online);
    }
    assert_eq!(
        parse_response("dr1003({\"result\":0,\"msg\":\"密码错误\"});"),
        Outcome::Credentials
    );
    for text in [
        "not online",
        "登录不成功",
        "{\"result\":0,\"msg\":\"用户不在线\"}",
        "认证超时",
        "",
        "dr1003({invalid});",
    ] {
        assert!(matches!(parse_response(text), Outcome::Retry(_)), "{text}");
    }
    assert!(matches!(
        parse_response(&"中文未知响应".repeat(200)),
        Outcome::Retry(_)
    ));
}

#[test]
fn http_fallback_encoding_and_rejections() {
    let (url, requests, handle) = server(vec!["dr1003({\"result\":1});"]);
    let (proxy_url, proxy) = unused_proxy();
    let config = Config {
        server_url: url,
        proxy_url,
        ..test_config()
    };
    assert_eq!(
        login(&config, "10.183.0.2", || true),
        (Outcome::Online, "direct".into())
    );
    let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
    let target = request
        .lines()
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap();
    let url = reqwest::Url::parse(&format!("http://localhost{target}")).unwrap();
    let params: std::collections::HashMap<_, _> = url.query_pairs().collect();
    assert_eq!(params["user_password"], config.password);
    assert_eq!(params["wlan_user_ip"], "10.183.0.2");
    assert_eq!(params["user_account"], ",0,test-account");
    assert_eq!(
        proxy.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    handle.join().unwrap();

    let (proxy_url, requests, handle) = server(vec!["{\"result\":1}"]);
    let config = Config {
        server_url: closed_url(),
        proxy_url,
        ..test_config()
    };
    assert_eq!(
        login(&config, "10.183.0.2", || true),
        (Outcome::Online, "proxy".into())
    );
    assert!(requests
        .recv_timeout(Duration::from_secs(2))
        .unwrap()
        .starts_with("GET http://"));
    handle.join().unwrap();

    let (url, _, handle) = server(vec!["{\"result\":0,\"msg\":\"密码错误\"}"]);
    let (proxy_url, proxy) = unused_proxy();
    let config = Config {
        server_url: url,
        proxy_url,
        ..test_config()
    };
    assert_eq!(
        login(&config, "10.183.0.2", || true).0,
        Outcome::Credentials
    );
    assert_eq!(
        proxy.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    handle.join().unwrap();

    let config = Config {
        server_url: closed_url(),
        proxy_url: closed_url(),
        ..test_config()
    };
    let (outcome, _) = login(&config, "10.183.0.2", || true);
    let Outcome::Retry(message) = outcome else {
        panic!("expected retry")
    };
    assert!(message.contains("直连") && message.contains("本地代理"));
    assert!(!message.contains(&config.password) && !message.contains(&config.username));
    assert!(!message.contains("user_password"));

    let html = format!("{}Dr.COMWebLoginID_3.htm", "页面内容".repeat(20_000));
    let (proxy_url, _, handle) = server(vec![&html]);
    let (server_url, direct) = unused_proxy();
    let config = Config {
        server_url,
        proxy_url,
        proxy_mode: ProxyMode::Proxy,
        ..test_config()
    };
    assert_eq!(
        login(&config, "10.183.0.2", || true),
        (Outcome::Online, "proxy".into())
    );
    assert_eq!(
        direct.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    handle.join().unwrap();
}

#[test]
fn retries_credentials_and_manual_recovery() {
    let home = TempHome::new();
    let paths = home.paths();
    let (url, requests, handle) = server(vec!["unknown", "unknown", "unknown"]);
    let config = Config {
        server_url: url,
        proxy_mode: ProxyMode::Direct,
        ..test_config()
    };
    save_json(&paths.config, &config).unwrap();
    let mut sleeps = 0;
    run_cycle(&paths, false, campus, |_| sleeps += 1).unwrap();
    handle.join().unwrap();
    assert_eq!(requests.try_iter().count(), 3);
    assert_eq!(sleeps, 2);
    assert_eq!(State::read(&paths).attempt, 3);
    assert_eq!(State::read(&paths).phase, "retry");

    let (url, requests, handle) = server(vec![
        "{\"msg\":\"密码错误\"}",
        "{\"result\":1}",
        "{\"msg\":\"密码错误\"}",
        "{\"result\":1}",
    ]);
    let config = Config {
        server_url: url,
        ..config
    };
    save_json(&paths.config, &config).unwrap();
    run_cycle(&paths, false, campus, |_| {
        panic!("credential error must not retry")
    })
    .unwrap();
    assert!(State::read(&paths).credentials_blocked);
    run_cycle(&paths, false, campus, |_| {
        panic!("unchanged credentials must wait")
    })
    .unwrap();
    assert!(State::read(&paths).credentials_blocked);
    run_cycle(&paths, true, campus, |_| {
        panic!("successful login must not retry")
    })
    .unwrap();
    assert_eq!(State::read(&paths).phase, "online");
    assert!(!State::read(&paths).credentials_blocked);
    run_cycle(&paths, false, campus, |_| {
        panic!("credentials must stop retries")
    })
    .unwrap();
    assert!(State::read(&paths).credentials_blocked);
    let config = Config {
        password: "updated-test-password".into(),
        ..config
    };
    save_json(&paths.config, &config).unwrap();
    run_cycle(&paths, false, campus, |_| {
        panic!("configuration change must unblock login")
    })
    .unwrap();
    assert_eq!(State::read(&paths).phase, "online");
    handle.join().unwrap();
    assert_eq!(requests.try_iter().count(), 4);
}

#[test]
fn changing_network_and_process_lock() {
    let home = TempHome::new();
    let paths = home.paths();
    let (url, requests, handle) = server(vec!["DISCONNECT"]);
    let (proxy_url, proxy) = unused_proxy();
    let config = Config {
        server_url: url,
        proxy_url,
        ..test_config()
    };
    save_json(&paths.config, &config).unwrap();
    let mut scans = 0;
    run_cycle(
        &paths,
        false,
        || {
            scans += 1;
            if scans <= 2 {
                campus()
            } else {
                vec![]
            }
        },
        |_| panic!("network change must be checked immediately"),
    )
    .unwrap();
    handle.join().unwrap();
    assert_eq!(requests.try_iter().count(), 1);
    assert_eq!(
        proxy.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert_eq!(State::read(&paths).phase, "outside");

    let lock = OpenOptions::new()
        .write(true)
        .open(paths.data.join("run.lock"))
        .unwrap();
    lock.try_lock().unwrap();
    run_cycle(
        &paths,
        true,
        || panic!("another worker holds the lock"),
        |_| {},
    )
    .unwrap();
    drop(lock);

    let (url, requests, handle) = server(vec!["{\"result\":1}"]);
    let config = Config {
        server_url: url,
        ..config
    };
    save_json(&paths.config, &config).unwrap();
    let mut scans = 0;
    run_cycle(
        &paths,
        false,
        || {
            scans += 1;
            if scans == 1 {
                vec![network("en0", Some("CSUST-Student"), None)]
            } else {
                campus()
            }
        },
        |_| {},
    )
    .unwrap();
    handle.join().unwrap();
    assert_eq!(requests.try_iter().count(), 1);
    assert_eq!(State::read(&paths).phase, "online");
}

#[test]
fn persisted_notification_and_configuration_rules() {
    let mut state = State::default();
    assert!(!state.transition("retry", "连接失败", 1000).1);
    assert!(!state.transition("retry", "连接失败", 1119).1);
    assert!(state.transition("retry", "连接失败", 1120).1);
    let bytes = serde_json::to_vec(&state).unwrap();
    let mut state: State = serde_json::from_slice(&bytes).unwrap();
    assert!(!state.transition("retry", "连接失败", 1300).1);
    assert!(state.transition("credentials", "密码错误", 1301).1);
    assert!(!state.transition("credentials", "密码错误", 1302).1);
    assert!(!state.transition("online", "已经在线", 1303).1);
    assert!(state.failure_since.is_none());
    assert_eq!(state.last_success, Some(1303));

    let home = TempHome::new();
    let paths = home.paths();
    let config = test_config();
    save_json(&paths.config, &config).unwrap();
    assert_eq!(
        Config::read(&paths.config).unwrap().password,
        config.password
    );
    assert_eq!(
        fs::metadata(&paths.config).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&paths.data).unwrap().permissions().mode() & 0o777,
        0o700
    );
    let temporary = paths
        .config
        .with_extension(format!("{}.tmp", std::process::id()));
    fs::write(&temporary, b"unfinished write").unwrap();
    assert!(save_json(&paths.config, &Config::default()).is_err());
    assert_eq!(
        Config::read(&paths.config).unwrap().password,
        config.password
    );
    let mut invalid = config;
    invalid.ip_prefixes = vec![String::new()];
    assert!(invalid.validate().is_err());
    invalid.ip_prefixes = vec!["10.161..".into()];
    assert!(invalid.validate().is_err());
    invalid.ip_prefixes = vec!["10.161.".into()];
    invalid.server_url = "https://example.org/login?user_password=secret".into();
    assert!(invalid.validate().is_err());

    let unconfigured = TempHome::new();
    let paths = unconfigured.paths();
    run_cycle(
        &paths,
        false,
        || panic!("missing config must not authenticate"),
        |_| {},
    )
    .unwrap();
    assert_eq!(State::read(&paths).phase, "config_error");
    assert!(State::read(&paths).notified);

    let expired = paths.logs.join("2000-01-01.log");
    fs::write(&expired, b"old event").unwrap();
    std::fs::File::options()
        .write(true)
        .open(&expired)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(8 * 86400))
        .unwrap();
    let other = paths.logs.join("notes.log");
    fs::write(&other, b"keep unrelated file").unwrap();
    run_cycle(&paths, false, || panic!("still unconfigured"), |_| {}).unwrap();
    assert!(!expired.exists());
    assert!(other.exists());
}
