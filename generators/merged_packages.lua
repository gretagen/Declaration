local gen = {}
gen.name = "merged_packages"

local subspace_dir = "/subspace"
local manifest_dir = "/var/db"

-- Distros that can be merged (glibc-based only)
local mergeable = {
  arch = true, debian = true, fedora = true, opensuse = true, gentoo = true, void = true,
}

-- Musl distros that cannot be merged
local musl = { alpine = true }

-- Read manifest of previously merged packages
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

-- Write manifest of currently merged packages
local function write_manifest(path, desired_set)
  local dir = path:match("^(.*/)")
  if dir then os.execute("mkdir -p '" .. dir .. "'") end
  local f, err = io.open(path, "w")
  if not f then
    io.stderr:write("[warn] failed to write manifest: " .. (err or "unknown") .. "\n")
    return
  end
  local sorted = {}
  for pkg in pairs(desired_set) do
    sorted[#sorted + 1] = pkg
  end
  table.sort(sorted)
  for _, pkg in ipairs(sorted) do
    f:write(pkg .. "\n")
  end
  f:close()
end

function gen.plan(cfg, sync)
  local changes = {}

  -- Collect all merged-* keys from config
  for key, desired in pairs(cfg) do
    local distro = key:match("^merged%-(.+)$")
    if distro then
      -- Validate distro
      if musl[distro] then
        io.stderr:write("[warn] merged_packages: skipping '" .. distro .. "' — musl distro cannot be merged onto glibc host\n")
      elseif not mergeable[distro] then
        io.stderr:write("[warn] merged_packages: unknown distro '" .. distro .. "'\n")
      elseif not desired or #desired == 0 then
        -- empty list, nothing to do
      else
        -- Read manifest of previously merged packages
        local manifest_path = manifest_dir .. "/merged-" .. distro
        local prev_merged = read_manifest(manifest_path)

        -- Build desired set
        local desired_set = {}
        for _, pkg in ipairs(desired) do
          desired_set[pkg] = true
        end

        -- Install missing (desired but not previously merged)
        for _, pkg in ipairs(desired) do
          if not prev_merged[pkg] then
            table.insert(changes, sync.change("+", "merged-packages (" .. distro .. ")", pkg, nil,
              function(_, s)
                io.stderr:write("[apply] merged-" .. distro .. ": installing " .. pkg .. " onto host\n")
                local ok = s.shell("subspace-merge --pass " .. distro .. " " .. pkg)
                if not ok then
                  io.stderr:write("[warn] '" .. pkg .. "' — install failed in " .. distro .. "\n")
                end
                return ok
              end))
          end
        end

        -- Remove undeclared (previously merged but no longer desired)
        local undeclared = {}
        for pkg in pairs(prev_merged) do
          if not desired_set[pkg] then
            undeclared[#undeclared + 1] = pkg
          end
        end
        table.sort(undeclared)

        for _, pkg in ipairs(undeclared) do
          table.insert(changes, sync.change("-", "merged-packages (" .. distro .. ")", pkg, nil,
            function(_, s)
              io.stderr:write("[apply] merged-" .. distro .. ": removing " .. pkg .. " from host\n")
              local ok = s.shell("subspace-unmerge --pass " .. distro .. " " .. pkg)
              if not ok then
                io.stderr:write("[warn] '" .. pkg .. "' — removal failed in " .. distro .. "\n")
              end
              return ok
            end))
        end

        -- Update manifest for next run
        write_manifest(manifest_path, desired_set)
      end
    end
  end

  return changes
end

-- Post-merge hooks: run after all packages for a distro are installed
-- These update desktop databases, icon caches, font caches, etc.
local post_merge_hooks = {
  "update-desktop-database /usr/share/applications/ 2>/dev/null || true",
  "gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true",
  "fc-cache -f 2>/dev/null || true",
  "glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true",
  "ldconfig 2>/dev/null || true",
  -- KDE Plasma: create qdbus symlink if qdbus6 exists but qdbus doesn't
  "[ -x /usr/bin/qdbus6 ] && [ ! -e /usr/bin/qdbus ] && ln -sf /usr/bin/qdbus6 /usr/bin/qdbus 2>/dev/null; true",
  -- Remove older wayland libs from merge dirs if host has newer version
  -- This prevents symbol lookup errors like wl_fixes_interface
  "host_wl=$(readlink -f /usr/lib/libwayland-client.so.0 2>/dev/null); " ..
  "for d in /usr/lib/{arch,debian,fedora,opensuse,void}-merge; do " ..
  "  [ -f \"$d/libwayland-client.so.0\" ] || continue; " ..
  "  merge_wl=$(readlink -f \"$d/libwayland-client.so.0\" 2>/dev/null); " ..
  "  [ -f \"$host_wl\" ] && [ -f \"$merge_wl\" ] && " ..
  "  [ \"$(stat -c %Y \"$host_wl\" 2>/dev/null || echo 0)\" -gt \"$(stat -c %Y \"$merge_wl\" 2>/dev/null || echo 0)\" ] && " ..
  "  rm -f \"$d\"/libwayland*.so* 2>/dev/null; " ..
  "done; true",
}

function gen.post_merge(sync)
  for _, hook in ipairs(post_merge_hooks) do
    sync.shell(hook)
  end
end

return gen
