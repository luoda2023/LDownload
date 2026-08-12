# IDM 全格式替换路线图（idm-parity）

> 目标：让 LDownload 覆盖 Internet Download Manager（IDM）的全部下载能力，成为完整替代。
> 状态：**进行中**。本文档是工程 plan，非承诺清单；协议逐项落地、逐版本发布。

## 一、能力差距矩阵（LDownload vs IDM）

| 能力 | IDM | LDownload | 差距 | 优先级 |
|---|---|---|---|---|
| HTTP/HTTPS 分段并发下载 | ✅ | ✅（segment_coordinator） | 无 | — |
| 断点续传 / 重试 / 调度 | ✅ | ✅ | 无 | — |
| FTP / FTPS | ✅ | ✅ | 无 | — |
| 限速 / 代理 / UA / Cookie / Referer | ✅ | ✅（auto_proxy / 每任务 UA） | 无 | — |
| 磁力 / BitTorrent | ✅ | ✅（rqbit + DHT 持久化） | 无 | — |
| ed2k | ✅ | ✅ | 无 | — |
| HLS / DASH 流媒体直链 | ✅ | ✅（ffmpeg 组件合并音视频轨） | 无 | — |
| 1000+ 视频站点解析 | ✅ | ✅（ytdlp 组件 / 插件系统） | 无 | — |
| 浏览器接管下载 | ✅ | ✅（扩展 + NMH + 油猴） | 无 | — |
| 批量 / 站点整站抓取（Site Grabber） | ✅ | ❌ | **缺** | 中 |
| Metalink（RFC 5854） | ✅ | ❌ | **缺** | 低 |
| RTSP 流 | ✅ | ❌ | **缺** | 低 |
| MMS（微软流） | ✅ | ❌ | **缺** | 极低（2012 年已废弃） |
| 定时任务 / 队列调度 | ✅ | ✅（队列 + 定时） | 无 | — |

## 二、实施批次

### 批次 1（当前已完成 / 已具备）
- 分段并发、断点续传、FTP、限速/代理/UA/Cookie、磁力/BT、ed2k、HLS/DASH、ytdlp 插件、浏览器接管 —— 全部已在生产可用。

### 批次 2：Metalink（RFC 5854）
- 引擎新增 `metalink` 协议解析（`.meta4` / `.metalink` XML → 多源列表）。
- `NewTaskSpec` 增加 `metalinks: Vec<MetalinkMirror>`，分段器从多源择优拉取（已有选择基础，见 segment_coordinator）。
- 难度：中。价值：低（实际使用稀少），但作为「IDM 全格式」声明必须补齐。

### 批次 3：RTSP 流
- 引擎新增 RTSP 客户端（rtsp:// URL），支持 DESCRIBE/SETUP/PLAY，RTP 收流 + 落盘。
- 注意：RTSP 多为防盗链私有实现，商用可靠性有限；以「能拉、能存」为目标。
- 难度：高（RTP/RTCP 处理、丢包重传）。价值：低。

### 批次 4：MMS 流
- MMS/MMST/MMSU 客户端。协议已死（微软 2012 弃用），仅做「探测即报不支持」+ 文档声明，不做完整实现。
- 决策：**明确不支持**，在下载失败提示里写清楚「MMS 已被淘汰，请用 HLS/DASH 替代」。

### 批次 5：Site Grabber（整站抓取）
- 复用现有 RSS / 插件解析框架，提供「给定起始 URL 递归抓取链接 + 过滤规则」的站点级任务。
- 难度：中高（防抖、去重、目录结构映射）。价值：中。

## 三、验收标准

- 每个批次合入后：`cargo nextest run -p ldown_engine` 全绿；新增协议有 `test/` 用例。
- 对外能力面：`ldown_api` 的 `ApiHost` 增加对应 wire 类型（metalink/rtsp），HTTP/aria2/MCP 三条入口同步透出。
- 发布节奏：每批次单独打版本（如 10.x 递进），不攒大包。

## 四、不做 / 明确边界

- **MMS 不做完整实现**（协议废弃，见批次 4）。
- 不做 IDM 的「下载完成自动杀毒」等安全套件集成（超出下载器职责）。
- 不复制 IDM 的付费墙 / 弹窗运营模式（LDownload 保持开源免费）。

## 五、参考

- RFC 5854（Metalink）、RFC 2326（RTSP）、RFC 3550（RTP/RTCP）
- 现有实现坐标：分段 `native/engine/src/segment_coordinator.rs`、协议路由 `native/engine/src/downloader.rs`、BT `bt_downloader.rs`、ed2k `ed2k/`
