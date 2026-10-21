-- command.lua — house generator: run user-defined shell commands in order
--
-- Configuration (house.lua):
--   command = {
--     "git clone https://github.com/random/software",                   -- plain string: runs every sync
--     { cmd = "git clone https://github.com/gretagen/house-handlers",   -- record form
--       wd      = "/home/alice",
--       creates = "/home/alice/house-handlers" },   -- skip when this path exists
--     { cmd  = "make install",
--       check = "test -f /usr/local/bin/app" },     -- skip when this exits 0
--   }
--
-- Commands run in listed order, each under /bin/bash (never /bin/sh, which
-- may map to a minimal shell on Haliade system). When one command fails, the
-- rest of the sequence is skipped and the failure blocks the chronos
-- generation.

local gen = {}
gen.name = "command"

function gen.plan(cfg, house_sync)
  local changes = {}

  if not cfg.command or next(cfg.command) == nil then return {} end

  -- shared abort flag: stop the sequence at the first failure
  local aborted = false

  for i, entry in ipairs(cfg.command) do
    local cmd, wd, creates, check
    if type(entry) == "string" then
      cmd = entry
    elseif type(entry) == "table" then
      cmd, wd, creates, check = entry.cmd, entry.wd, entry.creates, entry.check
    end

    if type(cmd) ~= "string" or cmd == "" then
      house_sync.vprint("command[%d]: skipping invalid entry (missing string 'cmd')", i)
    else
      local display = (wd and wd .. " $ " or "") .. cmd

      -- creates/check are "already done" detectors: repower ignores them so
      -- every command genuinely reruns (a rebuild that skipped on its own
      -- hints would not be a rebuild)
      local skip_reason
      if not house_sync.repower then
        if creates and house_sync.file_exists(creates) then
          skip_reason = "creates exists: " .. creates
        elseif check and house_sync.shell_ok(check) then
          skip_reason = "check passed: " .. check
        end
      end

      if skip_reason then
        house_sync.vprint("command[%d]: %s — skipped (%s)", i, display, skip_reason)
      else
        local parts = {}
        if creates then table.insert(parts, "creates: " .. creates) end
        if check then table.insert(parts, "check: " .. check) end
        local detail = (#parts > 0) and table.concat(parts, "  ") or nil

        table.insert(changes, house_sync.change("+", "command", display, detail,
          function()
            if aborted then return false end

            local full = cmd
            if wd then
              local ok = house_sync.ensure_dir(wd)
              if not ok then aborted = true; return false end
              full = "cd " .. house_sync.shell_quote(wd) .. " && " .. full
            end

            local ok = house_sync.shell_live(full)
            if not ok then aborted = true; return false end
            return true
          end))
      end
    end
  end

  return changes
end

return gen