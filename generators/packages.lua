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

  local declared = list_dir(sync, DECLARED_DIR)
  local tracked = list_dir(sync, "/var/db/zeta/packages")

  local desired = {}
  for _, pkg in ipairs(cfg.packages) do
    if valid_name(pkg) then
      desired[pkg] = true
    else
      io.stderr:write("[warn] skipping invalid package name '" .. tostring(pkg) .. "'\n")
    end
  end

  -- install declared packages that are not yet owned by config
  for _, pkg in ipairs(cfg.packages) do
    if desired[pkg] and not declared[pkg] then
      table.insert(changes, sync.change("+", "packages", pkg, nil,
        function(_, s)
          local q = shquote(pkg)
          if not tracked[pkg] then
            if not s.shell("zeta -Provide --pass --force " .. q) then
              io.stderr:write("[warn] '" .. pkg .. "' — not found, network error, or build failure\n")
              return false
            end
          end
          s.shell("mkdir -p " .. shquote(DECLARED_DIR))
          return s.shell("touch " .. shquote(DECLARED_DIR .. "/" .. pkg))
        end))
    end
  end

  -- remove declared packages that are no longer desired
  local undeclared = {}
  for pkg in pairs(declared) do
    if not desired[pkg] then undeclared[#undeclared + 1] = pkg end
  end
  table.sort(undeclared)

  for _, pkg in ipairs(undeclared) do
    table.insert(changes, sync.change("-", "packages", pkg, nil,
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