# 最小示例：一次性 solve 与 simulate（学术版即可运行）。
#
#     export ESML_BIN=/path/to/esml
#     julia --project=. examples/decay.jl

using ESML

doc = joinpath(@__DIR__, "decay.esml")

steady = solve(doc; system = "S")
println("稳态: ", steady.values)

traj = simulate(doc, (0.0, 1.0), 20; observe = ["m.x"], system = "S")
println("x(1) = ", traj.series["m.x"][end])
