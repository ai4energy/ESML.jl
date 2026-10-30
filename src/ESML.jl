"""ESML.jl — MIT Julia client for the ESML engine.

The engine (`esml`) is a native binary distributed separately under its own
license; this package only launches it and speaks the `esml.session/v1` JSON
protocol over stdin/stdout. No engine code is linked or embedded.
"""

module ESML

using JSON3

export Session,
    SolveResult,
    Trajectory,
    Info,
    SolveOutput,
    SimulateOutput,
    EsmlError,
    find_binary,
    engine_version,
    solve,
    simulate,
    predict,
    set_param!,
    set_params!,
    set_state!,
    set_states!,
    clear_state!,
    snapshot,
    restore!,
    info,
    close!,
    stderr_tail

include("errors.jl")
include("binary.jl")
include("session.jl")
include("oneshot.jl")

end
