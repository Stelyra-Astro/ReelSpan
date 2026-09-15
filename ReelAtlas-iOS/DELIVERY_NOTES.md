# ReelSpan Build 8 Delivery Notes

## 本次合并

Build 6 合并了 `codex/supabase-content-sync` 和 `codex/dynamic-metadata` 两条开发线。故事内容继续由 Supabase 管理并在冷启动同步为本地离线 SQLite；电影标题、简介、类型、导演、演员、评分与 poster 使用独立的动态元数据链路。

Build 8 修复了 MapKit 地点自动补全继承设备区域偏置的问题，地点搜索使用全球区域；设备电影缓存链路本次保持不变。

## 电影数据链路

详情读取顺序：

1. iPhone 持久 `MovieMetadataCache`；
2. Supabase `public.movies.payload`；
3. 缓存未命中时请求 `https://tmdb.xiaoguiwk.top/movie/{tmdb_id}`；
4. Worker 请求 TMDB，并把电影元数据和 w185 poster 写入 Supabase；
5. App 把返回结果写入设备缓存。

这允许当前约 6 天的 Supabase 后台回填期间继续使用 Worker fallback；回填完成后，大多数浏览会直接命中 Supabase。

## 列表 / 搜索 / 详情

- 抽屉按 15 部分页，继续滚动每次追加 15 部。
- 候选电影先按当前地点与故事时间从本地 story 数据筛选，再用 TMDB `rating` + `voteCount` 的 Bayesian 分数排序（C=6.5，m=500）。评分字段通过 PostgREST 直接投影 `movies.payload`，无需新的 Supabase 视图。
- 抽屉只对可见行加载完整 metadata，并限制并发；进入详情时详情请求优先。
- 搜索候选：地点在前、电影在后，总计最多 10 个。
- 电影搜索仍由 Worker/TMDB 提供召回，但只展示能够在本地 `story_movies` 通过 `tmdb_id` 匹配的电影。
- 搜索、抽屉和收藏中的电影都打开原生 `MovieDetailView`；IMDb 是详情页外部链接。

## 本地缓存

- metadata + poster 共用 150 MiB 上限；
- metadata TTL 30 天；
- 访问时间用于 LRU 式清理；
- Settings 显示缓存大小并支持清除电影缓存；
- 清除电影缓存不影响故事地点 SQLite、收藏或偏好。

## 清理

已移除运行时不再使用的：

- `ImageDownloadManager.swift`
- `TMDBImageMetadata.swift`
- `MovieTextStore.swift`
- `MovieArtworkView.swift`
- 8 张旧 `SmallPosters`
- 旧 `workers.dev` 和旧 Supabase poster 项目的源代码引用

保留 `StoryContentSyncService.swift` 和 story Supabase migration。

## Build

- Marketing Version: `1.0`
- Build: `8`
- Minimum iOS: `17.0`
- Bundle ID: `com.xiaoguiwk.ReelSpan`

## 本环境已验证

- `swift test`: 57 tests, 0 failures。
- `python -m unittest discover -s Tests/ProjectMergeTests -v`: project merge/source checks pass。
- Xcode Debug Simulator build：通过。
- 12 mini Simulator 安装并启动：通过；截图检查受 CoreSimulator 服务短暂断开影响。
- Xcode project 中动态 metadata 源文件各只进入 Sources 一次，已删除文件不再进入 target。

## 仍需在 Mac/Xcode 验证

Release Archive / TestFlight 上传使用：

```bash
xcodebuild -project ReelSpan.xcodeproj -scheme ReelSpan \
  -configuration Release -destination generic/platform=iOS \
  -archivePath /private/tmp/reelspan-build8-archive/ReelSpan.xcarchive archive
```

Build 8 的 Archive 和上传完成后，再补充处理状态。
