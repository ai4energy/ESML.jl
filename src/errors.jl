"""Errors raised by the ESML Julia client.

A single exception type with a `kind` field keeps `catch err; err isa
ESMLKit.EsmlError` sufficient at every call site while still distinguishing the
failure classes:

* `:engine`            — the engine reported an error envelope
* `:protocol`          — the engine emitted something that is not an
                         `esml.session/v1` envelope (the process is killed)
* `:timeout`           — no answer within the session timeout (killed)
* `:closed`            — the engine exited / the session was closed
* `:binary_not_found`  — the `esml` executable could not be located
"""

const ERROR_KINDS = (:engine, :protocol, :timeout, :closed, :binary_not_found)

struct EsmlError <: Exception
    message::String
    kind::Symbol
    op::Union{Nothing,String}
    request::Union{Nothing,String}
    raw::Any
    #: Stable code from `esml.error/v1` (nothing for client-side errors).
    code::Union{Nothing,String}
    #: Actionable engine suggestion, when available.
    hint::Union{Nothing,String}
    #: SHA-256 of the source document, when available.
    doc_hash::Union{Nothing,String}
end

function EsmlError(
    message::AbstractString;
    kind::Symbol = :engine,
    op = nothing,
    request = nothing,
    raw = nothing,
    code = nothing,
    hint = nothing,
    doc_hash = nothing,
)
    kind in ERROR_KINDS ||
        throw(ArgumentError("unknown EsmlError kind $(repr(kind))"))
    return EsmlError(
        String(message),
        kind,
        op === nothing ? nothing : String(op),
        request === nothing ? nothing : String(request),
        raw,
        code === nothing ? nothing : String(code),
        hint === nothing ? nothing : String(hint),
        doc_hash === nothing ? nothing : String(doc_hash),
    )
end

function Base.showerror(io::IO, err::EsmlError)
    print(io, "EsmlError[", err.kind, "]: ", err.message)
    err.op === nothing || print(io, " (op=", err.op, ")")
end
