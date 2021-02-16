module ConnectionRequest

import ..Layer, ..request
using URIs, ..Sockets
using ..Messages
using ..IOExtras
using ..ConnectionPool
using MbedTLS: SSLContext
using ..Pairs: getkv, setkv
using Base64: base64encode
import ..@debug, ..DEBUG_LEVEL

# hasdotsuffix reports whether s ends in "."+suffix.
hasdotsuffix(s, suffix) = endswith(s, "." * suffix)

function isnoproxy(host)
    for x in NO_PROXY
        (hasdotsuffix(host, x) || (host == x)) && return true
    end
    return false
end

const NO_PROXY = String[]

function __init__()
    # check for no_proxy environment variable
    if haskey(ENV, "no_proxy")
        for x in split(ENV["no_proxy"], ","; keepempty=false)
            push!(NO_PROXY, startswith(x, ".") ? x[2:end] : x)
        end
    end
    return
end

function getproxy(scheme, host)
    isnoproxy(host) && return nothing
    if scheme == "http" && !isempty(get(ENV, "http_proxy", ""))
        return ENV["http_proxy"]
    elseif scheme == "http" && haskey(ENV, "HTTP_PROXY") && !isempty(ENV["HTTP_PROXY"])
        return ENV["HTTP_PROXY"]
    elseif scheme == "https" && haskey(ENV, "https_proxy") && !isempty(ENV["https_proxy"])
        return ENV["https_proxy"]
    elseif scheme == "https" && haskey(ENV, "HTTPS_PROXY") && !isempty(ENV["HTTPS_PROXY"])
        return ENV["HTTPS_PROXY"]
    end
    return nothing
end

"""
    request(ConnectionPoolLayer, ::URI, ::Request, body) -> HTTP.Response

Retrieve an `IO` connection from the [`ConnectionPool`](@ref).

Close the connection if the request throws an exception.
Otherwise leave it open so that it can be reused.

`IO` related exceptions from `Base` are wrapped in `HTTP.IOError`.
See [`isioerror`](@ref).
"""
abstract type ConnectionPoolLayer{Next <: Layer} <: Layer{Next} end
export ConnectionPoolLayer

function request(::Type{ConnectionPoolLayer{Next}}, url::URI, req, body;
                 proxy=getproxy(url.scheme, url.host),
                 socket_type::Type=TCPSocket,
                 reuse_limit::Int=ConnectionPool.nolimit, kw...) where Next

    if proxy !== nothing
        target_url = url
        url = URI(proxy)
        if target_url.scheme == "http"
            req.target = string(target_url)
        end

        userinfo = unescapeuri(url.userinfo)
        if !isempty(userinfo) && getkv(req.headers, "Proxy-Authorization", "") == ""
            @debug 1 "Adding Proxy-Authorization: Basic header."
            setkv(req.headers, "Proxy-Authorization", "Basic $(base64encode(userinfo))")
        end
    end

    IOType = ConnectionPool.Transaction{sockettype(url, socket_type)}
    local io
    try
        io = getconnection(IOType, url.host, url.port;
                           reuse_limit=reuse_limit, kw...)
    catch e
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    end

    if io.sequence >= reuse_limit
        defaultheader!(req, "Connection" => "close")
    end

    try
        if proxy !== nothing && target_url.scheme == "https"
            # tunnel request
            target_url = merge(target_url, port=443)
            r = connect_tunnel(io, target_url, req)
            if r.status != 200
                close(io)
                return r
            end
            io = ConnectionPool.sslupgrade(io, target_url.host; kw...)
            req.headers = filter(x->x.first != "Proxy-Authorization", req.headers)
        end

        r =  request(Next, io, req, body; kw...)

        if (io.sequence >= reuse_limit
            || (proxy !== nothing && target_url.scheme == "https"))
            close(io)
        end

        return r
    catch e
        @debug 1 "❗️  ConnectionLayer $e. Closing: $io"
        try; close(io); catch; end
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    end

end

sockettype(url::URI, default) = url.scheme in ("wss", "https") ? SSLContext : default

function connect_tunnel(io, target_url, req)
    target = "$(URIs.hoststring(target_url.host)):$(target_url.port)"
    @debug 1 "📡  CONNECT HTTPS tunnel to $target"
    headers = Dict(filter(x->x.first == "Proxy-Authorization", req.headers))
    request = Request("CONNECT", target, headers)
    writeheaders(io, request)
    startread(io)
    readheaders(io, request.response)
    return request.response
end

end # module ConnectionRequest
