-- Spike 01: inventário do ambiente
-- Mostra a versão do REAPER, as APIs que o Live Sections usa, os valores das
-- config vars candidatas a smooth seek e as actions relevantes.
-- Rode uma vez, mude o smooth seek em Preferences e rode de novo: as config
-- vars que mudarem aparecem marcadas com "<- MUDOU".

local EXT = "LiveSections_Spike01"

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

reaper.ClearConsole()
out("== REAPER " .. reaper.GetAppVersion() .. " ==\n")

out("APIs:")
local apis = {
  "GoToRegion", "GoToMarker", "SetEditCurPos", "GetPlayPosition2",
  "MIDI_GetRecentInputEvent", "StuffMIDIMessage", "GetMIDIInputName", "GetMIDIOutputName",
  "GetProjectStateChangeCount", "GetSetRepeat", "GetSet_LoopTimeRange2",
  "TimeMap2_timeToBeats", "TimeMap2_beatsToTime", "TimeMap_GetMeasureInfo",
  "get_config_var_string", "SNM_GetIntConfigVar", "SNM_SetIntConfigVar",
  "ImGui_GetBuiltinPath", "ImGui_CreateContext",
  "kbd_enumerateActions", "SectionFromUniqueID",
}
for _, name in ipairs(apis) do
  out(string.format("  %-28s %s", name, reaper[name] and "OK" or "AUSENTE"))
end

out("\nConfig vars (candidatas):")
local vars = {
  "smoothseek", "smoothseekmeas", "seekmodes", "seekmode",
  "loopstopfx", "stopprojlen", "transflags", "loopselpr", "playcursormode",
}
for _, name in ipairs(vars) do
  local val = "n/d"
  if reaper.get_config_var_string then
    local ok, s = reaper.get_config_var_string(name)
    if ok then val = s end
  end
  if val == "n/d" and reaper.SNM_GetIntConfigVar then
    local i = reaper.SNM_GetIntConfigVar(name, -99999)
    if i ~= -99999 then val = tostring(i) end
  end
  local prev = reaper.GetExtState(EXT, name)
  local mark = (prev ~= "" and prev ~= val) and ("   <- MUDOU (antes: " .. prev .. ")") or ""
  out(string.format("  %-16s = %s%s", name, val, mark))
  reaper.SetExtState(EXT, name, val, false)
end

out("\nActions (seção Main) com 'smooth', 'seek' ou 'end of loop':")
local section = reaper.SectionFromUniqueID and reaper.SectionFromUniqueID(0)
if section and reaper.kbd_enumerateActions then
  local idx = 0
  while true do
    local cmd, name = reaper.kbd_enumerateActions(section, idx)
    if not cmd or cmd == 0 then break end
    local lower = name:lower()
    if lower:find("smooth") or lower:find("seek") or lower:find("end of loop") then
      local state = reaper.GetToggleCommandState(cmd)
      out(string.format("  %6d  [%s]  %s", cmd, state == 1 and "ON " or state == 0 and "off" or " - ", name))
    end
    idx = idx + 1
  end
else
  out("  (kbd_enumerateActions indisponível)")
end

out("\nCopie todo este console e mande de volta.")
