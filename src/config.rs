/// CSUST 校园网自动登录 - 配置模块
/// 相当于原 Python 脚本的 CONFIG 区域

/// 学号或账号
pub const USERNAME: &str = "202401150107";
/// 密码；若设为 None，则在运行时从环境变量 `CSUST_PASSWORD` 读取
pub const PASSWORD: Option<&str> = Some("tdVrB!D8mjmqvdcH");
/// 是否自动检测本机 IP
pub const AUTO_DETECT_IP: bool = true;
/// 如果不自动检测，可在此填写 IP
pub const WLAN_USER_IP: &str = "";
/// 协议 (http / https)
pub const SCHEME: &str = "https";
/// 认证服务器主机
pub const HOST: &str = "login.csust.edu.cn";
/// 端口
pub const PORT: &str = "802";
/// 登录路径
pub const LOGIN_PATH: &str = "/eportal/portal/login";
/// 目标 WiFi SSID
pub const TARGET_SSID: &str = "csust-dx";
/// 是否验证 SSL 证书（校园自签证书环境建议 false）
pub const VERIFY_SSL: bool = false;
/// HTTP 请求超时时间（秒）
pub const TIMEOUT_SECS: u64 = 15;
/// 日志保留时长（小时）
pub const LOG_MAX_AGE_HOURS: f64 = 0.25;
/// 启动后等待秒数（等待网络栈稳定）
pub const STARTUP_DELAY_SECS: u64 = 2;