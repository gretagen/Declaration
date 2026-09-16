local gen = {}
gen.name = "users"

function gen.plan(cfg, sync)
  local changes = {}

  local passwd = sync.read_file("/etc/passwd") or ""
  local existing = {}
  for line in passwd:gmatch("[^\n]+") do
    local name, _, uid = line:match("^([^:]+):[^:]*:(%d+):")
    if name and uid then
      local u = tonumber(uid)
      if u and u >= 1000 then
        existing[name] = u
      end
    end
  end

  local desired = {}
  for _, u in ipairs(cfg.users) do
    desired[u.username] = u
  end

  -- add missing users
  for _, u in ipairs(cfg.users) do
    if not existing[u.username] then
      local groups = ""
      if u.groups and #u.groups > 0 then
        groups = " -G " .. table.concat(u.groups, ",")
      end
      local shell = u.shell or "/bin/bash"
      table.insert(changes, sync.change("+", "users", u.username, nil,
        function()
          local ok = sync.shell("useradd -m -s " .. shell .. groups .. " " .. u.username)
          if ok and u.ssh_keys and #u.ssh_keys > 0 then
            local ssh_dir = "/home/" .. u.username .. "/.ssh"
            local auth_keys = table.concat(u.ssh_keys, "\n") .. "\n"
            sync.ensure_dir(ssh_dir)
            sync.write_file(ssh_dir .. "/authorized_keys", auth_keys)
            sync.shell("chown -R " .. u.username .. ":" .. u.username .. " " .. ssh_dir)
            sync.shell("chmod 700 " .. ssh_dir .. " && chmod 600 " .. ssh_dir .. "/authorized_keys")
          end
          return ok
        end))
    end
  end

  -- remove unexpected users (UID >= 1000)
  for name, uid in pairs(existing) do
    if not desired[name] then
      table.insert(changes, sync.change("-", "users", name, nil,
        function() return sync.shell("userdel -r " .. name) end))
    end
  end

  return changes
end

return gen
