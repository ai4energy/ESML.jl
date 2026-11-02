"""Minimal DTIL demo: simulate a decay, change a parameter, snapshot.

Run with the engine on PATH (or ``ESML_BIN=/path/to/esml``)::

    julia --project=. examples/demo.jl
"""

using ESMLKit

doc = joinpath(@__DIR__, "decay.esml")

session = Session(doc; system = "S")
try
    println(
        "engine $(session.engine_version) · dynamic=$(session.dynamic) · " *
        "unknowns=$(session.unknowns)",
    )
    first = simulate(session, (0.0, 1.0), 20; observe = ["m.x"])
    println("x(1) at lam=0.5: ", first.series["m.x"][end])

    set_param!(session, "m.lam", 0.2)
    clear_state!(session)
    second = simulate(session, (0.0, 1.0), 20; observe = ["m.x"])
    println("x(1) at lam=0.2: ", second.series["m.x"][end])

    println("snapshot params: ", snapshot(session)["params"])
finally
    close!(session)
end
