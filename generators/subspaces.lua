local gen = {}
gen.name = "subspaces"

local valid_distros = {
  debian = true, alpine = true, gentoo = true, void = true,
  fedora = true, opensuse = true, arch = true,
}

function gen.plan(cfg, sync)
  local changes = {}

  local subspace_dir = "/subspace"

  -- scan installed subspaces (look for /usr directory inside each)
  local installed = {}
  local ls = sync.shell_output("ls -1d " .. subspace_dir .. "/*/usr 2>/dev/null")
  for entry in (ls .. "\n"):gmatch("([^\n]+)") do
    if entry ~= "" then
      local name = entry:match(subspace_dir .. "/([^/]+)/usr")
      if name then installed[name] = true end
    end
  end

  -- build desired set
  local desired = {}
  for _, distro in ipairs(cfg.subspaces) do
    desired[distro] = true
  end

  -- warn about unknown distro names
  for _, distro in ipairs(cfg.subspaces) do
    if not valid_distros[distro] then
      io.stderr:write("[warn] subspaces: unknown distro '" .. distro .. "'\n")
      io.stderr:write("  supported: debian, alpine, gentoo, void, fedora, opensuse, arch\n")
    end
  end

  -- install missing
  for _, distro in ipairs(cfg.subspaces) do
    if valid_distros[distro] and not installed[distro] then
      table.insert(changes, sync.change("+", "subspaces", distro, nil,
        function(_, s)
          io.stderr:write("[apply] installing " .. distro .. " subspace...\n")
          local ok = s.shell("subspace-cli install " .. distro)
          if not ok then
            io.stderr:write("[warn] '" .. distro .. "' — installation failed\n")
          end
          return ok
        end))
    end
  end

  -- remove unexpected
  local undeclared = {}
  for name in pairs(installed) do
    if not desired[name] then undeclared[#undeclared + 1] = name end
  end
  table.sort(undeclared)

  for _, distro in ipairs(undeclared) do
    table.insert(changes, sync.change("-", "subspaces", distro, nil,
      function(_, s)
        io.stderr:write("[apply] removing " .. distro .. " subspace...\n")
        local ok = s.shell("subspace-cli remove " .. distro)
        if not ok then
          io.stderr:write("[warn] '" .. distro .. "' — removal failed\n")
        end
        return ok
      end))
  end

  return changes
end

return gen
