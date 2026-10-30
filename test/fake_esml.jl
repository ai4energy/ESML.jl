#!/usr/bin/env julia
"""A faithful fake of `esml session` for client tests (no engine needed).

It implements the subset of the `esml.session/v1` protocol the client uses and
mirrors the real engine's envelope shapes and error semantics. Set
`FAKE_ESML_MODE` to exercise failure modes:

* `bad-version` — the open envelope claims an unknown apiVersion
* `crash`       — exits right after the open envelope
* `silent`      — reads nothing and never answers (timeout test)
* `garbage`     — answers each request with a non-JSON line
"""

using JSON3

const API = "esml.session/v1"
const DOC_HASH = 42
const MODE = get(ENV, "FAKE_ESML_MODE", "ok")
const VARIABLES = ["m.x", "m.y"]
const STATES = ["m.x"]

plain(value::JSON3.Object) =
    Dict{String,Any}(String(key) => plain(item) for (key, item) in pairs(value))
plain(value::JSON3.Array) = Any[plain(item) for item in value]
plain(value) = value

function envelope(; kwargs...)
    out = Dict{String,Any}("apiVersion" => API)
    for (key, value) in kwargs
        out[String(key)] = value
    end
    return out
end

error_envelope(op, message) = envelope(op = "error", request = op, error = message)

mutable struct Fake
    params::Dict{String,Float64}
    state::Dict{String,Float64}
    sim_end::Union{Nothing,Vector{Float64}}
    cold::Int
    warm::Int
    sim_calls::Int
    last_steps::Int
end

Fake() = Fake(Dict("m.lam" => 0.5), Dict{String,Float64}(), nothing, 0, 0, 0, 0)

function x0(fake::Fake)
    haskey(fake.state, "m.x") && return fake.state["m.x"]
    fake.sim_end === nothing && return 1.0
    return fake.sim_end[2]
end

function values_at(fake::Fake, t_rel)
    lam = fake.params["m.lam"]
    x = x0(fake) * exp(-lam * t_rel)
    return Dict("m.x" => x, "m.y" => lam * x)
end

function solve_envelope(fake::Fake)
    lam = fake.params["m.lam"]
    x = x0(fake) / (1.0 + lam)
    warm = fake.cold > 0
    if warm
        fake.warm += 1
    else
        fake.cold += 1
    end
    return envelope(
        op = "solve",
        iterations = warm ? 3 : 5,
        warm = warm,
        unknowns = length(VARIABLES),
        values = [
            Dict{String,Any}("path" => "m.x", "value" => x),
            Dict{String,Any}("path" => "m.y", "value" => lam * x),
        ],
        durationMs = 1,
        docHash = DOC_HASH,
    )
end

function trajectory(fake::Fake, op, t0, t1, steps, observe)
    steps >= 1 || return error_envelope(op, "steps must be >= 1")
    projected = observe === nothing ? VARIABLES : observe
    length(unique(projected)) == length(projected) ||
        return error_envelope(op, "observe paths must be unique")
    t = [t0 + (t1 - t0) * i / steps for i in 0:steps]
    rows = [values_at(fake, tt - t0) for tt in t]
    series = Dict{String,Any}[]
    for path in projected
        path in VARIABLES ||
            return error_envelope(op, "unknown observe path `$(path)` (parameters are not observable)")
        push!(
            series,
            Dict{String,Any}("path" => path, "values" => [row[path] for row in rows]),
        )
    end
    continued = fake.sim_end !== nothing || !isempty(fake.state)
    if op == "simulate"
        fake.sim_end = [Float64(t1), rows[end]["m.x"]]
        empty!(fake.state)
        fake.sim_calls += 1
        fake.last_steps = steps
    end
    return envelope(
        op = op,
        steps = steps,
        points = length(t),
        continued = continued,
        t = t,
        series = series,
        durationMs = 1,
        docHash = DOC_HASH,
    )
end

function pairs_of(req, op)
    haskey(req, "values") || return nothing, error_envelope(op, "missing \"values\" array")
    req["values"] isa AbstractVector ||
        return nothing, error_envelope(op, "missing \"values\" array")
    rows = Pair{String,Float64}[]
    for item in req["values"]
        item isa AbstractDict || return nothing, error_envelope(op, "bad values entry")
        path = get(item, "path", nothing)
        value = get(item, "value", nothing)
        if !(path isa AbstractString) || !(value isa Real)
            return nothing, error_envelope(op, "each values item needs path (string) and value (number)")
        end
        push!(rows, String(path) => Float64(value))
    end
    return rows, nothing
end

function observe_of(req)
    haskey(req, "observe") || return nothing, nothing
    arr = req["observe"]
    (arr isa AbstractVector && !isempty(arr)) ||
        return nothing, "observing needs a non-empty array"
    all(p -> p isa AbstractString, arr) ||
        return nothing, "each observe path must be a string"
    return String[String(p) for p in arr], nothing
end

function handle(fake::Fake, req)
    op = get(req, "op", nothing)
    op isa AbstractString || return error_envelope(nothing, "missing \"op\" (string)")
    if op == "set_param"
        path = get(req, "path", nothing)
        value = get(req, "value", nothing)
        if !(path isa AbstractString) || !(value isa Real)
            return error_envelope(op, "set_param requires path (string) and value (number)")
        end
        haskey(fake.params, String(path)) ||
            return error_envelope(op, "`$(path)` is not a declared parameter")
        fake.params[String(path)] = Float64(value)
        return envelope(op = op, ok = true, path = path, value = Float64(value))
    elseif op == "set_state"
        path = get(req, "path", nothing)
        value = get(req, "value", nothing)
        if !(path isa AbstractString) || !(value isa Real)
            return error_envelope(op, "set_state requires path (string) and value (number)")
        end
        String(path) in STATES || return error_envelope(op, "`$(path)` is not a dynamic state")
        fake.state[String(path)] = Float64(value)
        return envelope(op = op, ok = true, path = path, value = Float64(value))
    elseif op == "set_params" || op == "set_states"
        rows, err = pairs_of(req, op)
        err === nothing || return err
        allowed = op == "set_params" ? collect(keys(fake.params)) : STATES
        for (path, _) in rows
            path in allowed ||
                return error_envelope(op, "`$(path)` is not a declared $(op == "set_params" ? "parameter" : "dynamic state")")
        end
        for (path, value) in rows
            if op == "set_params"
                fake.params[path] = value
            else
                fake.state[path] = value
            end
        end
        return envelope(op = op, ok = true, count = length(rows))
    elseif op == "clear_state"
        empty!(fake.state)
        fake.sim_end = nothing
        return envelope(op = op, ok = true, pendingStates = 0)
    elseif op == "solve"
        return solve_envelope(fake)
    elseif op == "simulate" || op == "predict"
        steps = get(req, "steps", 100)
        (steps isa Integer && !(steps isa Bool) && steps >= 1) ||
            return error_envelope(op, "\"steps\" must be an integer >= 1")
        observe, err = observe_of(req)
        err === nothing || return error_envelope(op, err)
        if op == "predict"
            horizon = get(req, "horizon", nothing)
            (horizon isa Real && horizon > 0) ||
                return error_envelope(op, "predict requires \"horizon\" (number, > 0)")
            return trajectory(fake, op, 0.0, Float64(horizon), Int(steps), observe)
        end
        span = get(req, "tspan", nothing)
        (span isa AbstractVector && length(span) == 2 && all(v -> v isa Real, span)) ||
            return error_envelope(op, "simulate requires \"tspan\": [t0, t1] (two numbers)")
        return trajectory(fake, op, Float64(span[1]), Float64(span[2]), Int(steps), observe)
    elseif op == "snapshot"
        return envelope(
            op = op,
            docHash = DOC_HASH,
            snapshot = Dict{String,Any}(
                "docHash" => DOC_HASH,
                "params" => [
                    [key, fake.params[key]] for key in sort(collect(keys(fake.params)))
                ],
                "simEnd" => fake.sim_end,
                "state" => [
                    [0, fake.state[key]] for key in sort(collect(keys(fake.state)))
                ],
                "coldSolves" => fake.cold,
                "warmSolves" => fake.warm,
                "simCalls" => fake.sim_calls,
                "lastSteps" => fake.last_steps,
            ),
        )
    elseif op == "restore"
        snap = get(req, "snapshot", nothing)
        snap isa AbstractDict || return error_envelope(op, "restore requires \"snapshot\" (object)")
        get(snap, "docHash", nothing) == DOC_HASH ||
            return error_envelope(op, "snapshot was taken from a different document")
        params = Dict{String,Float64}()
        for row in get(snap, "params", [])
            (row isa AbstractVector && length(row) == 2 && row[1] isa AbstractString && row[2] isa Real) ||
                return error_envelope(op, "bad snapshot params")
            haskey(fake.params, String(row[1])) ||
                return error_envelope(op, "snapshot parameter `$(row[1])` is not declared")
            params[String(row[1])] = Float64(row[2])
        end
        merge!(fake.params, params)
        sim_end = get(snap, "simEnd", nothing)
        if sim_end === nothing
            fake.sim_end = nothing
        elseif sim_end isa AbstractVector && length(sim_end) == 2 && all(v -> v isa Real, sim_end)
            fake.sim_end = Float64[sim_end[1], sim_end[2]]
        else
            return error_envelope(op, "bad snapshot simEnd")
        end
        state = Dict{String,Float64}()
        for row in get(snap, "state", [])
            (row isa AbstractVector && length(row) == 2 && row[1] isa Integer && row[2] isa Real) ||
                return error_envelope(op, "bad snapshot state")
            (0 <= row[1] < length(STATES)) ||
                return error_envelope(op, "snapshot state index out of range")
            state[STATES[row[1] + 1]] = Float64(row[2])
        end
        fake.state = state
        fake.cold = Int(get(snap, "coldSolves", 0))
        fake.warm = Int(get(snap, "warmSolves", 0))
        fake.sim_calls = Int(get(snap, "simCalls", 0))
        fake.last_steps = Int(get(snap, "lastSteps", 0))
        return envelope(op = op, ok = true, docHash = DOC_HASH)
    elseif op == "info"
        return envelope(
            op = op,
            docHash = DOC_HASH,
            unknowns = length(VARIABLES),
            coldSolves = fake.cold,
            warmSolves = fake.warm,
            lastIters = 5,
            closed = false,
            dynamic = true,
            pendingStates = length(fake.state),
            simCalls = fake.sim_calls,
            lastSteps = fake.last_steps,
        )
    elseif op == "close" || op == "quit"
        return envelope(
            op = "close",
            ok = true,
            coldSolves = fake.cold,
            warmSolves = fake.warm,
            simCalls = fake.sim_calls,
        )
    end
    return error_envelope(
        op,
        "unknown op `$(op)` (expected set_param / set_state / set_params / " *
        "set_states / clear_state / solve / simulate / predict / snapshot / " *
        "restore / info / close)",
    )
end

function main(args)
    if "--version" in args
        println("ESML v9.9.9-fake · fake engine for client tests")
        return 0
    end
    if length(args) < 2 || args[1] != "session"
        println(stderr, "fake esml: expected `session <file>`")
        return 2
    end
    fake = Fake()
    version = MODE == "bad-version" ? "esml.session/v0" : API
    println(
        JSON3.write(
            Dict{String,Any}(
                "apiVersion" => version,
                "op" => "open",
                "system" => "Fake",
                "unknowns" => length(VARIABLES),
                "docHash" => DOC_HASH,
                "dynamic" => true,
            ),
        ),
    )
    flush(stdout)
    MODE == "crash" && return 3
    if MODE == "silent"
        while true
            sleep(30)
        end
    end
    for line in eachline(stdin)
        line = strip(line)
        isempty(line) && continue
        if MODE == "garbage"
            println("this is not a json envelope")
            flush(stdout)
            continue
        end
        req = try
            plain(JSON3.read(line))
        catch
            nothing
        end
        if !(req isa Dict{String,Any})
            println(JSON3.write(error_envelope(nothing, "bad JSON")))
            flush(stdout)
            continue
        end
        out = handle(fake, req)
        println(JSON3.write(out))
        flush(stdout)
        get(out, "op", nothing) == "close" && return 0
    end
    return 0
end

exit(main(ARGS))
