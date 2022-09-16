--[[
  vod_broker.lua
  Description: sync playback position between multiple mpv instances
  Version:     1.0.0
  Author:      fffonion
  URL:         https://github.com/fffonion/mpv-sync-play
  License:     Apache License, Version 2.0
]]--

local utils = require("mp.utils")
local read_options = read_options or require("mp.options").read_options

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = utils.split_path(script_path)

local VERSION = "1.0.0"

local tmpDir

math.randomseed(os.clock()*100000000000)

local ident = "client-" .. math.random(10000, 99999)

local function getTmpDir()
  if not tmpDir then
    local temp = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR")
    if temp then
      tmpDir = temp
    else
      tmpDir = "/tmp"
    end
  end
  return tmpDir
end

local function fileExists(path)
  if utils.file_info then -- >= 0.28.0
      return utils.file_info(path)
  end
  local ok, _ = pcall(io.open, path)
  return ok
end

local function testDownloadTool()
  local _UA = mp.get_property("mpv-version"):gsub(" ", "/") .. " vod-broker-" .. VERSION
  local UA = "User-Agent: " .. _UA
  local cmds = {
    {"curl", "-SLs", "-H", UA, "--max-time", "5", "-d"},
    {"wget", "-q", "--header", UA, "-O", "-", "--post-data"},
    {
      "powershell",
      ' Invoke-WebRequest -UserAgent "' .. _UA .. '"  -ContentType "application/json charset=utf-8" -Method POST -URI'
    }
  }
  local _winhelper = script_dir .. "win-helper.vbs"
  if fileExists(_winhelper) then
    table.insert(cmds, { "cscript", "/nologo", _winhelper, _UA })
  end
  for i = 1, #cmds do
    local result =
      utils.subprocess(
      {
        args = {cmds[i][1], "-h"},
        cancellable = false
      }
    )
    if type(result.stdout) == "string" and result.status ~= -1 then
      mp.msg.info("selected: ", cmds[i][1])
      return cmds[i]
    end
  end
  return
end

local function post(args, body, url)
  local tbl = {}
  for i, arg in ipairs(args) do
    tbl[i] = arg
  end
  args = tbl

  local tmpFile = utils.join_path(getTmpDir(), ".vod-broker-helper.tmp")

  if args[1] == "powershell" then
    args[#args.length] = args[#args.length] .. '"' .. url .. '" -Outfile "' .. tmpFile .. '"' .. ' -Body "' .. body .. '"'
  else
    table.insert(args, body)
    table.insert(args, url)

    local result =
      utils.subprocess(
      {
        args = args,
        cancellable = true
      }
    )

    if result.stderr or result.status ~= 0 then
      return nil, result.stderr or ("subprocess exit with code: " .. result.status .. ", stderr: " .. tostring(result.stderr))
    end

    if args[1] == "powershell" or args[1] == "cscript" then
      return utils.read_file(saveFile)
    else
      return result.stdout
    end
  end
end

local RPC = {
  play = function(url)
    mp.msg.info("stream open filename ", mp.get_property_native("stream-open-filename", "") )
    if mp.get_property_native("stream-open-filename", "") ~= url then
      mp.msg.info("set file to " .. url)
      -- mp.set_property_native("stream-open-filename", url)
      mp.commandv('loadfile', url, 'replace')
    end
  end,

  pause = function(pause)
    mp.set_property_native("pause", pause)
  end,

  stop = function()
    -- mp.set_property_native("pause", pause)
  end,

  position = function(position_str)
    local position, ts = position_str:match("^([%d%.]+)%|([%d%.]+)$")
    position = mp.get_time_ms() - ts + position
    local cur = mp.get_property_native("time-pos")
    if not cur or math.abs(position - cur) > 1 then
      mp.msg.info("adjusting position: " .. position)
      mp.set_property_native("time-pos", position)
    end
  end,
}

local BROKER = {}

function BROKER.new(options)
  local options = options or {}
  local tbl = {}
  for k, v in pairs(options) do
    tbl[k] = v
  end
  tbl.is_host = true -- default to host
  return setmetatable(tbl, {__index = BROKER})
end

function BROKER:rpc(method, ...)
  if not self.cmd then
    self.cmd = testDownloadTool()
  end

  local body = utils.format_json({ method = method, args = {...} })
  mp.msg.info("RPC: " .. method)
  mp.msg.verbose("RPC: " .. body)

  local ret, err = post(self.cmd, body, self.broker_url .. "/" .. self.room_id)
  if err then
    mp.msg.error("RPC request error: " .. err)
    return
  end

  local decoded, err = utils.parse_json(ret)
  if err then
    mp.msg.error("RPC parse error: " .. err .. " raw body is: ".. ret)
    return
  end
  if decoded.code > 0 then
    mp.msg.error("RPC return error: " .. decoded.code .. ", message: " .. decoded.error)
    return
  end

  mp.msg.verbose("RPC: OK")

  return decoded.data
end


function sleep(time)
	local now = mp.get_time_ms()
	repeat until (mp.get_time_ms() - now > time)
end

function BROKER:join()
  local timeout = 300 -- try 5 minutes
  for i=1, timeout/5 do
    local start = self:sync_down()
    if start then
      break
    end
    sleep(5)
  end
end

function BROKER:sync_up()
  if mp.get_property("seekable") and self.is_host then
    local position = mp.get_property_number("time-pos")
    local url = mp.get_property("stream-open-filename", "")
    local pause = mp.get_property_native("pause")
    if position ~= nil then
      self:rpc("sync", ident, position, mp.get_time_ms(), url, pause)
    end
  end
end

function BROKER:sync_down(interval)
  if self.is_host then
    return
  end

  local start_play = false
  local state, err = self:rpc("get_state", interval)

  if state then
    mp.msg.verbose(utils.format_json(state))
    for _, s in pairs(state) do
      if s[1] == "play" then
        start_play = true
      elseif s[1] == "position" then
        self.lazy_reposition = s[2]
      end
      if s[1] == "host" then
        if s[2] == ident then
          if not self.is_host then
            mp.osd_message("claimed the host", 3)
            mp.msg.info("claimed the host")
          end
        end
        self.is_host = s[2] == ident
      elseif RPC[s[1]] then
        RPC[s[1]](s[2])
      else
        mp.msg.warn("unknown state: " .. s[1])
      end
    end
  end

  return start_play
end

function BROKER:check_lazy_reposition()
  if self.lazy_reposition then
    mp.msg.info("lazy reposition: " .. self.lazy_reposition)
    RPC.position(self.lazy_reposition)
    self.lazy_reposition = nil
  end
end


local function init()
  local userConfig = {
    broker_url = "http://broker.vod.yooooo.us",
    room_id = 1,
    sync_interval = 5,
  }
  read_options(userConfig, "vod_broker")

  -- Create and initialize the media browser instance.
  local broker
  local status, err =
    pcall(
    function()
      broker =
        BROKER.new(
        {
          broker_url = userConfig["broker_url"],
          room_id = userConfig["room_id"],
          sync_interval = userConfig["sync_interval"],
        }
      )
    end
  )
  if not status then
    mp.msg.error("BROKER: " .. err .. ".")
    mp.osd_message("BROKER: " .. err .. ".", 3)
    error(err) -- Critical init error. Stop script execution.
  end

  mp.msg.info("script loaded, default broker: " .. broker.broker_url .. "/" .. broker.room_id)

  local prefix = "broker://"

  mp.add_hook("on_load_fail", 10, function()
    local url = mp.get_property("stream-open-filename", "")
    if not (url:find(prefix) == 1) then
      return
    end
    broker.is_host = false
    broker:join(string.sub(url, #prefix+2))
  end)

  mp.register_event("start-file", function()
    local path = mp.get_property("stream-open-filename", "")
    if path ~= "" and not (path:find(prefix) == 1) then
      broker:rpc("play", path)
    end
  end)

  -- mp.register_event("end-file", function()
  --   -- end file
  -- end)

  mp.observe_property("pause", "bool", function(name, value)
    broker:rpc("pause", value)
  end)

  mp.register_event("seek", function()
    broker:sync_up()
  end)

  local broker_auto_joined = false
  mp.observe_property("idle-active", "bool", function(name, value)
    -- value is true when mpv is idle
    if value == true and not broker_auto_joined then
      broker_auto_joined = true
      broker:join(userConfig.room_id)
    end
  end)

  mp.register_event("file-loaded", function()
    broker:check_lazy_reposition()
  end)

  -- blocking query
  local timer1 = mp.add_periodic_timer(0.1, function()
    broker:sync_down(userConfig.sync_interval)
  end)

  -- timely sync
  local timer2 = mp.add_periodic_timer(userConfig.sync_interval, function()
    broker:sync_up()
  end)
end

init()
