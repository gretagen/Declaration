-- media.lua — house generator: download files from the internet with curl
--
-- Configuration (house.lua):
--   media = {
--     ["/home/alice/Downloads/cam5.jpg"] = "https://example.org/cam5.jpg",          -- exact destination
--     ["/home/alice/Downloads/"]         = "https://example.org/videos/clip.mp4",    -- directory: URL basename
--   }
--
-- Downloads are planned as "+" changes and skipped when the destination
-- file already exists. Files are staged to "<dest>.part" and renamed into
-- place, so an interrupted download never leaves a partial final file.

local gen = {}
gen.name = "media"

-- shell-quote a string for safe use inside a single-quoted shell argument
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- true when a path exists (file or directory)
local function exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- basename of a URL: strip query string/fragment, then take the last path segment
local function url_basename(url)
  local path = url:gsub("[?#].*$", "")
  return path:match("([^/]+)/?$")
end

function gen.plan(cfg, house_sync)
  local changes = {}

  if not cfg.media or next(cfg.media) == nil then return {} end

  for dest, url in pairs(cfg.media) do
    if type(dest) ~= "string" or type(url) ~= "string" then
      house_sync.vprint("media: skipping non-string entry (%s -> %s)", type(dest), type(url))
      -- skip to next entry
    else
      local target = dest
      if target:match("/$") then
        local name = url_basename(url)
        if not name or name == "" then
          house_sync.vprint("media: skipping '%s' - cannot derive filename from URL", url)
        else
          target = target .. name
        end
      end

      -- only download when the destination does not exist yet; repower
      -- re-downloads so the file comes straight from its source again
      local already = exists(target)
      if not already or house_sync.repower then
        local c = house_sync.change(already and "~" or "+", "media", target, url,
          function()
            local dir = target:match("^(.*/)")
            if dir then
              local ok = house_sync.ensure_dir(dir)
              if not ok then return false end
            end
            local tmp = target .. ".part"
            os.remove(tmp)
            local ok = house_sync.shell("curl -L --fail --silent --show-error -o " .. shell_quote(tmp) .. " " .. shell_quote(url))
            if not ok then return false end
            return house_sync.shell("mv " .. shell_quote(tmp) .. " " .. shell_quote(target))
          end)
        -- the download itself needs no privilege, but the destination dir does
        if not house_sync.writable_path(target) then
          c.requires_root = true
        end
        table.insert(changes, c)
      end
    end
  end

  return changes
end

return gen