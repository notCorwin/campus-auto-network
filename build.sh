#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "🔨 正在编译 csust-auto-login (release mode)..."
cargo build --release

echo ""
echo "✅ 编译完成！二进制文件位置："
echo "   $(pwd)/target/release/csust-auto-login"
echo ""
echo "💡 如需配置账号密码，请编辑 src/config.rs"
echo ""
echo "🚀 如需开机自启，请执行："
echo "   bash install.sh"