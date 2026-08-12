pub(crate) mod download_actor;

pub async fn create_actors() {
    // Determine the data directory using the shared resolver.
    //
    // Linux:   $XDG_DATA_HOME/ldownload  (~/.local/share/ldownload)
    // macOS:   ~/Library/Application Support/ldownload
    // Windows portable (marker file present): exe directory
    // Windows installed: %LOCALAPPDATA%\LDownload
    let db_dir = match ldown_engine::data_dir::resolve_data_dir(None) {
        Ok(dir) => dir,
        Err(e) => {
            crate::logger::write_error(&format!("Failed to resolve data directory: {e}"));
            return;
        }
    };

    download_actor::run(db_dir).await;
}
