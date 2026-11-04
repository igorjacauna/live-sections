-- Spike 12: como recriar o submenu "ReaPack" no menu Extensions?
--
-- Com o Live Sections em [Main extensions] (spike 11), o REAPER manda o
-- ReaPack para "Default menu: Main extensions". Para pôr de volta um submenu
-- "ReaPack" com as ações dele, falta saber:
--   1. os IDs de comando das ações do ReaPack;
--   2. como o reaper-menu.ini grava um submenu (início, itens, fim).
-- Antes de rodar, crie à mão um submenu de exemplo (passos no README). Este
-- script só lê: não grava nada.

local SECTION = "Main extensions"

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local SEP = package.config:sub(1, 1)
local function join(a, b) return (a:gsub("[\\/]$", "")) .. SEP .. b end

reaper.ClearConsole()
out("== Spike 12: submenu ReaPack ==")
out("REAPER " .. reaper.GetAppVersion())

-- 1. ações do ReaPack: nomes prováveis e, se der, todas as que começam com "ReaPack"
out("")
out("IDs do ReaPack (nomes prováveis):")
local guesses = { "REAPACK_SYNC", "REAPACK_BROWSE", "REAPACK_IMPORT", "REAPACK_MANAGE",
  "REAPACK_ABOUT", "REAPACK_SELF_ABOUT", "REAPACK_REFRESH", "REAPACK_UPLOAD" }
for _, name in ipairs(guesses) do
  local cmd = reaper.NamedCommandLookup("_" .. name)
  local text = cmd ~= 0 and reaper.kbd_getTextFromCmd and reaper.kbd_getTextFromCmd(cmd, 0) or ""
  out(string.format("  _%-20s %s %s", name, cmd ~= 0 and "existe" or "não existe", text))
end

local ok_enum = pcall(function() return reaper.kbd_enumerateActions end) and reaper.kbd_enumerateActions
if ok_enum then
  out("")
  out("Ações com \"ReaPack\" no nome (Main):")
  local section = reaper.SectionFromUniqueID and reaper.SectionFromUniqueID(0)
  local i = 0
  while true do
    local cmd, name = reaper.kbd_enumerateActions(section, i)
    if not cmd or cmd == 0 then break end
    if name and name:find("ReaPack", 1, true) then
      out(string.format("  %s  _%s", name, tostring(reaper.ReverseNamedCommandLookup(cmd))))
    end
    i = i + 1
  end
else
  out("(kbd_enumerateActions não existe neste REAPER)")
end

-- 2. a seção do menu Extensions como o REAPER gravou
local path = join(reaper.GetResourcePath(), "reaper-menu.ini")
local f = io.open(path, "rb")
local text = f and f:read("*a")
if f then f:close() end
out("")
if not text then out("reaper-menu.ini não existe"); return end
local body = text:match("%[" .. SECTION .. "%]\r?\n(.-)\r?\n%[") or text:match("%[" .. SECTION .. "%]\r?\n(.*)$")
out("[" .. SECTION .. "]:")
for line in (body or "(sem a seção)"):gmatch("[^\r\n]+") do out("  " .. line) end
