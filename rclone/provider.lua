local rc = require 'rclone.rc'

local M = {}

local function basename(path)
  local value = tostring(path or '')
  if value == '' then return '' end
  return value:match '([^/]+)$' or value
end

local function dirname_rel(path)
  local value = tostring(path or '')
  if value == '' then return '' end
  return value:match '^(.*)/[^/]+$' or ''
end

local function split_rel(path)
  local out = {}
  for segment in tostring(path or ''):gmatch '[^/]+' do
    table.insert(out, segment)
  end
  return out
end

local function join_rel(dir, name)
  local base = tostring(dir or '')
  local child = tostring(name or '')
  if base == '' then return child end
  if child == '' then return base end
  return base .. '/' .. child
end

local function trim(value)
  return tostring(value or ''):match '^%s*(.-)%s*$'
end

local function remote_fs(remote)
  local value = tostring(remote or '')
  if value:sub(-1) == ':' then return value end
  return value .. ':'
end

local function full_remote_path(handle)
  local fs = remote_fs(handle.remote)
  local rel = tostring(handle.rel_path or '')
  if rel == '' then return fs end
  return fs .. rel
end

local function item_size(item)
  local size = item and (item.Size or item.size)
  return tonumber(size)
end

function M.new(remote, opt)
  local self = {
    name = 'rclone',
    route_name = (opt or {}).route_name or 'rclone',
    remote = tostring(remote or ''),
  }
  return setmetatable(self, { __index = M })
end

function M:handle(rel_path, is_dir, item)
  local rel = tostring(rel_path or '')
  local name = rel == '' and self.remote or basename(rel)
  return {
    id = remote_fs(self.remote) .. rel,
    name = name,
    path = rel == '' and remote_fs(self.remote) or (remote_fs(self.remote) .. rel),
    rel_path = rel,
    remote = self.remote,
    is_dir = is_dir == true,
    size = item_size(item),
    item = item,
  }
end

function M:root()
  return self:handle('', true)
end

function M:decode_page_path(path)
  if type(path) ~= 'table' or path[1] ~= self.route_name or path[2] ~= self.remote then
    return nil, 'Invalid page path for rclone remote: ' .. tostring(self.remote)
  end
  local rel = ''
  if #path > 2 then rel = table.concat({ table.unpack(path, 3) }, '/') end
  if rel == '' then return self:root() end
  return self:handle(rel, true)
end

function M:encode_page_path(handle)
  local out = { self.route_name, self.remote }
  for _, segment in ipairs(split_rel(handle.rel_path or '')) do
    table.insert(out, segment)
  end
  return out
end

function M:parent(handle)
  local rel = tostring(handle.rel_path or '')
  if rel == '' then return nil end
  return self:handle(dirname_rel(rel), true)
end

function M:join(dir_handle, name)
  return self:handle(join_rel(dir_handle.rel_path or '', name), false)
end

function M:list(dir_handle, cb)
  rc.call('operations/list', {
    fs = remote_fs(self.remote),
    remote = tostring(dir_handle.rel_path or ''),
    opt = {
      recurse = false,
      noModTime = true,
      noMimeType = true,
    },
  }, function(result, err)
    if err then cb(nil, err) return end
    local entries = {}
    for _, item in ipairs((result or {}).list or {}) do
      local name = item.Name or item.name or basename(item.Path or item.path)
      local path = item.Path or item.path or name
      local is_dir = item.IsDir == true or item.isDir == true
      if name and name ~= '' then
        table.insert(entries, self:handle(path, is_dir, item))
      end
    end
    cb(entries)
  end)
end

function M:stat(handle, cb)
  if tostring(handle.rel_path or '') == '' then
    cb({ exists = true, is_dir = true, is_file = false })
    return
  end

  rc.call('operations/stat', {
    fs = remote_fs(self.remote),
    remote = tostring(handle.rel_path or ''),
    opt = { recurse = false, noModTime = true, noMimeType = true },
  }, function(result, err)
    if err then
      cb({ exists = false, is_dir = false, is_file = false }, err)
      return
    end
    local item = result and result.item
    if not item then
      cb({ exists = false, is_dir = false, is_file = false })
      return
    end
    local is_dir = item.IsDir == true or item.isDir == true
    cb({
      exists = true,
      is_dir = is_dir,
      is_file = not is_dir,
      size = item_size(item),
      item = item,
    })
  end)
end

function M:read_file(handle, opts, cb)
  local max_chars = tonumber((opts or {}).max_chars) or 3000
  -- rclone RC has no direct read-file primitive. Use core/command to execute
  -- rclone cat through the already running daemon, still over the HTTP RC API.
  rc.call('core/command', {
    command = 'cat',
    arg = { full_remote_path(handle) },
    returnType = 'COMBINED_OUTPUT',
  }, function(result, err)
    if err then cb('', err) return end
    if type(result) ~= 'table' then
      cb('', 'invalid response from rclone core/command')
      return
    end
    local content = tostring(result.result or '')
    local truncated = false
    if #content > max_chars then
      content = content:sub(1, max_chars)
      truncated = true
    end
    cb(content, nil, { truncated = truncated })
  end)
end

function M:create_dir(dir_handle, name, cb)
  local target = self:join(dir_handle, name)
  target.is_dir = true
  rc.call('operations/mkdir', {
    fs = remote_fs(self.remote),
    remote = target.rel_path,
  }, function(_, err)
    cb(err == nil, err)
  end)
end

function M:remove(handles, cb)
  local remaining = #(handles or {})
  if remaining == 0 then cb(true) return end

  local ok = true
  local first_err = nil
  for _, handle in ipairs(handles or {}) do
    local method = handle.is_dir and 'operations/purge' or 'operations/deletefile'
    rc.call(method, {
      fs = remote_fs(self.remote),
      remote = tostring(handle.rel_path or ''),
    }, function(_, err)
      if err and ok then
        ok = false
        first_err = err
      end
      remaining = remaining - 1
      if remaining == 0 then cb(ok, first_err) end
    end)
  end
end

local function transfer(self, op, handles, target_dir, cb)
  local items = handles or {}
  if #items == 0 then cb(true, nil, { targets = {} }) return end

  local ok = true
  local first_err = nil
  local remaining = 0
  local targets = {}

  local function finish()
    if remaining == 0 then
      if ok then
        cb(true, nil, { targets = targets })
      else
        cb(false, first_err)
      end
    end
  end

  for _, handle in ipairs(items) do
    if handle.is_dir then
      ok = false
      first_err = 'rclone RC file provider only supports ' .. op .. ' for files'
    else
      local target = self:join(target_dir, handle.name)
      target.is_dir = false
      table.insert(targets, target)
      remaining = remaining + 1
      rc.call(op == 'move' and 'operations/movefile' or 'operations/copyfile', {
        srcFs = remote_fs(handle.remote),
        srcRemote = tostring(handle.rel_path or ''),
        dstFs = remote_fs(target.remote),
        dstRemote = tostring(target.rel_path or ''),
      }, function(_, err)
        if err and ok then
          ok = false
          first_err = err
        end
        remaining = remaining - 1
        finish()
      end)
    end
  end

  finish()
end

function M:copy(handles, target_dir, cb)
  transfer(self, 'copy', handles, target_dir, cb)
end

function M:move(handles, target_dir, cb)
  transfer(self, 'move', handles, target_dir, cb)
end

function M:rename(handle, name, cb)
  if tostring(handle.rel_path or '') == '' then
    cb(false, 'Cannot rename remote root')
    return
  end
  if handle.is_dir then
    cb(false, 'rclone RC file provider only supports rename for files')
    return
  end

  local parent = self:parent(handle)
  if not parent then cb(false, 'Failed to resolve parent directory') return end
  local target = self:join(parent, name)
  rc.call('operations/movefile', {
    srcFs = remote_fs(handle.remote),
    srcRemote = tostring(handle.rel_path or ''),
    dstFs = remote_fs(target.remote),
    dstRemote = tostring(target.rel_path or ''),
  }, function(_, err)
    if err then cb(false, err) return end
    target.is_dir = handle.is_dir
    target.size = handle.size
    cb(true, nil, { target = target })
  end)
end

return M
