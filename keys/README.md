# 密钥目录说明

此目录是占位目录，不含任何密钥。生产签名使用外部 KMS/HSM 或 CI Secret；不得把私钥、证书密码或 token 写入仓库。

建议变量：`RELEASE_SIGNING_KEY_ID`、`RELEASE_SIGNING_PROVIDER`。未配置时只能生成未签名校验和，禁止标记为 signed。
