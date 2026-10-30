using Test
using ESML

const FAKE = joinpath(@__DIR__, "fake_esml.jl")
const ROOT = dirname(@__DIR__)
const SHIM_DIR = mktempdir()

function make_shim()
    shim = joinpath(SHIM_DIR, "esml")
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    open(shim, "w") do io
        println(io, "#!/bin/sh")
        println(io, "exec '$(julia)' --startup-file=no --project='$(ROOT)' '$(FAKE)' \"\$@\"")
    end
    chmod(shim, 0o755)
    return shim
end

const SHIM = make_shim()

"Return the exception thrown by `f`, or `nothing`."
function caught(f)
    try
        f()
        return nothing
    catch err
        return err
    end
end

function with_session(f; mode = "ok", timeout = 5.0)
    return withenv("FAKE_ESML_MODE" => mode) do
        session = Session("plant.esml"; binary = SHIM, timeout = timeout)
        try
            f(session)
        finally
            close!(session)
        end
    end
end

@testset "ESML.jl" begin
    @testset "open envelope" begin
        with_session() do s
            @test s.doc_hash == 42
            @test s.system == "Fake"
            @test s.unknowns == 2
            @test s.dynamic === true
            @test s.engine_version == "9.9.9-fake"
        end
    end

    @testset "solve + hot parameter" begin
        with_session() do s
            first = solve(s)
            @test Set(keys(first.values)) == Set(["m.x", "m.y"])
            @test first.values["m.x"] ≈ 1.0 / 1.5
            @test first.warm === false
            @test first.iterations == 5

            set_param!(s, "m.lam", 2.0)
            second = solve(s)
            @test second.values["m.x"] ≈ 1.0 / 3.0
            @test second.values["m.y"] ≈ 2.0 / 3.0
            @test second.warm === true
            @test second.iterations == 3
        end
    end

    @testset "set_params! mapping and pairs" begin
        with_session() do s
            set_params!(s, Dict("m.lam" => 1.0))
            @test solve(s).values["m.x"] ≈ 0.5
            set_params!(s, [("m.lam", 3.0)])
            @test solve(s).values["m.x"] ≈ 0.25

            @test_throws ArgumentError set_params!(s, Dict{String,Float64}())
            err = caught(() -> set_params!(s, [("m.missing", 1.0)]))
            @test err isa EsmlError && err.kind == :engine
            @test solve(s).values["m.x"] ≈ 0.25
        end
    end

    @testset "simulate: window, observe, chaining" begin
        with_session() do s
            first = simulate(s, (0.0, 2.0), 4; observe = ["m.y"])
            @test first.steps == 4
            @test length(first.t) == 5
            @test collect(keys(first.series)) == ["m.y"]
            @test first.series["m.y"][1] ≈ 0.5
            @test first.continued === false

            chained = simulate(s, (2.0, 3.0), 2; observe = ["m.x"])
            @test chained.continued === true
            @test chained.series["m.x"][1] ≈ first.series["m.y"][end] / 0.5

            clear_state!(s)
            fresh = simulate(s, (2.0, 3.0), 2; observe = ["m.x"])
            @test fresh.continued === false
            @test fresh.series["m.x"][1] ≈ 1.0
        end
    end

    @testset "simulate defaults to all variables" begin
        with_session() do s
            traj = simulate(s, (0.0, 1.0), 2)
            @test Set(keys(traj.series)) == Set(["m.x", "m.y"])
        end
    end

    @testset "predict does not advance the session" begin
        with_session() do s
            p = predict(s, 1.0, 2; observe = ["m.x"])
            @test p.t ≈ [0.0, 0.5, 1.0]
            @test p.continued === false
            traj = simulate(s, (0.0, 1.0), 2; observe = ["m.x"])
            @test traj.continued === false
        end
    end

    @testset "state injection and info" begin
        with_session() do s
            set_state!(s, "m.x", 2.0)
            status = info(s)
            @test status.pending_states == 1
            @test status.dynamic === true
            @test status.doc_hash == 42
            @test solve(s).values["m.x"] ≈ 2.0 / 1.5

            clear_state!(s)
            @test info(s).pending_states == 0

            err = caught(() -> set_state!(s, "m.y", 1.0))
            @test err isa EsmlError && err.kind == :engine
        end
    end

    @testset "set_states! batch" begin
        with_session() do s
            set_states!(s, Dict("m.x" => 3.0))
            @test info(s).pending_states == 1
            @test solve(s).values["m.x"] ≈ 3.0 / 1.5
            @test_throws ArgumentError set_states!(s, [])
        end
    end

    @testset "snapshot / restore" begin
        with_session() do s
            set_param!(s, "m.lam", 1.5)
            simulate(s, (0.0, 1.0), 2; observe = ["m.x"])
            snap = snapshot(s)
            @test snap["docHash"] == 42
            @test length(snap["params"]) == 1
            @test snap["params"][1][1] == "m.lam"
            @test snap["params"][1][2] ≈ 1.5

            set_param!(s, "m.lam", 0.25)
            clear_state!(s)
            restore!(s, snap)
            @test snapshot(s)["params"][1][2] ≈ 1.5
            chained = simulate(s, (1.0, 2.0), 2; observe = ["m.x"])
            @test chained.continued === true

            @test_throws ArgumentError restore!(s, "not a snapshot")
            bad = Dict{String,Any}(snap)
            bad["docHash"] = 7
            err = caught(() -> restore!(s, bad))
            @test err isa EsmlError && err.kind == :engine
        end
    end

    @testset "engine error carries kind, op, raw envelope" begin
        with_session() do s
            err = caught(() -> set_param!(s, "m.missing", 1.0))
            @test err isa EsmlError
            @test err.kind == :engine
            @test err.op == "set_param"
            @test occursin("not a declared parameter", err.message)
            @test err.raw["op"] == "error"
            @test err.raw["request"] == "set_param"
            @test solve(s).values["m.x"] ≈ 1.0 / 1.5
        end
    end

    @testset "observe rejected by engine" begin
        with_session() do s
            @test_throws EsmlError simulate(s, (0.0, 1.0), 1; observe = ["m.lam"])
            @test_throws EsmlError simulate(s, (0.0, 1.0), 1; observe = ["m.x", "m.x"])
        end
    end

    @testset "client rejects malformed input before sending" begin
        with_session() do s
            @test_throws ArgumentError set_param!(s, "m.lam", NaN)
            @test_throws ArgumentError set_param!(s, "m.lam", Inf)
            @test_throws ArgumentError set_params!(s, Dict("m.lam" => NaN))
            @test_throws ArgumentError simulate(s, (0.0, NaN))
            @test_throws ArgumentError simulate(s, (0.0, 1.0), 1; observe = String[])
            @test_throws ArgumentError simulate(s, (0.0, 1.0), 0)
            @test_throws ArgumentError predict(s, 0.0)
            @test_throws ArgumentError predict(s, -1.0)
            @test_throws ArgumentError set_state!(s, "m.x", NaN)
            @test info(s).doc_hash == 42
        end
    end

    @testset "close is idempotent; ops after close raise" begin
        with_session() do s
            close!(s)
            close!(s)
            @test s.closed
            err = caught(() -> solve(s))
            @test err isa EsmlError && err.kind == :closed
        end
    end

    @testset "bad apiVersion" begin
        err = withenv("FAKE_ESML_MODE" => "bad-version") do
            caught(() -> Session("plant.esml"; binary = SHIM, timeout = 5.0))
        end
        @test err isa EsmlError
        @test err.kind == :protocol
        @test occursin("apiVersion", err.message)
    end

    @testset "engine crash" begin
        err = withenv("FAKE_ESML_MODE" => "crash") do
            session = Session("plant.esml"; binary = SHIM, timeout = 5.0)
            try
                caught(() -> info(session))
            finally
                close!(session)
            end
        end
        @test err isa EsmlError
        @test err.kind == :closed
    end

    @testset "timeout kills the engine" begin
        started = time()
        err = withenv("FAKE_ESML_MODE" => "silent") do
            # 2 s must cover the Julia fake's startup (the open envelope), while
            # `info` still hits the timeout because the fake never answers.
            session = Session("plant.esml"; binary = SHIM, timeout = 2.0)
            try
                caught(() -> info(session))
            finally
                close!(session)
            end
        end
        @test err isa EsmlError
        @test err.kind == :timeout
        @test time() - started < 10.0
    end

    @testset "non-JSON output" begin
        session = withenv("FAKE_ESML_MODE" => "garbage") do
            Session("plant.esml"; binary = SHIM, timeout = 5.0)
        end
        err = caught(() -> solve(session))
        @test err isa EsmlError
        @test err.kind == :protocol
        @test session.closed
        close!(session)
    end

    @testset "binary resolution" begin
        missing = joinpath(mktempdir(), "esml")
        err = caught(() -> find_binary(missing))
        @test err isa EsmlError && err.kind == :binary_not_found

        err = withenv("ESML_BIN" => missing) do
            caught(() -> find_binary())
        end
        @test err isa EsmlError && err.kind == :binary_not_found

        plain_file = joinpath(mktempdir(), "esml")
        write(plain_file, "not executable")
        err = caught(() -> find_binary(plain_file))
        @test err isa EsmlError && err.kind == :binary_not_found

        @test find_binary(SHIM) == SHIM
    end

    # ── real engine (opt-in) ─────────────────────────────────────────────
    let bin = get(ENV, "ESML_BIN", nothing)
        if bin === nothing
            @info "ESML.jl: integration tests skipped — set ESML_BIN to a real `esml` binary"
        else
            doc = joinpath(@__DIR__, "decay.esml")
            @testset "real engine" begin
                session = Session(doc; system = "S", binary = bin, timeout = 120.0)
                try
                    @test session.dynamic === true
                    @test session.doc_hash !== nothing
                    @test session.unknowns >= 1

                    err = caught(
                        () -> ESML.solve(
                            "/tmp/esml-missing-for-client.esml";
                            binary = bin,
                        ),
                    )
                    @test err isa EsmlError
                    @test err.code == "io.read"
                    @test err.hint !== nothing
                    @test err.doc_hash === nothing

                    traj = simulate(session, (0.0, 1.0), 20; observe = ["m.x"])
                    @test traj.points == 21
                    @test collect(keys(traj.series)) == ["m.x"]
                    @test traj.series["m.x"][1] ≈ 1.0
                    @test traj.series["m.x"][end] ≈ exp(-0.5) rtol = 2e-3
                    @test traj.continued === false

                    clear_state!(session)
                    set_param!(session, "m.lam", 0.2)
                    hot = simulate(session, (0.0, 1.0), 20; observe = ["m.x"])
                    @test hot.series["m.x"][end] ≈ exp(-0.2) rtol = 2e-3

                    @test_throws EsmlError simulate(
                        session,
                        (0.0, 1.0),
                        2;
                        observe = ["m.lam"],
                    )
                    @test_throws EsmlError simulate(
                        session,
                        (0.0, 1.0),
                        2;
                        observe = ["m.x", "m.x"],
                    )
                    @test info(session).sim_calls == 2

                    clear_state!(session)
                    first = simulate(session, (0.0, 1.0), 10; observe = ["m.x"])
                    @test first.meta["engineVersion"] isa AbstractString
                    @test isempty(first.units)
                    p = predict(session, 0.5, 5; observe = ["m.x"])
                    @test p.continued === true
                    @test p.t[1] == 0.0
                    @test p.series["m.x"][1] ≈ first.series["m.x"][end] rtol = 1e-6
                    chained = simulate(session, (1.0, 2.0), 10; observe = ["m.x"])
                    @test chained.continued === true
                    @test chained.series["m.x"][1] ≈ first.series["m.x"][end] rtol = 1e-6

                    sres = solve(session)
                    @test sres.meta["converged"] == true
                    @test sres.meta["engineVersion"] isa AbstractString
                    @test sres.meta["docHash"] isa AbstractString
                    @test isempty(sres.units)
                    @test sres.iterations !== nothing
                    @test sres.meta["residual"] <= sres.meta["residualTolerance"]

                    one = ESML.solve(doc; system = "S", binary = bin)
                    @test one.values["m.x"] ≈ 0.0 atol = 1e-8
                    @test one.meta["converged"] == true
                    @test one.meta["docHash"] isa AbstractString
                    @test length(one.meta["docHash"]) == 64
                    @test one.meta["unitCoverage"]["total"] == 1
                    @test one.meta["iterations"] >= 1
                    @test one.meta["residual"] <= one.meta["residualTolerance"]
                    @test isempty(one.units)
                    oneshot = ESML.simulate(
                        doc,
                        (0.0, 1.0),
                        10;
                        observe = ["m.x"],
                        system = "S",
                        binary = bin,
                    )
                    @test oneshot.series["m.x"][1] ≈ 1.0
                    @test oneshot.steps == 10
                    @test oneshot.meta["engineVersion"] == one.meta["engineVersion"]
                    @test isempty(oneshot.units)
                finally
                    close!(session)
                end

                @testset "snapshot into a fresh session" begin
                    a = Session(doc; system = "S", binary = bin, timeout = 120.0)
                    b = Session(doc; system = "S", binary = bin, timeout = 120.0)
                    try
                        clear_state!(a)
                        set_param!(a, "m.lam", 0.3)
                        first = simulate(a, (0.0, 1.0), 10; observe = ["m.x"])
                        snap = snapshot(a)
                        @test snap["docHash"] == a.doc_hash
                        restore!(b, snap)
                        @test snapshot(b)["params"] == snap["params"]
                        chained = simulate(b, (1.0, 2.0), 10; observe = ["m.x"])
                        @test chained.continued === true
                        @test chained.series["m.x"][1] ≈ first.series["m.x"][end] rtol = 1e-6
                    finally
                        close!(a)
                        close!(b)
                    end
                end
            end
        end
    end
end
