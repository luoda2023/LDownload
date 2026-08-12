//! 站点 HTTP Basic 认证的建任务链路集成测试。
//!
//! 单测已覆盖 `site_auth` 纯函数（站点键 / Basic 编码 / 凭据库序列化）。
//! 这里验证只有跑通 `create_task` 才能证明的接线：
//!
//! 1. 显式凭据 → `Authorization: Basic` 注入并随请求上下文持久化
//!    （`tasks.extra_headers`，resume/probe 复用同一链路）；
//! 2. 「为此网站保存」→ 凭据按站点键落 config 键 `site_auth_credentials`；
//! 3. 同站点后续任务未显式给凭据 → 自动套用已保存凭据；
//! 4. 其他站点 / 已带 Authorization 头的任务不受影响。
//!
//! 任务全部 `start_paused` 落库，不发起真实网络请求。

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::HashMap;
use std::sync::Arc;

use ldown_engine::bt_downloader::BtConfig;
use ldown_engine::download_manager::NewTaskSpec;
use ldown_engine::proxy_config::ProxyConfig;
use ldown_engine::site_auth;
use ldown_engine::{Engine, EngineConfig, NoopSelection, NoopSink};

fn uniq() -> String {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}-{}", std::process::id(), n)
}

async fn make_engine(work: &std::path::Path) -> Engine {
    let cfg = EngineConfig {
        max_concurrent: 4,
        speed_limit_bps: 0,
        upload_limit_bps: 0,
        default_save_dir: work.to_string_lossy().into_owned(),
        app_data_dir: work.to_string_lossy().into_owned(),
        bt_config: BtConfig::default(),
        proxy_config: ProxyConfig::default(),
        user_agent: String::new(),
        data_dir_override: Some(work.to_path_buf()),
        database_url: None,
    };
    Engine::new(cfg, Arc::new(NoopSink), Arc::new(NoopSelection))
        .await
        .expect("engine")
}

/// 读取任务持久化的 extra_headers JSON 并反序列化（空串 = 无）。
async fn task_headers(engine: &Engine, id: &str) -> HashMap<String, String> {
    let (_, _, headers_json) = engine
        .db
        .load_task_request_context(id)
        .await
        .expect("load request context")
        .expect("task exists");
    if headers_json.is_empty() {
        HashMap::new()
    } else {
        serde_json::from_str(&headers_json).expect("headers json")
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_credentials_are_injected_saved_and_auto_applied() {
    let work = std::env::temp_dir().join(format!("ldownload-siteauth-{}", uniq()));
    tokio::fs::create_dir_all(&work).await.expect("mkdir");
    let mut engine = make_engine(&work).await;
    let save_dir = work.to_string_lossy().into_owned();

    // ── 1+2：显式凭据 + 为此网站保存 ────────────────────────────────
    let id_a = engine
        .manager
        .create_task(NewTaskSpec {
            url: "http://nas.example:8443/protected/a.bin".to_string(),
            save_dir: save_dir.clone(),
            file_name: "a.bin".to_string(),
            start_paused: true,
            http_user: "alice".to_string(),
            http_password: "secret".to_string(),
            save_site_auth: true,
            ..Default::default()
        })
        .await
        .expect("create task a");
    let headers = task_headers(&engine, &id_a).await;
    let expected = site_auth::basic_auth_value("alice", "secret");
    assert_eq!(
        headers.get("Authorization").map(String::as_str),
        Some(expected.as_str()),
        "explicit credentials must inject Authorization"
    );

    let store_json = engine
        .db
        .get_config(site_auth::SITE_AUTH_CONFIG_KEY)
        .await
        .expect("get config")
        .expect("store persisted");
    let store = site_auth::parse_store(&store_json);
    let cred = store.get("nas.example:8443").expect("site key saved");
    assert_eq!(cred.user, "alice");
    assert_eq!(cred.pass, "secret");

    // ── 3：同站点后续任务自动套用 ──────────────────────────────────
    let id_b = engine
        .manager
        .create_task(NewTaskSpec {
            url: "http://nas.example:8443/protected/b.bin".to_string(),
            save_dir: save_dir.clone(),
            file_name: "b.bin".to_string(),
            start_paused: true,
            ..Default::default()
        })
        .await
        .expect("create task b");
    let headers = task_headers(&engine, &id_b).await;
    assert_eq!(
        headers.get("Authorization").map(String::as_str),
        Some(expected.as_str()),
        "saved credential must auto-apply for the same site"
    );

    // ── 4a：其他站点不受影响 ──────────────────────────────────────
    let id_c = engine
        .manager
        .create_task(NewTaskSpec {
            url: "http://other.example/c.bin".to_string(),
            save_dir: save_dir.clone(),
            file_name: "c.bin".to_string(),
            start_paused: true,
            ..Default::default()
        })
        .await
        .expect("create task c");
    assert!(
        !site_auth::has_authorization(&task_headers(&engine, &id_c).await),
        "unrelated site must not receive credentials"
    );

    // ── 4b：已带 Authorization（浏览器捕获）时不覆盖 ────────────────
    let mut captured = HashMap::new();
    captured.insert("authorization".to_string(), "Bearer tok".to_string());
    let id_d = engine
        .manager
        .create_task(NewTaskSpec {
            url: "http://nas.example:8443/protected/d.bin".to_string(),
            save_dir: save_dir.clone(),
            file_name: "d.bin".to_string(),
            start_paused: true,
            extra_headers: captured,
            ..Default::default()
        })
        .await
        .expect("create task d");
    let headers = task_headers(&engine, &id_d).await;
    assert_eq!(
        headers.get("authorization").map(String::as_str),
        Some("Bearer tok"),
        "captured Authorization must win over the saved credential"
    );

    let _ = tokio::fs::remove_dir_all(&work).await;
}
