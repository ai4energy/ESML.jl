"""One-shot engine calls — the public surface of the academic edition.

`Session` (resident DTIL: start/predict/snapshot) is a **commercial-edition**
capability. The academic binary exposes the engine core only. These wrappers
run `esml solve` / `esml simulate` as one process per call and parse the
`esml.solve/v1` / `esml.simulate/v1` JSON envelopes; no state is carried
between calls.
"""

struct SolveOutput
    values::Dict{String,Float64}
    unknowns::Union{Nothing,Int}
    system::Union{Nothing,String}
    raw::Dict{String,Any}
end

struct SimulateOutput
    t::Vector{Float64}
    series::Dict{String,Vector{Float64}}
    steps::Int
    system::Union{Nothing,String}
    raw::Dict{String,Any}
end

"""
    solve(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0)

Solve one document's steady state (no resident session).
"""
function solve(
    path::AbstractString;
    system = nothing,
    libraries = String[],
    binary = nothing,
    timeout = 120.0,
)
    args = _cli_args("solve", path, system, libraries, binary)
    push!(args, "--json")
    env = _run_cli(args, "esml.solve/v1", timeout, "solve")
    values = Dict{String,Float64}()
    for row in _array(env, "values")
        row isa AbstractDict ||
            throw(protocol_error("protocol: `values` entry is not an object"))
        values[String(row["path"])] = _as_float(row["value"], "values[].value")
    end
    return SolveOutput(values, _to_int(_field(env, "unknowns")), _maybe_string(_field(env, "system")), env)
end

"""
    simulate(path, tspan=(0.0, 1.0), steps=100; observe=nothing,
             system=nothing, libraries=String[], binary=nothing, timeout=120.0)

Integrate one document once over `tspan` (no resident session).
"""
function simulate(
    path::AbstractString,
    tspan = (0.0, 1.0),
    steps::Integer = 100;
    observe = nothing,
    system = nothing,
    libraries = String[],
    binary = nothing,
    timeout = 120.0,
)
    t0, t1 = _tspan(tspan)
    n = _steps(steps)
    args = _cli_args("simulate", path, system, libraries, binary)
    append!(args, ["--tspan", "$(t0),$(t1)", "--steps", string(n), "--json"])
    if observe !== nothing
        push!(args, "--observe")
        push!(args, join(_observe(observe), ","))
    end
    env = _run_cli(args, "esml.simulate/v1", timeout, "simulate")
    columns = [String(c) for c in _array(env, "columns")]
    rows = _array(env, "rows")
    series = Dict{String,Vector{Float64}}()
    for (i, column) in enumerate(columns)
        series[column] = Float64[_as_float(row[i], "rows[][]") for row in rows]
    end
    t = Float64[_as_float(x, "t[]") for x in _array(env, "t")]
    steps_out = _to_int(_field(env, "steps"))
    steps_out === nothing &&
        throw(protocol_error("protocol: `steps` is missing or not an integer"; env = env))
    return SimulateOutput(t, series, steps_out, _maybe_string(_field(env, "system")), env)
end

_maybe_string(value) = value isa AbstractString ? String(value) : nothing

function _cli_args(op, path, system, libraries, binary)
    args = String[find_binary(binary), op, String(path)]
    system === nothing || append!(args, ["--system", String(system)])
    for lib in libraries
        append!(args, ["-L", String(lib)])
    end
    return args
end

function _run_cli(args, api, timeout, op)
    out_path, out_io = mktemp()
    close(out_io)
    err_path, err_io = mktemp()
    close(err_io)
    try
        proc = run(
            pipeline(ignorestatus(Cmd(args)), stdout = out_path, stderr = err_path);
            wait = false,
        )
        if timeout === nothing
            wait(proc)
        elseif timedwait(() -> Base.process_exited(proc), Float64(timeout)) == :timed_out
            kill(proc, Base.SIGKILL)
            wait(proc)
            throw(
                EsmlError(
                    "`esml $(op)` did not finish within $(timeout)s";
                    kind = :timeout,
                    op = op,
                ),
            )
        end
        err = strip(read(err_path, String))
        if !success(proc)
            message = isempty(err) ? "`esml $(op)` exited with code $(proc.exitcode)" : err
            throw(EsmlError(message; kind = :engine, op = op))
        end
        text = read(out_path, String)
        parsed = try
            JSON3.read(text)
        catch e
            throw(
                EsmlError(
                    "`esml $(op) --json` emitted non-JSON output: $(repr(text)) " *
                    "($(sprint(showerror, e)))";
                    kind = :protocol,
                    op = op,
                ),
            )
        end
        env = plain(parsed)
        env isa Dict{String,Any} ||
            throw(
                EsmlError(
                    "expected a JSON object from `esml $(op) --json`";
                    kind = :protocol,
                    op = op,
                ),
            )
        _field(env, "apiVersion") == api || throw(
            EsmlError(
                "unexpected envelope from `esml $(op) --json` (expected $(api))";
                kind = :protocol,
                op = op,
                raw = env,
            ),
        )
        return env
    finally
        rm(out_path; force = true)
        rm(err_path; force = true)
    end
end
