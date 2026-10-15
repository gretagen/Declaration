-- plugins.lua — resolve which generators haliade-synchronize enables.
--
-- The enable list lives in /etc/haliade/enabled_modules.lua (user-edited,
-- never owned by a package, so a declaration update can never clobber it).
-- sync.lua owns no list of its own anymore: it just asks this module
-- "who's enabled?" and iterates whatever comes back.
--
--   file missing → built-in default list (fresh installs, package tests)
--   file present → replaces the default entirely: add a generator name to
--                  enable it, remove one to disable it
--   file broken  → hard error naming the file (never sync with a half-read
--                  list)
--
-- Order in the return list is respected by the loader (collection is stable),
-- so the file can also order generators where that matters — subspaces must
-- run before subspaces_packages/merged_packages.

local plugins = {}

local DEFAULT_ENABLED_FILE = "/etc/haliade/enabled_modules.lua"

-- Built-in default, used when the enable file does not exist. Keep in sync
-- with the file shipped in the rootfs (etc/haliade/enabled_modules.lua).
local DEFAULT_GENERATORS = {
  "hostname", "timezone", "locale", "hwclock", "keymap",
  "console_font", "env", "boot", "init", "packages", "packages-isolated",
  "subspaces", "subspaces_packages", "merged_packages",
  "users", "network", "fstab",
  "rc-services", "runit-services", "dinit-services", "sysmd-services",
  "modules",
  "ssh", "edit",
}

-- Load the enable file. Accepts both forms:
--   local enabled_generators = { ... }          (no return — see rootfs sketch)
--   return { ... }                              (already-returning file)
-- A missing file yields nil; the caller falls back to DEFAULT_GENERATORS.
-- Any other failure (syntax error, runtime error, wrong shape) is a hard
-- error that names the file, so a corrupt enable list can never silently
-- produce a partial sync.
local function load_enabled_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()

  -- Try the file as-is first: handles files that already return the list.
  local chunk, err = load(src, "@" .. path)
  if not chunk then
    error("plugin enable file " .. path .. ": " .. tostring(err), 0)
  end
  local ok, res = pcall(chunk)
  if not ok then
    error("plugin enable file " .. path .. ":\n" .. tostring(res), 0)
  end
  if type(res) == "table" then
    return res
  end

  -- No table returned: the file must be using the `local enabled_generators`
  -- form, so re-chunk with a return appended to read it back from the same
  -- scope. (Only reached when the as-is chunk ran without returning a table.)
  local chunk2, err2 = load(src .. "\nreturn enabled_generators", "@" .. path .. " (+return)")
  if not chunk2 then
    -- The as-is chunk compiled and ran, so a second top-level return can only
    -- fail here; the file already returned something non-table.
    error("plugin enable file " .. path .. " must define local enabled_generators = { ... }"
      .. " or return the list (file ended by returning a " .. type(res) .. ")", 0)
  end
  local ok2, res2 = pcall(chunk2)
  if not ok2 then
    error("plugin enable file " .. path .. ":\n" .. tostring(res2), 0)
  end
  if type(res2) ~= "table" then
    error("plugin enable file " .. path ..
      " must define local enabled_generators = { ... } or return the list", 0)
  end
  return res2
end

-- Return the list of enabled generators for a sync run. The optional argument
-- overrides the default file location (used by package tests).
function plugins.enabled_generators(path)
  local list = load_enabled_file(path or DEFAULT_ENABLED_FILE)
  if list == nil then
    return DEFAULT_GENERATORS
  end
  return list
end

return plugins