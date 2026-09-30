local gen = {}
gen.name = "init"

-- Known init binaries, matched by suffix exactly like iniswap's
-- detect_current_init (*/openrc-init, */runit-init, */dinit). Note dinit has
-- no -init wrapper: iniswap writes init=/sbin/dinit, and matching by suffix
-- keeps /sbin vs /usr/sbin irrelevant.
local valid_inits = { "openrc", "runit", "dinit" }

local init_suffixes = {
  { pattern = "/openrc%-init$", name = "openrc" },
  { pattern = "/runit%-init$",  name = "runit" },
  { pattern = "/dinit$",        name = "dinit" },
}

-- Detect the init declared in limine.conf. Returns "openrc" when no init=
-- param is present (the default), or "unknown" when a param exists but
-- matches nothing we know. Anchored to start/whitespace so params whose
-- name merely ends in "init=" (e.g. "reinit=5") don't false-match — the
-- same anchoring boot.lua uses when preserving the param.
local function detect_declared(content)
  local line = content:match("cmdline:%s*(%S[^\n]*)")
  local init_param
  if line then
    init_param = line:match("^init=%S+") or line:match("%s(init=%S+)")
  end
  if not init_param then
    return "openrc"
  end
  for _, entry in ipairs(init_suffixes) do
    if init_param:match(entry.pattern) then
      return entry.name
    end
  end
  return "unknown"
end

-- The init the universal shutdown/reboot wrappers will act on next boot.
-- /var/db/init/current is written by iniswap on every swap; a boot.lua
-- cmdline rebuild that dropped init= used to leave this stale, so treat a
-- mismatch as drift to repair. Read via sync so it stays testable.
local function read_init_db(sync)
  local content = sync.read_file("/var/db/init/current")
  if not content then return nil end
  local value = content:match("^[^\n]+")
  if value then value = value:gsub("%s+$", "") end
  if value == "" then return nil end
  return value
end

local function write_init_db(sync, desired)
  return sync.write_file("/var/db/init/current", desired .. "\n")
end

function gen.plan(cfg, sync)
  local changes = {}
  local desired = cfg.init

  -- validate before anything else (replaces the old dead "unknown" check
  -- that tested the wrong variable)
  local is_valid = false
  for _, name in ipairs(valid_inits) do
    if name == desired then is_valid = true break end
  end
  if not is_valid then
    io.stderr:write("[warn] init: invalid init '" .. tostring(desired)
      .. "' in config (valid: " .. table.concat(valid_inits, ", ") .. "), skipping\n")
    return {}
  end

  local limine = "/boot/limine.conf"
  local content = sync.read_file(limine)
  if not content then
    io.stderr:write("[warn] init: cannot read " .. limine .. "\n")
    return {}
  end

  local current = detect_declared(content)
  local swap_planned = false

  if current ~= desired then
    if current == "unknown" then
      -- iniswap does its own detection and strips any init= before writing,
      -- so swapping away from an unrecognized param is safe.
      io.stderr:write("[warn] init: unrecognized init= in " .. limine .. ", swapping anyway\n")
    end
    swap_planned = true
    table.insert(changes, sync.change("~", "init", desired,
      "swap init from " .. current .. " to " .. desired,
      function(_, s)
        local ok = s.shell("iniswap --pass " .. desired)
        if not ok then
          io.stderr:write("[error] init: iniswap " .. desired .. " failed\n")
        end
        return ok
      end))
  end

  -- Repair stale /var/db/init: the wrappers read current (then previous)
  -- to pick a shutdown tool, so it must match what limine.conf will boot.
  -- iniswap only records on an actual swap — a silent cmdline overwrite
  -- left the db claiming an init that no longer runs. Skip when a swap is
  -- planned: iniswap records the db itself, and a plan-time repair would
  -- apply after it and clobber the fresh value.
  local db = read_init_db(sync)
  if not swap_planned and current ~= "unknown" and db ~= current then
    table.insert(changes, sync.change("~", "init", "/var/db/init/current",
      (db or "(unset)") .. "  →  " .. current .. " (align with limine.conf)",
      function(_, s)
        -- roll current into previous only if current holds a different,
        -- real value — mirrors iniswap's record_init_state ordering
        if db and db ~= current then
          s.write_file("/var/db/init/previous", db .. "\n")
        end
        return write_init_db(s, current)
      end))
  end

  return changes
end

return gen
