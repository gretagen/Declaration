local gen = {}
gen.name = "subspaces_packages"

local subspace_dir = "/subspace"

-- Package manager commands for each distro
local distros = {
  arch = {
    list    = "pacman -Qeq",
    install = "pacman -S --noconfirm",
    remove  = "pacman -Rns --noconfirm",
  },
  debian = {
    list    = "dpkg --get-selections | grep -v deinstall | awk '{print $1}'",
    install = "apt-get install -y",
    remove  = "apt-get remove -y",
  },
  fedora = {
    list    = "dnf list installed --quiet 2>/dev/null | awk '{print $1}' | tail -n+3",
    install = "dnf install -y",
    remove  = "dnf remove -y",
  },
  opensuse = {
    list    = "rpm -qa --qf '%{NAME}\n'",
    install = "zypper install -y",
    remove  = "zypper remove -y",
  },
  gentoo = {
    list    = "qlist -I",
    install = "emerge",
    remove  = "emerge --deselect",
  },
  alpine = {
    list    = "apk info 2>/dev/null",
    install = "apk add",
    remove  = "apk del",
  },
  void = {
    list    = "xbps-query -m 2>/dev/null",
    install = "xbps-install -Sy",
    remove  = "xbps-remove -Ry",
  },
}

-- Read manifest of previously declared packages
--
-- Written by nothing here on purpose: gen.plan only plans, and sync.lua asks
-- for confirmation afterwards. Writing the manifest during planning would mean
-- a declined prompt or a failed install left the manifest claiming the change
-- was made, so the next run would see no diff and never retry. subspace-run
-- reports what is actually installed, which is the real source of truth here —
-- the manifest only decides what to *remove*.
local function read_manifest(path)
  local declared = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      local pkg = line:match("^%s*(.-)%s*$")
      if pkg and pkg ~= "" then
        declared[pkg] = true
      end
    end
    f:close()
  end
  return declared
end

function gen.plan(cfg, sync)
  local changes = {}

  for distro, cmds in pairs(distros) do
    local config_key = "packages-" .. distro
    local desired = cfg[config_key]
    if not desired or #desired == 0 then
      -- no packages declared for this distro, skip
    else
      -- Read previous manifest (what we previously declared)
      local manifest_path = subspace_dir .. "/.manifest/packages-" .. distro
      local prev_declared = read_manifest(manifest_path)

      -- List currently installed packages
      local listing = sync.shell_output("subspace-run " .. distro .. " " .. cmds.list .. " 2>/dev/null")
      local installed = {}
      for line in (listing .. "\n"):gmatch("([^\n]+)") do
        local pkg = line:match("^%s*(.-)%s*$")
        if pkg and pkg ~= "" then
          installed[pkg] = true
        end
      end

      -- Build desired set
      local desired_set = {}
      for _, pkg in ipairs(desired) do
        desired_set[pkg] = true
      end

      -- Install missing (desired but not installed)
      for _, pkg in ipairs(desired) do
        if not installed[pkg] then
          table.insert(changes, sync.change("+", "subspace-packages (" .. distro .. ")", pkg, nil,
            function(_, s)
              io.stderr:write("[apply] " .. distro .. ": installing " .. pkg .. "\n")
              local ok = s.shell("subspace-run " .. distro .. " " .. cmds.install .. " " .. pkg)
              if not ok then
                io.stderr:write("[warn] '" .. pkg .. "' — install failed in " .. distro .. "\n")
              end
              return ok
            end))
        end
      end

      -- Remove undeclared (previously declared but no longer desired)
      for pkg in pairs(prev_declared) do
        if not desired_set[pkg] then
          table.insert(changes, sync.change("-", "subspace-packages (" .. distro .. ")", pkg, nil,
            function(_, s)
              io.stderr:write("[apply] " .. distro .. ": removing " .. pkg .. "\n")
              local ok = s.shell("subspace-run " .. distro .. " " .. cmds.remove .. " " .. pkg)
              if not ok then
                io.stderr:write("[warn] '" .. pkg .. "' — removal failed in " .. distro .. "\n")
              end
              return ok
            end))
        end
      end

      end
    end

  return changes
end

return gen
