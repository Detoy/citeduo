#!/usr/bin/env bash
# 重制 README / 发布用的素材：docs/images/*.png、docs/images/graph-demo.gif、
# docs/images/social-preview.png。
#
# 背景：素材是"截图"，产品改名或改版后就会过期——2026-10-10 项目改名为 CiteDuo 时，
# 10-09 拍的那批截图仍然显示旧名，README 和链接预览卡都是错的（见 issue #13）。
# 这个脚本把整条流水线固定下来，让重拍变成一条命令。
#
# 用法:
#   bash scripts/assets/capture-assets.sh            # 全部重拍
#   bash scripts/assets/capture-assets.sh shots      # 只重拍 5 张 PNG
#   bash scripts/assets/capture-assets.sh gif        # 只重录 GIF
#   bash scripts/assets/capture-assets.sh card       # 只渲染社交卡
#
# 前置条件:
#   1. 本地服务在跑，且用的是本地库 data/app.db（素材里的图和数据都来自它）:
#        VITE_BASE=/ pnpm --dir academic-paper-explorer build
#        S2_MIN_INTERVAL_MS=1000 bun --env-file=server/.env run server/main.ts
#   2. agent-browser 已安装（npm i -g agent-browser && agent-browser install）
#   3. ffmpeg 可用（合成 GIF）
#
# 素材里用到的两篇论文来自本地库，深链是确定性的:
#   OCSampler (06404140…) 与 Look More but Care Less (9eb14624…)，均为视频方向论文。
#   阅读器用 Attention Is All You Need (1706.03762)，正文与译文命中本地缓存。
#
# 注意：agent-browser 的页面状态不跨 CLI 进程保留，所以每一步都必须在同一个进程里
# 完成「open → 等待渲染 → 截图」。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${CAPTURE_BASE:-http://127.0.0.1:8787}"
STAGE="$REPO/.tmp/capture-assets"
JS="$STAGE/js"
IMAGES="$REPO/docs/images"
WHAT="${1:-all}"

FROM=06404140b2d500b1b46ff3273f82bb12cf6ee5e8          # OCSampler
TO=9eb146249b5c0b9a03aef6cfbb00bc28299f546c            # Look More but Care Less in Video Recognition
READER=1706.03762                                       # Attention Is All You Need

# ── agent-browser 环境 ────────────────────────────────────────────────────
# 代理会打断 Chrome（ERR_NO_SUPPORTED_PROXIES），显式清掉。
export AGENT_BROWSER_PROXY=""
export AGENT_BROWSER_SOCKET_DIR="$STAGE/ab"
export XDG_RUNTIME_DIR="$STAGE/ab"
export AGENT_BROWSER_SESSION=assets
export AGENT_BROWSER_SCREENSHOT_DIR="$STAGE"

mkdir -p "$JS" "$STAGE/ab" "$STAGE/frames"
[ -f "$IMAGES/graph-demo.gif" ] || { echo "!! 找不到 $IMAGES，仓库结构不符"; exit 1; }

probe() { agent-browser eval "$1" 2>/dev/null | tail -1; }
jsp()   { agent-browser eval "$(cat "$JS/$1")" 2>/dev/null | tail -1; }
shot()  { agent-browser screenshot "$1" 2>&1 | tail -1; }

# wait_true <标签> <返回 true/false 的 JS> [轮数] [间隔秒]
wait_true() {
  local label="$1" js="$2" rounds="${3:-15}" gap="${4:-3}" i v
  for i in $(seq 1 "$rounds"); do
    sleep "$gap"
    v=$(probe "$js")
    echo "    [$label t=$((i*gap))s] $v"
    if [ "$v" = "true" ]; then return 0; fi
  done
  echo "    !! $label 超时，继续下一步"
  return 1
}

check_server() {
  local code
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null)
  if [ "$code" != "200" ]; then
    echo "!! $BASE 不可用（HTTP ${code:-无响应}）。先起本地服务，见脚本头部注释。"
    exit 1
  fi
  echo "== 目标: $BASE"
}

write_probes() {
  # 阅读器正文在 iframe 里（应用把 arXiv HTML 注入 iframe），所以正文/译文必须
  # 从 contentDocument 读，而不是 document.body。
  cat > "$JS/reader-ready.js" <<'EOF'
(() => {
  const btn = [...document.querySelectorAll('button')].find(b => b.textContent.includes('翻译'))
  return JSON.stringify({ ready: !!btn && !btn.disabled, btnDisabled: btn ? btn.disabled : null })
})()
EOF
  cat > "$JS/reader-translate.js" <<'EOF'
(() => {
  const btn = [...document.querySelectorAll('button')].find(b => b.textContent.includes('翻译') || b.textContent.includes('隐藏译文'))
  if (!btn) return 'no-btn'
  if (btn.disabled) return 'btn-disabled'
  btn.click()
  return 'clicked'
})()
EOF
  cat > "$JS/ai-open.js" <<'EOF'
(() => {
  const btn = [...document.querySelectorAll('button')].find(b => b.textContent.includes('AI 助手'))
  if (!btn) return 'no-btn'
  btn.click()
  return 'opened'
})()
EOF
  # 用原型上的 setter 写值，否则 React 收不到 input 事件。
  cat > "$JS/ai-send.js" <<'EOF'
(() => {
  const el = document.querySelector('input[placeholder*="提问"]')
  if (!el) return 'no-input'
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set
  setter.call(el, '这篇论文的核心贡献是什么？请用三点概括。')
  el.dispatchEvent(new Event('input', { bubbles: true }))
  const send = [...document.querySelectorAll('button')].find(b => b.getAttribute('aria-label') === '发送')
  if (!send) return 'no-send'
  if (send.disabled) return 'send-disabled'
  send.click()
  return 'sent'
})()
EOF
}

# ── 5 张 PNG（1920x1080）─────────────────────────────────────────────────
capture_shots() {
  check_server
  write_probes
  # 截图按相对路径落盘，所以先站到暂存目录里（不要落在仓库根目录）
  cd "$STAGE" || exit 1
  agent-browser set viewport 1920 1080 >/dev/null 2>&1

  echo "== network-graph.png"
  agent-browser open "$BASE/?paper=$FROM&d=1&mn=50" >/dev/null 2>&1
  wait_true graph "(()=>{const t=document.body.innerText;return !!document.querySelector('canvas')&&/\d+\s*节点\s*·\s*\d+\s*边/.test(t)&&t.length>3000})()" 12 3
  sleep 6; shot network-graph.png

  echo "== two-paper-connection.png"
  agent-browser open "$BASE/?paper=$FROM&from=$FROM&to=$TO&d=1&mn=50" >/dev/null 2>&1
  wait_true connection "(()=>{const t=document.body.innerText;return /共被引|文献耦合|直接引用|语义相近/.test(t)&&/跳/.test(t)&&t.length>8000})()" 15 3
  sleep 6; shot two-paper-connection.png

  echo "== compare.png"
  agent-browser open "$BASE/?paper=$FROM&paper2=$TO&d=1&mn=50" >/dev/null 2>&1
  wait_true compare "(()=>{const c=document.querySelectorAll('canvas');return c.length>=2&&document.body.innerText.length>4000})()" 15 3
  sleep 6; shot compare.png

  echo "== reader-translation.png"
  agent-browser open "$BASE/read/$READER" >/dev/null 2>&1
  wait_true reader-ready "(()=>{const b=[...document.querySelectorAll('button')].find(x=>x.textContent.includes('翻译'));return !!b&&!b.disabled})()" 20 3
  echo "    翻译 -> $(jsp reader-translate.js)"
  wait_true translated "(()=>{const f=document.querySelector('iframe');if(!f||!f.contentDocument||!f.contentDocument.body)return false;const t=f.contentDocument.body.innerText||'';return (t.match(/[\u4e00-\u9fa5]/g)||[]).length>250})()" 24 3
  sleep 6; shot reader-translation.png

  echo "== ai-assistant.png"
  echo "    面板 -> $(jsp ai-open.js)"
  for i in 1 2 3 4 5 6; do sleep 2; if [ "$(probe "!!document.querySelector('[data-testid=\"ai-messages\"]')")" = "true" ]; then break; fi; done
  echo "    提问 -> $(jsp ai-send.js)"
  wait_true ai-answer "(()=>{const b=document.querySelector('[data-testid=\"ai-messages\"]');const t=b?b.innerText:'';return t.length>300&&!/生成中|思考中/.test(t.slice(-60))})()" 30 4
  sleep 4; shot ai-assistant.png

  for f in network-graph two-paper-connection compare reader-translation ai-assistant; do
    cp "$STAGE/$f.png" "$IMAGES/$f.png"
  done
  echo "== 已写入 $IMAGES/"
}

# ── GIF（1600x1000 录制 → 1200x750 合成）────────────────────────────────
capture_gif() {
  check_server
  local FR="$STAGE/frames"
  rm -rf "$FR"; mkdir -p "$FR"
  cd "$FR" || exit 1
  local i=0
  # shellcheck disable=SC2317
  shot_frame() { i=$((i+1)); printf -v n "%03d" "$i"; agent-browser screenshot "frame-$n.png" >/dev/null 2>&1 || echo "  frame $n 失败"; }

  agent-browser set viewport 1600 1000 >/dev/null 2>&1
  agent-browser open "$BASE/?paper=$FROM&d=1&mn=50" >/dev/null 2>&1
  wait_true gif-ready "(()=>{return /\d+\s*节点\s*·\s*\d+\s*边/.test(document.body.innerText)})()" 10 2
  sleep 6

  local k
  for k in 1 2 3; do shot_frame; sleep 0.06; done

  local box cx cy s x y
  box=$(probe "(()=>{const c=document.querySelector('canvas').getBoundingClientRect();return JSON.stringify([Math.round(c.x+c.width/2),Math.round(c.y+c.height/2)])})()" | tr -d '"')
  cx=$(echo "$box" | tr -d '[]' | cut -d, -f1); cy=$(echo "$box" | tr -d '[]' | cut -d, -f2)
  echo "    画布中心 $cx,$cy"
  agent-browser mouse move "$cx" "$cy" >/dev/null 2>&1; sleep 0.3
  agent-browser mouse down >/dev/null 2>&1; sleep 0.2
  for s in $(seq 1 10); do
    x=$((cx + s*20)); y=$((cy - s*9))
    agent-browser mouse move "$x" "$y" >/dev/null 2>&1
    shot_frame; sleep 0.05
  done
  agent-browser mouse up >/dev/null 2>&1
  for k in 1 2 3 4; do shot_frame; sleep 0.07; done
  echo "    共 $i 帧"

  cd "$REPO" || exit 1
  local RATE=5.882   # 1/0.17s → 每帧 170ms，和初版 GIF 一致
  ffmpeg -y -loglevel error -framerate $RATE -i "$FR/frame-%03d.png" \
    -vf "scale=1200:750:flags=lanczos,palettegen=stats_mode=diff" "$STAGE/palette.png"
  ffmpeg -y -loglevel error -framerate $RATE -i "$FR/frame-%03d.png" -i "$STAGE/palette.png" \
    -lavfi "scale=1200:750:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
    -loop 0 "$IMAGES/graph-demo.gif"
  echo "== 已写入 $IMAGES/graph-demo.gif"
}

# ── 社交预览卡（1280x640）───────────────────────────────────────────────
capture_card() {
  # 卡片是 HTML，用浏览器渲染，所以文案/字体和页面一致；图里嵌的是
  # two-paper-connection.png，重拍截图后要重新渲染这张卡。
  local port=8899 pid
  cd "$STAGE" || exit 1
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$REPO" >/dev/null 2>&1 &
  pid=$!
  sleep 2
  agent-browser set viewport 1280 640 >/dev/null 2>&1
  agent-browser open "http://127.0.0.1:$port/scripts/assets/social-card.html" >/dev/null 2>&1
  sleep 3
  echo "    卡片状态: $(probe "(()=>{const i=document.querySelector('.shot img');return JSON.stringify({h1:document.querySelector('h1').textContent,img:i?i.naturalWidth+'x'+i.naturalHeight:'未加载'})})()")"
  shot social-preview.png
  kill "$pid" 2>/dev/null
  cp "$STAGE/social-preview.png" "$IMAGES/social-preview.png"
  cp "$STAGE/social-preview.png" "$REPO/academic-paper-explorer/public/social-card.png"
  echo "== 已写入 $IMAGES/social-preview.png 与 public/social-card.png"
}

case "$WHAT" in
  shots) capture_shots ;;
  gif)   capture_gif ;;
  card)  capture_card ;;
  all)   capture_shots; capture_gif; capture_card ;;
  *)     echo "用法: $0 [all|shots|gif|card]"; exit 2 ;;
esac

echo "== 完成。检查差异: git status --short docs/images academic-paper-explorer/public"
