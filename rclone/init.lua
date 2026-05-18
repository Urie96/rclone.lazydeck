local config = require 'rclone.config'
local file = require 'file'
local Provider = require 'rclone.provider'
local rc = require 'rclone.rc'

local M = {}

local runtime = {
  browsers = {},
}

local CACHE_NS = 'rclone'
local REMOTES_CACHE_KEY = 'listremotes'

local function span(text, color)
  local s = deck.style.span(tostring(text or ''))
  if color and color ~= '' then s = s:fg(color) end
  return s
end

local function line(parts) return deck.style.line(parts) end
local function text(lines) return deck.style.text(lines) end

local function info_entry(key, message, color)
  return {
    key = key,
    kind = 'info',
    message = message,
    color = color or 'darkgray',
    display = line { span(message, color or 'darkgray') },
    preview = function(self, cb)
      cb(text { line { span(self.message or message, color or 'darkgray') } })
    end,
  }
end

local function browser_options()
  local cfg = config.get()
  return {
    preview_max_chars = cfg.preview_max_chars,
    preview_mode = cfg.preview_mode,
    show_hidden = cfg.show_hidden,
    keymap = cfg.keymap,
  }
end

local function get_browser(remote)
  if runtime.browsers[remote] then return runtime.browsers[remote] end
  runtime.browsers[remote] = file.new(Provider.new(remote, { route_name = 'rclone' }), browser_options())
  return runtime.browsers[remote]
end

local function remote_entry(remote)
  local name = tostring(remote or ''):gsub(':$', '')
  return {
    key = name,
    kind = 'remote',
    remote = name,
    display = line {
      span(name, 'cyan'),
      span(':', 'darkgray'),
    },
    preview = function(self, cb)
      cb(text {
        line { span('Remote: ', 'darkgray'), span(self.remote .. ':', 'cyan') },
        line { span('Backend and detailed info are loaded by rclone on demand.', 'darkgray') },
      })
    end,
  }
end

local function build_remote_entries(remotes)
  remotes = remotes or {}
  table.sort(remotes, function(a, b) return string.lower(tostring(a)) < string.lower(tostring(b)) end)

  local entries = {}
  for _, remote in ipairs(remotes) do
    table.insert(entries, remote_entry(remote))
  end
  if #entries == 0 then
    table.insert(entries, info_entry('empty', 'No rclone remotes configured', 'yellow'))
  end
  return entries
end

local function update_root_entries_if_current(expected_path, entries)
  if deck.deep_equal(expected_path, deck.api.get_current_path() or {}) then
    deck.api.set_entries(nil, entries)
  end
end

local function refresh_remotes_in_background(expected_path)
  rc.call('config/listremotes', {}, function(result, err)
    if err then
      if not deck.cache.get(CACHE_NS, REMOTES_CACHE_KEY) then
        update_root_entries_if_current(expected_path, {
          info_entry('error', 'Failed to list rclone remotes', 'red'),
          info_entry('error-detail', tostring(err), 'red'),
        })
      else
        deck.notify('Failed to refresh rclone remotes: ' .. tostring(err))
      end
      return
    end

    local remotes = (result or {}).remotes or {}
    deck.cache.set(CACHE_NS, REMOTES_CACHE_KEY, remotes)
    update_root_entries_if_current(expected_path, build_remote_entries(remotes))
  end)
end

local function list_remotes(path, cb)
  local expected_path = path
  local cached = deck.cache.get(CACHE_NS, REMOTES_CACHE_KEY)
  if cached then
    cb(build_remote_entries(cached))
  else
    cb { info_entry('loading', 'Loading rclone remotes...', 'darkgray') }
  end

  refresh_remotes_in_background(expected_path)
end

function M.setup(opt)
  config.setup(opt or {})
  runtime.browsers = {}

  if not deck.system.executable(config.get().command) then
    deck.notify(config.get().command .. ' command not found')
    deck.log('warn', config.get().command .. ' command not found')
  end

  deck.plugin.load 'file'
  deck.hook.pre_quit(function()
    rc.close()
  end)
end

function M.list(path, cb)
  if #path <= 1 then
    list_remotes(path, cb)
    return
  end

  local remote = path[2]
  local expected_path = path
  local browser = get_browser(remote)
  browser:list(path, function(entries)
    if deck.deep_equal(expected_path, deck.api.get_current_path() or {}) then cb(entries) end
  end)
end

function M.preview(entry, cb)
  if entry and entry.preview then return entry:preview(cb) end
end

return M
