-- Spike 06: "Marcar compasso 1" mexe no áudio ou nas regiões?
--
-- Rode numa ABA DE PROJETO NOVA E VAZIA (File → New project tab), com as
-- configurações padrão do REAPER (timebase em batidas). Ele monta
-- um cenário de teste, aplica o mesmo código do Live Sections
-- (core/tempo_align.lua) e imprime no console o que mudou. Não precisa de
-- áudio nem de controlador. No fim, feche a aba sem salvar.
--
-- Cenário: 120 BPM em 4/4.
--   Música A: marcador "SONG: A" em 0 s, item de áudio vazio em 3,1 s,
--             região "Verso A" em 20–30 s. O compasso 1 do áudio está em 3,1 s.
--   Música B: marcador "SONG: B" em 60 s, região "Intro B" em 64–70 s,
--             item em 64 s (timebase do projeto) e item em 70 s (timebase beats).
--             B é alinhada antes (compasso 1 em 61,5 s a 120 BPM), para ver se
--             o alinhamento de A preserva o de B.

local TOL = 0.0005 -- 0,5 ms

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function script_dir()
  local _, path = reaper.get_action_context()
  return path:match("^(.*[/\\])")
end
package.path = script_dir() .. "../LiveSections/?.lua;" .. package.path
package.loaded["core.tempo_align"] = nil
local tempo_align = require("core.tempo_align")

-- Qual cópia do tempo_align foi carregada, e se é a versão que conta as
-- batidas pela lista de marcadores (commit 4aec117).
local function module_info()
  local path = package.searchpath("core.tempo_align", package.path) or "?"
  local f = io.open(path, "r")
  local src = f and f:read("a") or ""
  if f then f:close() end
  return path, src:find("grid_before", 1, true) ~= nil
end

local results = { ok = 0, fail = 0 }
local function check(label, cond, detail)
  if cond then results.ok = results.ok + 1 else results.fail = results.fail + 1 end
  out(string.format("  [%s] %s%s", cond and "ok" or "FALHOU", label, detail and ("  (" .. detail .. ")") or ""))
end

local function snapshot(items)
  local s = { items = {}, markers = {} }
  for name, it in pairs(items) do s.items[name] = reaper.GetMediaItemInfo_Value(it, "D_POSITION") end
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    s.markers[name] = { pos = pos, rgnend = isrgn and rgnend or nil }
    i = i + 1
  end
  return s
end

local function compare(before, after)
  for name, pos in pairs(before.items) do
    local now = after.items[name]
    check("item " .. name .. " ficou no lugar", math.abs(now - pos) < TOL, string.format("%.4f s → %.4f s", pos, now))
  end
  for name, m in pairs(before.markers) do
    local now = after.markers[name]
    local same = now and math.abs(now.pos - m.pos) < TOL and (not m.rgnend or math.abs(now.rgnend - m.rgnend) < TOL)
    check(string.format('"%s" ficou no lugar', name), same,
      string.format("%.4f s → %s", m.pos, now and string.format("%.4f s", now.pos) or "sumiu"))
  end
end

local function bar_of(t)
  local beat, measure = reaper.TimeMap2_timeToBeats(0, t)
  return measure, beat
end

local function print_tempo_markers(title)
  out(title)
  for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
    local _, time, _, _, bpm, num, denom = reaper.GetTempoTimeSigMarker(0, i)
    out(string.format("    %8.4f s  %8.3f BPM  %s", time, bpm, num > 0 and (num .. "/" .. denom) or "(só tempo)"))
  end
end

local function setup()
  if reaper.CountTracks(0) > 0 or reaper.CountProjectMarkers(0) > 0 or reaper.CountTempoTimeSigMarkers(0) > 0 then
    reaper.MB("Rode o spike 06 numa aba de projeto nova e vazia (File → New project tab).", "Spike 06", 0)
    return nil
  end
  reaper.SetCurrentBPM(0, 120, false)
  reaper.InsertTrackAtIndex(0, false)
  local tr = reaper.GetTrack(0, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Spike 06", true)
  local function item(pos, len, beat_mode)
    local it = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len)
    if beat_mode then reaper.SetMediaItemInfo_Value(it, "C_BEATATTACHMODE", beat_mode) end
    return it
  end
  local items = {
    ["A (3,1 s)"] = item(3.1, 40, nil),
    ["B (64 s, timebase do projeto)"] = item(64, 5, nil),
    ["B (70 s, timebase beats)"] = item(70, 5, 1),
  }
  reaper.AddProjectMarker2(0, false, 0, 0, "SONG: A", -1, 0)
  reaper.AddProjectMarker2(0, true, 20, 30, "Verso A", -1, 0)
  reaper.AddProjectMarker2(0, false, 60, 0, "SONG: B", -1, 0)
  reaper.AddProjectMarker2(0, true, 64, 70, "Intro B", -1, 0)
  reaper.UpdateTimeline()
  return items
end

local function run()
  reaper.ClearConsole()
  local items = setup()
  if not items then return end
  local song_a = { start_pos = 0, end_pos = 60 }
  local song_b = { start_pos = 60, end_pos = 120 }

  local _, tb = reaper.get_config_var_string("itemtimelock")
  local _, ttb = reaper.get_config_var_string("tempoenvtimelock")
  out("Spike 06: marcar compasso 1 em 3,1 s com 97,3 BPM na música A")
  out(string.format("itemtimelock = %s, tempoenvtimelock = %s", tb, ttb))
  local mod_path, is_new = module_info()
  out("script: " .. select(2, reaper.get_action_context()))
  out(string.format("tempo_align: %s (%s)", mod_path, is_new and "versão nova" or "VERSÃO ANTIGA"))
  if not is_new then
    out("Este não é o tempo_align do repositório atualizado. Rode o spike direto da pasta live-sections/spikes.")
    return
  end

  local okb = tempo_align.set_downbeat(song_b, nil, 61.5, 120)
  out(string.format("Música B alinhada antes (compasso 1 em 61,5 s): %s", tostring(okb)))
  print_tempo_markers("  marcadores de tempo antes:")
  local before = snapshot(items)

  local ok, bpm = tempo_align.set_downbeat(song_a, song_b, 3.1, 97.3)
  reaper.UpdateTimeline()
  out(string.format("set_downbeat: %s, BPM %s", tostring(ok), tostring(bpm)))
  print_tempo_markers("  marcadores de tempo depois:")
  local after = snapshot(items)

  out("\n1. Nada saiu do lugar")
  compare(before, after)

  out("\n2. O compasso 1 começa no ponto marcado")
  local m, beat = bar_of(3.1)
  check("3,1 s é início de compasso", math.abs(beat) < 0.001, string.format("compasso %d, batida %.3f", m + 1, beat + 1))
  local next_bar = reaper.TimeMap2_beatsToTime(0, 0, m + 1)
  local expected = 3.1 + 4 * 60 / 97.3
  check("o compasso seguinte tem a duração de 97,3 BPM", math.abs(next_bar - expected) < TOL,
    string.format("esperado %.4f s, veio %.4f s", expected, next_bar))

  out("\n3. A música B mantém o tempo dela")
  local _, _, tempo_b = reaper.TimeMap_GetTimeSigAtTime(0, 62)
  check("tempo em 62 s continua 120 BPM", math.abs(tempo_b - 120) < 0.001, string.format("%.3f BPM", tempo_b))
  local _, beat_b = bar_of(61.5)
  check("61,5 s (compasso 1 de B) continua início de compasso", math.abs(beat_b) < 0.001, string.format("batida %.3f", beat_b + 1))
  local _, _, tempo_b70 = reaper.TimeMap_GetTimeSigAtTime(0, 70)
  check("tempo em 70 s continua 120 BPM", math.abs(tempo_b70 - 120) < 0.001, string.format("%.3f BPM", tempo_b70))

  out("\n4. Ajuste fino: +0,01 BPM e +1 ms")
  local before2 = snapshot(items)
  local ok2, bpm2, t2 = tempo_align.nudge(song_a, song_b, 0.01, 1)
  reaper.UpdateTimeline()
  check("nudge aplicado", ok2 and math.abs(bpm2 - 97.31) < 0.001 and math.abs(t2 - 3.101) < TOL,
    string.format("BPM %s, compasso 1 em %s s", tostring(bpm2), tostring(t2)))
  compare(before2, snapshot(items))
  print_tempo_markers("  marcadores de tempo depois do ajuste:")
  local _, beat_b2 = bar_of(61.5)
  check("61,5 s continua início de compasso", math.abs(beat_b2) < 0.001, string.format("batida %.3f", beat_b2 + 1))
  local _, _, tempo_b2 = reaper.TimeMap_GetTimeSigAtTime(0, 62)
  check("música B continua a 120 BPM", math.abs(tempo_b2 - 120) < 0.001, string.format("%.3f BPM", tempo_b2))

  out(string.format("\nResultado: %d ok, %d falharam. Feche a aba sem salvar.", results.ok, results.fail))
end

run()
