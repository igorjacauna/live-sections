-- Spike 11: o Live Sections consegue se colocar sozinho no menu Extensions?
--
-- Scripts não têm API de menu; o caminho é gravar um item em
-- <recursos do REAPER>/reaper-menu.ini, o arquivo que o "Customize
-- menus/toolbars" grava. Este spike:
--   1. acha o LiveSections.lua instalado e o ID de comando dele (_RS…);
--   2. mostra as seções que já existem no reaper-menu.ini;
--   3. se você confirmar, faz backup do arquivo e grava o item
--      "Live Sections" na seção [Main extensions].
-- Depois é reiniciar o REAPER e conferir o menu Extensions.
--
-- Para desfazer: feche o REAPER e troque o reaper-menu.ini pelo
-- reaper-menu.ini.spike11-backup (ou apague o reaper-menu.ini se o backup
-- disser que ele não existia).

local SECTION = "Main extensions"
local LABEL = "Live Sections"

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local SEP = package.config:sub(1, 1)
local function join(a, b) return (a:gsub("[\\/]$", "")) .. SEP .. b end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- LiveSections.lua dentro de Scripts (o ReaPack põe numa subpasta do repositório)
local function find_script(dir, depth)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f == "LiveSections.lua" then return join(dir, f) end
    i = i + 1
  end
  if depth <= 0 then return nil end
  i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i)
    if not d then break end
    local found = find_script(join(dir, d), depth - 1)
    if found then return found end
    i = i + 1
  end
end

reaper.ClearConsole()
out("== Spike 11: menu Extensions ==")
out("REAPER " .. reaper.GetAppVersion())

local res = reaper.GetResourcePath()
local script = find_script(join(res, "Scripts"), 4)
if not script then out("LiveSections.lua não encontrado em Scripts."); return end
out("Script: " .. script)

-- registrar de novo um script já registrado devolve o mesmo ID
local cmd = reaper.AddRemoveReaScript(true, 0, script, true)
local named = cmd ~= 0 and reaper.ReverseNamedCommandLookup(cmd)
out("ID de comando: " .. tostring(cmd) .. "  nome: _" .. tostring(named))
if not named then out("Sem ID de comando; parei."); return end

local menu_path = join(res, "reaper-menu.ini")
local text = read(menu_path)
out("")
out("reaper-menu.ini: " .. (text and (#text .. " bytes") or "não existe"))
if text then
  out("Seções:")
  for name in text:gmatch("%[([^%]\r\n]+)%]") do out("  [" .. name .. "]") end
  local body = text:match("%[" .. SECTION .. "%]\r?\n(.-)\r?\n%[") or text:match("%[" .. SECTION .. "%]\r?\n(.*)$")
  if body then
    out("Conteúdo de [" .. SECTION .. "]:")
    for line in body:gmatch("[^\r\n]+") do out("  " .. line) end
  end
  if text:find("_" .. named, 1, true) then out("O Live Sections já está em algum menu.") end
end

local answer = reaper.ShowMessageBox(
  "Gravar o item \"" .. LABEL .. "\" no menu Extensions?\n\n" ..
  "O reaper-menu.ini atual vai para reaper-menu.ini.spike11-backup. " ..
  "Depois, reinicie o REAPER e confira o menu Extensions.", "Spike 11", 4)
if answer ~= 6 then out("\nNada gravado."); return end

local backup = menu_path .. ".spike11-backup"
local b = io.open(backup, "wb")
b:write(text or "; o reaper-menu.ini não existia: para desfazer, apague o reaper-menu.ini\n")
b:close()

local eol = (text and text:find("\r\n", 1, true)) and "\r\n" or (SEP == "\\" and "\r\n" or "\n")
local item = "_" .. named .. " " .. LABEL
local new
if text and text:find("%[" .. SECTION .. "%]") then
  -- próximo índice livre dentro da seção
  local start = text:find("%[" .. SECTION .. "%]")
  local stop = text:find("\n%[", start + 1) or #text + 1
  local section = text:sub(start, stop - 1)
  local n = -1
  for k in section:gmatch("item_(%d+)=") do n = math.max(n, tonumber(k)) end
  local line = "item_" .. (n + 1) .. "=" .. item
  local body = section:gsub("[\r\n]+$", "")
  new = text:sub(1, start - 1) .. body .. eol .. line .. eol .. text:sub(stop)
else
  new = (text or "") .. ((text and not text:match("\n$")) and eol or "") ..
    "[" .. SECTION .. "]" .. eol .. "item_0=" .. item .. eol
end
local f = io.open(menu_path, "wb")
f:write(new)
f:close()
out("\nGravado em " .. menu_path .. ":")
out("  [" .. SECTION .. "] … " .. item)
out("Backup: " .. backup)
out("\nAgora: 1) confira o menu Extensions SEM reiniciar; 2) feche e abra o REAPER e confira de novo.")
out("Nas duas vezes: o Live Sections aparece? O ReaPack continua lá? Clicar abre o Live Sections?")
