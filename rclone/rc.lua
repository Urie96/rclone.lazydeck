local config = require 'rclone.config'

local M = {}

local state = {
  pid = nil,
  last_start_at = 0,
}

local function trim(value)
  return tostring(value or ''):match '^%s*(.-)%s*$'
end

local function is_connection_error(err)
  local msg = tostring(err or ''):lower()
  return msg:find('error sending request for url', 1, true) ~= nil
    or msg:find('connection refused', 1, true) ~= nil
    or msg:find('tcp connect error', 1, true) ~= nil
    or msg:find('connection reset', 1, true) ~= nil
end

local function endpoint(method)
  local cfg = config.get()
  return tostring(cfg.rc_url):gsub('/+$', '') .. '/' .. method
end

local function build_start_cmd(cfg)
  if cfg.start_cmd then return cfg.start_cmd end
  return {
    cfg.command,
    'rcd',
    '--rc-addr', cfg.rc_addr,
    '--rc-no-auth',
  }
end

local function ensure_started()
  local cfg = config.get()
  if not cfg.auto_start then return false, 'rclone rcd auto start disabled' end
  if not deck.system.executable(cfg.command) then return false, 'command not found: ' .. tostring(cfg.command) end

  local now = deck.time.now()
  if state.last_start_at > 0 and (now - state.last_start_at) < 5 then
    return true, 'rclone rcd start already requested'
  end

  local cmd = build_start_cmd(cfg)
  local ok, pid = pcall(deck.system.spawn, cmd)
  if not ok then return false, pid end

  state.pid = pid
  state.last_start_at = now
  deck.notify('rclone rcd started' .. (pid and (' (pid ' .. tostring(pid) .. ')') or ''))
  return true
end

local function decode_response(response)
  if not response.success then
    return nil, response.error or ('HTTP ' .. tostring(response.status))
  end
  if tonumber(response.status or 0) < 200 or tonumber(response.status or 0) >= 300 then
    return nil, trim(response.body) ~= '' and trim(response.body) or ('HTTP ' .. tostring(response.status))
  end

  local body = tostring(response.body or '')
  if body == '' then return {} end
  local ok, decoded = pcall(deck.json.decode, body)
  if not ok then return nil, 'failed to decode rclone RC response: ' .. tostring(decoded) end
  if type(decoded) == 'table' and decoded.error then
    return nil, tostring(decoded.error)
  end
  return decoded
end

function M.call(method, params, cb, opts)
  deck.http.request({
    method = 'POST',
    url = endpoint(method),
    headers = { ['Content-Type'] = 'application/json' },
    body = deck.json.encode(params or {}),
  }, function(response)
    local result, err = decode_response(response)
    if err and is_connection_error(err) and not (opts and opts.skip_auto_start) then
      local started = ensure_started()
      if started and deck.system.executable 'sleep' then
        deck.system.exec({ 'sleep', tostring(config.get().auto_start_delay or 1) }, function()
          M.call(method, params, cb, { skip_auto_start = true })
        end)
        return
      end
    end
    cb(result, err)
  end)
end

function M.ensure(cb)
  M.call('core/version', {}, function(result, err)
    if err then cb(false, err) else cb(true, nil, result) end
  end)
end

function M.close()
  if state.pid then
    pcall(deck.system.kill, state.pid)
    state.pid = nil
  end
end

return M
