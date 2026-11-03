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
    _project_path = "/proj",
    _files = {},
    _project_length = 0,       -- valor devolvido por GetProjectLength
    _repeat = 0,
    _loop = { 0, 0 },          -- loop points { início, fim }
    _play_state = 0,           -- bit 1 = tocando
    _play_pos = 0,
    _cursor = 0,
    _undo = {},
    _ext = {},                 -- ProjExtState: [section][key] = valor
    _gext = {},                -- ExtState global: [section][key] = valor
    _midi_cc = false,          -- { resolution, val } da action disparada por CC
    -- Marcadores de tempo da API SetTempoTimeSigMarker, por tempo. São uma
    -- lista à parte: não alteram o mapa de _tempo usado pelo TimeMap2_*.
    _tempo_markers = {},       -- { time, bpm, num, denom, linear }
    _items = {},               -- { info = { D_POSITION, D_LENGTH, C_BEATATTACHMODE } }
    _midi_inputs = {},         -- [dev] = { name, present }
    _midi_outputs = {},        -- [idx] = nome
    _midi_events = {},         -- { seq, buf, ts, dev }, do mais velho ao mais novo
    _midi_seq = 0,
    _now = 0,                  -- valor de time_precise
  }

  local api = {}

  local function log(name, ...)
    r.calls[#r.calls + 1] = { name = name, args = table.pack(...) }
  end

  local function touch() r._state_count = r._state_count + 1 end

  -- ---------------------------------------------------------------- cenário
  -- Índices crescem sempre, para não repetir depois de apagar um marcador.
  local next_idx = 0
  local function new_marker(isrgn, pos, rgnend, name, color)
    next_idx = next_idx + 1
    r._markers[#r._markers + 1] = { isrgn = isrgn, pos = pos, rgnend = rgnend, name = name or "", idx = next_idx, color = color or 0 }
    touch()
    return next_idx
  end

  function r.add_marker(pos, name, color) return new_marker(false, pos, 0, name, color) end
  function r.add_region(pos, rgnend, name, color) return new_marker(true, pos, rgnend, name, color) end

  -- Regiões do projeto em ordem de posição: { {pos, rgnend, name}, ... }
  function r.regions()
    local out = {}
    for _, m in ipairs(r._markers) do
      if m.isrgn then out[#out + 1] = { m.pos, m.rgnend, m.name } end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
  end

  -- `parent`: track pai (para camadas em tracks filhas).
  function r.add_track(name, guid, parent)
    local t = { name = name or "", guid = guid or ("{TRACK-" .. (#r._tracks + 1) .. "}"), info = {}, parent = parent }
    r._tracks[#r._tracks + 1] = t
    touch()
    return t
  end

  -- Item de mídia; beat_mode: -1 (do projeto), 0 (tempo), 1 ou 2 (batidas).
  -- `track`: a track do item (para CountTrackMediaItems).
  function r.add_item(pos, len, beat_mode, track)
    local it = { info = { D_POSITION = pos, D_LENGTH = len, C_BEATATTACHMODE = beat_mode or -1 } }
    r._items[#r._items + 1] = it
    if track then
      track.items = track.items or {}
      track.items[#track.items + 1] = it
    end
    touch()
    return it
  end

  function r.set_tempo_map(segments)
    r._tempo = segments
    touch()
  end

  -- Simula uma edição feita no REAPER (renomear, recolorir, mover) sem passar pela API.
  function r.touch() touch() end

  function r.set_project_length(len) r._project_length = len end

  -- Põe o transporte num estado: tocando (true/false) e posição de reprodução.
  function r.set_play(playing, pos)
    r._play_state = playing and 1 or 0
    if pos then r._play_pos = pos end
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

  local function find_marker(idx, isrgn)
    for i, m in ipairs(r._markers) do
      if m.idx == idx and m.isrgn == isrgn then return m, i end
    end
  end

  function api.SetProjectMarker3(_, idx, isrgn, pos, rgnend, name, color)
    log("SetProjectMarker3", idx, isrgn, pos, rgnend, name, color)
    local m = find_marker(idx, isrgn)
    if not m then return false end
    m.pos, m.rgnend, m.name, m.color = pos, rgnend, name, color
    touch()
    return true
  end

  function api.DeleteProjectMarker(_, idx, isrgn)
    log("DeleteProjectMarker", idx, isrgn)
    local _, i = find_marker(idx, isrgn)
    if not i then return false end
    table.remove(r._markers, i)
    touch()
    return true
  end

  -- Só MARKER_GUID:<índice da enumeração>; o GUID é estável por marcador.
  function api.GetSetProjectInfo_String(_, desc, value, set)
    local i = desc:match("^MARKER_GUID:(%d+)$")
    if not i or set then error("stub: GetSetProjectInfo_String só lê MARKER_GUID, recebeu " .. desc) end
    local m = sorted_markers()[tonumber(i) + 1]
    if not m then return false, "" end
    m.guid = m.guid or string.format("{MK-%s-%d}", m.isrgn and "R" or "M", m.idx)
    return true, m.guid
  end

  function api.GetProjectStateChangeCount(_) return r._state_count end
  function api.GetProjectLength(_) return r._project_length end

  -- ------------------------------------------------------------------ tracks
  function api.CountTracks(_) return #r._tracks end
  function api.GetTrack(_, i) return r._tracks[i + 1] end
  function api.GetTrackGUID(track) return track.guid end
  -- Pai explícito (add_track) ou pela profundidade de pasta (I_FOLDERDEPTH).
  function api.GetParentTrack(track)
    if track.parent then return track.parent end
    local stack = {}
    for _, t in ipairs(r._tracks) do
      if t == track then return stack[#stack] end
      local d = math.floor(t.info.I_FOLDERDEPTH or 0)
      if d > 0 then stack[#stack + 1] = t
      else for _ = 1, -d do stack[#stack] = nil end end
    end
  end
  function api.GetTrackDepth(track)
    local d, p = 0, api.GetParentTrack(track)
    while p do d, p = d + 1, api.GetParentTrack(p) end
    return d
  end
  -- item.file: arquivo da fonte do take ativo (sem ele, o item não tem take)
  function api.GetActiveTake(item) return item.file and { item = item } or nil end
  function api.GetMediaItemTake_Source(take) return { file = take.item.file } end
  function api.GetMediaSourceFileName(src, _) return src.file or "" end
  function api.CountTrackMediaItems(track) return #(track.items or {}) end
  function api.GetTrackMediaItem(track, i) return (track.items or {})[i + 1] end
  -- track.chunk: texto devolvido por GetTrackStateChunk (o teste monta).
  function api.GetTrackStateChunk(track, _, _) return track.chunk ~= nil, track.chunk or "" end
  -- AUXRECV <índice da origem> … <canais de origem (8º campo)>: vira receive
  function api.SetTrackStateChunk(track, chunk, _)
    log("SetTrackStateChunk", track, chunk)
    track.chunk = chunk
    for line in chunk:gmatch("[^\n]+") do
      local f = {}
      for w in line:gsub("^%s+", ""):gmatch("%S+") do f[#f + 1] = w end
      if f[1] == "NAME" then track.name = line:match("NAME%s+(.-)%s*$")
      elseif f[1] == "AUXRECV" then
        local src = r._tracks[tonumber(f[2]) + 1]
        src.sends = src.sends or {}
        src.sends[#src.sends + 1] = { dst = track, info = { I_SRCCHAN = tonumber(f[9]) or 0 } }
      end
    end
    touch()
    return true
  end
  function api.InsertTrackAtIndex(idx, _)
    log("InsertTrackAtIndex", idx)
    table.insert(r._tracks, idx + 1, { name = "", guid = "{TRACK-NEW-" .. #r._tracks + 1 .. "}", info = {} })
    touch()
  end
  function api.CreateTrackSend(src, dst)
    src.sends = src.sends or {}
    src.sends[#src.sends + 1] = { dst = dst, info = {} }
    log("CreateTrackSend", src, dst)
    return #src.sends - 1
  end
  function api.SetTrackSendInfo_Value(tr, _, idx, key, value) tr.sends[idx + 1].info[key] = value; return true end
  -- category -1: sends que a track recebe (na ordem das tracks de origem)
  local function receives(tr)
    local out = {}
    for _, src in ipairs(r._tracks) do
      for _, snd in ipairs(src.sends or {}) do
        if snd.dst == tr then out[#out + 1] = { src = src, info = snd.info } end
      end
    end
    return out
  end
  function api.GetTrackNumSends(tr, category)
    if category == -1 then return #receives(tr) end
    return #(tr.sends or {})
  end
  function api.GetTrackSendInfo_Value(tr, category, idx, key)
    local list = category == -1 and receives(tr) or tr.sends or {}
    local snd = list[idx + 1]
    if not snd then return 0 end
    if key == "P_SRCTRACK" then return category == -1 and snd.src or tr end
    if key == "P_DESTTRACK" then return snd.dst end
    return snd.info[key] or 0
  end
  -- layer: helper de teste para criar o send do Kontakt para a camada
  function r.add_receive(src, dst, srcchan)
    src.sends = src.sends or {}
    src.sends[#src.sends + 1] = { dst = dst, info = { I_SRCCHAN = srcchan or 0 } }
  end
  -- tr.fx: nomes dos FX, na ordem; tr.fx_state[i]: { ident, params = {} }
  -- (criado ao adicionar pela API ou sob demanda). JSFX adicionado por
  -- "JS:<arquivo>" ganha o nome r._js_desc[<arquivo>] ou o próprio arquivo.
  local function fx_state(tr, i)
    tr.fx_state = tr.fx_state or {}
    tr.fx_state[i + 1] = tr.fx_state[i + 1] or { ident = tr.fx[i + 1], params = {} }
    return tr.fx_state[i + 1]
  end
  function api.TrackFX_GetCount(tr) return #(tr.fx or {}) end
  function api.TrackFX_GetFXName(tr, i, _) return true, tr.fx[i + 1] end
  function api.TrackFX_AddByName(tr, name, _, instantiate)
    tr.fx = tr.fx or {}
    tr.fx_state = tr.fx_state or {}
    for i = 1, #tr.fx do fx_state(tr, i - 1) end
    local file = name:match("^JS:(.*)$")
    if not file or rawget(r, "_js_missing") then return -1 end
    local pos = instantiate <= -1000 and math.min(-instantiate - 1000, #tr.fx) or #tr.fx
    local desc = (rawget(r, "_js_desc") or {})[file] or file
    table.insert(tr.fx, pos + 1, "JS: " .. desc)
    table.insert(tr.fx_state, pos + 1, { ident = file, params = {} })
    log("TrackFX_AddByName", tr, name, pos)
    return pos
  end
  function api.TrackFX_Delete(tr, i)
    fx_state(tr, i)
    table.remove(tr.fx, i + 1)
    table.remove(tr.fx_state, i + 1)
    log("TrackFX_Delete", tr, i)
    return true
  end
  function api.TrackFX_CopyToTrack(src, i, dst, to, move)
    if src ~= dst or not move then error("stub: TrackFX_CopyToTrack só simula mover na mesma track") end
    for k = 1, #src.fx do fx_state(src, k - 1) end
    local name, st = table.remove(src.fx, i + 1), table.remove(src.fx_state, i + 1)
    table.insert(src.fx, to + 1, name)
    table.insert(src.fx_state, to + 1, st)
    log("TrackFX_CopyToTrack", src, i, to)
  end
  function api.TrackFX_GetNamedConfigParm(tr, i, parm)
    if parm ~= "fx_ident" or not tr.fx or not tr.fx[i + 1] then return false, "" end
    return true, fx_state(tr, i).ident
  end
  function api.TrackFX_SetParam(tr, i, p, v)
    fx_state(tr, i).params[p] = v
    log("TrackFX_SetParam", tr, i, p, v)
    return true
  end
  function api.TrackFX_GetParam(tr, i, p)
    return fx_state(tr, i).params[p] or 0, 0, 0
  end
  -- janela flutuante do FX: fx_state.open
  function api.TrackFX_GetOpen(tr, i) return tr.fx[i + 1] ~= nil and fx_state(tr, i).open == true end
  function api.TrackFX_Show(tr, i, flag)
    fx_state(tr, i).open = flag == 3 or flag == 1
    log("TrackFX_Show", tr, i, flag)
  end
  function api.TrackList_AdjustWindows() end
  function api.Track_GetPeakInfo(tr, ch) return (tr.peak or {})[ch + 1] or 0 end

  -- Curva do fader: aproximação invertível da do REAPER (0 → -inf, 716 → 0 dB,
  -- 1000 → ≈ +5,8 dB).
  function api.SLIDER2DB(y)
    if y <= 0 then return -150 end
    return 40 * math.log(y / 716, 10)
  end
  function api.DB2SLIDER(db) return 716 * 10 ^ (db / 40) end

  -- Só "MediaTrack*": a track ainda está no projeto.
  function api.ValidatePtr(ptr, kind)
    if kind ~= "MediaTrack*" then error("stub: ValidatePtr só simula MediaTrack*") end
    for _, t in ipairs(r._tracks) do if t == ptr then return true end end
    return false
  end

  function api.GetMediaTrackInfo_Value(track, key)
    if key == "IP_TRACKNUMBER" then
      for i, t in ipairs(r._tracks) do if t == track then return i end end
    end
    return track.info[key] or 0
  end

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

  -- Só o modo 2 (compassos.batidas.centésimos), como a régua do REAPER.
  function api.format_timestr_pos(t, _, mode)
    if mode ~= 2 then error("stub: format_timestr_pos só simula o modo 2") end
    local beat, measure = api.TimeMap2_timeToBeats(0, t)
    local whole = math.floor(beat + 1e-9)
    return string.format("%d.%d.%02d", measure + 1, whole + 1, math.floor((beat - whole) * 100 + 0.5))
  end

  -- ------------------------------------------------------------------ itens
  function api.CountMediaItems(_) return #r._items end
  function api.GetMediaItem(_, i) return r._items[i + 1] end
  function api.GetMediaItemInfo_Value(item, key) return item.info[key] or 0 end
  function api.SetMediaItemInfo_Value(item, key, value)
    log("SetMediaItemInfo_Value", item, key, value)
    item.info[key] = value
    touch()
    return true
  end

  -- ------------------------------------------------------ marcadores de tempo
  local function sort_tempo_markers()
    table.sort(r._tempo_markers, function(a, b) return a.time < b.time end)
  end

  function api.CountTempoTimeSigMarkers(_) return #r._tempo_markers end

  function api.GetTempoTimeSigMarker(_, idx)
    local m = r._tempo_markers[idx + 1]
    if not m then return false, -1, 0, 0, 0, 0, 0, false end
    return true, m.time, 0, 0, m.bpm, m.num, m.denom, m.linear or false
  end

  -- ptidx -1 cria; senão altera. num/denom 0 = sem mudança de fórmula.
  function api.SetTempoTimeSigMarker(_, ptidx, timepos, measurepos, beatpos, bpm, num, denom, linear)
    log("SetTempoTimeSigMarker", ptidx, timepos, measurepos, beatpos, bpm, num, denom, linear)
    if ptidx == -1 then
      r._tempo_markers[#r._tempo_markers + 1] = { time = timepos, bpm = bpm, num = num, denom = denom, linear = linear }
    else
      local m = r._tempo_markers[ptidx + 1]
      if not m then return false end
      m.time, m.bpm, m.num, m.denom, m.linear = timepos, bpm, num, denom, linear
    end
    sort_tempo_markers()
    touch()
    return true
  end

  function api.DeleteTempoTimeSigMarker(_, idx)
    log("DeleteTempoTimeSigMarker", idx)
    if not r._tempo_markers[idx + 1] then return false end
    table.remove(r._tempo_markers, idx + 1)
    touch()
    return true
  end

  -- Tempo e numerador das configurações do projeto: o primeiro segmento.
  function api.GetProjectTimeSignature2(_)
    return r._tempo[1].bpm, r._tempo[1].num
  end

  -- Fórmula e tempo em vigor em `t`: o tempo do último marcador até `t` e a
  -- fórmula do último marcador que define fórmula (num > 0). O que faltar vem
  -- do segmento do mapa de _tempo.
  function api.TimeMap_GetTimeSigAtTime(_, t)
    local seg = segment_at_time(t)
    local num, denom, bpm = seg.num, seg.denom, seg.bpm
    for _, m in ipairs(r._tempo_markers) do
      if m.time <= t + EPS then
        bpm = m.bpm
        if m.num > 0 then num, denom = m.num, m.denom end
      end
    end
    return num, denom, bpm
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

  -- ---------------------------------------------------------- ProjExtState
  -- ExtState global (não persistente): [section][key] = valor
  function api.GetExtState(section, key) return (r._gext[section] or {})[key] or "" end
  function api.SetExtState(section, key, value, _)
    r._gext[section] = r._gext[section] or {}
    r._gext[section][key] = value
  end
  function api.DeleteExtState(section, key, _) if r._gext[section] then r._gext[section][key] = nil end end

  function api.GetProjExtState(_, section, key)
    local v = r._ext[section] and r._ext[section][key]
    if v == nil or v == "" then return 0, "" end
    return 1, v
  end

  function api.SetProjExtState(_, section, key, value)
    log("SetProjExtState", section, key, value)
    r._ext[section] = r._ext[section] or {}
    r._ext[section][key] = value ~= "" and value or nil
    touch()
    return 1
  end

  -- --------------------------------------------------------------- transporte
  -- Os saltos só são registrados; o stub não simula a reprodução.
  function api.SetEditCurPos(time, moveview, seekplay)
    log("SetEditCurPos", time, moveview, seekplay)
    r._cursor = time
  end
  function api.GetCursorPosition() return r._cursor end
  function api.GetPlayState() return r._play_state end
  function api.GetPlayPosition2() return r._play_pos end
  function api.OnPlayButton() log("OnPlayButton"); r._play_state = 1; r._play_pos = r._cursor end
  function api.OnStopButton() log("OnStopButton"); r._play_state = 0 end
  function api.OnPauseButton()
    log("OnPauseButton")
    if r._play_state == 1 then r._play_state = 2 elseif r._play_state == 2 then r._play_state = 1 end
  end
  function api.GoToRegion(proj, region_index, use_timeline_order) log("GoToRegion", proj, region_index, use_timeline_order) end

  -- val < 0 consulta; 0 desliga; 1 liga. Retorna o estado.
  function api.GetSetRepeat(val)
    if val >= 0 then log("GetSetRepeat", val); r._repeat = val end
    return r._repeat
  end

  function api.GetSet_LoopTimeRange2(proj, isSet, isLoop, start, finish, allowautoseek)
    if isSet then
      log("GetSet_LoopTimeRange2", proj, isSet, isLoop, start, finish, allowautoseek)
      r._loop = { start, finish }
    end
    return r._loop[1], r._loop[2]
  end

  -- -------------------------------------------------------------- entrada MIDI
  function r.add_midi_input(dev, name, present)
    r._midi_inputs[dev] = { name = name, present = present ~= false }
  end

  function r.set_midi_present(dev, present) r._midi_inputs[dev].present = present end

  -- Evento recebido; `dev` pode trazer o bit 0x10000 do modo de controle.
  function r.midi_in(dev, status, d1, d2, ts)
    r._midi_seq = r._midi_seq + 1
    local buf = string.char(status, d1 or 0, d2 or 0)
    r._midi_events[#r._midi_events + 1] = { seq = r._midi_seq, buf = buf, ts = ts or 0, dev = dev }
  end

  function r.set_now(t) r._now = t end

  function r.add_midi_output(idx, name) r._midi_outputs[idx] = name end

  function api.GetMaxMidiOutputs()
    local n = 0
    for idx in pairs(r._midi_outputs) do n = math.max(n, idx + 1) end
    return n
  end

  function api.GetMIDIOutputName(idx, _)
    local name = r._midi_outputs[idx]
    return name ~= nil, name or ""
  end

  function api.StuffMIDIMessage(mode, b1, b2, b3) log("StuffMIDIMessage", mode, b1, b2, b3) end

  function api.MIDI_GetRecentInputEvent(idx)
    local e = r._midi_events[#r._midi_events - idx]
    if not e then return 0, "", 0, -1, 0, 0 end
    return e.seq, e.buf, e.ts, e.dev, 0, 0
  end

  function api.GetNumMIDIInputs()
    local n = 0
    for dev in pairs(r._midi_inputs) do n = math.max(n, dev + 1) end
    return n
  end

  -- true só com o dispositivo presente; o nome vem mesmo sem ele.
  function api.GetMIDIInputName(dev, _)
    local d = r._midi_inputs[dev]
    if not d then return false, "" end
    return d.present, d.name
  end

  function api.time_precise() return r._now end

  -- ------------------------------------------------------------------ outros
  function api.GetAppVersion() return r._app_version end
  -- r._exec[cmd] = saída do comando (sem a linha do código de saída)
  function api.GetOS() return r._app_version:match("/(.*)$") or "macOS-arm64" end
  function api.ExecProcess(cmd, _)
    log("ExecProcess", cmd)
    local out = (rawget(r, "_exec") or {})[cmd]
    if not out then return "-1\n" end
    return "0\n" .. out
  end
  -- área útil do monitor: r._screen = { l, t, r, b }
  function api.my_getViewport(_, _, _, _, _, _, _, _, _)
    local sc = rawget(r, "_screen") or { 0, 25, 1920, 1080 }
    return sc[1], sc[2], sc[3], sc[4]
  end
  function api.get_ini_file() return rawget(r, "_ini_path") or (r._resource_path .. "/reaper.ini") end
  function api.GetResourcePath() return r._resource_path end
  function api.GetProjectPath() return r._project_path end
  -- r._files: [caminho] = true/false força o resultado; senão vale o disco
  function api.file_exists(path)
    if r._files[path] ~= nil then return r._files[path] end
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
  end
  -- pastas de verdade no disco (os testes da biblioteca usam um diretório temporário)
  function api.EnumerateSubdirectories(path, i)
    local p = io.popen("find '" .. path .. "' -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort")
    local names = {}
    for line in p:lines() do names[#names + 1] = line:match("([^/]+)$") end
    p:close()
    return names[i + 1]
  end
  function api.EnumerateFiles(path, i)
    local p = io.popen("find '" .. path .. "' -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort")
    local names = {}
    for line in p:lines() do names[#names + 1] = line:match("([^/]+)$") end
    p:close()
    return names[i + 1]
  end
  -- r._user_file: arquivo "escolhido" no diálogo (nil = cancelou)
  function api.GetUserFileNameForRead(file, title, ext)
    log("GetUserFileNameForRead", file, title, ext)
    local picked = rawget(r, "_user_file")
    return picked ~= nil, picked or file
  end
  -- r._installed_fx = { { name, ident } }
  function api.EnumInstalledFX(i)
    local fx = (rawget(r, "_installed_fx") or {})[i + 1]
    if not fx then return false, "", "" end
    return true, fx[1], fx[2]
  end
  function api.RecursiveCreateDirectory(path, _)
    log("RecursiveCreateDirectory", path)
    os.execute("mkdir -p '" .. path .. "' 2>/dev/null")
    return 1
  end
  -- r._midi_cc = { resolution, val }: a action foi disparada por um CC
  function api.get_action_context()
    local cc = r._midi_cc or { -1, -1 }
    return true, "/stub/LiveSections/LiveSections.lua", 0, 0, 0, cc[1], cc[2]
  end
  function api.ShowConsoleMsg(msg) log("ShowConsoleMsg", msg) end
  function api.MB(msg, title, kind) log("MB", msg, title, kind); return 1 end
  function api.defer(fn) log("defer", fn) end
  function api.atexit(fn) log("atexit", fn) end
  function api.UpdateTimeline() log("UpdateTimeline") end
  function api.UpdateArrange() log("UpdateArrange") end
  function api.PreventUIRefresh(n) log("PreventUIRefresh", n) end
  function api.MarkProjectDirty() log("MarkProjectDirty") end
  function api.Undo_BeginBlock() log("Undo_BeginBlock") end
  function api.Undo_EndBlock(desc, flags)
    log("Undo_EndBlock", desc, flags)
    r._undo[#r._undo + 1] = desc
  end
  function api.Undo_CanUndo2(_) return r._undo[#r._undo] end
  function api.Undo_DoUndo2(_) log("Undo_DoUndo2"); r._undo[#r._undo] = nil; return 1 end
  function api.Undo_CanRedo2(_) return nil end
  function api.Undo_DoRedo2(_) log("Undo_DoRedo2"); return 0 end
  function api.ColorToNative(red, green, blue) return red | (green << 8) | (blue << 16) end
  function api.ColorFromNative(c) return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF end

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
