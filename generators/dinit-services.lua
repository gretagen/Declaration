local gen = {}
gen.name = "dinit-services"

-- Dinit services: ensure each entry in ["dinit-services"] is enabled via a
-- symlink in /etc/dinit.d/boot.d. Add-only — services dropped from the list
-- are left enabled (not disabled).
--
-- Service definitions ship in the rootfs (/etc/dinit.d/<name>); this
-- generator only toggles enablement, it never writes dinit definitions.

function gen.plan(cfg, sync)
  local changes = {}
  local defs_dir = "/etc/dinit.d"
  local boot_dir = defs_dir .. "/boot.d"

  local enabled = {}
  local ls = sync.shell_output("ls -1 " .. boot_dir .. " 2>/dev/null")
  for name in ls:gmatch("[^\n]+") do
    enabled[name] = true
  end

  for _, svc in ipairs(cfg["dinit-services"] or {}) do
    if enabled[svc] then
      -- already enabled
    elseif sync.read_file(defs_dir .. "/" .. svc) then
      table.insert(changes, sync.change("+", "dinit-services", svc, "enable in boot.d",
        function()
          sync.shell("mkdir -p " .. boot_dir)
          return sync.shell("ln -sfn ../" .. svc .. " " .. boot_dir .. "/" .. svc)
        end))
    else
      io.stderr:write("[warn] dinit-services: no dinit definition for '" .. svc .. "', skipping\n")
    end
  end

  return changes
end

return gen
