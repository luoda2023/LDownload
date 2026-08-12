//! MMS / RTSP / RTMP 流媒体下载器（经受管 ffmpeg 录制）。
//!
//! IDM 支持的协议面包含 MMS / RTSP 这类**流式协议**：它们没有 HTTP 的
//! Range/Content-Length 语义，也无法分段并发——最可靠的做法是调用受管
//! ffmpeg 组件（manual → managed → system 三级解析，见 [`crate::components`]）
//! 把流录制到本地文件，与 DASH 轨对 mux 共用同一套组件底座，**零新依赖**。
//!
//! 判定谓词 [`is_stream_url`] 覆盖：
//! - `mms://` / `mmst://` / `mmsu://`（Windows Media 流，IDM 传统支持面）
//! - `rtsp://` / `rtsps://`（实时流传输协议）
//! - `rtmp://` / `rtmps://`（Flash 直播流）
//!
//! 注意与 HLS 的区别：HLS 是 `.m3u8` 后缀判定（HTTP 上的分段清单），不在此列；
//! 本模块只处理**非 HTTP 前缀的流协议 scheme**，与 `is_hls_url` 互斥不重叠。

use std::path::PathBuf;
use std::time::Duration;

use tokio::io::AsyncBufReadExt;
use tokio::process::Command;

use crate::downloader::{DownloadError, DownloadParams, ProgressUpdate, sanitize_filename};
use crate::logger::log_info;

/// 判定 URL 是否为 MMS / RTSP / RTMP 流协议（大小写不敏感前缀匹配）。
///
/// 只认明确的前缀，绝不做后缀/内容嗅探——避免把普通 HTTP 下载误判为流。
pub fn is_stream_url(url: &str) -> bool {
    let lower = url.get(..10).map(|s| s.to_ascii_lowercase()).unwrap_or_default();
    lower.starts_with("mms://")
        || lower.starts_with("mmst://")
        || lower.starts_with("mmsu://")
        || lower.starts_with("rtsp://")
        || lower.starts_with("rtsps://")
        || lower.starts_with("rtmp://")
        || lower.starts_with("rtmps://")
}

/// 从流 URL 提取一个可用的默认文件名（URL 末段 + 兜底扩展名）。
///
/// 流协议没有 Content-Disposition / Content-Length，无法 probe 文件名，
/// 只能从 URL 尾巴取。`mms://host/path/stream.asf` → `stream.asf`；
/// `rtsp://host/live` → `live.mp4`（无扩展名时按 MP4 兜底，ffmpeg
/// 会把任何容器录制进 `.mp4` 外壳，播放器兼容性最好）。
pub fn stream_file_name_from_url(url: &str) -> String {
    let base = crate::downloader::extract_from_url(url).unwrap_or_else(|| "stream".to_string());
    if base.contains('.') {
        base
    } else {
        format!("{}.mp4", base)
    }
}

/// ffmpeg 未找到时的统一错误信息（提示用户去设置页装组件）。
fn ffmpeg_missing_error() -> DownloadError {
    DownloadError::Other(
        "stream download requires ffmpeg (not found). Install it in Settings → Components \
         (or system PATH), then retry."
            .to_string(),
    )
}

/// 入口：外层包装与 run_hls_download / run_dash_download 同构。
///
/// 成功 → status=3 + 完成进度；取消 → 静默；失败 → status=4 + 保留 DB 进度。
pub async fn run_stream_download(params: DownloadParams) {
    let task_id_log = params.task_id.clone();
    let result = run_stream_download_inner(&params).await;

    match result {
        Ok(total) => {
            log_info!(
                "[stream-download] task {} completed, total={} bytes",
                task_id_log,
                total
            );
            let _ = params.db.update_task_status(&params.task_id, 3, "").await;
            let _ = params
                .progress_tx
                .send(ProgressUpdate {
                    task_id: params.task_id,
                    downloaded_bytes: total,
                    total_bytes: total,
                    status: 3,
                    error_message: String::new(),
                    file_name: String::new(),
                    segment_details: None,
                    ..Default::default()
                })
                .await;
        }
        Err(DownloadError::Cancelled) => {
            log_info!("[stream-download] task {} cancelled", task_id_log);
        }
        Err(e) => {
            let msg = e.to_string();
            log_info!("[stream-download] task {} error: {}", task_id_log, msg);
            let _ = params.db.update_task_status(&params.task_id, 4, &msg).await;

            // Preserve actual progress from DB so the UI doesn't jump back to 0%.
            let (dl, total) = match params.db.load_task_by_id(&params.task_id).await {
                Ok(Some(t)) => (t.downloaded_bytes, t.total_bytes),
                other => {
                    log_info!(
                        "[stream-download] task {} warning: failed to read progress from DB: {:?}",
                        task_id_log,
                        other.err()
                    );
                    (0, 0)
                }
            };
            let _ = params
                .progress_tx
                .send(ProgressUpdate {
                    task_id: params.task_id,
                    downloaded_bytes: dl,
                    total_bytes: total,
                    status: 4,
                    error_message: msg,
                    file_name: String::new(),
                    segment_details: None,
                    ..Default::default()
                })
                .await;
        }
    }
}

/// ffmpeg 录制进度：`-progress pipe:1` 的 key=value 输出。
///
/// 每次读到 `out_time_ms=` 或 `total_size=` 都代表录制有进展。流式协议
/// 总时长未知，进度条只能按"已录制字节数"展示（`total_bytes=0` 表示未知，
/// 由前端渲染为不确定进度）；这里按 500ms 节流上报，避免信号风暴。
struct StreamProgressParser {
    task_id: String,
    progress_tx: tokio::sync::mpsc::Sender<ProgressUpdate>,
    db: crate::db::Db,
    last_report: std::time::Instant,
    last_bytes: i64,
    file_name: String,
}

impl StreamProgressParser {
    fn on_line(&mut self, line: &str) {
        // -progress 输出形如 "out_time_us=123456" / "total_size=1024"
        let Some((key, value)) = line.split_once('=') else {
            return;
        };
        match key {
            "total_size" | "out_time_us" => {
                if let Ok(v) = value.trim().parse::<i64>() {
                    self.last_bytes = v;
                }
            }
            _ => {}
        }
    }

    /// 周期上报（500ms 节流）。返回 true = 需要继续；false = 已完成（progress=end）。
    async fn maybe_report(&mut self, done: bool) {
        let now = std::time::Instant::now();
        if !done && now.duration_since(self.last_report) < Duration::from_millis(500) {
            return;
        }
        self.last_report = now;
        let status = if done { 3 } else { 1 };
        let total = self.last_bytes;
        let _ = self
            .progress_tx
            .try_send(ProgressUpdate {
                task_id: self.task_id.clone(),
                downloaded_bytes: self.last_bytes,
                total_bytes: total,
                status,
                error_message: String::new(),
                file_name: if done {
                    String::new()
                } else {
                    self.file_name.clone()
                },
                segment_details: None,
                ..Default::default()
            });
        if done {
            _ = self.db.update_task_status(&self.task_id, 3, "").await;
        }
    }
}

async fn run_stream_download_inner(p: &DownloadParams) -> Result<i64, DownloadError> {
    // 文件名：manager 的 finalize_start_file_name 已决策（含 dedup/预订），
    // 空名兜底用 URL 末段。
    let actual_name = if p.file_name.is_empty() {
        stream_file_name_from_url(&p.url)
    } else {
        sanitize_filename(&p.file_name)
    };
    p.db.update_task_file_info(&p.task_id, &actual_name, 0)
        .await?;

    // 早期取消检查（与 HLS/DASH 一致）：probe/解析完成后、创建文件之前。
    if p.cancel_token.is_cancelled() {
        return Err(DownloadError::Cancelled);
    }

    let _ = p.db.update_task_status(&p.task_id, 1, "").await;
    let _ = p
        .progress_tx
        .send(ProgressUpdate {
            task_id: p.task_id.clone(),
            downloaded_bytes: 0,
            total_bytes: 0,
            status: 1,
            error_message: String::new(),
            file_name: actual_name.clone(),
            segment_details: None,
            ..Default::default()
        })
        .await;

    let save_dir = PathBuf::from(&p.save_dir);
    let dest_path = save_dir.join(&actual_name);
    if let Some(parent) = dest_path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    // 流协议无断点续传语义，resume = 重新录制（覆盖旧文件）。
    let _ = tokio::fs::remove_file(&dest_path).await;

    // 解析 ffmpeg：优先 manager 注入的组件路径，回退 PATH。
    let ffmpeg: PathBuf = match &p.ffmpeg_path {
        Some(fp) if fp.is_file() => fp.clone(),
        _ => {
            // 组件未安装时尝试 PATH 上的 ffmpeg（与 DASH mux 的兜底一致）。
            match crate::components::find_system_ffmpeg() {
                Some(f) => f,
                None => return Err(ffmpeg_missing_error()),
            }
        }
    };

    // 构造 ffmpeg 录制命令。
    // - `-rtsp_transport tcp`：RTSP 默认 UDP，多数内网/NAT 下 UDP 不通，
    //   TCP 可靠；仅对 RTSP 生效（对 mms/rtmp 会被 ffmpeg 忽略或安全无害，
    //   但为稳妥只在 rtsp 前缀时加）。
    // - `-c copy`：流复制不转码，几乎实时；容器由输出扩展名决定。
    // - `-y` 覆盖；`-nostdin` 防 ffmpeg 读 stdin 挂起；`-loglevel error`
    //   减少噪声（进度走 -progress pipe:1）。
    let url_lower = p.url.to_ascii_lowercase();
    let mut cmd = Command::new(&ffmpeg);
    crate::proc::no_console_window(&mut cmd);
    cmd.arg("-y")
        .arg("-nostdin")
        .arg("-loglevel")
        .arg("error")
        .arg("-progress")
        .arg("pipe:1");
    if url_lower.starts_with("rtsp://") || url_lower.starts_with("rtsps://") {
        cmd.arg("-rtsp_transport").arg("tcp");
    }
    cmd.arg("-i").arg(&p.url).arg("-c").arg("copy").arg(&dest_path);

    log_info!(
        "[stream-download] task {} recording {} → {}",
        p.task_id,
        p.url,
        dest_path.display()
    );

    // Spawn；`kill_on_drop` 保证 select 取消时子进程被自动杀掉。
    let mut child = cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| {
            DownloadError::Other(format!("failed to spawn ffmpeg: {} ({})", e, ffmpeg.display()))
        })?;

    let mut parser = StreamProgressParser {
        task_id: p.task_id.clone(),
        progress_tx: p.progress_tx.clone(),
        db: p.db.clone(),
        last_report: std::time::Instant::now() - Duration::from_secs(1),
        last_bytes: 0,
        file_name: actual_name.clone(),
    };

    // 从 stdout 逐行解析 `-progress` 输出；stderr 留到结束后读取错误信息。
    let stdout = match child.stdout.take() {
        Some(s) => s,
        None => {
            return Err(DownloadError::Other(
                "failed to capture ffmpeg stdout".to_string(),
            ));
        }
    };
    let mut lines = tokio::io::BufReader::new(stdout).lines();

    let parse_result = loop {
        tokio::select! {
            _ = p.cancel_token.cancelled() => {
                // kill_on_drop 会在 future 被 drop 时杀子进程；这里显式 kill
                // 让 ffmpeg 立即退出，避免拖到 future drop。
                let _ = child.kill().await;
                let _ = tokio::fs::remove_file(&dest_path).await;
                break Err(DownloadError::Cancelled);
            }
            line = lines.next_line() => match line {
                Ok(Some(l)) => {
                    if l.trim() == "progress=end" {
                        parser.on_line(&l);
                        parser.maybe_report(false).await;
                        break Ok(());
                    }
                    parser.on_line(&l);
                    parser.maybe_report(false).await;
                }
                Ok(None) => {
                    // stdout EOF 而未见 progress=end：可能是 ffmpeg 未按预期
                    // 输出（老版本/自定义构建）。等待退出码再判断。
                    parser.maybe_report(false).await;
                    break Ok(());
                }
                Err(e) => {
                    break Err(DownloadError::Other(format!(
                        "failed reading ffmpeg progress: {e}"
                    )));
                }
            },
        }
    };

    // 等待 ffmpeg 退出并检查退出码。
    let status = child.wait().await;
    parse_result?;

    match status {
        Ok(s) if s.success() => {
            // 确认产物存在且非空（流协议可能在录制中途被对端掐断，
            // ffmpeg 也会返回成功——按文件大小兜底判断）。
            let len = tokio::fs::metadata(&dest_path)
                .await
                .map(|m| m.len() as i64)
                .unwrap_or(0);
            if len == 0 {
                let _ = tokio::fs::remove_file(&dest_path).await;
                return Err(DownloadError::Other(
                    "stream ended without producing any data".to_string(),
                ));
            }
            parser.last_bytes = len;
            parser.maybe_report(true).await;
            Ok(len)
        }
        Ok(s) => {
            // 读取 stderr 尾部帮助诊断（ffmpeg 错误信息在 stderr）。
            // wait() 已完成，stderr 管道已 EOF，异步读完不阻塞。
            let mut buf = Vec::new();
            if let Some(mut err_reader) = child.stderr.take() {
                use tokio::io::AsyncReadExt;
                let _ = err_reader.read_to_end(&mut buf).await;
            }
            let stderr = String::from_utf8_lossy(&buf).chars().take(400).collect::<String>();
            let _ = tokio::fs::remove_file(&dest_path).await;
            Err(DownloadError::Other(format!(
                "ffmpeg exited with {s}: {}",
                stderr.trim()
            )))
        }
        Err(e) => {
            let _ = tokio::fs::remove_file(&dest_path).await;
            Err(DownloadError::Other(format!(
                "failed waiting for ffmpeg: {e}"
            )))
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::{is_stream_url, stream_file_name_from_url};

    #[test]
    fn detects_stream_schemes() {
        for url in [
            "mms://host/path/file.asf",
            "MMS://HOST/PATH/FILE.ASF",
            "mmst://host/a.wmv",
            "mmsu://host/b.wma",
            "rtsp://host/live/stream",
            "rtsps://host:554/stream1",
            "rtmp://host/live/room",
            "rtmps://host/app/stream",
        ] {
            assert!(is_stream_url(url), "should detect: {url}");
        }
    }

    #[test]
    fn rejects_non_stream() {
        for url in [
            "http://example.com/a.mp4",
            "https://example.com/stream.m3u8",
            "ftp://example.com/a.zip",
            "magnet:?xt=urn:btih:abc",
            "ed2k://|file|a|1|0|/",
            "torrent-file://local",
        ] {
            assert!(!is_stream_url(url), "should reject: {url}");
        }
    }

    #[test]
    fn file_name_fallback() {
        assert_eq!(
            stream_file_name_from_url("mms://host/path/stream.asf"),
            "stream.asf"
        );
        assert_eq!(
            stream_file_name_from_url("rtsp://host/live"),
            "live.mp4"
        );
        assert_eq!(
            stream_file_name_from_url("rtmp://host/app"),
            "app.mp4"
        );
        assert_eq!(
            stream_file_name_from_url("rtsp://host/live/stream.flv"),
            "stream.flv"
        );
        // URL 编码的段名会被解码
        assert_eq!(
            stream_file_name_from_url("rtsp://host/%E8%A7%86%E9%A2%91.mp4"),
            "视频.mp4"
        );
    }
}
