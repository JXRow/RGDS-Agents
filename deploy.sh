#!/bin/sh
# 部署本仓库到 Anbernic RG DS（TF 卡 /mnt/mmc），与原版 rgds-lua-demo 并存互不覆盖
# 用法: ./deploy.sh [目标]        默认 rgds（mDNS: rgds.local）
#
# 目录布局（全部在 TF 卡上，自包含）：
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2.sh               ← 前端菜单入口
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/main.lua
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/conf.lua
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/subscreen.lua     ← 第二块屏上的信息面板窗口
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/micwave.lua       ← 麦克风波形/电平/按键录音（主线程）
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/micthread.lua     ← 录音线程（OpenAL → 共享环形缓冲）
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/alsoft.conf       ← OpenAL 私有配置：录音走 dsnoop（启动脚本 export ALSOFT_CONF）
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/stt.lua          ← 常驻 SenseVoice 助手（游戏启动/退出时拉起和关掉）
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/sttthread.lua
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/aid.lua          ← MiniMax 对话（游戏启动/退出时拉起和关掉 rgds-aid）
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/aidthread.lua
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/rgds-aid.py      ← 本机 sidecar，密钥在设备 config 里，不进仓库
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/stt/             ← sv-helper、两个 sherpa .so、model.int8.onnx、tokens.txt
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/fonts/          ← 思源黑体，信息面板和主屏字幕用
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/run-via-menu.sh  ← SSH 按菜单流程启动
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/bin/love         ← LÖVE 11.5 aarch64
#   /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/lib/*.so         ← 系统缺失的 3 个 so
#   /mnt/mmc/Roms/APPS/Imgs/rgds-lua-demo-v2.png         ← 菜单图标
# 前端只把 APPS 根目录下的 *.sh 列为条目，子目录里的 run-via-menu.sh 不会出现在菜单里。

set -e

TARGET="${1:-rgds}"
NAME="rgds-lua-demo-v2"
APPS="/mnt/mmc/Roms/APPS"
GAME="$APPS/$NAME"
SCRIPT="$APPS/$NAME.sh"

echo ">> 目标: $TARGET"
echo ">> 复制应用代码"
ssh "$TARGET" "mkdir -p '$GAME/bin' '$GAME/lib' '$APPS/Imgs'"
scp -q main.lua conf.lua subscreen.lua micwave.lua micthread.lua stt.lua sttthread.lua aid.lua aidthread.lua rgds-aid.py alsoft.conf run-via-menu.sh "$TARGET:$GAME/"
ssh "$TARGET" "chmod +x '$GAME/run-via-menu.sh'"

if [ -f fonts/SourceHanSansCN-Regular.otf ]; then
  echo ">> 复制中日文字体"
  ssh "$TARGET" "mkdir -p '$GAME/fonts'"
  scp -q fonts/SourceHanSansCN-Regular.otf "$TARGET:$GAME/fonts/"
fi

if [ -x stt/sv-helper ]; then
  echo ">> 复制语音识别助手和模型（模型约 229MB，大小相同则跳过）"
  ssh "$TARGET" "mkdir -p '$GAME/stt/lib'"
  scp -q stt/sv-helper stt/tokens.txt "$TARGET:$GAME/stt/"
  scp -q stt/lib/libonnxruntime.so stt/lib/libsherpa-onnx-c-api.so "$TARGET:$GAME/stt/lib/"
  ssh "$TARGET" "chmod +x '$GAME/stt/sv-helper'"
  local_size=$(wc -c < stt/model.int8.onnx)
  remote_size=$(ssh "$TARGET" "wc -c < '$GAME/stt/model.int8.onnx' 2>/dev/null" || echo 0)
  if [ "$local_size" != "$remote_size" ]; then
    scp -q stt/model.int8.onnx "$TARGET:$GAME/stt/model.int8.onnx"
  else
    echo ">> 模型已在掌机上，跳过"
  fi
fi

echo ">> 从掌机 /opt/love 复制运行时（若不存在则提示）"
ssh "$TARGET" "
set -e
if [ ! -x /opt/love/love-11.5 ]; then
  echo '!! /opt/love/love-11.5 不存在。先安装 LÖVE 11.5 aarch64：'
  echo '   curl -sLO https://deb.debian.org/debian/pool/main/l/love/love_11.5-4_arm64.deb'
  echo '   dpkg-deb -x love_11.5-4_arm64.deb /tmp/lv && cp /tmp/lv/usr/bin/love-11.5 /opt/love/'
  exit 1
fi
cp /opt/love/love-11.5 '$GAME/bin/love'
for so in libluajit-5.1.so.2 libmodplug.so.1 libtheoradec.so.2; do
  src=/opt/love/lib/\$so
  case \$so in
    libmodplug.so.1) [ -f \$src ] || src=/opt/love/lib/libmodplug.so.1.0.0 ;;
    libtheoradec.so.2) [ -f \$src ] || src=/opt/love/lib/libtheoradec.so.2.1.1 ;;
  esac
  [ -f \"\$src\" ] && cp \"\$src\" '$GAME/lib/'\$so
done
chmod +x '$GAME/bin/love'
"

echo ">> 安装菜单入口脚本"
LAUNCHER_TMP="$(mktemp)"
cat > "$LAUNCHER_TMP" <<'LAUNCHER'
#!/bin/sh
# Pocket Garden (v2) — RGDS 启动器（由前端菜单调用，stdout 被丢弃，故另存日志）
SHDIR="$(cd "$(dirname "$0")" && pwd)"
export HOME=/root
export LD_LIBRARY_PATH="$SHDIR/rgds-lua-demo-v2/lib:$LD_LIBRARY_PATH"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
export SDL_VIDEO_DOUBLE_BUFFER=1
export RGDS_LOG=/tmp/rgds-lua-demo-v2.log
export ALSOFT_CONF="$SHDIR/rgds-lua-demo-v2/alsoft.conf"
cd "$SHDIR/rgds-lua-demo-v2" || exit 1
"$SHDIR/rgds-lua-demo-v2/bin/love" . "$@" > "$RGDS_LOG" 2>&1
LAUNCHER
scp -q "$LAUNCHER_TMP" "$TARGET:$SCRIPT"
rm -f "$LAUNCHER_TMP"
ssh "$TARGET" "chmod +x '$SCRIPT'"

if [ -f icon.png ]; then
  echo ">> 安装菜单图标"
  scp -q icon.png "$TARGET:$APPS/Imgs/$NAME.png"
fi

echo ">> 校验"
ssh "$TARGET" "ls -l '$SCRIPT'; echo; ls -lR '$GAME' | head -20; echo; df -h /mnt/mmc | tail -1"

echo ">> 完成。从掌机菜单 APPS 里运行 $NAME.sh"
echo "   SSH 按菜单流程启动（前端需在菜单界面）: ssh $TARGET '$GAME/run-via-menu.sh'"
echo "   不要直接 ssh 执行 $SCRIPT：菜单仍占着音频和手柄，app 会无声且按键被菜单同时响应"
