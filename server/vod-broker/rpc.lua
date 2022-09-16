local RPC = {}

local shm = ngx.shared.broker
local TTL = 60

local function post_update(room)
  ngx.update_time()
  shm:set(room .. ":update", ngx.now(), 1)
end

function RPC.play(room, url)
  shm:set(room .. ":play", url, TTL)
  post_update(room)
end

function RPC.pause(room, pause)
  shm:set(room .. ":pause", pause, TTL)
  post_update(room)
end

function RPC.sync(room, ident, position, ts, url, pause)
  local ok, err = shm:add(room .. ":host", ident, 60)
  shm:expire(room .. ":host", 60) -- refresh ttl

  ngx.update_time()
  position = position + ngx.now() - ts -- amend network latency
  shm:set(room .. ":position", position .. "|" .. ngx.now(), TTL)

  RPC.play(room, url)
  RPC.pause(room, pause)

  post_update(room)

  return RPC.get_state(room, 0)
end

function RPC.get_state(room, wait)
  wait = wait or 0
  for i=0, wait, 0.2 do
    if shm:get(room .. ":update") then
      break
    end
    ngx.sleep(0.2)
  end
  local states = { "play", "position", "pause", "host" }
  local ret = {}
  for _, k in ipairs(states) do
    local v, err = shm:get(room .. ":" .. k)
    if v ~= nil then
      table.insert(ret, { k, v })
    end
  end
  return ret
end

return RPC