"""Locate the ESML **engine binary** and read its version.

Only the engine binary is required: this package does not need (or ship) the
worker, the MCP server, or any platform component. The whole client/server
contract is the `esml session` JSON protocol (`esml.session/v1`).
"""

const _VERSION_RE = r"\bv(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b"

"""
    find_binary(explicit=nothing) -> String

Return the path to the `esml` executable.

Resolution order: `explicit` argument → `ENV["ESML_BIN"]` → `PATH`. A path
that was given explicitly (or via `ESML_BIN`) but is not an executable file is
a loud error — the client never silently falls back to another binary.
"""
function find_binary(explicit = nothing)
    for (source, candidate) in
        (("argument", explicit), ("ESML_BIN", get(ENV, "ESML_BIN", nothing)))
        candidate === nothing && continue
        path = expanduser(String(candidate))
        if isfile(path) && Sys.isexecutable(path)
            return path
        end
        throw(
            EsmlError(
                "the ESML engine binary from $(source) is not an executable file: $(repr(path))";
                kind = :binary_not_found,
            ),
        )
    end
    found = Sys.which("esml")
    found === nothing || return String(found)
    throw(
        EsmlError(
            "the ESML engine binary (`esml`) was not found: put it on PATH or set " *
            "ESML_BIN=<path>. Only the engine binary is required — no worker, MCP " *
            "server, or platform component is needed.";
            kind = :binary_not_found,
        ),
    )
end

"""
    engine_version(binary) -> Union{Nothing,String}

Return the engine version string (e.g. `"1.8.0"`), or `nothing`.

The version is informational; protocol compatibility is checked by the
`apiVersion` of the first envelope, not by this string.
"""
function engine_version(binary::AbstractString)
    out = try
        read(ignorestatus(Cmd([String(binary), "--version"])))
    catch
        return nothing
    end
    m = match(_VERSION_RE, String(out))
    return m === nothing ? nothing : String(m.captures[1])
end
