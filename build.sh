#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "🔨 正在编译 csust-auto-login (release mode)..."
cargo build --release --locked
swiftc -swift-version 5 -O -framework Network \
  -o target/release/csust-auto-login-monitor network_monitor.swift

echo ""
echo "✅ 编译完成！二进制文件位置："
echo "   $(pwd)/target/release/csust-auto-login"
echo "   $(pwd)/target/release/csust-auto-login-monitor"
echo ""
echo "💡 配置账号密码：./target/release/csust-auto-login configure"
echo ""
echo "🚀 如需开机自启，请执行："
echo "   bash install.sh"
