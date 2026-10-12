# 素材流水线

`docs/images/` 里的截图、GIF 和社交预览卡是**截图**，不是设计稿。产品的名字、配色、
面板宽度一变，它们就过期了——2026-10-10 项目改名为 CiteDuo 时，10-09 拍的整批素材
仍然显示旧名，而 README 首屏和链接预览卡都在用它们（见 issue #13）。

所以这个目录把整条流水线固定下来：

| 文件 | 作用 |
|---|---|
| `capture-assets.sh` | 一条命令重拍全部素材 |
| `check-assets.py` | 检查素材是否和当前产品名/尺寸一致（防止再次静默过期） |
| `social-card.html` | 社交预览卡的源文件（1280×640，浏览器渲染） |

## 重拍

```bash
# 1. 起本地服务（用本地库 data/app.db，素材里的图和数据都来自它）
VITE_BASE=/ pnpm --dir academic-paper-explorer build
S2_MIN_INTERVAL_MS=1000 bun --env-file=server/.env run server/main.ts

# 2. 重拍（可选参数: all | shots | gif | card）
bash scripts/assets/capture-assets.sh all
```

依赖：`agent-browser`（`npm i -g agent-browser && agent-browser install`）、`ffmpeg`、
`python3` + `Pillow`。

产出写回 `docs/images/`；社交卡同时写到 `academic-paper-explorer/public/social-card.png`
（构建后就是线上的 `og:image`）。

## 为什么素材是确定性的

素材靠深链复现，不靠手点：

- 引用网络与关联分析：`/?paper=<id>` 与 `/?paper=<id>&from=<A>&to=<B>`
- 并排对比：`/?paper=<A>&paper2=<B>`
- 阅读器：`/read/<arxivId>`（正文在 iframe 里，译文要读 `contentDocument`）

脚本里固定用的两篇论文是 OCSampler (`06404140…`) 与 Look More but Care Less
(`9eb14624…`)，阅读器用 Attention Is All You Need (`1706.03762`)。这三篇的正文与
译文在本地库里已有缓存，所以重拍不需要联网。

## 检查

```bash
python3 scripts/assets/check-assets.py
```

它做两件不依赖 OCR 的事：

1. 量出每张截图顶部标题文字的像素宽度。旧名 "Academic Paper Explorer" 在 24px 字号
   下宽 286px，`CiteDuo` 只有 104px——宽度对不上就说明素材是别的版本的画面。
2. 比对 `social-card.html` 里的 `<h1>`、`HomePage.tsx` 里的标题、以及仓库 About 的
   描述是否还是同一个名字。

改名或改标题字串后请重跑这两步，不要只改代码。
