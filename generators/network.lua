local gen = {}
gen.name = "network"

function gen.plan(cfg, sync)
  local changes = {}
  local nm_dir = "/etc/NetworkManager/system-connections"

  -- existing profiles
  local existing = {}
  local ls = sync.shell_output("ls " .. nm_dir .. " 2>/dev/null")
  for file in ls:gmatch("[^\n]+") do
    if file:match("%.nmconnection$") then
      existing[file] = true
    end
  end

  local desired_names = {}

  for _, conn in ipairs(cfg.network.connections) do
    desired_names[conn.name .. ".nmconnection"] = true

    local filepath = nm_dir .. "/" .. conn.name .. ".nmconnection"
    local content = "[connection]\n"
    content = content .. "id=" .. conn.name .. "\n"
    content = content .. "type=" .. (conn.type or "wifi") .. "\n"
    content = content .. "interface-name=" .. conn.name .. "\n"
    content = content .. "autoconnect=true\n\n"

    if conn.type ~= "ethernet" then
      content = content .. "[wifi]\n"
      content = content .. "ssid=" .. (conn.ssid or conn.name) .. "\n"
      if conn.hidden then
        content = content .. "hidden=true\n"
      end
      content = content .. "\n"
    end

    if conn.password and conn.password ~= "" then
      content = content .. "[wifi-security]\n"
      content = content .. "key-mgmt=wpa-psk\n"
      content = content .. "psk=" .. conn.password .. "\n\n"
    end

    if conn.ipv4 == "static" and conn.address then
      content = content .. "[ipv4]\n"
      content = content .. "method=manual\n"
      content = content .. "addresses=" .. conn.address .. "\n"
      if conn.gateway then
        content = content .. "gateway=" .. conn.gateway .. "\n"
      end
      if conn.dns and #conn.dns > 0 then
        content = content .. "dns=" .. table.concat(conn.dns, ";") .. "\n"
      end
    else
      content = content .. "[ipv4]\nmethod=auto\n"
    end

    content = content .. "\n[ipv6]\nmethod=disabled\n"

    local current = sync.read_file(filepath)
    if current ~= content then
      table.insert(changes, sync.change("~", "network", conn.name .. ".nmconnection",
        current and "update" or "create", function()
          return sync.write_file(filepath, content)
            and sync.shell("chmod 600 " .. filepath)
        end))
    end
  end

  -- remove profiles not in config
  for file in pairs(existing) do
    if not desired_names[file] then
      table.insert(changes, sync.change("-", "network", file, nil,
        function()
          os.remove(nm_dir .. "/" .. file)
          return true
        end))
    end
  end

  return changes
end

return gen
