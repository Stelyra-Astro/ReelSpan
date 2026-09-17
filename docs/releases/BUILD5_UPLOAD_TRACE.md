# Build 5 签名与上传回查

## 结论

Build 5 的原始 Archive 与最终上传包不是同一签名阶段：原始 Archive 使用本地 Apple Development 签名；导出流水线将包重新签名为 Apple 托管的 Distribution 证书，再上传。

成功上传不是直接执行 altool/Transporter，也不依赖 Organizer 的 Apple ID 凭据识别。它通过 xcodebuild -exportArchive 显式传入 App Store Connect API Key。

## 原始归档

本地历史文件 ReelAtlas-iOS/build/ReelSpan.xcarchive/Info.plist 确认为 1.0 (5)，SigningIdentity 为 Apple Development: KUN WANG (3HUJ7J4F2C)。其 embedded.mobileprovision 名称为 iOS Team Provisioning Profile: com.xiaoguiwk.ReelSpan。

本机有效签名身份中仍有对应证书，SHA-1：51B9219C1C6557E9E47B90293D09324E78EC13FF。

## 导出重新签名

2026-09-15 09:46:08 的 distribution logs 中，IDEDistributionPipeline.log：

- 97 行：输入 Archive 的 Apple Development 签名。
- 203 行：replacing existing signature。
- 207 行：RemoteSigningToolConfiguration，Apple Distribution: KUN WANG (KCC8FFFAA5)，SHA-1 249EEAAC5AAFAABD58871E60E063F9C3E367704C。
- 434 行：certificateType = DISTRIBUTION_MANAGED。

本机存在 Store profile：64e37f7e-6f7b-4d25-8f54-85da305b7b2a，名称 iOS Team Store Provisioning Profile: com.xiaoguiwk.ReelSpan，有效期至 2027-08-14T03:18:03Z，get-task-allow=false，无 ProvisionedDevices，包含上述 Distribution 证书。Store profile 已存在不等于本机拥有该证书私钥；历史日志明确使用远程托管签名。

## 成功上传命令

历史任务 01a0a2b9-5c3a-7fd2-aebb-9f1d5bc0df9d 记录：

```sh
xcodebuild -exportArchive \
  -archivePath ReelAtlas-iOS/Artifacts/ReelSpan-1.0-5.xcarchive \
  -exportOptionsPlist ReelAtlas-iOS/Artifacts/ExportOptions-TestFlight.plist \
  -exportPath ReelAtlas-iOS/Artifacts/TestFlightUpload-1.0-5 \
  -allowProvisioningUpdates \
  -authenticationKeyPath /Users/xiaoguiwk/Downloads/AuthKey_PU8UDCHLM8.p8 \
  -authenticationKeyID PU8UDCHLM8 \
  -authenticationKeyIssuerID 36487f60-f44c-4748-a397-9e9a4b0e7235
```

之前未传 API Key 的调用退出码 70，Failed to Use Accounts；传入 API Key 后，2026-09-15 09:47:39.279 日志显示 Upload succeeded / EXPORT SUCCEEDED。altool 只用于能力探测，list-providers API Key 探测失败，并非成功上传命令。

## Build 12

API Key 文件仍存在（仅检查存在性，未输出内容）。本次按用户先前上传要求，使用同一 API Key 和托管签名导出链路重试，日志为 upload-build-12-api.log。无需要求用户先修复 Organizer 账号。

结果：2026-09-17 09:39:58.351 Upload succeeded / EXPORT SUCCEEDED，退出码 0。Build 12 导出日志也确认同一托管 Distribution 证书。上传包已开始处理；立即查询 API 时 builds 列表尚未显示 12。
