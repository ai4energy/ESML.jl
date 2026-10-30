"""Resident ESML session (DTIL) over the `esml session` JSON protocol.

The client launches *only* the engine binary as a child process and speaks one
JSON envelope per line (`esml.session/v1`). Nothing is linked into Julia, so
this package stays pure MIT while the engine binary keeps its own license.
"""

const API = "esml.session/v1"

# ── results ────────────────────────────────────────────────────────────────

"""Result of [`solve`](@ref) (a steady-state fixed point)."""
struct SolveResult
    values::Dict{String,Float64}
    iterations::Union{Nothing,Int}
    warm::Union{Nothing,Bool}
    unknowns::Union{Nothing,Int}
    duration_ms::Union{Nothing,Int}
    doc_hash::Any
    raw::Dict{String,Any}
end

"""Result of [`simulate`](@ref) / [`predict`](@ref)."""
struct Trajectory
    t::Vector{Float64}
    series::Dict{String,Vector{Float64}}
    steps::Int
    points::Union{Nothing,Int}
    continued::Bool
    duration_ms::Union{Nothing,Int}
    doc_hash::Any
    raw::Dict{String,Any}
end

"""Result of [`info`](@ref) (a session status snapshot)."""
struct Info
    doc_hash::Any
    unknowns::Union{Nothing,Int}
    cold_solves::Union{Nothing,Int}
    warm_solves::Union{Nothing,Int}
    last_iters::Union{Nothing,Int}
    closed::Union{Nothing,Bool}
    dynamic::Union{Nothing,Bool}
    pending_states::Union{Nothing,Int}
    sim_calls::Union{Nothing,Int}
    last_steps::Union{Nothing,Int}
    raw::Dict{String,Any}
end

# ── session ────────────────────────────────────────────────────────────────

"""
    Session(path; system=nothing, libraries=String[], binary=nothing,
            timeout=nothing, extra_args=String[])

Open a resident engine session.

* `path` — the ESML document.
* `system` — system name; omitted ⇒ the engine picks the document's system.
* `libraries` — extra library roots passed as `-L`.
* `binary` — explicit `esml` path (otherwise `ENV["ESML_BIN"]` or `PATH`).
* `timeout` — per-op timeout in seconds (`nothing` = wait forever). On timeout
  the engine process is killed and an `EsmlError` with `kind == :timeout` is
  thrown.
* `extra_args` — additional flags appended to the `esml session` command line.
"""
mutable struct Session
    binary::String
    engine_version::Union{Nothing,String}
    doc_hash::Any
    system::Any
    unknowns::Union{Nothing,Int}
    dynamic::Union{Nothing,Bool}
    proc::Base.Process
    err_path::String
    timeout::Union{Nothing,Float64}
    lines::Channel{Any}
    closed::Bool
    lock::ReentrantLock
end

function Session(
    path::AbstractString;
    system = nothing,
    libraries = String[],
    binary = nothing,
    timeout = nothing,
    extra_args = String[],
)
    bin = find_binary(binary)
    version = engine_version(bin)
    args = String[bin, "session", String(path)]
    system === nothing || append!(args, ["--system", String(system)])
    for lib in libraries
        append!(args, ["-L", String(lib)])
    end
    append!(args, String.(extra_args))

    err_path, err_io = mktemp()
    close(err_io)
    proc = try
        open(pipeline(Cmd(args), stderr = err_path), "r+")
    catch err
        rm(err_path; force = true)
        throw(
            EsmlError(
                "failed to launch the ESML engine ($(join(args, ' '))): $(sprint(showerror, err))";
                kind = :binary_not_found,
            ),
        )
    end

    lines = Channel{Any}(Inf)
    @async begin
        try
            for line in eachline(proc)
                put!(lines, line)
            end
        catch
            # The process was killed or exited; EOF is signalled below.
        finally
            put!(lines, nothing)
        end
    end

    session = Session(
        bin,
        version,
        nothing,
        nothing,
        nothing,
        nothing,
        proc,
        err_path,
        timeout === nothing ? nothing : Float64(timeout),
        lines,
        false,
        ReentrantLock(),
    )

    env = try
        read_envelope(session)
    catch
        try
            close!(session)
        catch
        end
        rethrow()
    end
    if _field(env, "op") == "error"
        raw_message = _field(env, "error")
        message =
            raw_message isa AbstractString ? String(raw_message) :
            "the engine reported an error without a message"
        kill!(session)
        throw(
            EsmlError(
                message;
                kind = :engine,
                op = "open",
                request = _field(env, "request"),
                raw = env,
            ),
        )
    end
    if _field(env, "op") != "open"
        kill!(session)
        throw(
            EsmlError(
                "expected an `open` envelope, got $(repr(_field(env, "op")))";
                kind = :protocol,
                raw = env,
            ),
        )
    end
    session.doc_hash = _field(env, "docHash")
    session.system = _field(env, "system")
    session.unknowns = _to_int(_field(env, "unknowns"))
    session.dynamic = _to_bool(_field(env, "dynamic"))
    finalizer(x -> (kill!(x); rm(x.err_path; force = true)), session)
    return session
end

# ── ops ────────────────────────────────────────────────────────────────────

"""Solve the current parameters' steady-state fixed point."""
function solve(session::Session)
    env = request(session, "solve")
    values = Dict{String,Float64}()
    for row in _array(env, "values")
        row isa AbstractDict ||
            throw(protocol_error("protocol: `values` entry is not an object"))
        values[String(row["path"])] = _as_float(row["value"], "values[].value")
    end
    return SolveResult(
        values,
        _to_int(_field(env, "iterations")),
        _to_bool(_field(env, "warm")),
        _to_int(_field(env, "unknowns")),
        _to_int(_field(env, "durationMs")),
        _field(env, "docHash"),
        env,
    )
end

"""
    simulate(session, tspan=(0.0, 1.0), steps=100; observe=nothing)

Integrate one window from the current state (chained). `observe` names
variables (not parameters); omit it to get all flat variables.
"""
function simulate(
    session::Session,
    tspan = (0.0, 1.0),
    steps::Integer = 100;
    observe = nothing,
)
    t0, t1 = _tspan(tspan)
    fields = (tspan = [t0, t1], steps = _steps(steps))
    observe === nothing || (fields = merge(fields, (observe = _observe(observe),)))
    return _trajectory(request(session, "simulate"; fields...))
end

"""
    predict(session, horizon, steps=100; observe=nothing)

Non-advancing rollout `0..horizon` from the current state (MPC).
"""
function predict(
    session::Session,
    horizon,
    steps::Integer = 100;
    observe = nothing,
)
    h = _number(horizon, "predict horizon")
    h > 0 || throw(ArgumentError("predict horizon must be > 0 (got $(repr(horizon)))"))
    fields = (horizon = h, steps = _steps(steps))
    observe === nothing || (fields = merge(fields, (observe = _observe(observe),)))
    return _trajectory(request(session, "predict"; fields...))
end

"""Change one declared parameter (hot: no cache rebuild)."""
function set_param!(session::Session, path::AbstractString, value)
    request(
        session,
        "set_param";
        path = String(path),
        value = _number(value, "set_param value"),
    )
    return nothing
end

"""Change several parameters in one batched fold."""
function set_params!(session::Session, values)
    request(session, "set_params"; values = _pairs(values, "set_params"))
    return nothing
end

"""Inject a measured state (affects the next solve/simulate start)."""
function set_state!(session::Session, path::AbstractString, value)
    request(
        session,
        "set_state";
        path = String(path),
        value = _number(value, "set_state value"),
    )
    return nothing
end

"""Inject several measured states in one batch."""
function set_states!(session::Session, values)
    request(session, "set_states"; values = _pairs(values, "set_states"))
    return nothing
end

"""Drop state injections and the chained trajectory end."""
function clear_state!(session::Session)
    request(session, "clear_state")
    return nothing
end

"""Export the session snapshot (params + chained row + injections)."""
function snapshot(session::Session)
    env = request(session, "snapshot")
    snap = _field(env, "snapshot")
    snap isa AbstractDict ||
        throw(protocol_error("protocol: the `snapshot` op returned no snapshot object"; env = env))
    # JSON3 turns a u64 `docHash` above typemax(Int64) into Float64; use the
    # exact value parsed from the raw open/snapshot envelope instead.
    exact = _field(env, "docHash")
    exact === nothing || (snap["docHash"] = exact)
    return snap
end

"""Restore a snapshot produced by [`snapshot`](@ref) (same document only)."""
function restore!(session::Session, snap)
    snap isa AbstractDict || throw(ArgumentError("restore! expects a snapshot Dict"))
    request(session, "restore"; snapshot = snap)
    return nothing
end

"""Return a session status snapshot."""
function info(session::Session)
    env = request(session, "info")
    return Info(
        _field(env, "docHash"),
        _to_int(_field(env, "unknowns")),
        _to_int(_field(env, "coldSolves")),
        _to_int(_field(env, "warmSolves")),
        _to_int(_field(env, "lastIters")),
        _to_bool(_field(env, "closed")),
        _to_bool(_field(env, "dynamic")),
        _to_int(_field(env, "pendingStates")),
        _to_int(_field(env, "simCalls")),
        _to_int(_field(env, "lastSteps")),
        env,
    )
end

"Close the session and stop the engine process (idempotent)."
function close!(session::Session)
    session.closed && return nothing
    graceful = lock(session.lock) do
        session.closed && return false
        ok = false
        try
            println(session.proc, JSON3.write(Dict{String,Any}("op" => "close")))
            flush(session.proc)
            env = read_envelope(session)
            ok = _field(env, "op") == "close"
        catch
            # A failed close handshake means the process is not following the
            # protocol; the caller only needs the process gone.
            ok = false
        end
        session.closed = true
        ok
    end
    if !graceful
        # The handshake failed, so the process is not following the protocol;
        # do not wait for it.
        kill!(session)
        return nothing
    end
    if !Base.process_exited(session.proc) &&
       timedwait(() -> Base.process_exited(session.proc), 5.0) != :ok
        kill!(session)
    end
    rm(session.err_path; force = true)
    return nothing
end

"Last `lines` lines the engine wrote to stderr (diagnostics)."
function stderr_tail(session::Session; lines::Int = 20)
    isfile(session.err_path) || return ""
    text = try
        read(session.err_path, String)
    catch
        return ""
    end
    parts = split(text, '\n')
    while !isempty(parts) && isempty(parts[end])
        pop!(parts)
    end
    isempty(parts) && return ""
    first = max(1, length(parts) - lines + 1)
    return join(parts[first:end], "\n")
end

# ── internals ──────────────────────────────────────────────────────────────

_field(env::Dict{String,Any}, key::AbstractString, default = nothing) =
    get(env, String(key), default)

_to_int(value) = value isa Integer ? Int(value) : nothing
_to_bool(value) = value isa Bool ? value : nothing

function _as_float(value, what::AbstractString)
    value isa Real || throw(protocol_error("protocol: $(what) is not a number (got $(repr(value)))"))
    return Float64(value)
end

function _array(env::Dict{String,Any}, key::AbstractString)
    value = _field(env, key)
    value isa AbstractVector ||
        throw(protocol_error("protocol: `$(key)` is missing or not an array"; env = env))
    return value
end

function _number(value, what::AbstractString)
    value isa Real || throw(ArgumentError("$(what) must be a number (got $(repr(value)))"))
    out = Float64(value)
    isfinite(out) || throw(ArgumentError("$(what) must be finite (got $(repr(value)))"))
    return out
end

function _steps(value)
    value isa Bool && throw(ArgumentError("steps must be an integer >= 1 (got $(repr(value)))"))
    value isa Integer || throw(ArgumentError("steps must be an integer >= 1 (got $(repr(value)))"))
    value >= 1 || throw(ArgumentError("steps must be an integer >= 1 (got $(repr(value)))"))
    return Int(value)
end

function _tspan(tspan)
    length(tspan) == 2 ||
        throw(ArgumentError("tspan must be (t0, t1), got $(repr(tspan))"))
    t0 = _number(tspan[1], "tspan[1]")
    t1 = _number(tspan[2], "tspan[2]")
    return (t0, t1)
end

function _observe(observe)
    paths = String[String(p) for p in observe]
    isempty(paths) &&
        throw(ArgumentError("observe must name at least one path (omit it to get all variables)"))
    return paths
end

function _pairs(values, what::AbstractString)
    items = values isa AbstractDict || values isa NamedTuple ? pairs(values) : values
    rows = Dict{String,Any}[]
    for item in items
        path, value = item
        push!(
            rows,
            Dict{String,Any}(
                "path" => String(path),
                "value" => _number(value, "$(what) value for $(repr(path))"),
            ),
        )
    end
    isempty(rows) && throw(ArgumentError("$(what) needs at least one (path, value) pair"))
    return rows
end

"""Recursively convert JSON3 values into plain Julia containers."""
plain(value::JSON3.Object) =
    Dict{String,Any}(String(key) => plain(item) for (key, item) in pairs(value))
plain(value::JSON3.Array) = Any[plain(item) for item in value]
plain(value) = value

function request(session::Session, op::AbstractString; fields...)
    lock(session.lock) do
        session.closed &&
            throw(EsmlError("session is closed (op `$(op)` not sent)"; kind = :closed, op = op))
        payload = Dict{String,Any}("op" => String(op))
        for (key, value) in pairs(fields)
            payload[String(key)] = value
        end
        try
            println(session.proc, JSON3.write(payload))
            flush(session.proc)
        catch err
            tail = stderr_tail(session)
            kill!(session)
            throw(
                EsmlError(
                    "the ESML engine is not accepting input ($(sprint(showerror, err))); " *
                    "stderr tail:\n$(tail)";
                    kind = :closed,
                    op = op,
                ),
            )
        end
        env = read_envelope(session)
        if _field(env, "op") == "error"
            throw(
                EsmlError(
                    String(_field(env, "error"));
                    kind = :engine,
                    op = op,
                    request = _field(env, "request"),
                    raw = env,
                ),
            )
        end
        return env
    end
end

function read_envelope(session::Session)
    line = next_line(session)
    parsed = try
        JSON3.read(line)
    catch err
        tail = stderr_tail(session)
        kill!(session)
        throw(
            EsmlError(
                "the ESML engine emitted non-JSON output: $(repr(line)) " *
                "($(sprint(showerror, err)))" * _tail_suffix(tail);
                kind = :protocol,
            ),
        )
    end
    env = plain(parsed)
    if !(env isa Dict{String,Any})
        tail = stderr_tail(session)
        kill!(session)
        throw(
            EsmlError(
                "expected a JSON object envelope, got $(repr(env))" * _tail_suffix(tail);
                kind = :protocol,
            ),
        )
    end
    api = _field(env, "apiVersion")
    if api != API
        tail = stderr_tail(session)
        kill!(session)
        throw(
            EsmlError(
                "unexpected apiVersion $(repr(api)) (expected $(API)); " *
                "the engine binary is too old or not an ESML engine" * _tail_suffix(tail);
                kind = :protocol,
                raw = env,
            ),
        )
    end
    _restore_exact_doc_hash!(env, line)
    return env
end

# `docHash` is an unsigned 64-bit integer. JSON3 parses integers above `typemax(Int64)` as
# Float64 (53-bit mantissa), which would corrupt the hash on `restore!`:
# serde then rejects the float, or worse, a rounded value could alias another
# document. Re-read the decimal digits from the raw envelope and keep a BigInt.
function _restore_exact_doc_hash!(env::Dict{String,Any}, line::AbstractString)
    m = match(r"\"docHash\"\s*:\s*(\d+)", line)
    m === nothing && return env
    env["docHash"] = parse(BigInt, m.captures[1])
    return env
end

_tail_suffix(tail::AbstractString) = isempty(tail) ? "" : "\nstderr tail:\n" * tail

protocol_error(message::AbstractString; env = nothing) =
    EsmlError(message; kind = :protocol, raw = env)

function next_line(session::Session)
    blanks = 0
    while true
        item = nothing
        if session.timeout === nothing
            item = take!(session.lines)
        else
            status = timedwait(() -> isready(session.lines), session.timeout)
            if status == :timed_out
                tail = stderr_tail(session)
                kill!(session)
                throw(
                    EsmlError(
                        "no response from the ESML engine within $(session.timeout)s; " *
                        "stderr tail:\n$(tail)";
                        kind = :timeout,
                    ),
                )
            end
            item = take!(session.lines)
        end
        if item === nothing
            code = Base.process_exited(session.proc) ? session.proc.exitcode : "unknown"
            tail = stderr_tail(session)
            session.closed = true
            try
                wait(session.proc)
            catch
            end
            rm(session.err_path; force = true)
            throw(
                EsmlError(
                    "the ESML engine exited (code $(code)); stderr tail:\n$(tail)";
                    kind = :closed,
                ),
            )
        end
        line = strip(String(item))
        if !isempty(line)
            return line
        end
        blanks += 1
        blanks > 100 &&
            throw(protocol_error("the ESML engine emitted more than 100 blank lines"))
    end
end

function kill!(session::Session)
    session.closed && return nothing
    session.closed = true
    try
        Base.process_running(session.proc) && kill(session.proc, Base.SIGKILL)
    catch
    end
    try
        wait(session.proc)
    catch
    end
    rm(session.err_path; force = true)
    return nothing
end

function _trajectory(env::Dict{String,Any})
    t = Float64[_as_float(x, "t[]") for x in _array(env, "t")]
    series = Dict{String,Vector{Float64}}()
    for row in _array(env, "series")
        row isa AbstractDict ||
            throw(protocol_error("protocol: `series` entry is not an object"; env = env))
        path = String(row["path"])
        series[path] = Float64[_as_float(x, "series[].values") for x in row["values"]]
    end
    steps = _to_int(_field(env, "steps"))
    steps === nothing &&
        throw(protocol_error("protocol: `steps` is missing or not an integer"; env = env))
    continued = _to_bool(_field(env, "continued"))
    continued === nothing &&
        throw(protocol_error("protocol: `continued` is missing or not a bool"; env = env))
    return Trajectory(
        t,
        series,
        steps,
        _to_int(_field(env, "points")),
        continued,
        _to_int(_field(env, "durationMs")),
        _field(env, "docHash"),
        env,
    )
end
