# LDownload 设计系统 — MASTER

> 生成于 2026-08-13 · 流程：Frontend Design（定方向）→ UI/UX Pro Max（上系统）→ taste-skill（抛光）
> 本文件是全局设计基准；页面级覆盖见 `design-system/LDownload/pages/`。

---

## 1. Design Read（方向）

**Reading this as:** desktop download manager（效率工具 / 每日高频使用）for power users
wanting an IDM replacement, with a **Refined Utility / 石墨精密风** language —
calm, precise, high signal-to-noise, leaning toward "Linear × Things × macOS
system utilities", 克制而非炫技。

| 维度 | 值 | 说明 |
|---|---|---|
| DESIGN_VARIANCE | 4 / 10 | 克制的对称与刻意层级，不做艺术化不对称 |
| MOTION_INTENSITY | 4 / 10 | 微交互（120–150ms easeOut），尊重 reduced-motion |
| VISUAL_DENSITY | 6 / 10 | 工具型数据密度，但保留呼吸感 |

**Anti-Default（taste-skill 禁令）：** 不引入 AI 紫渐变、不在全局铺玻璃拟态、
不堆叠无意义动效；accent 维持 Indigo-600（非 Bootstrap 模板蓝）。

---

## 2. 设计系统（UI/UX Pro Max 落地）

### 2.1 表面层级（Surface Elevation）

目标：用「明度差」而非「色相差」表达层级，浮层/输入框一眼可辨。

**暗色（Graphite）** — `flux_theme_tokens.dart defaultDark`：

| Token | 值 | 用途 |
|---|---|---|
| `background` | `#141416` | 窗口底（近黑，拉开层级） |
| `surface1` | `#1D1D21` | 侧栏 / 面板 / 浮层卡片 |
| `surface2` | `#28282E` | 内嵌块 / hover 底 |
| `surface3` | `#33333A` | 强 hover / 窗口按钮 |
| `border` | `#37373F` | 发丝线 |
| `dialogBackground` | `#232329` | 对话框 / toast（比面板亮一档，浮起） |
| `inputBackground` | `#141416` | 输入框（比所在面板深，反衬填充感） |

**亮色（Warm Paper）** — `defaultLight`：

| Token | 值 | 用途 |
|---|---|---|
| `background` | `#F6F7F9` | 窗口底（近白冷灰） |
| `surface1` | `#FFFFFF` | 面板 / 卡片 |
| `surface2` | `#F1F3F6` | 内嵌块 / hover |
| `surface3` | `#E8EBF0` | 强 hover / 输入框衬底 |
| `border` | `#E4E7EC` | 发丝线 |
| `inputBackground` | `#F2F4F7` | 输入框（比白卡片深一档，消灭「贴纸感」） |

### 2.2 文字（Typography，MiSans）

- 正文主层：13–14px / w400–500；任务文件名 13px / w500（强化标题感）。
- 次级：11–12px muted；区块小标题：9.5px / w600 / 大写 / letter-spacing 0.9
  （侧栏分组标识，与正文拉开层级）。
- 对比度（AA）：`textMuted` 暗色 `#8A8A96`（≈5.3:1@近黑底）、亮色 `#6E6E78`
  （≈5.1:1@白底）；`textSecondary` 亮色 `#52525B`（≈7.8:1）。

### 2.3 几何（Radius / Spacing，`flux_metric_tokens.dart`）

半径收敛为「控件方、容器圆」：`progress 1.5 / xs 2 / segmentCell 2.5 / sm 4 /
md 6 / input 9 / card 10 / iconTile 10 / dialog 12 / pill 999`。
间距沿用 4/8/12/16/24 五阶。

### 2.4 状态色（Status）

暗色保留高亮系（`#22C55E / #F59E0B / #EF4444`，深底对比足够）；亮色用深调
（`#16A34A / #D97706 / #DC2626`，图标/色块对比 ≥3:1，WCAG 1.4.11）。

---

## 3. 组件规范

### 3.1 侧栏（sidebar.dart）

- 右侧 1px 发丝线分隔内容区（层级浮起，替代全平拼接）。
- 分组小标题：9.5px 大写 + 0.9 字距；可折叠头 hover 有 0.55 alpha 底 + 箭头
  120ms 旋转动画。
- 导航项：高 34px、margin 6px；选中态 = accentBg 底 + 左侧 2.5px accent
  指示条（Positioned 覆盖，不位移）+ accent 图标/文字 w600 + 数字计数
  （tabular figures）；hover/选中 120ms easeOut 过渡。
- 计数 0 不再显示（去噪）；队列/RSS 项同高、同交互。

### 3.2 顶栏（header_bar.dart）

- 「新建下载」主按钮 32px 高，icon/text 用 `accentForeground`（跟随自定义
  accent 对比度，不再写死白）。

### 3.3 任务行（task_list_item.dart）

- 文件名 13px / w500；协议/设备徽标统一 `brSm` 圆角 + `surface2` 底。
- 优先下载闪电徽章用 `statusWarning`（语义色，弃硬编码 amber）。

---

## 4. 浏览器扩展安装 UX（v10.0.5+）

**根因**：Chrome 137+ 移除 `--load-extension`；Firefox 移除 `file://*.xpi`
直开；NMH 未注册时扩展「装上却连不上」。

**方案（extension_install_service.dart）**：
1. 解压内嵌包到稳定目录（`dataDir/extensions/chrome-mv3|firefox-mv2`）；
2. 打开浏览器扩展管理页（chrome://extensions / edge://extensions /
   about:debugging#/runtime/this-firefox）；
3. 自动用系统文件管理器打开解压目录（Explorer/Finder/Nautilus），
   用户「加载已解压/临时加载」一步选到；
4. 触发 `RepairNmhRegistration` 信号注册原生消息宿主；
5. 内置包缺失 → `assetMissing` + GitHub Release 下载链接
   （https://github.com/luoda2023/LDownload/releases）。

---

## 5. 反模板清单（taste-skill 审计）

- [x] 无 AI 紫渐变（Indigo 是有意的品牌 accent）
- [x] 无全局玻璃拟态（仅浮层/操作簇用 surface 实底 + 柔和投影）
- [x] 动效 ≤150ms、只在 hover/选中/展开处出现，尊重 reduced-motion
- [x] 亮/暗双主题文本对比度 ≥ AA 4.5:1、状态色 ≥ 3:1
- [x] 计数 0 不渲染、空状态有文案（去噪）
