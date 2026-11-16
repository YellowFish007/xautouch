-- Shared by clients that know the destination before the TLS handshake.
return function(params, host)
   host = host:match("^%[(.*)%]$") or host
   local copy = params
   if type(params) ~= "userdata" then
      copy = {}
      for k, v in pairs(params or {}) do copy[k] = v end
      local peer = copy.verify == "peer"
      if type(copy.verify) == "table" then
         for _, flag in ipairs(copy.verify) do
            if flag == "peer" then peer = true end
         end
      end
      if peer and copy.host == nil and not copy.dane then copy.host = host end
   end
   local explicit_sni = type(copy) == "table" and copy.server_name
   local sni = explicit_sni or host
   if not explicit_sni and (sni:find(":", 1, true) or
      sni:match("^%d+%.%d+%.%d+%.%d+$")) then
      sni = nil
   end
   return copy, sni
end
