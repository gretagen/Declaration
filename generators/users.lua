local gen = {}
gen.name = "users"

-- Users are declared keyed by username:
--   users = { ["alice"] = { groups = {...}, shell = "...", ssh_keys = {...} } }
-- Fields are optional. Declared users are created if missing; groups, shell
-- and authorized_keys converge every run (adding "input" to an existing
-- account works, as does removing one); undeclared users (UID >= 1000) are
-- removed with their home directories.

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
  local shells = {}    -- name -> login shell (field 7)
  local removable = {}  -- name -> uid (UID >= 1000 only)
  for line in passwd:gmatch("[^\n]+") do
    local name, _, uid, shell = line:match("^([^:]+):([^:]*):(%d+):[^:]*:[^:]*:[^:]*:([^:]*)")
    if name and uid then
      local u = tonumber(uid)
      if u then
        all[name] = u
        shells[name] = shell or ""
        if u >= 1000 then removable[name] = u end
      end
    end
  end

  -- Parse /etc/group: supplementary-group reality, also used to validate
  -- that declared groups exist before planning a usermod.
  local member_of = {}    -- user -> { group = true }
  local member_count = {} -- user -> number of supplementary groups
  local exists = {}       -- group -> true
  local groupfile = sync.read_file("/etc/group") or ""
  for line in groupfile:gmatch("[^\n]+") do
    local gname, members = line:match("^([^:]+):[^:]*:%d+:(.*)$")
    if gname then
      exists[gname] = true
      if members and members ~= "" then
        for m in members:gmatch("[^,]+") do
          local s = member_of[m]
          if not s then s = {}; member_of[m] = s end
          if not s[gname] then
            s[gname] = true
            member_count[m] = (member_count[m] or 0) + 1
          end
        end
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

  -- converge groups + shell for users that already exist — create sets them
  -- once at useradd, so without this pass editing definition.lua would never
  -- change an existing account (adding "input" to alice does nothing).
  -- Groups use REPLACE semantics: the declared list is the FULL desired
  -- supplementary set, so hand-added groups not in the declaration are
  -- removed too. Every diff shows up in the plan preview before apply.
  for name, spec in pairs(desired) do
    if all[name] then
      -- supplementary groups
      if spec.groups ~= nil then
        if type(spec.groups) == "table" and #spec.groups > 0 then
          local want, seen, bad = {}, {}, false
          for _, g in ipairs(spec.groups) do
            if type(g) ~= "string" then
              bad = true
            elseif not seen[g] then
              seen[g] = true
              want[#want + 1] = g
            end
          end
          if bad then
            io.stderr:write("[warn] users: '" .. name .. "' groups must be strings — ignoring\n")
          elseif #want == 0 then
            io.stderr:write("[warn] users: '" .. name .. "' groups must be a non-empty list — ignoring\n")
          else
            -- validate against /etc/group first: a usermod -G with a
            -- nonexistent group fails on every sync, and under replace
            -- semantics a partial -G would silently drop the missing group.
            local missing = {}
            for _, g in ipairs(want) do
              if not exists[g] then missing[#missing + 1] = g end
            end
            if #missing > 0 then
              io.stderr:write("[warn] users: '" .. name .. "' group(s) '" .. table.concat(missing, "', '")
                .. "' do not exist in /etc/group — skipping group sync\n")
            else
              local cur = member_of[name]
              local same = (member_count[name] or 0) == #want
              if same and cur then
                for _, g in ipairs(want) do
                  if not cur[g] then same = false break end
                end
              end
              if not same then
                local joined = table.concat(want, ",")
                table.insert(changes, sync.change("~", "users", name .. " groups", joined,
                  function()
                    return sync.shell("usermod -G " .. joined .. " " .. name)
                  end))
              end
            end
          end
        else
          io.stderr:write("[warn] users: '" .. name .. "' groups must be a non-empty list — ignoring\n")
        end
      end
      -- login shell
      if spec.shell ~= nil then
        if type(spec.shell) == "string" then
          if shells[name] ~= spec.shell then
            local sh = spec.shell
            table.insert(changes, sync.change("~", "users", name .. " shell", sh,
              function()
                return sync.shell("usermod -s " .. sh .. " " .. name)
              end))
          end
        else
          io.stderr:write("[warn] users: '" .. name .. "' shell must be a string — ignoring\n")
        end
      end
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
