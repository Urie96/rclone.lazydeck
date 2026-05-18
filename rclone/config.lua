local M = {}

local defaults = {
  command = 'rclone',
  rc_addr = '127.0.0.1:5572',
  rc_url = nil,
  auto_start = true,
  auto_start_delay = 1,
  start_cmd = nil,
  preview_max_chars = 3000,
  preview_mode = 'full',
  show_hidden = false,
  keymap = {
    -- Keep only capabilities naturally provided by file provider + rclone RC.
    -- edit is intentionally disabled: rclone RC has no direct edit primitive.
    edit = false,
  },
}

local cfg = deck.tbl_deep_extend('force', {}, defaults)

local function trim(s)
  if s == nil then return nil end
  return tostring(s):match '^%s*(.-)%s*$'
end

local function normalize(next_cfg)
  local out = deck.tbl_deep_extend('force', {}, defaults, next_cfg or {})
  out.command = trim(out.command) or defaults.command
  out.rc_addr = trim(out.rc_addr) or defaults.rc_addr
  out.rc_url = trim(out.rc_url) or ('http://' .. out.rc_addr)
  out.auto_start = out.auto_start ~= false
  out.auto_start_delay = tonumber(out.auto_start_delay) or defaults.auto_start_delay
  out.preview_max_chars = tonumber(out.preview_max_chars) or defaults.preview_max_chars
  out.preview_mode = tostring(out.preview_mode or defaults.preview_mode)
  out.show_hidden = out.show_hidden == true
  out.keymap = deck.tbl_deep_extend('force', {}, defaults.keymap, out.keymap or {})
  return out
end

function M.setup(opt)
  cfg = normalize(opt or {})
end

function M.get()
  return cfg
end

return M
