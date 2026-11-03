-- Adiciona uma música da biblioteca no fim do projeto ("Montar setlist").
--
-- A música começa um compasso depois do fim do projeto, numa linha de
-- compasso mais a fase que ela tinha (RF-196); num projeto vazio, no
-- início. O tempo é recriado antes das tracks: assim os itens caem no ponto
-- certo da grade (spike 10). As tracks entram numa track-pasta com o nome da
-- música, nos níveis do pacote (RF-197), com POSITION/PT absolutos, FILE
-- apontando para a biblioteca (RF-203) e AUXRECV para as tracks novas
-- (RF-200). Cifra, anotação, vínculo do Kontakt e parâmetros valem com os
-- GUIDs novos (RF-199); linhas do Mapeamento que faltam são criadas (RF-202).
-- Tudo num passo de undo (RF-204).
--
-- M.init({ layers, layer_params, chart, song_notes, kontakt_cc, tempo_align, jsfx })
-- M.position(pkg) -> bar_line, start_pos
-- M.add(pkg) -> ok, report     pkg lido por core/library (pkg.folder, audio[i].path)
--   report = { song = { marker_idx, name, start_pos },
--              learn = { nome da linha }, cc_differs = { nome da linha },
--              offline = { arquivo } }

local M = {}

local PROJ = 0
local EPS = 1e-6
local SEP = package.config:sub(1, 1)
local UNDO = "Live Sections: adicionar música da biblioteca"
local OWN_JSFX = "JS: LiveSections/"

local layers, layer_params, chart, song_notes, kcc, tempo_align, jsfx

function M.init(deps)
  layers, layer_params, chart = deps.layers, deps.layer_params, deps.chart
  song_notes, kcc, tempo_align, jsfx = deps.song_notes, deps.kontakt_cc, deps.tempo_align, deps.jsfx
end

-- ------------------------------------------------------------------ posição

-- Fim do projeto: itens (GetProjectLength), marcadores e regiões.
local function project_end()
  local last = reaper.GetProjectLength(PROJ)
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend = reaper.EnumProjectMarkers3(PROJ, i)
    if ret == 0 then break end
    last = math.max(last, isrgn and rgnend or pos)
    i = i + 1
  end
  return last
end

function M.position(pkg)
  local phase = (pkg and pkg.phase_beats) or 0
  local first = pkg and pkg.tempo and pkg.tempo[1]
  local offset = (first and phase > EPS) and phase * 60 / first.bpm or 0
  local last = project_end()
  if last < EPS and reaper.CountTracks(PROJ) == 0 then return 0, offset end
  local beat, measure = reaper.TimeMap2_timeToBeats(PROJ, last)
  local bar = measure + (beat > EPS and 2 or 1)          -- folga de 1 compasso inteiro
  local bar_line = reaper.TimeMap2_beatsToTime(PROJ, 0, bar)
  return bar_line, bar_line + offset
end

-- ------------------------------------------------------------------ chunk

local function num(x)
  local s = string.format("%.10f", x)
  return (s:gsub("0+$", ""):gsub("%.$", ""))
end

-- Chunk do pacote → chunk desta posição. `first` = índice 0-based da 1ª
-- track do pacote no projeto (AUXRECV i → first + i).
local function place_chunk(chunk, start_pos, first, folder)
  local out = {}
  local depth, item_depth, env_depth = 0, nil, nil
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local t = line:match("^%s*(.-)%s*$")
    local indent = line:match("^(%s*)")
    if t:sub(1, 1) == "<" then
      depth = depth + 1
      if t:match("^<ITEM") then item_depth = depth
      elseif not item_depth and t:match("^<%u*ENV") then env_depth = depth end
    elseif t == ">" then
      if depth == item_depth then item_depth = nil end
      if depth == env_depth then env_depth = nil end
      depth = depth - 1
    else
      local key = t:match("^(%S+)")
      if key == "POSITION" and item_depth and depth == item_depth then
        local p, rest = t:match("^POSITION%s+(%S+)(.*)$")
        line = indent .. "POSITION " .. num(start_pos + tonumber(p)) .. rest
      elseif key == "PT" and env_depth and depth == env_depth then
        local p, rest = t:match("^PT%s+(%S+)(.*)$")
        line = indent .. "PT " .. num(start_pos + tonumber(p)) .. rest
      elseif key == "FILE" then
        local rel, rest = t:match('^FILE%s+"audio/(.-)"(.*)$')
        if rel then line = indent .. 'FILE "' .. folder .. SEP .. "audio" .. SEP .. rel .. '"' .. rest end
      elseif key == "AUXRECV" then
        local i, rest = t:match("^AUXRECV%s+(%d+)(.*)$")
        if i then line = indent .. "AUXRECV " .. (first + tonumber(i)) .. rest end
      end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------ adicionar

local function add_tracks(pkg, start_pos)
  local base = reaper.CountTracks(PROJ)
  reaper.InsertTrackAtIndex(base, true)
  local folder = reaper.GetTrack(PROJ, base)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", pkg.name, true)
  local new = {}
  for n in ipairs(pkg.tracks) do
    reaper.InsertTrackAtIndex(base + n, true)
    new[n] = reaper.GetTrack(PROJ, base + n)
  end
  for n, t in ipairs(pkg.tracks) do
    reaper.SetTrackStateChunk(new[n], place_chunk(t.chunk, start_pos, base + 1, pkg.folder), false)
  end
  -- pasta: cada track sobe/desce até o nível da seguinte; a última fecha tudo
  local levels = { 0 }
  for n, t in ipairs(pkg.tracks) do levels[n + 1] = 1 + (tonumber(t.level) or 0) end
  local all = { folder, table.unpack(new) }
  for i, tr in ipairs(all) do
    reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", (levels[i + 1] or 0) - levels[i])
  end
  return new
end

local function add_markers(pkg, start_pos)
  local idx = reaper.AddProjectMarker2(PROJ, false, start_pos, 0, "SONG: " .. pkg.name, -1, 0)
  for _, r in ipairs(pkg.regions or {}) do
    reaper.AddProjectMarker2(PROJ, true, start_pos + r.start, start_pos + r["end"], r.name or "", -1, r.color or 0)
  end
  return idx
end

local function add_params(pkg, song, new, report)
  local kontakt = pkg.kontakt and new[pkg.kontakt]
  if not kontakt then return end
  layers.link(song, kontakt)
  for _, row in ipairs(pkg.mapping_rows or {}) do
    local res = kcc.ensure_row(row)
    if res == "created" then report.learn[#report.learn + 1] = row.name
    elseif res == "cc_differs" then report.cc_differs[#report.cc_differs + 1] = row.name end
  end
  local slot_of = {}
  for slot, l in ipairs(layers.layers(song)) do slot_of[l.track_guid] = slot end
  for _, p in ipairs(pkg.params or {}) do
    local tr = new[p.layer]
    local slot = tr and slot_of[reaper.GetTrackGUID(tr)]
    if slot and layer_params.bind(song, slot, p.row) and (p.name or "") ~= "" then
      layer_params.rename(song, p.row, p.name)
    end
  end
end

function M.add(pkg)
  local report = { learn = {}, cc_differs = {}, offline = {} }
  for _, a in ipairs(pkg.audio or {}) do
    if a.missing or not (a.path and reaper.file_exists(a.path)) then report.offline[#report.offline + 1] = a.file end
  end
  for _, name in ipairs(pkg.plugins or {}) do
    if name:sub(1, #OWN_JSFX) == OWN_JSFX then jsfx.write_file(); break end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local bar_line, start_pos = M.position(pkg)
  if pkg.tempo and #pkg.tempo > 0 then tempo_align.place_song_tempo(bar_line, start_pos, pkg.tempo) end
  local new = add_tracks(pkg, start_pos)
  local idx = add_markers(pkg, start_pos)
  local song = { marker_idx = idx, name = pkg.name, start_pos = start_pos }
  if (pkg.chart or "") ~= "" then chart.set_text(song, pkg.chart) end
  if (pkg.note or "") ~= "" then song_notes.set(song, pkg.note) end
  add_params(pkg, song, new, report)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock(UNDO, -1)
  report.song = song
  return true, report
end

return M
