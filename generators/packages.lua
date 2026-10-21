local gen = {}
gen.name = "packages"

-- Declarative state lives under /var/db/declared (one empty file per package).
-- Imperative installs tracked by zeta under /var/db/zeta/packages are never
-- touched: the config only owns what it declares.

local DECLARED_DIR = "/var/db/declared"

local function shquote(s)
  if s:match("^[%w%._+-]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function valid_name(pkg)
  return pkg:match("^[A-Za-z0-9][A-Za-z0-9._+-]*$") ~= nil
end

-- repower rebuild for one package: repair its direct dependencies with
-- -Solve, then reinstall the package itself with -ReProvide.
local function rebuild(s, q)
  if not s.shell("zeta -Solve --pass " .. q) then
    io.stderr:write("[warn] " .. q .. ": zeta -Solve failed\n")
    return false
  end
  if not s.shell("zeta -ReProvide --pass --force " .. q) then
    io.stderr:write("[warn] " .. q .. ": zeta -ReProvide failed\n")
    return false
  end
  return true
end

local function list_dir(sync, dir)
  local seen = {}
  local out = sync.shell_output("ls -1 " .. shquote(dir))
  for line in (out .. "\n"):gmatch("([^\n]+)") do
    if line ~= "" and line ~= "packages" and line ~= "dependencies" and valid_name(line) then
      seen[line] = true
    end
  end
  return seen
end

function gen.plan(cfg, sync)
  local changes = {}
  local desired_list = cfg["packages-haliade"] or {}

  local declared = list_dir(sync, DECLARED_DIR)
  local tracked = list_dir(sync, "/var/db/zeta/packages")

  local desired = {}
  for _, pkg in ipairs(desired_list) do
    if valid_name(pkg) then
      desired[pkg] = true
    else
      io.stderr:write("[warn] skipping invalid package name '" .. tostring(pkg) .. "'\n")
    end
  end

  -- install declared packages that are not yet owned by config
  for _, pkg in ipairs(desired_list) do
    if desired[pkg] and not declared[pkg] then
      table.insert(changes, sync.change("+", "packages-haliade", pkg, nil,
        function(_, s)
          local q = shquote(pkg)
          if not tracked[pkg] then
            if not s.shell("zeta -Provide --pass --force " .. q) then
              io.stderr:write("[warn] '" .. pkg .. "' — not found, network error, or build failure\n")
              return false
            end
          elseif sync.repower then
            -- already installed but only now entering the declaration:
            -- rebuild it like any other declared package
            if not rebuild(s, q) then return false end
          end
          s.shell("mkdir -p " .. shquote(DECLARED_DIR))
          return s.shell("touch " .. shquote(DECLARED_DIR .. "/" .. pkg))
        end))
    end
  end

  -- repower: rebuild every declared package: repair its direct dependencies
  -- with -Solve, then reinstall the package itself with -ReProvide. This is
  -- the zeta equivalent of nixos-rebuild switch, and it is what makes a
  -- converged run produce changes instead of "already synchronized".
  if sync.repower then
    for _, pkg in ipairs(desired_list) do
      if desired[pkg] and declared[pkg] then
        local q = shquote(pkg)
        table.insert(changes, sync.change("~", "packages-haliade", pkg,
          "rebuild : zeta -Solve, then -ReProvide",
          function(_, s) return rebuild(s, q) end))
      end
    end
  end

  -- remove declared packages that are no longer desired
  local undeclared = {}
  for pkg in pairs(declared) do
    if not desired[pkg] then undeclared[#undeclared + 1] = pkg end
  end
  table.sort(undeclared)

  for _, pkg in ipairs(undeclared) do
    table.insert(changes, sync.change("-", "packages-haliade", pkg, nil,
      function(_, s)
        if tracked[pkg] then
          if not s.shell("zeta -Remove --pass --force " .. shquote(pkg)) then
            io.stderr:write("[warn] '" .. pkg .. "' — could not be removed\n")
            return false
          end
        end
        return s.shell("rm -f " .. shquote(DECLARED_DIR .. "/" .. pkg))
      end))
  end

  return changes
end

return gen