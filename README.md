# rclone.lazydeck

rclone remote browser for lazydeck.

## Design

- `/rclone` lists all configured rclone remotes.
- Entering a remote delegates file browsing to `file.lazydeck` via a rclone provider.
- The plugin starts a local `rclone rcd` background process and all rclone operations go through the HTTP RC API.
- It intentionally does not implement arbitrary command input or UI features outside `file.lazydeck` provider capabilities.
- Directory listing skips modtime and MIME type by default for better performance on large directories / slower backends.

## Config

```lua
{
  dir = 'plugins/rclone.lazydeck',
  config = function()
    require('rclone').setup {
      rc_addr = '127.0.0.1:5572',
      auto_start = true,
    }
  end,
}
```
