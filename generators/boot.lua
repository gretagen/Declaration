local gen = {}
gen.name = "boot"

function gen.plan(cfg, sync)
  local path = "/boot/limine.conf"
  local content = sync.read_file(path)
  if not content then return {} end

  local changes = {}
  local new = content
  local globals_dirty = false

  -- timeout
  if cfg.boot.timeout then
    local t = tostring(cfg.boot.timeout)
    local updated, n = new:gsub("timeout:%s*%d+", "timeout: " .. t, 1)
    if n > 0 then
      new = updated
    elseif not new:match("timeout:") then
      new = "timeout: " .. t .. "\n" .. new
      globals_dirty = true
    end
    if new ~= content then globals_dirty = true end
  end

  -- wallpaper (only if key already present or explicitly set)
  if cfg.boot.wallpaper and cfg.boot.wallpaper ~= "" then
    if new:match("wallpaper:") then
      new = new:gsub("wallpaper:%s*.*", "wallpaper: " .. cfg.boot.wallpaper, 1)
      if not new:match("wallpaper_style:") then
        new = new:gsub("(wallpaper:%s*.*)", "%1\nwallpaper_style: stretched", 1)
      else
        new = new:gsub("wallpaper_style:%s*.*", "wallpaper_style: stretched", 1)
      end
    end
  end

  -- serial
  if cfg.boot.serial then
    if new:match("serial:") then
      new = new:gsub("serial:%s*%w+", "serial: yes", 1)
    end
  end

  if new ~= content then
    globals_dirty = true
  end

  -- Build desired shared cmdline extras (root identity + kernel_cmdline)
  -- Applied via genzee rewrite-limine after patching one existing cmdline.
  local cmdline_parts = {}
  if cfg.root_partuuid and cfg.root_partuuid ~= "PLACEHOLDER" then
    table.insert(cmdline_parts, "root=PARTUUID=" .. cfg.root_partuuid)
  else
    local current_cmdline_str = content:match("cmdline:%s*(%S[^\n]*)")
    if current_cmdline_str then
      local existing_root = current_cmdline_str:match("(root=%S+)")
      if existing_root then
        table.insert(cmdline_parts, existing_root)
      end
    end
  end

  -- Preserve rootflags from current default entry
  local current_cmdline_str = content:match("cmdline:%s*(%S[^\n]*)")
  local rootflags = current_cmdline_str and current_cmdline_str:match("(rootflags=%S+)")
  if rootflags then
    table.insert(cmdline_parts, rootflags)
  else
    table.insert(cmdline_parts, "rootflags=subvol=@")
  end
  table.insert(cmdline_parts, "rw")

  if cfg.kernel_cmdline and cfg.kernel_cmdline ~= "" then
    table.insert(cmdline_parts, cfg.kernel_cmdline)
  end

  local desired_cmdline = table.concat(cmdline_parts, " ")
  local need_cmdline = false
  if current_cmdline_str and current_cmdline_str ~= desired_cmdline then
    need_cmdline = true
    -- Patch only the first (default /Haliade OS) cmdline so genzee can
    -- harvest extras; full multi-entry rewrite happens via genzee.
    new = new:gsub("cmdline:%s*[^\n]*", "cmdline: " .. desired_cmdline, 1)
  end

  if globals_dirty or need_cmdline or new ~= content then
    table.insert(changes, sync.change("~", "boot", "/boot/limine.conf",
      "update bootloader globals/cmdline", function()
        sync.write_file(path, new)
        -- Regenerate generation entries from snapshots
        sync.shell("genzee rewrite-limine")
      end))
  end

  return changes
end

return gen
