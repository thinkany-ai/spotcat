#!/bin/bash
# 开发模式（make dev）：构建并启动开发版，日志直接输出到终端，改动后自动生效。
#
#   - Swift 代码 / Package.swift / Info.plist：保存后自动增量编译并重启；编译失败时旧进程继续运行
#   - 聊天面板（Resources/chat）和扩展（同级目录 ../spotcat-extensions/extensions）：直接从源码目录加载，保存后页面自动刷新，
#     只改 CSS 时就地替换样式、保留页面状态（见 Sources/Spotcat/Web/DevReload.swift）
#
# Ctrl+C 退出并关闭开发版。不依赖 fswatch 等外部工具。
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="build/Spotcat Dev.app"
STAMP="$(mktemp)"
# 应用日志先写到临时文件，只把 Spotcat 自己的日志（NSLog "Spotcat: …"）和崩溃信息转到终端，
# 过滤掉系统框架的噪音
LOG="$(mktemp -t spotcat-dev)"
tail -n0 -F "$LOG" 2>/dev/null | grep --line-buffered -E '\] Spotcat: |Fatal error|Assertion failed|Thread [0-9]+ Crashed' &
TAIL_PID=$!
# 扩展源码：默认同级目录的 spotcat-extensions 仓库，可用 SPOTCAT_EXTENSIONS_DIR 指定；不存在时只用插件目录
EXTENSIONS_DIR="${SPOTCAT_EXTENSIONS_DIR:-$ROOT/../spotcat-extensions/extensions}"
if [ -d "$EXTENSIONS_DIR" ]; then
  EXTENSIONS_DIR="$(cd "$EXTENSIONS_DIR" && pwd)"
  echo "==> extensions from $EXTENSIONS_DIR"
else
  EXTENSIONS_DIR=""
fi

stop_app() {
  pkill -f "$APP/Contents/MacOS/Spotcat" 2>/dev/null
  while pgrep -f "$APP/Contents/MacOS/Spotcat" >/dev/null; do sleep 0.1; done
}

# 用 open 通过 LaunchServices 启动，与双击打开一致。直接执行二进制时应用是终端的子进程，
# macOS 14+ 会拒绝把它切到前台，设置等普通窗口会被其他应用挡住
# OS_ACTIVITY_DT_MODE 让 NSLog 同时写到 stderr（open 启动时默认只进系统日志）
start_app() {
  open -n "$APP" --env OS_ACTIVITY_DT_MODE=YES \
    --env "SPOTCAT_SOURCE_ROOT=$ROOT" --env "SPOTCAT_EXTENSIONS_DIR=$EXTENSIONS_DIR" \
    --stdout "$LOG" --stderr "$LOG"
}

build() {
  touch "$STAMP"
  echo "==> $(date +%H:%M:%S) building…"
  ./scripts/bundle.sh debug 2>&1 | grep -vE '^\[([0-9]+ ?/ ?[0-9]+|Planning)|replacing existing signature'
  return "${PIPESTATUS[0]}"
}

trap 'stop_app; kill $TAIL_PID 2>/dev/null; rm -f "$STAMP" "$LOG"; exit 0' INT TERM

# 首次构建成功前不启动
until build; do
  echo "!! build failed, waiting for changes…"
  while [ -z "$(find Sources Package.swift Resources/Info.plist -newer "$STAMP" -print -quit)" ]; do sleep 0.5; done
done
stop_app
start_app
echo "==> Spotcat Dev running (Swift changes rebuild + restart; chat/extensions reload live). Ctrl+C to quit."

while true; do
  sleep 0.5
  [ -n "$(find Sources Package.swift Resources/Info.plist -newer "$STAMP" -print -quit)" ] || continue
  sleep 0.3 # 等编辑器把一批文件写完
  if build; then
    stop_app
    start_app
    echo "==> restarted"
  else
    echo "!! build failed, keeping the running app"
  fi
done
