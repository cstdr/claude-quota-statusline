# 截图

README 引用的所有 statusline 截图都在这里。

| 文件 | 状态 | 重点展示 |
|------|------|----------|
| `kimi-normal.png` | 正常（绿/黄） | ctx 8% 绿、5h 4% 绿、周 53% 黄；周配额上 dim 灰虚线 ┊ 标时间位置 |
| `kimi-5h-full.png` | 红色告警 | 5h 100% 红 + ↑+16% 红 delta；周 20% 仍绿但 5h 段整体染色 |
| `kimi-week-burn.png` | 烧速警示 | 周 53% 黄 + ↑+40% 黄 delta（远超时间步长）；5h 6% 仍绿 |

## 录新截图

要补 demo.gif 或更新现有图，参考：

- `terminalizer record` / `asciinema` / `kap` — 录 mp4/gif
- macOS 自带 `screencapture -R x,y,w,h out.png` — 抓单帧
- `sips -s format png in.png --out out@2x.png` — 缩放

更新时同步改主 README 的图片引用。
