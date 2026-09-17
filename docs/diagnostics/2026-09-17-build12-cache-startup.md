# Build 12 启动空白 / unavailable 根因调查

调查日期：2026-09-17。范围为实际上传 Build 12 的独立源码副本 `Artifacts/silent-refresh-validation/ReelSpan-main/ReelAtlas-iOS`，不是尚未合并这些改动的根项目。此次只做诊断，没有修改 app 功能代码、云端 schema、设备数据或重新发布。

后续提交更新：诊断之后，用户要求将已上传 Build 12 的源码与测试原样合并到根项目 `ReelAtlas-iOS/` 并推送 main；上述问题仍未修复。本文件的源码分析同样适用于合并后的根项目。

## 结论

不是“缓存被更新删除”，也没有证据证明是 actor 死锁。主要故障链是：服务端默认列表 RPC 超时 → 新页面缓存未命中 → 列表分支拒绝已有 SQLite 回退 → UI 将错误解释为 Films unavailable for now。

截图的 49,995 是 `syncTotal` 元数据，不是当前可显示列表的条数，也不证明该次网络请求成功。

## 已核验的证据

### 服务端

使用 app 本身的 publishable key、相同 RPC 参数（空查询、无筛选、limit=16、offset=0）只读访问：

- sort=country:Q30：HTTP 500，约 4,380 ms，PostgREST 57014，canceling statement due to statement timeout。
- sort=recommended：HTTP 500，约 3,240 ms，同一错误。
- pg_roles：anon 的 statement_timeout=3s，authenticated=8s。
- 读取线上 reelatlas_discover 实际函数定义，展开默认 recommended 参数执行 EXPLAIN ANALYZE：Execution Time=9,375.672 ms，返回 16 行前处理 50,008 行故事数据；全表扫描 13,925 条 movies 元数据，宽字段 hash join 分成 8 批，有临时磁盘读写。 LIMIT 发生在大规模关联及排序之后。
- 线上函数没有本地 202609160006_search_candidate_prefilter.sql 中的 candidates CTE。可确认线上/本地优化定义不一致，但未确认具体哪次迁移或部署覆盖了函数，不能武断归因于某一个 migration。

这些观察证明当前服务端确实有超时，不是设备网络故障的猜测。展开查询的管理连接执行环境不完全等同 RPC；其大规模关联/分页后置瓶颈与匿名 RPC 的实测超时互相印证。

### 本机连接的 12 mini

仅只读列出 app 文件并拷贝故事数据库，不读取收藏、不重装、不清缓存：

- `Library/Application Support/ReelAtlas/content.sqlite` 约 33.1 MB。
- `SELECT count(*) FROM movies`：50,005。
- SQLite quick_check：ok；sync_complete=1；sync_downloaded=50,005；sync_total=49,995。
- 50,005 行 title_en 全部仍是 movie_qid，tmdb_overview 非空数为 0。影片元数据在另一套 MovieMetadata-v1 缓存，不在这套故事表里。
- `Caches/reelspan-where-catalog-v1.json` 存在。
- 未发现 `Caches/reelspan-discovery-pages-v1.json`。这套目录页缓存是 Build 12 新增的，旧版本有故事和元数据缓存，不代表具有新页缓存。

没有取得截图发生时的设备 HTTP 日志，所以不能宣称上述查询就是截图那次请求的完整逐步时间线；代码路径、现存缓存与当前服务端实测可以解释同一故障。

## 客户端具体缺陷

1. **目录页 network-first，缓存被网络挡住。** CatalogDiscoveryService.swift:212-244，启动时 offlineUntil=distantPast，先请求 RPC；只有请求失败后才读取精确 key 的缓存。即使已有页缓存，冷启动也会等待网络和重试结束。15 秒请求超时、最多 3 次请求外加退避，在真实网络故障下延迟可能接近 46.5 秒；本次 SQL 超时场景主要是 3 秒级请求反复失败。
2. **列表直接禁止 SQLite fallback。** AppModel.swift:744-754 的 `if listMode ... return` 对所有普通列表生效，不只文本/Genre 等无法本地精确查询的场景。50k 故事缓存存在，仍完全不能给列表提供兜底。
3. **缓存粒度不一致。** SQLite 故事关系、MovieMetadata-v1 元数据、精确请求页缓存是三套存储。新增目录页缓存没有为旧版已有数据做可显示数据迁移/组合。直接放开 fallback 还不够：现有故事表标题全为 QID，必须结合已有元数据缓存，不能把 QID 列表或不符合筛选的旧页冒充正常结果。
4. **reload 先清空，再加载。** AppModel.swift:669-684，取消任务并清 movies 和 pins；加载失败时已显示数据也可能消失。准确的筛选缓存 key 包含语言、国家优先排序、分页等字段；定位国家改变或语言恢复后，旧 key 不匹配会再次触发空白。
5. **UI 用错误标志代替“无可用数据”的判断。** FilmListView.swift:66-72，只要 movies 为空且 catalogSearchError 非空就显示 unavailable，没检查其他持久缓存是否可显示或正等待读取。

已有故事库的 ensureCurrentContent 分支本身先返回磁盘缓存，没有等待 fetchManifest；剩余同步由独立 Task 启动。所以不能把全部问题归结为 ensureCurrentContent 等待后台全库更新。但启动仍夹有定位/iCloud 等 await，列表缓存读取又是 network-first。

## 关联病症（源码确认路径，未全部真机复现）

- **地图在后台同步时闪空、图钉消失、请求反复取消：** acceptSyncedBatch 在地图模式调用 reload，后者清空影片和 pins；初次全库下载可多次触发，完成后的更新也会触发。
- **iCloud 恢复使普通列表重载：** 启动及每次完成同步会恢复备份，只要 restore 返回 manifest，即便收藏/语言未变化也调用 reload。它可以把已经显示的列表清空，再撞上故障 RPC。
- **收藏/本地回退也等待网络：** MoviePageWorker.page 在返回本地候选前 await metadataService.rankings；rankings 不走 metadata cache 读取，网络评分失败/慢响应会挡住已有本地影片（请求超时配置 12 秒）。
- **首次安装不是真正首批优先：** rebuildFirstBatch 先顺序下载并写入全套 targets、places、time concepts，再获取 250 部影片及其关系，成功后才发布数据库；随后普通列表仍走目录 RPC 而不是立即展示这 250 部本地影片。
- **首次安装失败后的缓存初始化恢复不足：** loadStoryContent catch 只设置 catalogSearchError，没有安排缓存初始化重试；已有 content 才能 scheduleContentSyncRetry。目录重试只 reload 影片，不重建 content。初始化重试主要依赖之后 foreground 且距离上次尝试已满 300 秒，持续前台可一直没有初始化恢复。
- **地点分组可能长期显示 spinner：** Where 目录/国家关联请求失败时，分组条件仍要求对应数据；关联加载失败直接返回，缺少明确的降级展示/持续重试路径。
- **数量标签可能过时：** 实际本地 50,005 行而 syncTotal=49,995；图上总数来自同步元数据，不能用其推断列表可用性。

## 建议修复方向（未实施）

1. 本地可显示数据加载与联网更新解耦：启动先读本地目录快照，立即 publish；RPC/增量同步只在后台刷新，不占据首屏等待链。
2. 为升级用户组合/迁移已有故事库与 metadata cache；持久化足以离线展示及正确筛选的目录元数据。没有精确筛选缓存时，明确离线筛选能力，不能展示无关页或把服务端故障当成零结果。
3. 首次安装分阶段下载首批影片、其必需关系和可显示元数据，立即展示；其余地点/概念/影片后台补齐，而不是先抓全套父表。
4. 相同筛选的刷新保留当前 rows/pins，只原位替换成功结果；评分、海报等 enrichment 不挡住基础影片；iCloud/定位更新只在实际相关状态改变时刷新。
5. 优化线上发现 RPC，默认浏览先分页 ID，再加载这页元数据/关系；按筛选和排序分别保持正确语义，搜索先限制候选。不能只提高 statement_timeout 或靠客户端反复重试。
6. 补齐初始化失败、前后台转换、地点分组的重试状态机，并分开“加载中 / 有缓存刷新失败 / 真无结果 / 真无可用数据”。

## 必须补的回归验证

- 旧版完整故事库和元数据缓存、无新页缓存：升级后断网也能显示已有可显示影片。
- 有精确页缓存：RPC 慢响应/永不返回时，缓存仍先于网络结果显示。
- 已显示列表/地图：同步失败或成功、iCloud 无变化恢复均不得清空当前数据。
- 首次安装：全库未完成时首批可显示，后续失败不影响首批；初始化失败后持续前台也能自动恢复。
- 收藏：评分服务慢或失败不阻塞本地 rows。
- 新筛选/语言/国家优先顺序：不能用不匹配缓存冒充正确结果。
- 匿名角色下实测线上 RPC 默认浏览、排序、筛选、搜索的执行时长低于超时预算。

旧测试的盲区：同步集成测试验证了数据库保留，新增 Python 回归多为源码字符串存在性检查；它们没有验证上面的“用户可见缓存先显示”和升级路径。先前的 85 Swift / 48 Python 通过不能作为这些交互场景正确的证据。
