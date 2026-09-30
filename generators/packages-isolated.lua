local gen = {}
gen.name = "packages-isolated"

-- Isolated packages live in their own store (/zeta/reserve/<pkg>-<version>)
-- and are tracked by zeta under /var/db/zeta/isolated. Declarative state is
-- kept apart from the normal packages list in /var/db/declared-isolated so
-- the two generators never see each other's entries.

local DECLARED_DIR = "/var/db/declared-isolated"
local ZETA_ISOLATED_DIR = "/var/db/zeta/isolated"

local function shquote(s)
  if s:match("^[%w%._+-]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function valid_name(pkg)
  return pkg:match("^[A-Za-z0-9][A-Za-z0-9._+-]*$") ~= nil
end

local function list_dir(sync, dir)
  local seen = {}
  local out = sync.shell_output("ls -1 " .. shquote(dir))
  for line in (out .. "\n"):gmatch("([^\n]+)") do
    if line ~= "" and valid_name(line) then
      seen[line] = true
    end
  end
  return seen
end

function gen.plan(cfg, sync)
  local changes = {}
  local desired_list = cfg["packages-isolated"] or {}

  local declared = list_dir(sync, DECLARED_DIR)
  local tracked = list_dir(sync, ZETA_ISOLATED_DIR)

  local desired = {}
  for _, pkg in ipairs(desired_list) do
    if valid_name(pkg) then
      desired[pkg] = true
    else
      io.stderr:write("[warn] skipping invalid package name '" .. tostring(pkg) .. "'\n")
    end
  end

  -- install declared isolated packages that are not yet owned by config
  for _, pkg in ipairs(desired_list) do
    if desired[pkg] and not declared[pkg] then
      table.insert(changes, sync.change("+", "packages-isolated", pkg, nil,
        function(_, s)
          local q = shquote(pkg)
          if not tracked[pkg] then
            if not s.shell("zeta -Provide --pass --force --isolate " .. q) then
              io.stderr:write("[warn] '" .. pkg .. "' — not found, network error, or build failure\n")
              return false
            end
          end
          s.shell("mkdir -p " .. shquote(DECLARED_DIR))
          return s.shell("touch " .. shquote(DECLARED_DIR .. "/" .. pkg))
        end))
    end
  end

  -- remove declared isolated packages that are no longer desired
  local undeclared = {}
  for pkg in pairs(declared) do
    if not desired[pkg] then undeclared[#undeclared + 1] = pkg end
  end
  table.sort(undeclared)

  for _, pkg in ipairs(undeclared) do
    table.insert(changes, sync.change("-", "packages-isolated", pkg, nil,
      function(_, s)
        if tracked[pkg] then
          if not s.shell("zeta -Remove --pass --force --isolate " .. shquote(pkg)) then
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
