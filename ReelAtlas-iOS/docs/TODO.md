# ReelSpan 待办

更新时间：2026-09-15

## 当前状态

- 当前分支已开始把故事地点数据从 App 内置 SQLite 迁移到 Supabase，并在设备端重建离线缓存。
- 首启同步已限制到 `story_movie_target_matches` 中真正发布的电影，避免下载全部候选数据；内容就绪前不再把经纬度显示成地点名。
- 当前版本的电影元数据链路尚未接回 UI：`story_movies` 只提供 Wikidata QID、legacy ID、TMDB ID 和 IMDb ID，因此列表会暂时显示 `Q…`、`Genre pending` 等占位内容。
- 当前海报来自独立的公开 Supabase Storage：`https://qvfdtvfgnlpctcykpfgy.supabase.co/storage/v1/object/public/posters/{tmdb_id}.jpg`。`AsyncImage` 只使用系统网络缓存，并未接入项目现有的 30 天 / 150 MiB 持久缓存。
- 项目已有详细设计与实施计划：
  - `docs/superpowers/specs/2026-09-14-dynamic-movie-metadata-search-tip-design.md`
  - `docs/superpowers/plans/2026-09-14-dynamic-movie-metadata-search-tip.md`

## P0 — 恢复核心体验

- [ ] 接入 `reelspan-tmdb.xiaoguiwk.workers.dev` 的电影详情接口，通过 `tmdb_id` 获取标题、年份、时长、类型、简介、导演、演员、评分和图片 URL；不再把 Wikidata QID 当作电影标题。
- [ ] 列表首屏只展示 15 部电影；滑动到底部后每次继续加载 15 部，保持稳定排序并避免重复请求。
- [ ] 点击电影列表进入 App 内原生 `MovieDetailView`，不再直接跳转 IMDb。
- [ ] 在原生详情页中保留 IMDb 外部超链接。
- [ ] 恢复详情页优先级加载：进入详情时优先请求该电影元数据，并暂停/取消低优先级列表请求；退出详情后继续列表加载。
- [ ] 修复地图点选坐标偏移，确认手指触点、`MapReader` 坐标空间、底部 Sheet 覆盖区域和地图可见区域之间的换算一致。

## P1 — 缓存与可控性

- [ ] 将电影元数据 JSON 持久缓存到设备，按语言和 TMDB ID 分键，过期时间 30 天。
- [ ] 将浏览过的海报写入设备持久缓存；确认二次进入列表/详情时离线可读，而不是只依赖 `AsyncImage` 临时缓存。
- [ ] 对电影元数据和图片共用 150 MiB 上限，并按最近最少使用策略清理。
- [ ] 在设置中增加“清除电影缓存”按钮，显示当前缓存大小，并同时清除元数据与海报缓存；不要清除收藏、偏好或故事地点数据库。
- [ ] 验证故事地点 SQLite 缓存在断网启动、版本未变化和同步失败时仍可用。

## P1 — Tip

- [ ] 在地图首页增加 Tip 入口。
- [ ] 使用 StoreKit 2 消耗型商品 `com.reelatlas.tip`，提供 1、3、5 快捷数量和 1–10 自定义数量。
- [ ] 补齐购买中、成功、取消、失败和不可购买状态，以及中英文文案。

## 验收清单

- [ ] 干净安装后，短暂显示“正在载入故事地图”，随后出现真实地点名和电影结果，不出现经纬度假标题。
- [ ] 列表中的标题、年份、时长和类型均为真实元数据；缺失字段显示明确占位，但不能回退为 Wikidata QID 标题。
- [ ] 首屏网络请求不超过 15 部电影的详情；继续下拉才请求下一批 15 部。
- [ ] 点击电影打开原生详情页；详情页 IMDb 链接可打开对应条目。
- [ ] 点击地图后，标记与手指触点在允许误差内重合。
- [ ] 浏览电影后断网重开，已缓存元数据和海报仍显示；清除缓存后对应文件和缓存大小归零。
- [ ] 首页 Tip 入口和 StoreKit 流程可在 StoreKit 测试配置中完成购买。
- [ ] Swift 单元测试、Release 真机编译和签名 Archive 全部通过后再交付 Build 6。
