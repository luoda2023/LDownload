# 浏览器扩展内置资源

构建桌面安装包时，CI 会把扩展产物复制到此目录并重命名为固定文件名：

- `ldownload-chrome.zip`  → Chrome / Edge 侧载扩展（含 key，固定扩展 ID）
- `ldownload-firefox.xpi` → Firefox 离线安装包

若此目录在本地开发时为空，应用会回退到从 GitHub Release 下载对应扩展包。
