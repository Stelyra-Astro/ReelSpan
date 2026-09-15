# ReelSpan 待办

更新时间：2026-09-15（Build 8 合并版）

## 当前状态

- [x] 已合并 `codex/supabase-content-sync` 与 `codex/dynamic-metadata` 的功能：Supabase 故事内容同步、本地离线 SQLite、动态 TMDB 元数据、原生详情页、15 条分页、Tip、持久缓存均保留。
- [x] 冷启动会主动读取 Supabase `dataset_meta`；故事数据版本变化时重建本地 `content.sqlite`，版本未变化或联网失败且已有本地库时继续使用本地缓存。
- [x] 电影详情数据改为 **设备缓存 → Supabase `movies.payload` → `https://tmdb.xiaoguiwk.top` Worker fallback**。Worker 负责 TMDB 请求并把电影和 w185 poster 永久写回 Supabase。
- [x] Worker/TMDB 允许为空的文本、评分和演职员字段使用容错解码，单个 `null` 不再导致整部电影或整批排序数据解码失败。
- [x] 抽屉列表不再把 Wikidata QID 当作标题。只有当前可见电影才按需加载真实 TMDB 元数据。
- [x] 抽屉首批 15 部，滚动到底每次再加载 15 部。
- [x] 默认抽屉排序改为 TMDB 评分 + 评分人数的 Bayesian 加权（C=6.5，m=500）；评分数据直接从 `movies.payload` 的 `rating` / `voteCount` 做轻量 PostgREST 投影，无需新增评分表。
- [x] 搜索候选为“地点在前、电影在后”，总计最多 10 条；电影结果由 Worker 搜索后再用本地 `story_movies.tmdb_id` 过滤，ReelSpan 故事库中不存在的电影不展示。
- [x] 搜索电影、抽屉电影、收藏电影都进入原生 `MovieDetailView`；IMDb 仅保留为详情页中的外部链接。
- [x] 元数据和海报共用设备持久缓存：30 天、150 MiB，并可在 Settings 中查看大小和清除；不会清除收藏、偏好或故事地点库。
- [x] 已移除旧的 `workers.dev`、旧 Supabase poster 项目、旧 `ImageDownloadManager` / `TMDBImageMetadata`、内置 SmallPosters 等运行路径。

## 后续 / 真机验收

- [ ] 在 macOS + Xcode 下执行 iPhone Simulator Debug build、Release Archive 和签名验证；当前交付环境没有 Xcode/iOS SDK。
- [ ] 真机验证冷启动 Supabase 版本检查、离线启动回退、地图定位权限和 MapKit 反查。
- [ ] 真机快速滚动抽屉，确认 1 秒可见停留策略不会产生过量 Worker/Supabase 请求。
- [ ] 真机验证三个 ReelSpan consumable Tip 的购买流程。
- [ ] 若仍能稳定复现“地图点击坐标偏移”，记录设备、Sheet 档位、点击位置后再修；本次未在没有复现证据的情况下改 MapReader 坐标换算。

## 运行时数据规范

### Story 数据

Supabase：`story_*` + `dataset_meta` → iPhone 本地 `content.sqlite`。

### Movie metadata

```text
设备 MovieMetadataCache
  ↓ miss
Supabase public.movies.payload
  ↓ miss / error
https://tmdb.xiaoguiwk.top/movie/{tmdb_id}
  ↓
Worker → TMDB → Supabase movies + Storage/posters
  ↓
返回 App → 写入设备缓存
```

### Search

```text
地点：本地 story_places + MapKit（原逻辑）
电影：Worker /search/movie → 本地 story_movies.tmdb_id 过滤 → 最多 10 个候选总量中的电影部分
```
