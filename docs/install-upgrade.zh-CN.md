# 安装、升级与回滚

## Windows
1. 安装 Node.js 20/22，从可信发布页下载目录包。
2. 对照 `SHA256SUMS` 校验全部文件；当前产物未签名，不能声称已验证发布者身份。
3. 解压到新目录，复制 `.env.example` 为 `.env`，执行 `hosts/windows/start.ps1`。

升级前备份 `.env`、工作区及 `.shelly` 数据；在新目录完成校验和冒烟测试后再切换。失败时停止新进程并切回旧目录。不要覆盖安装，以便原子回滚。

## Android
当前状态为 `contract-only`，仓库没有 Gradle 工程、APK/AAB 或可安装应用。Android workflow 只验证 bridge 契约并明确阻止伪造 APK 发布。待真实宿主工程、applicationId、versionCode、SDK 与 keystore 流程落地后方可安装。

## 校验
Linux/macOS: `sha256sum -c SHA256SUMS`；PowerShell 可逐项执行 `Get-FileHash -Algorithm SHA256`。SBOM 位于 `sbom.cdx.json`。
