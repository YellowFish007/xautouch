-----------------------------------------------------------------------------
-- Full copy of the LuaSocket code, modified to include
-- https and http/https redirects, and Copas async enabled.
-----------------------------------------------------------------------------
-- HTTP/1.1 client support for the Lua language.
-- LuaSocket toolkit.
-- Author: Diego Nehab
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Declare module and import dependencies
-------------------------------------------------------------------------------
local socket = require("socket")
local url = require("socket.url")
local ltn12 = require("ltn12")
local mime = require("mime")
local string = require("string")
local headers = require("socket.headers")
local base = _G
local table = require("table")
local copas = require("copas")
local clientparams = require("ssl.clientparams")
copas.http = {}
local _M = copas.http

-----------------------------------------------------------------------------
-- Program constants
-----------------------------------------------------------------------------
-- connection timeout in seconds
_M.TIMEOUT = 60
-- default port for document retrieval
_M.PORT = 80
-- user agent field sent in request
_M.USERAGENT = socket._VERSION

-- Default settings for SSL
_M.SSLPORT = 443
_M.SSLPROTOCOL = "tlsv1_2"
_M.SSLOPTIONS  = "all"
_M.SSLVERIFY   = "none"
_M.MAXHEADERLINE = 8192
_M.MAXHEADERSIZE = 65536


-----------------------------------------------------------------------------
-- Reads MIME headers from a connection, unfolding where needed
-----------------------------------------------------------------------------
local function receiveheaders(sock, headers)
    local line, name, value, err
    headers = headers or {}
    -- bounds total bytes read across all header lines, on top of the
    -- per-line MAXHEADERLINE cap, so a peer can't exhaust memory by sending
    -- many lines that each individually fit under MAXHEADERLINE
    local budget = _M.MAXHEADERSIZE
    local function recvline()
        local line, err = sock:receive("*l", nil, math.max(1, math.min(budget, _M.MAXHEADERLINE)))
        if line then
            if #line > budget then return nil, "oversized" end
            budget = budget - #line
        end
        return line, err
    end
    -- get first line
    line, err = recvline()
    if err then return nil, err end
    -- headers go until a blank line is found
    while line ~= "" do
        -- get field-name and value
        name, value = socket.skip(2, string.find(line, "^(.-):%s*(.*)"))
        if not (name and value) then return nil, "malformed response headers" end
        name = string.lower(name)
        -- get next line (value might be folded)
        line, err  = recvline()
        if err then return nil, err end
        -- unfold any folded values
        while string.find(line, "^%s") do
            value = value .. line
            line, err = recvline()
            if err then return nil, err end
        end
        -- save pair in table
        if headers[name] then headers[name] = headers[name] .. ", " .. value
        else headers[name] = value end
    end
    return headers
end

-----------------------------------------------------------------------------
-- Extra sources and sinks
-----------------------------------------------------------------------------
local function source_http_chunked(sock, headers)
    return base.setmetatable({
        getfd = function() return sock:getfd() end,
        dirty = function() return sock:dirty() end
    }, {
        __call = function()
            -- get chunk size, skip extension
            local line, err = sock:receive("*l", nil, _M.MAXHEADERLINE)
            if err then return nil, err end
            local size = base.tonumber(string.gsub(line, ";.*", ""), 16)
            if not size then return nil, "invalid chunk size" end
            -- was it the last chunk?
            if size > 0 then
                -- if not, get chunk and skip terminating CRLF
                local chunk, err, _ = sock:receive(size)
                if chunk then
                    local ending
                    ending, err = sock:receive("*l", nil, _M.MAXHEADERLINE)
                    if not ending then return nil, err end
                    if ending ~= "" then return nil, "invalid chunk ending" end
                end
                return chunk, err
            else
                -- if it was, read trailers into headers table
                headers, err = receiveheaders(sock, headers)
                if not headers then return nil, err end
            end
        end
    })
end

socket.sourcet["http-chunked"] = source_http_chunked

socket.sinkt["http-chunked"] = function(sock)
    return base.setmetatable({
        getfd = function() return sock:getfd() end,
        dirty = function() return sock:dirty() end
    }, {
        __call = function(self, chunk, err)
            if not chunk then return sock:send("0\r\n\r\n") end
            local size = string.format("%X\r\n", string.len(chunk))
            return sock:send(size ..  chunk .. "\r\n")
        end
    })
end

-----------------------------------------------------------------------------
-- Low level HTTP API
-----------------------------------------------------------------------------
local metat = { __index = {} }

function _M.open(reqt)
    -- create socket with user connect function
    local c = socket.try(reqt:create())   -- method call, passing reqt table as self!
    local h = base.setmetatable({ c = c }, metat)
    -- create finalized try
    h.try = socket.newtry(function() h:close() end)
    -- set timeout before connecting
    local to = reqt.timeout or _M.TIMEOUT
    if type(to) == "table" then
      h.try(c:settimeouts(
        to.connect or _M.TIMEOUT,
        to.send or _M.TIMEOUT,
        to.receive or _M.TIMEOUT))
    else
      h.try(c:settimeout(to))
    end
    h.try(c:connect(reqt.host, reqt.port or _M.PORT))
    -- here everything worked
    return h
end

function metat.__index:sendrequestline(method, uri)
    local reqline = string.format("%s %s HTTP/1.1\r\n", method or "GET", uri)
    return self.try(self.c:send(reqline))
end

function metat.__index:sendheaders(tosend)
    local canonic = headers.canonic
    local h = "\r\n"
    for f, v in base.pairs(tosend) do
        h = (canonic[f] or f) .. ": " .. v .. "\r\n" .. h
    end
    self.try(self.c:send(h))
    return 1
end

function metat.__index:sendbody(headers, source, step)
    source = source or ltn12.source.empty()
    step = step or ltn12.pump.step
    -- if we don't know the size in advance, send chunked and hope for the best
    local mode = "http-chunked"
    if headers["content-length"] then mode = "keep-open" end
    return self.try(ltn12.pump.all(source, socket.sink(mode, self.c), step))
end

function metat.__index:receivestatusline()
    local status = self.try(self.c:receive(5))
    -- identify HTTP/0.9 responses, which do not contain a status line
    -- this is just a heuristic, but is what the RFC recommends
    if status ~= "HTTP/" then return nil, status end
    -- otherwise proceed reading a status line
    status = self.try(self.c:receive("*l", status, _M.MAXHEADERLINE))
    local code = socket.skip(2, string.find(status, "HTTP/%d*%.%d* (%d%d%d)"))
    return self.try(base.tonumber(code), status)
end

function metat.__index:receiveheaders()
    return self.try(receiveheaders(self.c))
end

function metat.__index:receivebody(headers, sink, step)
    sink = sink or ltn12.sink.null()
    step = step or ltn12.pump.step
    local length = base.tonumber(headers["content-length"])
    local t = headers["transfer-encoding"] -- shortcut
    local mode = "default" -- connection close
    if t and t ~= "identity" then mode = "http-chunked"
    elseif base.tonumber(headers["content-length"]) then mode = "by-length" end
    -- Each HTTP client keeps its own limits even when both modules are loaded.
    local source = mode == "http-chunked" and source_http_chunked(self.c, headers)
        or socket.source(mode, self.c, length)
    return self.try(ltn12.pump.all(source, sink, step))
end

function metat.__index:receive09body(status, sink, step)
    local source = ltn12.source.rewind(socket.source("until-closed", self.c))
    source(status)
    return self.try(ltn12.pump.all(source, sink, step))
end

function metat.__index:close()
    return self.c:close()
end

-----------------------------------------------------------------------------
-- High level HTTP API
-----------------------------------------------------------------------------
local function adjusturi(reqt)
    local u = reqt
    reqt.fragment = nil -- fragments are client-side only and must never be sent on the wire
    -- if there is a proxy, we need the full url. otherwise, just a part.
    if not reqt.proxy and not _M.PROXY then
        u = {
           path = socket.try(reqt.path, "invalid path 'nil'"),
           params = reqt.params,
           query = reqt.query,
        }
    end
    return url.build(u)
end

local function adjustproxy(reqt)
    local proxy = reqt.proxy or _M.PROXY
    if proxy then
        proxy = url.parse(proxy)
        return proxy.host, proxy.port or 3128
    else
        return reqt.host, reqt.port
    end
end

local function adjustheaders(reqt)
    -- default headers
    local host = string.gsub(reqt.authority, "^.-@", "")
    local lower = {
        ["user-agent"] = _M.USERAGENT,
        ["host"] = host,
        ["connection"] = "close, TE",
        ["te"] = "trailers"
    }
    -- if we have authentication information, pass it along
    if reqt.user and reqt.password then
        lower["authorization"] =
            "Basic " ..  (mime.b64(reqt.user .. ":" .. reqt.password))
    end
    -- override with user headers
    for i,v in base.pairs(reqt.headers or lower) do
        lower[string.lower(i)] = v
    end
    return lower
end

-- default url parts
local default = {
    host = "",
    port = _M.PORT,
    path ="/",
    scheme = "http"
}

local function adjustrequest(reqt)
    -- parse url if provided
    local nreqt = reqt.url and url.parse(reqt.url, default) or {}
    -- explicit components override url
    for i,v in base.pairs(reqt) do nreqt[i] = v end
    socket.try(base.type(nreqt.scheme) == "string",
        "invalid scheme '" .. base.tostring(nreqt.scheme) .. "'")
    nreqt.scheme = string.lower(nreqt.scheme)
    socket.try(nreqt.scheme == "http" or nreqt.scheme == "https",
        "unsupported scheme '" .. nreqt.scheme .. "'")
    if nreqt.port == "" then nreqt.port = 80 end
    socket.try(nreqt.host and nreqt.host ~= "",
        "invalid host '" .. base.tostring(nreqt.host) .. "'")
    -- compute uri if user hasn't overriden
    nreqt.uri = reqt.uri or adjusturi(nreqt)
    -- ajust host and port if there is a proxy
    nreqt.host, nreqt.port = adjustproxy(nreqt)
    -- adjust headers in request
    nreqt.headers = adjustheaders(nreqt)
    return nreqt
end

local function shouldredirect(reqt, code, headers)
    return headers.location and
           string.gsub(headers.location, "%s", "") ~= "" and
           (reqt.redirect ~= false) and
           (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and
           (not reqt.method or reqt.method == "GET" or reqt.method == "HEAD")
           and (not reqt.nredirects or reqt.nredirects < 5)
end

local function shouldreceivebody(reqt, code)
    if reqt.method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return 1
end

-- forward declarations
local trequest, tredirect

--[[local]] function tredirect(reqt, location)
    local result, code, headers, status = trequest {
        -- the RFC says the redirect URL has to be absolute, but some
        -- servers do not respect that
        url = url.absolute(reqt.url, location),
        method = reqt.method,
        redirect = reqt.redirect,
        source = reqt.source,
        sink = reqt.sink,
        headers = reqt.headers,
        proxy = reqt.proxy,
        nredirects = (reqt.nredirects or 0) + 1,
        create = reqt.create,
        timeout = reqt.timeout,
    }
    -- pass location header back as a hint we redirected
    headers = headers or {}
    headers.location = headers.location or location
    return result, code, headers, status
end

--[[local]] function trequest(reqt)
    -- we loop until we get what we want, or
    -- until we are sure there is no way to get it
    local nreqt = adjustrequest(reqt)
    local h = _M.open(nreqt)
    -- send request line and headers
    h:sendrequestline(nreqt.method, nreqt.uri)
    h:sendheaders(nreqt.headers)
    -- if there is a body, send it
    if nreqt.source then
        h:sendbody(nreqt.headers, nreqt.source, nreqt.step)
    end
    local code, status = h:receivestatusline()
    -- if it is an HTTP/0.9 server, simply get the body and we are done
    if not code then
        h:receive09body(status, nreqt.sink, nreqt.step)
        return 1, 200
    end
    local headers
    -- ignore any 100-continue messages
    while code == 100 do
        h:receiveheaders()
        code, status = h:receivestatusline()
    end
    headers = h:receiveheaders()
    -- at this point we should have a honest reply from the server
    -- we can't redirect if we already used the source, so we report the error
    if shouldredirect(nreqt, code, headers) and not nreqt.source then
        h:close()
        return tredirect(reqt, headers.location)
    end
    -- here we are finally done
    if shouldreceivebody(nreqt, code) then
        h:receivebody(headers, nreqt.sink, nreqt.step)
    end
    h:close()
    return 1, code, headers, status
end

-- Returns true if `host` is a literal IPv4 or IPv6 address rather than a DNS
-- hostname. RFC 6066 disallows IP literals in the TLS SNI extension, so these
-- must not be sent as an SNI name.
local function ishostliteral(host)
  if string.find(host, ":", 1, true) then
    return true -- IPv6 addresses always contain a colon (socket.url strips the brackets)
  end
  return string.match(host, "^%d+%.%d+%.%d+%.%d+$") ~= nil
end

-- Return a function which creates a tcp socket that will
-- include the optional SSL/TLS connection, and unsafe redirect checks
function _M.getcreatefunc(params)
   params = params or {}
   local original = params.sslparams or {}
   local wrap = {}
   for k, v in pairs(original.wrap or {
      protocol = params.protocol, options = params.options, verify = params.verify,
      cafile = params.cafile, capath = params.capath, host = params.host,
      hostflags = params.hostflags,
   }) do wrap[k] = v end
   wrap.protocol = wrap.protocol or _M.SSLPROTOCOL
   wrap.options = wrap.options or _M.SSLOPTIONS
   if wrap.verify == nil then wrap.verify = _M.SSLVERIFY end
   wrap.mode = "client"
   local sni_name = type(original.sni) == "table" and original.sni.names or nil

   -- upvalue to track https -> http redirection
   local washttps = false
   local first_request = true -- on follow up redirects we must clear sni-name

   -- 'create' function for LuaSocket
   return function (reqt)
      local u = url.parse(reqt.url)
      local scheme = string.lower(reqt.scheme or u.scheme or "")
      socket.try(scheme == "http" or scheme == "https",
          "unsupported scheme '" .. scheme .. "'")
      local initial = first_request
      first_request = false
      if scheme == "https" then
        local next_wrap = {}
        for k, v in pairs(wrap) do next_wrap[k] = v end
        if not initial then
          next_wrap.host = nil
          next_wrap.server_name = nil
        end
        next_wrap = clientparams(next_wrap, u.host)
        local name = initial and sni_name or nil
        if not name and not ishostliteral(u.host) then name = u.host end
        local ssl_params = {
          wrap = next_wrap,
          sni = name and { names = name } or false,
        }
        -- https, provide an ssl wrapped socket
        local conn = copas.wrap(socket.tcp(), ssl_params)
        -- insert https default port, overriding http port inserted by LuaSocket
        if not u.port then
           u.port = _M.SSLPORT
           reqt.url = url.build(u)
           reqt.port = _M.SSLPORT
        end
        washttps = true
        return conn
      else
        -- regular http, needs just a socket...
        if washttps and params.redirect ~= "all" then
          socket.try(nil, "Unallowed insecure redirect https to http")
        end
        return copas.wrap(socket.tcp())
      end
   end
end

-- parses a shorthand form into the advanced table form.
-- adds field `target` to the table. This will hold the return values.
_M.parseRequest = function(u, b)
    local reqt = {
        url = u,
        target = {},
    }
    reqt.sink = ltn12.sink.table(reqt.target)
    if b then
        reqt.source = ltn12.source.string(b)
        reqt.headers = {
            ["content-length"] = string.len(b),
            ["content-type"] = "application/x-www-form-urlencoded"
        }
        reqt.method = "POST"
    end
    return reqt
end

_M.request = socket.protect(function(reqt, body)
    if base.type(reqt) == "string" then
        reqt = _M.parseRequest(reqt, body)
        local ok, code, headers, status = _M.request(reqt)

        if ok then
            return table.concat(reqt.target), code, headers, status
        else
            return nil, code
        end
    else
        -- strict check on timeout table to prevent typo's from going unnoticed
        if type(reqt.timeout) == "table" then
          local allowed = { connect = true, send = true, receive = true }
          for k in pairs(reqt.timeout) do
            assert(allowed[k], "'"..tostring(k).."' is not a valid timeout option. Valid: 'connect', 'send', 'receive'")
          end
        end
        if not reqt.create then
          -- The factory owns one redirect chain; caching it on the caller would
          -- turn a later independent request into another hop of that chain.
          local original = reqt
          reqt = {}
          for key, value in pairs(original) do reqt[key] = value end
          reqt.create = _M.getcreatefunc(reqt)
        end
        return trequest(reqt)
    end
end)

return _M
