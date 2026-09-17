# ReelSpan 项目指令

## Build 编号

- 2026-09-17 已成功上传版本 1.0 (12)，下一次新发布归档从 Build 13 开始；此记录为历史基线，发布前核对 App Store Connect 最新编号，避免重复。
- 不要照搬旧 ZIP 中的 CURRENT_PROJECT_VERSION（本次 ZIP 原值为 10）。核对 Debug、Release 设置及最终 Archive/IPA 的 CFBundleVersion。
- 导出设置使用 `manageAppVersionAndBuildNumber=false`，保留明确指定的编号。
- 新编号使用后同步更新本文件与 BUILD_NUMBER.md。

## App Store Connect 已验证上传链路

优先复用 Build 5 与 Build 12 已成功的链路：`xcodebuild -exportArchive` 显式传入 App Store Connect API Key，使用 Apple 托管 Distribution 签名后上传。不要仅因 Organizer / Xcode Apple ID 账号识别失败就断言无法上传，或要求用户必须先重新登录。

本机配置（使用前确认文件存在、权限仍有效；不要读取或输出私钥内容到日志，也不要提交私钥）：

- Bundle ID：`com.xiaoguiwk.ReelSpan`
- Team ID：`KCC8FFFAA5`
- App Store Connect App ID：`6811527529`
- API Key 路径：`/Users/xiaoguiwk/Downloads/AuthKey_PU8UDCHLM8.p8`
- Key ID：`PU8UDCHLM8`
- Issuer ID：`36487f60-f44c-4748-a397-9e9a4b0e7235`

命令模板（替换为本次已验证归档和输出路径；上传须有用户授权）：

```sh
xcodebuild -exportArchive \
  -archivePath '<本次归档.xcarchive>' \
  -exportOptionsPlist '<UploadOptions.plist>' \
  -exportPath '<本次输出目录>' \
  -allowProvisioningUpdates \
  -authenticationKeyPath /Users/xiaoguiwk/Downloads/AuthKey_PU8UDCHLM8.p8 \
  -authenticationKeyID PU8UDCHLM8 \
  -authenticationKeyIssuerID 36487f60-f44c-4748-a397-9e9a4b0e7235
```

UploadOptions.plist 使用：`method=app-store-connect`、`destination=upload`、`signingStyle=automatic`、`teamID=KCC8FFFAA5`、`manageAppVersionAndBuildNumber=false`、`uploadSymbols=true`。

## 区分原始 Archive 签名与最终上传签名

- Build 5 原始 Archive 使用本机 `Apple Development: KUN WANG (3HUJ7J4F2C)`，证书 SHA-1：`51B9219C1C6557E9E47B90293D09324E78EC13FF`。
- 导出流水线替换签名，通过 `RemoteSigningToolConfiguration` 使用 `Apple Distribution: KUN WANG (KCC8FFFAA5)`，类型 `DISTRIBUTION_MANAGED`，证书 SHA-1：`249EEAAC5AAFAABD58871E60E063F9C3E367704C`。Build 12 复用了同一链路。
- 已存在的 Store profile：`iOS Team Store Provisioning Profile: com.xiaoguiwk.ReelSpan`，UUID `64e37f7e-6f7b-4d25-8f54-85da305b7b2a`，`get-task-allow=false`，无 `ProvisionedDevices`，有效期至 2027-08-14T03:18:03Z。每次发布重新核验，不假设该 UUID 永远有效。
- 本地存在 Store profile 或公共 Distribution 证书，不等于本地拥有签名私钥。历史成功链路使用 Apple 远程托管签名；不要强行改成离线手动签名。
- Build 5 成功上传命令不是直接 altool/Transporter；历史 altool 调用只是能力探测，不能作为上传成功证据。
- 未传 API Key 时曾报 `Failed to Use Accounts` / `missing Xcode-Username`（退出码 70）；显式传入上述 API Key 后成功。不要把认证失败误判为 profile 类型错误。

## 验证和授权边界

- 先核验归档的版本、Bundle ID、签名及 dSYM；上传后确认命令退出码 0 和 `Upload succeeded` / `EXPORT SUCCEEDED`。
- “上传成功”和“Apple 处理完成 / TestFlight 可用”必须分开报告；处理期间 builds API 暂未显示新版本不代表上传失败，不要盲目重复上传。
- 上传授权不等于提交审核授权；未经明确请求，不提交审核。
- Build 12 于 2026-09-17 09:39:58 上传成功，当时日志显示 `Uploaded package is processing`，没有提交审核。后续状态须重新查询。
- Build 12 的 silent-refresh-map 源码与测试现已合并到根项目 `ReelAtlas-iOS/`。首次发布时使用的独立副本仍保留在本机 `Artifacts/silent-refresh-validation/ReelSpan-main/`，不提交编译产物。
- Build 12 存在已知的启动缓存策略和线上发现 RPC 超时问题，尚未修复；不要将本次合并解释为修复。根因与待验证场景见 `docs/diagnostics/2026-09-17-build12-cache-startup.md`。

已提交的完整回查：`docs/releases/BUILD5_UPLOAD_TRACE.md`。本机证据：`Artifacts/silent-refresh-validation/VALIDATION.md`、`upload-build-12-api.log`（不提交产物和原始日志）。若本机证据缺失，不要宣称重新核验过上传。
