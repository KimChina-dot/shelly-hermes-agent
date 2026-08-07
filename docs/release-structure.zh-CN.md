# 发行与打包结构

## 目标产物

```text
release/
  shelly-hermes-agent-vX.Y.Z/
    dist/                 # 编译后的 JS、d.ts、map
    hosts/windows/        # cli.js、start.ps1、README
    docs/                 # 中文运行与安全说明
    package.json
    package-lock.json
    README.md
    SHA256SUMS
  shelly-hermes-agent-vX.Y.Z.zip
```

核心库与宿主分层：`src/` 是可复用核心；`hosts/windows/` 是 Node CLI；Android 宿主工程不塞进核心包，另行发布 APK/AAB 或 host SDK。

## 包元数据

当前 `0.1.0` 为 private MVP。达到 RC 后移除 `private`，设置 `main`/`types`/`exports` 指向 `dist/src/index.js` 与声明文件，并限制 `files` 为 `dist`、`hosts`、`docs`、`README.md`、许可证和变更日志。每个 tag 必须由 package.json、lockfile、git tag 使用同一版本。

## 发布流程

1. PR 通过核心矩阵、Windows host、Android contract 与文档检查。
2. 合并后由 `v*` tag 触发 `npm ci`、`npm run verify`、`npm run package`。
3. 打包目录生成 SHA-256；上传 GitHub Release；RC 先 internal，稳定版再 npm/制品库。
4. 发布说明包含兼容性、权限变化、迁移步骤、已知限制和可复现验证命令。

禁止将 `.env`、API key、checkpoint、审计日志、`node_modules` 放入发行包。
