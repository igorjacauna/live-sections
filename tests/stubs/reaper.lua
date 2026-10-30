-- Stub da API reaper.* para testes fora do REAPER.
--
-- Uso:
--   local stub = require("stubs.reaper")
--   local r = stub.install()            -- cria um projeto vazio e define _G.reaper
--   r.add_region(0, 8, "Verso")         -- helpers de cenário (não existem na API real)
--   r.EnumProjectMarkers3(0, 0)         -- API simulada
--   r.calls                             -- chamadas registradas: { name = ..., args = {...} }
--
-- Mapa de tempo: lista de segmentos que começam em compassos (0-based). O BPM
-- conta batidas na unidade do denominador (em 7/8, uma batida = colcheia).
-- Chamar uma função da API que o stub não simula gera erro, para que o teste
-- deixe claro o que falta simular.

local M = {}

local EPS = 1e-9

-- Funções de extensões (ReaImGui, SWS) que podem não existir no REAPER real.
local OPTIONAL = {
  ImGui_GetBuiltinPath = true,
  SNM_GetIntConfigVar = true,
  SNM_SetIntConfigVar = true,
}

local function floor_eps(x) return math.floor(x + EPS) end

function M.new()
  local r = {
    calls = {},
    _markers = {},             -- { isrgn, pos, rgnend, name, idx, color }
    _tracks = {},              -- { name, guid, info = {} }
    _toggles = {},             -- [cmd] = 0 | 1
    _config = {},              -- [name] = string
    _state_count = 0,
    _app_version = "7.84/macOS-arm64",
    _tempo = { { measure = 0, bpm = 120, num = 4, denom = 4 } },
    _resource_path = "/tmp/reaper-stub",
  }

  local api = {}

  local function log(name, ...)
    r.calls[#r.calls + 1] = { name = name, args = table.pack(...) }
  end

  local function touch() r._state_count = r._state_count + 1 end

  -- ---------------------------------------------------------------- cenário
  function r.add_marker(pos, name, color)
    r._markers[#r._markers + 1] = { isrgn = false, pos = pos, rgnend = 0, name = name or "", idx = #r._markers + 1, color = color or 0 }
    touch()
    return r._markers[#r._markers].idx
  end

  function r.add_region(pos, rgnend, name, color)
    r._markers[#r._markers + 1] = { isrgn = true, pos = pos, rgnend = rgnend, name = name or "", idx = #r._markers + 1, color = color or 0 }
    touch()
    return r._markers[#r._markers].idx
  end

  function r.add_track(name, guid)
    local t = { name = name or "", guid = guid or ("{TRACK-" .. (#r._tracks + 1) .. "}"), info = {} }
    r._tracks[#r._tracks + 1] = t
    touch()
    return t
  end

  function r.set_tempo_map(segments)
    r._tempo = segments
    touch()
  end

  function r.set_toggle(cmd, state) r._toggles[cmd] = state end
  function r.set_config(name, value) r._config[name] = tostring(value) end
  function r.set_app_version(v) r._app_version = v end

  function r.calls_to(name)
    local out = {}
    for _, c in ipairs(r.calls) do
      if c.name == name then out[#out + 1] = c.args end
    end
    return out
  end

  -- ------------------------------------------------------------ ordenação
  local function sorted_markers()
    local list = {}
    for _, m in ipairs(r._markers) do list[#list + 1] = m end
    table.sort(list, function(a, b)
      if a.pos ~= b.pos then return a.pos < b.pos end
      return a.idx < b.idx
    end)
    return list
  end

  -- -------------------------------------------------------- marcadores/regiões
  function api.CountProjectMarkers(_)
    local markers, regions = 0, 0
    for _, m in ipairs(r._markers) do
      if m.isrgn then regions = regions + 1 else markers = markers + 1 end
    end
    return markers + regions, markers, regions
  end

  function api.EnumProjectMarkers3(_, i)
    local m = sorted_markers()[i + 1]
    if not m then return 0, false, 0, 0, "", 0, 0 end
    return i + 1, m.isrgn, m.pos, m.rgnend, m.name, m.idx, m.color
  end

  function api.AddProjectMarker2(_, isrgn, pos, rgnend, name, wantidx, color)
    log("AddProjectMarker2", isrgn, pos, rgnend, name, wantidx, color)
    if isrgn then return r.add_region(pos, rgnend, name, color) end
    return r.add_marker(pos, name, color)
  end

  function api.GetProjectStateChangeCount(_) return r._state_count end

  -- ------------------------------------------------------------------ tracks
  function api.CountTracks(_) return #r._tracks end
  function api.GetTrack(_, i) return r._tracks[i + 1] end
  function api.GetTrackGUID(track) return track.guid end

  function api.GetMediaTrackInfo_Value(track, key) return track.info[key] or 0 end

  function api.SetMediaTrackInfo_Value(track, key, value)
    log("SetMediaTrackInfo_Value", track, key, value)
    track.info[key] = value
    touch()
    return true
  end

  function api.GetSetMediaTrackInfo_String(track, key, value, set)
    if key ~= "P_NAME" then error("stub: GetSetMediaTrackInfo_String só simula P_NAME, recebeu " .. tostring(key)) end
    if set then track.name = value; touch() end
    return true, track.name
  end

  -- ------------------------------------------------------------ mapa de tempo
  -- Tempo (em segundos) em que cada segmento começa.
  local function segment_starts()
    local starts, t = {}, 0
    for i, seg in ipairs(r._tempo) do
      starts[i] = t
      local nxt = r._tempo[i + 1]
      if nxt then t = t + (nxt.measure - seg.measure) * seg.num * 60 / seg.bpm end
    end
    return starts
  end

  local function segment_at_time(t)
    local starts = segment_starts()
    local idx = 1
    for i = 1, #r._tempo do
      if t + EPS >= starts[i] then idx = i end
    end
    return r._tempo[idx], starts[idx], idx
  end

  local function full_beats_before(idx)
    local total = 0
    for i = 1, idx - 1 do
      total = total + (r._tempo[i + 1].measure - r._tempo[i].measure) * r._tempo[i].num
    end
    return total
  end

  -- Retorna: batidas dentro do compasso, compasso (0-based), batidas por
  -- compasso, batidas desde o início, denominador.
  function api.TimeMap2_timeToBeats(_, t)
    local seg, start, idx = segment_at_time(t)
    local elapsed = (t - start) * seg.bpm / 60
    local measures_in_seg = floor_eps(elapsed / seg.num)
    local beat = elapsed - measures_in_seg * seg.num
    if math.abs(beat) < EPS then beat = 0 end
    local fullbeats = full_beats_before(idx) + elapsed
    return beat, seg.measure + measures_in_seg, seg.num, fullbeats, seg.denom
  end

  -- Sem `measures`, `beats` conta desde o início do projeto; com `measures`,
  -- conta a partir do início daquele compasso.
  function api.TimeMap2_beatsToTime(_, beats, measures)
    local starts = segment_starts()
    if measures == nil then
      local remaining = beats
      for i, seg in ipairs(r._tempo) do
        local nxt = r._tempo[i + 1]
        local seg_beats = nxt and (nxt.measure - seg.measure) * seg.num or math.huge
        if remaining < seg_beats - EPS or not nxt then
          return starts[i] + remaining * 60 / seg.bpm
        end
        remaining = remaining - seg_beats
      end
    end
    local idx = 1
    for i, seg in ipairs(r._tempo) do
      if measures >= seg.measure then idx = i end
    end
    local seg = r._tempo[idx]
    return starts[idx] + ((measures - seg.measure) * seg.num + beats) * 60 / seg.bpm
  end

  -- -------------------------------------------------------- actions e config
  function api.Main_OnCommand(cmd, flag)
    log("Main_OnCommand", cmd, flag)
    r._toggles[cmd] = (r._toggles[cmd] == 1) and 0 or 1
  end

  function api.GetToggleCommandState(cmd) return r._toggles[cmd] or -1 end

  function api.get_config_var_string(name)
    local v = r._config[name]
    if v == nil then return false, "" end
    return true, v
  end

  -- ------------------------------------------------------------------ outros
  function api.GetAppVersion() return r._app_version end
  function api.GetResourcePath() return r._resource_path end
  function api.get_action_context() return true, "/stub/LiveSections/LiveSections.lua", 0, 0, 0, 0, 0 end
  function api.ShowConsoleMsg(msg) log("ShowConsoleMsg", msg) end
  function api.MB(msg, title, kind) log("MB", msg, title, kind); return 1 end
  function api.defer(fn) log("defer", fn) end
  function api.atexit(fn) log("atexit", fn) end
  function api.Undo_BeginBlock() log("Undo_BeginBlock") end
  function api.Undo_EndBlock(desc, flags) log("Undo_EndBlock", desc, flags) end

  -- Extensões opcionais: ausentes por padrão (o código testa se existem).
  function r.install_imgui(builtin_path)
    r.ImGui_GetBuiltinPath = function() return builtin_path end
  end

  for name, fn in pairs(api) do r[name] = fn end

  return setmetatable(r, {
    __index = function(_, key)
      if OPTIONAL[key] then return nil end
      error("stub reaper: função não simulada: " .. tostring(key), 2)
    end,
  })
end

-- Cria um stub novo e o instala como _G.reaper.
function M.install()
  local r = M.new()
  _G.reaper = r
  return r
end

return M
