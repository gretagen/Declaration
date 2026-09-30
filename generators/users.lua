local gen = {}
gen.name = "users"

-- Users are declared keyed by username:
--   users = { ["alice"] = { groups = {...}, shell = "...", ssh_keys = {...} } }
-- Fields are optional. Declared users are created if missing and their
-- authorized_keys converge; undeclared users (UID >= 1000) are removed
-- with their home directories.

-- Usernames are interpolated unquoted into useradd/userdel, so restrict to
-- shell-safe characters and forbid a leading dash (would parse as a flag).
local function valid_name(name)
  return type(name) == "string" and name:match("^[%w][%w._-]*$") ~= nil
end

local function keys_content(keys)
  if #keys == 0 then return "" end
  return table.concat(keys, "\n") .. "\n"
end

function gen.plan(cfg, sync)
  local changes = {}

  -- Parse /etc/passwd into all accounts plus the removable set.
  -- THREE captures: an earlier version wrote `name, _, uid` against a
  -- two-capture pattern, binding the UID to the throwaway and leaving uid
  -- nil — no user was ever detected, so declared users were re-planned
  -- (and useradd re-failed) on every single run.
  local passwd = sync.read_file("/etc/passwd") or ""
  local all = {}       -- name -> uid (every account, any uid)
  local removable = {}  -- name -> uid (UID >= 1000 only)
  for line in passwd:gmatch("[^\n]+") do
    local name, _, uid = line:match("^([^:]+):([^:]*):(%d+):")
    if name and uid then
      local u = tonumber(uid)
      if u then
        all[name] = u
        if u >= 1000 then removable[name] = u end
      end
    end
  end

  -- Old array format guard: numeric keys mean the previous schema
  -- ({ {username = "alice"} }). Bail out entirely rather than planning
  -- useradd/userdel for everything — nothing would match a keyed lookup,
  -- which would otherwise delete every user on the system.
  for key in pairs(cfg.users) do
    if type(key) ~= "string" then
      io.stderr:write("[warn] users: numeric keys found — old array format; "
        .. 'update definition to ["name"] = { ... }\n')
      return {}
    end
  end

  local desired = {}
  for name, spec in pairs(cfg.users) do
    if not valid_name(name) then
      io.stderr:write("[warn] users: skipping invalid username '" .. tostring(name) .. "'\n")
    elseif type(spec) ~= "table" then
      -- protect an existing account of that name from removal, plan nothing
      io.stderr:write("[warn] users: entry '" .. name .. "' must be a table, got "
        .. type(spec) .. " — ignoring fields\n")
      desired[name] = {}
    else
      desired[name] = spec
    end
  end

  -- create missing users (existence checked by name for ANY uid — filtering
  -- detection by UID >= 1000 is what left existing users looking absent)
  for name, spec in pairs(desired) do
    if not all[name] then
      local groups = ""
      if spec.groups ~= nil then
        if type(spec.groups) == "table" and #spec.groups > 0 then
          groups = " -G " .. table.concat(spec.groups, ",")
        else
          io.stderr:write("[warn] users: '" .. name .. "' groups must be a non-empty list — ignoring\n")
        end
      end
      local shell = "/bin/bash"
      if spec.shell ~= nil then
        if type(spec.shell) == "string" then
          shell = spec.shell
        else
          io.stderr:write("[warn] users: '" .. name .. "' shell must be a string — using /bin/bash\n")
        end
      end
      table.insert(changes, sync.change("+", "users", name, nil,
        function()
          return sync.shell("useradd -m -s " .. shell .. groups .. " " .. name)
        end))
    end
  end

  -- converge authorized_keys: ssh_keys present = manage (also for users that
  -- already exist, so keys can be added/removed without deleting the user),
  -- absent = leave the file alone. Applies as "~" after the "+" creates
  -- (sync sorts + before ~), so a fresh user's home exists by then.
  for name, spec in pairs(desired) do
    if spec.ssh_keys ~= nil then
      if type(spec.ssh_keys) ~= "table" then
        io.stderr:write("[warn] users: '" .. name .. "' ssh_keys must be a list — ignoring\n")
      else
        local wanted = keys_content(spec.ssh_keys)
        local path = "/home/" .. name .. "/.ssh/authorized_keys"
        if sync.read_file(path) ~= wanted then
          table.insert(changes, sync.change("~", "users", name .. " ssh_keys", path,
            function()
              local ssh_dir = "/home/" .. name .. "/.ssh"
              sync.ensure_dir(ssh_dir)
              if not sync.write_file(path, wanted) then return false end
              sync.shell("chown -R " .. name .. ":" .. name .. " " .. ssh_dir)
              return sync.shell("chmod 700 " .. ssh_dir .. " && chmod 600 " .. path)
            end))
        end
      end
    end
  end

  -- remove undeclared users (UID >= 1000), home included
  for name in pairs(removable) do
    if not desired[name] then
      table.insert(changes, sync.change("-", "users", name, nil,
        function() return sync.shell("userdel -r " .. name) end))
    end
  end

  return changes
end

return gen
