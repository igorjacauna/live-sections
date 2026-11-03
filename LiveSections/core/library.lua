-- Biblioteca de músicas: uma pasta por música, com musica.json (o pacote de
-- core/song_package) e os áudios em audio/.
--
-- A pasta fica, por padrão, em <recursos do REAPER>/Live Sections/Músicas
-- (RF-191). Outra pasta pode ser escolhida nas Configurações e fica em
-- settings.library_dir do config.json (RF-192). Levar a pasta para outro
-- computador leva as músicas: os áudios ficam com caminho relativo no pacote
-- e viram absolutos ao ler (RF-203).
--
-- M.init({ mappings })
-- M.default_dir() -> caminho
-- M.dir() -> caminho, ok        ok = false: a pasta escolhida não existe (RF-210)
-- M.set_dir(caminho|nil)        nil volta à padrão
-- M.folder_name(nome) -> nome de pasta válido no Windows
-- M.exists(nome) -> bool        já há música com esse nome (RF-189)
-- M.write(pkg) -> ok, err, info grava musica.json e copia os áudios
--   err = "no_dir"|"no_write" (info.path diz onde) (RF-206)
--   info = { path, copied, bytes }
-- M.read(pasta) -> pkg | nil, err      err = "unreadable"|"unknown_format" (RF-207)
--   pkg.folder = caminho da pasta; audio[i].path = caminho absoluto
-- M.list() -> { Summary }   por nome (RF-193)
--   Summary = { name, folder, path, bpm, signature, bars, sections,
--               exported_at, ok, err? }
-- M.missing_plugins(pkg) -> { nome }   plugins do pacote não instalados (RF-201)
-- M.open_folder(caminho)        Explorer/Finder (RF-194)

local json = require("vendor.json")

local M = {}

local SEP = package.config:sub(1, 1)
local FILE = "musica.json"
local BLOCK = 1024 * 1024
local FORMAT = 1
local OWN_JSFX = "JS: LiveSections/"   -- o Live Sections grava o JSFX do Mapeamento

local mappings
local installed = nil   -- [nome] = true, lido uma vez

function M.init(deps)
  mappings = deps.mappings
  installed = nil
end

local function join(a, b) return (a:gsub("[\\/]$", "")) .. SEP .. b end

local function dir_exists(path)
  if path == "" then return false end
  -- renomear para o mesmo nome só dá certo se existe; pasta com algo dentro
  -- também aparece na enumeração
  return os.rename(path, path) == true or reaper.EnumerateSubdirectories(path, 0) ~= nil
    or (reaper.EnumerateFiles and reaper.EnumerateFiles(path, 0) ~= nil) or false
end

-- ------------------------------------------------------------------ pasta

function M.default_dir()
  return join(join(reaper.GetResourcePath(), "Live Sections"), "Músicas")
end

function M.dir()
  local chosen = mappings.settings().library_dir
  if type(chosen) == "string" and chosen ~= "" then return chosen, dir_exists(chosen) end
  local path = M.default_dir()
  reaper.RecursiveCreateDirectory(path, 0)
  return path, true
end

function M.set_dir(path)
  local settings = mappings.settings()
  settings.library_dir = (path and path ~= "") and path or nil
  return mappings.save_settings(settings)
end

function M.folder_name(name)
  local s = tostring(name or ""):gsub('[<>:"/\\|%?%*%c]', "_"):gsub("^%s+", ""):gsub("[%s%.]+$", "")
  return s ~= "" and s or "Música"
end

function M.exists(name)
  local dir = M.dir()
  return reaper.file_exists(join(join(dir, M.folder_name(name)), FILE))
end

-- ------------------------------------------------------------------ arquivos

local function copy(src, dst)
  local i = io.open(src, "rb")
  if not i then return false, 0 end
  local o = io.open(dst, "wb")
  if not o then i:close(); return false, 0, "no_write" end
  local n = 0
  while true do
    local block = i:read(BLOCK)
    if not block then break end
    o:write(block)
    n = n + #block
  end
  i:close(); o:close()
  return true, n
end

local function same_path(a, b)
  local function norm(p) return (p:gsub("\\", "/"):lower()) end
  return norm(a) == norm(b)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function decode(path)
  local text = read_file(path)
  if not text then return nil, "unreadable" end
  local ok, pkg = pcall(json.decode, text)
  if not ok or type(pkg) ~= "table" then return nil, "unreadable" end
  if pkg.format ~= FORMAT or type(pkg.tracks) ~= "table" then return nil, "unknown_format" end
  return pkg
end

function M.write(pkg)
  local dir, ok = M.dir()
  if not ok then return false, "no_dir", { path = dir } end
  local folder = join(dir, M.folder_name(pkg.name))
  local audio_dir = join(folder, "audio")
  reaper.RecursiveCreateDirectory(audio_dir, 0)

  -- substituir: os áudios da versão anterior que não voltam saem
  local old = decode(join(folder, FILE))
  local keep = {}
  for _, a in ipairs(pkg.audio or {}) do keep[a.file] = true end
  for _, a in ipairs(old and old.audio or {}) do
    if type(a.file) == "string" and not keep[a.file] then os.remove(join(folder, a.file)) end
  end

  local copied, bytes = 0, 0
  local out = {}
  for _, a in ipairs(pkg.audio or {}) do
    local entry = { file = a.file, from = a.from, missing = a.missing }
    local dst = join(folder, a.file)
    if not a.missing and not same_path(a.from, dst) then
      local done, n, err = copy(a.from, dst)
      if err then return false, "no_write", { path = dst } end
      if done then copied, bytes = copied + 1, bytes + n; entry.bytes = n else entry.missing = true end
    end
    out[#out + 1] = entry
  end

  local data = {}
  for k, v in pairs(pkg) do data[k] = v end
  data.audio, data.folder = out, nil
  local path = join(folder, FILE)
  local f = io.open(path, "wb")
  if not f then return false, "no_write", { path = path } end
  f:write(json.encode(data))
  f:close()
  return true, nil, { path = folder, copied = copied, bytes = bytes }
end

function M.read(folder_name)
  local folder = join(M.dir(), folder_name)
  local pkg, err = decode(join(folder, FILE))
  if not pkg then return nil, err end
  pkg.folder = folder
  for _, a in ipairs(pkg.audio or {}) do
    if type(a.file) == "string" then a.path = join(folder, (a.file:gsub("/", SEP))) end
  end
  return pkg
end

-- Compassos da música pelo tempo do pacote (rampas pelo tempo médio).
local function bars_of(pkg)
  local list = type(pkg.tempo) == "table" and pkg.tempo or {}
  if #list == 0 or not pkg.length then return nil end
  local bars = 0
  for i, m in ipairs(list) do
    local nxt = list[i + 1]
    local span = (nxt and nxt.t or pkg.length) - m.t
    local bpm = m.bpm
    if m.linear and nxt then bpm = (m.bpm + nxt.bpm) / 2 end
    local num, denom = m.num, m.denom
    if not num or num <= 0 then
      for k = i, 1, -1 do
        if (list[k].num or 0) > 0 then num, denom = list[k].num, list[k].denom; break end
      end
    end
    bars = bars + span * bpm / 60 / ((num or 4) * 4 / (denom or 4))
  end
  return math.floor(bars + 0.5)
end

function M.list()
  local dir, ok = M.dir()
  local out = {}
  if not ok then return out end
  local i = 0
  while true do
    local name = reaper.EnumerateSubdirectories(dir, i)
    if not name then break end
    local path = join(dir, name)
    if reaper.file_exists(join(path, FILE)) then
      local pkg, err = decode(join(path, FILE))
      if pkg then
        out[#out + 1] = {
          name = tostring(pkg.name or name), folder = name, path = path, ok = true,
          bpm = pkg.bpm, signature = pkg.signature, bars = bars_of(pkg),
          sections = type(pkg.regions) == "table" and #pkg.regions or 0,
          exported_at = pkg.exported_at,
        }
      else
        out[#out + 1] = { name = name, folder = name, path = path, ok = false, err = err }
      end
    end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- ------------------------------------------------------------------ plugins

local function installed_fx()
  if installed then return installed end
  installed = {}
  if not reaper.EnumInstalledFX then return installed end
  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    installed[name] = true
    if name:match("^JS:") and ident and ident ~= "" then installed["JS: " .. ident] = true end
    i = i + 1
  end
  return installed
end

function M.missing_plugins(pkg)
  local have, out = installed_fx(), {}
  for _, name in ipairs(pkg.plugins or {}) do
    if not have[name] and name:sub(1, #OWN_JSFX) ~= OWN_JSFX then out[#out + 1] = name end
  end
  return out
end

function M.open_folder(path)
  local os_name = reaper.GetOS():lower()
  if os_name:match("^win") then
    reaper.ExecProcess('explorer "' .. path .. '"', -1)
  else
    reaper.ExecProcess('/usr/bin/open "' .. path .. '"', -1)
  end
end

return M
