# 签名密钥占位与安全说明

仓库**不包含私钥**，也不伪造签名。`keys/` 仅记录接口约定；生产密钥必须存放在受控 KMS/HSM 或 GitHub Actions Secrets，发布任务通过短期凭据签名并审计 key ID。

- `signature.status=unsigned` 是当前默认状态；客户端不得把它当作已验证签名。
- 发布前必须生成 SHA256SUMS 与 CycloneDX SBOM，再由门禁检查元数据完整性。
- 真实发布、签名、密钥轮换和撤销由受审批的发布管理员执行。
- 私钥、token、`.env`、APK keystore 均禁止提交；发现泄露应立即撤销并发布安全公告。
