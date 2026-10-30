# ESML.jl

ESML 引擎的 **MIT** Julia 客户端。公开面是**一次性调用**：`solve` / `simulate`
每次启动一个 `esml` 进程，读取 `esml.solve/v1` / `esml.simulate/v1` JSON，
调用之间不保留状态。

常驻数字孪生（DTIL）会话 `Session`（`predict` / `snapshot` / `restore`）属于
**商业版**能力，需要商业版引擎；学术版会在 `esml session` 入口响亮拒绝。

本包绑定的是 ESML 引擎二进制；Julia 侧的示范性实现是
[`ai4ecom/esml-engine-julia`](https://github.com/ai4ecom/esml-engine-julia)，
与本包是两件独立的东西。

```julia
using ESML

steady = solve("plant.esml"; system = "Plant")
println(steady.values)
println(get(steady.units, "tank.T", nothing), " ", steady.meta["unitCoverage"])

traj = simulate("plant.esml", (0.0, 60.0), 60; observe = ["tank.T"])
println(traj.series["tank.T"][end], " ", get(traj.units, "tank.T", nothing))
```

## 安装

```julia
using Pkg
Pkg.add(url = "https://github.com/ai4energy/ESML.jl")
```

还需要**引擎二进制**：

- 免费学术版（展平未知量 ≤ 16,384，非商业用途）：
  <https://github.com/ai4energy/esml/releases>
- 放到 `PATH`，或设 `ESML_BIN=/path/to/esml`，或传 `binary="/path/to/esml"`。
  显式给出的路径不可执行时**响亮报错**，绝不静默换一个二进制。

## API

一次性调用（学术版即可用）：

| 调用 | 含义 |
| --- | --- |
| `solve(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0)` | 稳态求解 → `SolveOutput(values, unknowns, system, raw, units, meta)` |
| `simulate(path, tspan=(0.0, 1.0), steps=100; observe=nothing, …)` | 一次性时间积分 → `SimulateOutput(t, series, steps, system, raw, units, meta)` |

`units` 是路径 → SI 量纲表达式的映射（模型未声明单位时缺项）；`meta` 含
`engineVersion`、`docHash`（源文件 SHA-256）、`durationMs`、`converged`、
`iterations`、`residual`、`residualTolerance` 与 `unitCoverage`。字段语义见
[结果契约](https://docs.ai4energy.cn/esml/results)。

引擎版本：`units` / `meta` 需引擎 **>= 1.8.1**；`iterations` / `residual` /
`EsmlError.code` 需引擎 **>= 1.9.0**。旧引擎缺少的字段会表现为空的 `meta` /
`units` 或 `None`，客户端不伪造。


`observe` 只接受变量路径；空列表在客户端拒绝，未知/重复路径由引擎拒绝。

商业版常驻会话（DTIL）：

| 调用 | 含义 |
| --- | --- |
| `Session(path; system=nothing, libraries=String[], binary=nothing, timeout=nothing)` | 常驻会话 |
| `solve(session)` / `simulate(session, tspan, steps; observe)` / `predict(session, horizon, …)` | 求解、链式积分、非推进预测 |
| `set_param!` / `set_params!` / `set_state!` / `set_states!` / `clear_state!` | 热参数与状态注入 |
| `snapshot` / `restore!` / `info` / `close!` | 快照恢复、状态与生命周期 |

`SolveResult` / `Trajectory` 含 `units` 与 `meta`，字段与一次性契约一致。

`EsmlError` 还带 `code` / `hint` / `doc_hash`（来自 `esml.error/v1`）。

失败抛 `EsmlError`，`kind` 区分 `:engine` / `:protocol` / `:timeout` / `:closed` /
`:binary_not_found`；客户端参数错误抛 `ArgumentError`。

## 许可

- **本包**：MIT（见 `LICENSE`）。
- **ESML 引擎**：**商业软件，不是 MIT**（见 `LICENSE-ENGINE.md`）。学术版（≤ 16,384 未知量、不含 DTIL）
  非商业用途免费；商业用途需取得商业许可（mingtao.li@gmail.com）。本包不含引擎
  代码，只通过公开 JSON 协议调用引擎。

## 开发

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'                  # 协议测试（假引擎）
ESML_BIN=/path/to/esml julia --project=. test/runtests.jl     # 含真机集成
```

协议测试使用 `test/fake_esml.jl`；真机集成只在设置 `ESML_BIN` 时运行。
