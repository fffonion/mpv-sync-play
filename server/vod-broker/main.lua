local cjson = require("cjson.safe")
local rpc = require("rpc")

local EMPTY_T = {}

local function err_reponse(code, message)
  ngx.say(
    cjson.encode(
      {
        code = code,
        error = message
      }
    )
  )
end

local function serve()
  local err
  local room = tonumber(string.sub(ngx.var.request_uri, 2)) -- stirp /
  if not room then
    return err_reponse(400, "Invalid room number")
  end

  ngx.req.read_body()
  local request_body = ngx.req.get_body_data()
  if not request_body then
    return err_reponse(400, "No request body")
  end

  request_body, err = cjson.decode(request_body)
  if err or not request_body then
    return err_reponse(400, "Invalid request body: " .. tostring(err))
  end

  local method = request_body.method
  local args = request_body.args
  if not method or not rpc[method] then
    return err_reponse(400, "Invalid method " .. tostring(method))
  end

  args = args or EMPTY_T
  local ret, err = rpc[method](room, table.unpack(args))
  if err then
    return err_reponse(500, "Internal error: " .. err)
  end

  return ngx.say(
    cjson.encode(
      {
        code = 0,
        data = ret
      }
    )
  )
end

serve()
