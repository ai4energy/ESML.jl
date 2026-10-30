# 注册到 Julia General（准备清单）

当前状态：**未注册**。Julia General 中 `ESML` 为空（2026-10-30 检查）；
包 UUID 已定稿为 `6fa1d99e-4a66-4af0-9128-1d23b8695e9c`。

## 前提

- `Project.toml` 的 `version` 与 `[compat]` 已定稿；
- `Pkg.test()` 通过（协议测试；集成测试需 `MMPROPS_BIN`/`ESML_BIN`）；
- 仓库已有 tag `v0.1.0`。

## 推荐路径：JuliaRegistrator

1. 由 ai4energy 组织管理员把 **JuliaRegistrator** GitHub App 安装到本仓
   （<https://github.com/apps/juliahub-registrator>）。
2. tag 并推送：
   ```bash
   git tag -a vX.Y.Z -m "ESML.jl vX.Y.Z"
   git push origin vX.Y.Z
   ```
3. 在 tag 对应的 commit 上评论：
   ```
   @JuliaRegistrator register
   ```
4. 等待 AutoMerge / General 维护者评审。合并后即可
   `Pkg.add("ESML")`。

## 备选：手工 PR

在 `ai4energy/General` 的 fork 中添加 `E/ESML/`：

- `Package.toml`
  ```toml
  name = "ESML"
  uuid = "6fa1d99e-4a66-4af0-9128-1d23b8695e9c"
  repo = "https://github.com/ai4energy/ESML.jl.git"
  ```
- `Versions.toml`
  ```toml
  ["0.1.0"]
  git-tree-sha1 = "<git rev-parse v0.1.0^{tree}>"
  ```
- `Deps.toml`（JSON3，UUID `0f8b85d8-7281-11e9-16c2-39a750bddbf1`）
- `Compat.toml`（`julia = "1.6"`、`JSON3 = "1"`）

然后向 `JuliaRegistries/General` 提 PR。

## 注册前验证

```bash
julia -e 'using Pkg; Pkg.activate(temp=true);
          Pkg.add(url="https://github.com/ai4energy/ESML.jl", rev="v0.1.0");
          using ESML; println(ESML.engine_version(ESML.find_binary()))'
```
