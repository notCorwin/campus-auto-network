#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PLIST_SRC="com.nowaywastaken.csustautologin.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.nowaywastaken.csustautologin.plist"
LABEL="com.nowaywastaken.csustautologin"

echo "🔨 正在编译 csust-auto-login (release mode)..."
cargo build --release

echo ""
echo "📁 复制 plist 到 LaunchAgents..."
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DEST"

echo ""
echo "⏳ 卸载旧任务（如有）..."
launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true

echo "🚀 加载 launchd 任务..."
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo ""
echo "✅ 安装完成！csust-auto-login 将在每次登录时自动运行。"
echo ""
echo "📋 常用命令："
echo "   查看状态：launchctl print gui/$(id -u)/${LABEL}"
echo "   手动加载：launchctl bootstrap gui/$(id -u) \"$PLIST_DEST\""
echo "   手动卸载：launchctl bootout gui/$(id -u) \"$PLIST_DEST\""
echo "   查看日志：ls -la \"$(pwd)/logs/\""
echo ""
echo "⚠️  如需修改登录凭据，请编辑 src/config.rs 后重新执行本脚本。"