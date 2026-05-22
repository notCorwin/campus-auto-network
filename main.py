#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto_login_csust_no_deps.py
纯标准库实现的 CSUST eportal 自动登录脚本（GET）
不依赖第三方库，方便打包为 macOS 应用（Automator）。
配置：在文件顶部填 USERNAME / PASSWORD（或将 PASSWORD=None 以运行时输入）
"""

import os
import sys
import ssl
import json
import socket
import urllib.parse
import urllib.request
import http.cookiejar as cookiejar
from pathlib import Path
from getpass import getpass
from datetime import datetime, timedelta
import subprocess

def cleanup_old_logs(logs_dir, max_age_hours=0.25):
    """删除超过指定小时数的日志文件（彻底删除，不放回收站）。
    
    使用文件修改时间(mtime)判断，支持所有 .log 文件。
    默认保留最近 15 分钟 (0.25小时)。
    """
    if not logs_dir.exists():
        return
    
    # 计算截止时间戳
    cutoff_timestamp = datetime.now().timestamp() - (max_age_hours * 3600)
    
    try:
        for log_file in logs_dir.glob("*.log"):
            try:
                # 获取文件修改时间
                mtime = log_file.stat().st_mtime
                if mtime < cutoff_timestamp:
                    log_file.unlink()  # 彻底删除
            except OSError:
                continue
    except Exception:
        pass

def show_alert(message, title="CSUST Auto Login"):
    """使用 AppleScript 在 macOS 上发送原生通知横幅（非阻塞）。"""
    # 转义双引号以防 AppleScript 报错
    safe_msg = message.replace('"', '\\"')
    script = f'display notification "{safe_msg}" with title "{title}"'
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except Exception:
        # 如果 osascript 失败，回退到标准输出
        print(f"[{title}] {message}")

# ---------------- CONFIG ----------------
USERNAME = "202401150107"   # 填学号或账号
PASSWORD = "tdVrB!D8mjmqvdcH"   # 填密码；若设为 None，运行时会提示你输入
# 如果你愿意让脚本自动检测 IP，设为 True；否则手动把 IP 填到 WLAN_USER_IP
AUTO_DETECT_IP = True
WLAN_USER_IP = ""  # 如果不自动检测，可填 "10.161.206.109"
# 目标 (通常可按抓包来)
SCHEME = "https"  # 修改为 https， port 802 是加密端口
HOST = "login.csust.edu.cn"
PORT = "802"
LOGIN_PATH = "/eportal/portal/login"

TARGET_SSID = "csust-dx"  # 目标 WiFi 名称
# ----------------------------------------

SCRIPT_DIR = Path(__file__).parent
COOKIES_PATH = SCRIPT_DIR / "csust_session_cookies.json"
LOGS_DIR = SCRIPT_DIR / "logs"
VERIFY_SSL = False  # 校园自签证书环境，设 False
TIMEOUT = 15

# Ensure no system proxy interferes at both the OS and Python level
PROXY_VARS = (
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"
)
for var in PROXY_VARS:
    os.environ.pop(var, None)

def get_current_ssid():
    """获取当前连接的 WiFi SSID (macOS)，优先使用 ipconfig。"""
    # 尝试遍历常见的 WiFi 接口名称
    for interface in ["en0", "en1", "en2"]:
        # 方案1: ipconfig getsummary
        try:
            cmd = ["ipconfig", "getsummary", interface]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if "SSID :" in line:
                        parts = line.split(" : ")
                        if len(parts) > 1:
                            ssid = parts[1].strip()
                            if ssid: return ssid
        except Exception:
            pass

        # 方案2: networksetup (备选)
        try:
            cmd = ["networksetup", "-getairportnetwork", interface]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0:
                line = result.stdout.strip()
                if "Current Wi-Fi Network:" in line:
                    ssid = line.split(": ")[1].strip()
                    if ssid: return ssid
        except Exception:
            continue
    return None

def detect_local_ip():
    """尝试通过 UDP socket 推断本机局域网出口 IP（不会发送数据）。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return ""

def load_cookies_jar():
    cj = cookiejar.LWPCookieJar()
    if COOKIES_PATH.exists():
        try:
            cj.load(str(COOKIES_PATH), ignore_discard=True, ignore_expires=True)
        except Exception:
            # try parse as JSON fallback
            try:
                data = json.loads(COOKIES_PATH.read_text(encoding="utf-8"))
                for k, v in data.items():
                    ck = cookiejar.Cookie(version=0, name=k, value=v, port=None, port_specified=False,
                                         domain=HOST, domain_specified=False, domain_initial_dot=False,
                                         path="/", path_specified=True, secure=False, expires=None,
                                         discard=True, comment=None, comment_url=None, rest={})
                    cj.set_cookie(ck)
            except Exception:
                pass
    return cj

def save_cookies_jar(cj):
    # 保存为两种格式：LWPCookieJar（兼容性）与简易 JSON（方便查看）
    try:
        cj.save(str(COOKIES_PATH), ignore_discard=True, ignore_expires=True)
    except Exception:
        pass
    try:
        d = {c.name: c.value for c in cj}
        json_path = COOKIES_PATH.with_suffix(".json")
        json_path.write_text(json.dumps(d), encoding="utf-8")
    except Exception:
        pass

def build_params(username, password, wlan_ip):
    """跟你浏览器抓到的 GET 参数保持一致"""
    user_account = f",0,{username}"
    params = {
        "callback": "dr1003",
        "login_method": "1",
        "user_account": user_account,
        "user_password": password,
        "wlan_user_ip": wlan_ip or "",
        "wlan_user_ipv6": "",
        "wlan_user_mac": "000000000000",
        "wlan_ac_ip": "",
        "wlan_ac_name": "",
        "jsVersion": "4.2.1",
        "terminal_type": "1",
        "lang": "zh-cn",
        "v": "8207",
    }
    return params

def make_opener(cj, verify_ssl):
    """构造 urllib opener：cookie 支持 + 不走代理 + 允许忽略证书"""
    handlers = []
    handlers.append(urllib.request.HTTPCookieProcessor(cj))
    # empty proxy handler => 显式不走代理
    handlers.append(urllib.request.ProxyHandler({}))
    if not verify_ssl:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        # Allow legacy protocols for older campus network hardware
        ctx.set_ciphers('DEFAULT@SECLEVEL=1')
        ctx.options |= ssl.OP_NO_SSLv2 | ssl.OP_NO_SSLv3
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    else:
        handlers.append(urllib.request.HTTPSHandler())
    opener = urllib.request.build_opener(*handlers)
    # set a browser-like User-Agent
    opener.addheaders = [
        ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36"),
        ("Accept", "*/*"),
        ("Referer", f"{SCHEME}://{HOST}:{PORT}/"),
    ]
    return opener

def log_to_file(content, filename_prefix=""):
    """保存日志到文件。"""
    try:
        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d%H%M%S%f")[:16]
        prefix = f"{filename_prefix}_" if filename_prefix else ""
        log_file = LOGS_DIR / f"{prefix}{timestamp}.log"
        
        with open(log_file, "wb") as f:
            if isinstance(content, str):
                f.write(content.encode('utf-8', errors='replace'))
            else:
                f.write(content)
        
        # 清理超过15分钟的旧日志
        cleanup_old_logs(LOGS_DIR, max_age_hours=0.25)
    except Exception:
        pass

def main():
    global WLAN_USER_IP
    # 静默等待 2 秒以确保系统网络栈在自动化触发后完全稳定（解决 RemoteDisconnected）
    import time
    time.sleep(2)
    
    # 检查当前目录是否可写
    try:
        test_file = SCRIPT_DIR / ".write_test"
        test_file.touch()
        test_file.unlink()
    except Exception:
        show_alert(f"当前目录缺少写入权限：\n{SCRIPT_DIR}\n\n请将脚本移动到“桌面”或“下载”文件夹后再运行。", "权限错误")
        sys.exit(1)

    # 启动时立即清理超过15分钟的旧日志
    cleanup_old_logs(LOGS_DIR, max_age_hours=0.25)

    # WiFi/网络环境检测 (移除重试逻辑，直接检测一次)
    current_ssid = get_current_ssid()
    detected_ip = detect_local_ip()
    
    # 1. SSID 匹配 (不分大小写)
    ssid_match = current_ssid and current_ssid.lower() == TARGET_SSID.lower()
    # 2. IP 段匹配 (10.161.*)
    ip_match = detected_ip.startswith("10.161.")
    
    if not (ssid_match or ip_match):
        # 如果环境不匹配，完全静默退出，不生成垃圾日志
        return

    if not USERNAME or USERNAME.startswith("your_"):
        show_alert("请先编辑脚本顶部，将 USERNAME 填入。", "配置错误")
        sys.exit(2)
        
    pw = PASSWORD
    if pw is None:
        pw = getpass("Password: ")

    if AUTO_DETECT_IP:
        if detected_ip:
            WLAN_USER_IP = detected_ip
        else:
            show_alert("自动检测 IP 失败，无法进行登录。", "检测失败")
            return

    # 构造请求
    cj = load_cookies_jar()
    opener = make_opener(cj, VERIFY_SSL)
    params = build_params(USERNAME, pw, WLAN_USER_IP)
    query = urllib.parse.urlencode(params, safe=',')
    url = f"{SCHEME}://{HOST}:{PORT}{LOGIN_PATH}?{query}"

    # 立即尝试登录 (无重试逻辑)
    try:
        req = urllib.request.Request(url)
        with opener.open(req, timeout=TIMEOUT) as resp:
            body = resp.read()
            try:
                text = body.decode('utf-8', errors='replace')
            except Exception:
                text = body.decode('latin1', errors='replace')
            
            # 保存本次运行日志
            log_to_file(f"Request URL: {url}\nParams: {query}\n" + ("-" * 40) + "\n" + text, filename_prefix="RUN")

            if "Dr.COMWebLoginID_3.htm" in text or "成功" in text or "online" in text.lower() or "已经在线" in text or "认证超时" in text:
                save_cookies_jar(cj)
                print("登录成功或已在线。")
            elif "Dr.COMWebLoginID_2.htm" in text or "密码错误" in text:
                show_alert("登录失败: 账号密码有误或登录参数失效。", "登录失败")
            else:
                show_alert(f"无法确定登录结果。服务器返回：\n{text[:200]}...", "状态未知")
                
    except Exception as e:
        show_alert(f"网络连接失败: {repr(e)}\n\n(提示: 请检查是否连上了校园网 WiFi)", "网络异常")

if __name__ == "__main__":
    main()
