-- Pacote de uma música para a biblioteca ("Exportar música").
--
-- Junta tudo o que a música precisa para tocar em outro projeto: as tracks
-- (chunk com FX e o estado do Kontakt, rotas, automação e itens), o marcador
-- e as regiões, a cifra, a anotação, o vínculo do Kontakt, os parâmetros das
-- camadas e as linhas do Mapeamento que eles usam. Não grava arquivos: quem
-- grava e copia os áudios é core/library.
--
-- Posições ficam relativas ao início da música (RF-186). Nos chunks
-- (validado no spike 10):
--   - TRACKID/FXID/GUID/IGUID saem: o REAPER cria GUIDs novos ao importar,
--     e a mesma música pode entrar duas vezes no setlist;
--   - só ficam os itens que começam dentro da música, e só os pontos de
--     automação da track dentro dela, com um ponto no início com o valor que
--     vinha de antes (RF-185);
--   - AUXRECV aponta para o índice da track no pacote (0 = 1ª); rotas de
--     tracks fora do pacote saem (RF-200);
--   - FILE vira "audio/<nome>", sem repetir nome entre arquivos (RF-187);
--   - ISBUS vira "0 0": a hierarquia vai em `level` e o import refaz a pasta.
--
-- M.init({ layers, layer_params, chart, song_notes, kontakt_cc })
-- M.detect_tracks(song) -> { track }   na ordem do projeto (RF-179)
-- M.filter_chunk(chunk, start_pos, end_pos, index_of, name_of)
--     -> chunk, files, plugins
--   index_of[índice 0-based da track no projeto] = índice 1-based no pacote
--   name_of(caminho do FILE) -> "audio/<nome>" (sem ele, FILE fica igual)
--   files = { caminho do FILE como estava }, plugins = { "VSTi: Kontakt…" }
-- M.build(song, tracks, opts) -> pkg, problems     opts.name
--   problems = { missing_audio = { caminho } }
--   pkg: ver o Modelo de Dados da TechSpec (formato 1)

local M = {}

M.FORMAT = 1

local PROJ = 0
local EPS = 1e-6

local layers, layer_params, chart, song_notes, kcc

function M.init(deps)
  layers, layer_params, chart = deps.layers, deps.layer_params, deps.chart
  song_notes, kcc = deps.song_notes, deps.kontakt_cc
end

-- ------------------------------------------------------------------ detecção

local function index_of_track(tr)
  return math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1
end

local function has_item_in(tr, song)
  for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local p = reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, k), "D_POSITION")
    if p >= song.start_pos - EPS and p < song.end_pos - EPS then return true end
  end
  return false
end

function M.detect_tracks(song)
  local picked = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if has_item_in(tr, song) then picked[tr] = true end
  end
  local kontakt = layers.track_of(song)
  if kontakt then
    picked[kontakt] = true
    for _, tr in ipairs(layers.layers_of(kontakt)) do picked[tr] = true end
  end
  -- pastas que contêm qualquer uma delas
  for tr in pairs(picked) do
    local p = reaper.GetParentTrack(tr)
    while p do picked[p] = true; p = reaper.GetParentTrack(p) end
  end
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if picked[tr] then out[#out + 1] = tr end
  end
  return out
end

-- ------------------------------------------------------------------ chunk

local function num(x)
  local s = string.format("%.10f", math.abs(x) < EPS and 0 or x)
  return (s:gsub("0+$", ""):gsub("%.$", ""))
end

-- Nome do plugin na linha que abre o FX: <VST "VSTi: Kontakt (NI)" …,
-- <JS arquivo "" …, <AU "AUi: …", <CLAP "CLAPi: …", <LV2 …, <DX ….
local function plugin_name(t)
  local tag, rest = t:match("^<(%u[%u%d]*)%s+(.*)$")
  if not tag then return nil end
  if tag == "JS" then
    local file = rest:match('^"(.-)"') or rest:match("^(%S+)")
    return file and ("JS: " .. file)
  end
  if tag == "VST" or tag == "AU" or tag == "CLAP" or tag == "LV2" or tag == "DX" then
    return rest:match('^"(.-)"') or rest:match("^(%S+)")
  end
end

local GUID_LINE = { TRACKID = true, FXID = true, GUID = true, IGUID = true }

function M.filter_chunk(chunk, start_pos, end_pos, index_of, name_of)
  local out, files, plugins, seen_file, seen_plugin = {}, {}, {}, {}, {}
  local depth = 0
  local skip_to = nil        -- pulando um item fora da música até voltar a esta profundidade
  local item = nil           -- { first = índice em out, depth } até ler o POSITION
  local item_depth = nil     -- dentro de um item (envelopes de take não mudam)
  local env = nil            -- envelope da track: { depth, before = linha PT, has_start }

  local function emit(line) out[#out + 1] = line end

  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local t = line:match("^%s*(.-)%s*$")
    local indent = line:match("^(%s*)")
    local opens, closes = t:sub(1, 1) == "<", t == ">"

    if skip_to then
      if opens then depth = depth + 1 elseif closes then depth = depth - 1 end
      if depth < skip_to then skip_to = nil end
      goto continue
    end

    if opens then
      depth = depth + 1
      if t:match("^<ITEM") then
        item, item_depth = { first = #out + 1, depth = depth }, depth
      elseif not item_depth and t:match("^<%u*ENV") then
        env = { depth = depth }
      end
      local name = plugin_name(t)
      if name and not seen_plugin[name] then seen_plugin[name] = true; plugins[#plugins + 1] = name end
      if t:match("^<TRACK") then line = (line:gsub("%s*{[%x%-]+}", "")) end
      emit(line)
      goto continue
    end

    if closes then
      if env and depth == env.depth then
        -- automação só com pontos antes da música: mantém o último valor
        if env.before and not env.has_start then
          table.insert(out, env.at, env.before)
        end
        env = nil
      end
      if item_depth and depth == item_depth then item_depth = nil end
      depth = depth - 1
      emit(line)
      goto continue
    end

    do
      local key = t:match("^(%S+)")
      if GUID_LINE[key] then goto continue end

      if item and key == "POSITION" then
        local p = tonumber(t:match("^POSITION%s+(%S+)"))
        if p and (p < start_pos - EPS or p >= end_pos - EPS) then
          for _ = item.first, #out do out[#out] = nil end
          skip_to, item, item_depth = item.depth, nil, nil   -- pula até o item fechar
          goto continue
        end
        line = indent .. "POSITION " .. num(p - start_pos) .. (t:match("^POSITION%s+%S+(.*)$") or "")
        item = nil
      elseif env and depth == env.depth and key == "PT" then
        local tm, rest = t:match("^PT%s+(%S+)(.*)$")
        tm = tonumber(tm)
        if tm and tm < start_pos - EPS then
          env.before = indent .. "PT 0" .. rest
          env.at = env.at or #out + 1
          goto continue
        end
        if tm and tm >= end_pos - EPS then goto continue end
        if tm then
          if math.abs(tm - start_pos) < EPS then env.has_start = true end
          env.at = env.at or #out + 1
          line = indent .. "PT " .. num(tm - start_pos) .. rest
        end
      elseif key == "FILE" then
        local path, rest = t:match('^FILE%s+"(.-)"(.*)$')
        if not path then path, rest = t:match("^FILE%s+(%S+)(.*)$") end
        if path then
          if not seen_file[path] then seen_file[path] = true; files[#files + 1] = path end
          if name_of then line = indent .. 'FILE "' .. name_of(path) .. '"' .. rest end
        end
      elseif key == "AUXRECV" then
        local src, rest = t:match("^AUXRECV%s+(%d+)(.*)$")
        local idx = src and index_of and index_of[tonumber(src)]
        if not idx then goto continue end
        line = indent .. "AUXRECV " .. (idx - 1) .. rest
      elseif key == "ISBUS" then
        line = indent .. "ISBUS 0 0"
      end
    end
    emit(line)
    ::continue::
  end
  return table.concat(out, "\n"), files, plugins
end

-- ------------------------------------------------------------------ pacote

local SEP = package.config:sub(1, 1)

local function is_abs(p) return p:match("^%a:[\\/]") or p:match("^[\\/]") end
local function base(p) return p:match("([^\\/]+)$") or p end

local function absolute(path)
  if is_abs(path) then return path end
  return (reaper.GetProjectPath("") or ""):gsub("[\\/]$", "") .. SEP .. path
end

-- Dá a cada arquivo um nome único em audio/ ("Guia.wav", "Guia 2.wav").
local function namer(audio, problems)
  local by_path, used = {}, {}
  return function(path)
    local abs = absolute(path)
    if by_path[abs] then return by_path[abs] end
    local name = base(abs)
    local stem, ext = name:match("^(.-)(%.[^.]*)$")
    stem, ext = stem or name, ext or ""
    local k = 1
    while used[name:lower()] do k = k + 1; name = stem .. " " .. k .. ext end
    used[name:lower()] = true
    local entry = { file = "audio/" .. name, from = abs }
    if not reaper.file_exists(abs) then
      entry.missing = true
      problems.missing_audio[#problems.missing_audio + 1] = abs
    end
    audio[#audio + 1] = entry
    by_path[abs] = entry.file
    return entry.file
  end
end

function M.build(song, tracks, opts)
  opts = opts or {}
  local problems = { missing_audio = {} }
  local pkg = {
    format = M.FORMAT,
    name = opts.name or song.name,
    exported_at = os.date("%Y-%m-%d %H:%M"),
    live_sections = require("version"),
    length = song.end_pos - song.start_pos,
    regions = {}, params = {}, mapping_rows = {}, plugins = {}, tracks = {}, audio = {},
    chart = chart.get_text(song),
    note = song_notes.get(song),
  }

  for _, sec in ipairs(song.sections or {}) do
    pkg.regions[#pkg.regions + 1] = {
      start = sec.start_pos - song.start_pos, ["end"] = sec.end_pos - song.start_pos,
      name = sec.name, color = sec.color,
    }
  end

  local index_of, by_guid, in_pkg = {}, {}, {}
  for n, tr in ipairs(tracks) do
    index_of[index_of_track(tr)] = n
    by_guid[reaper.GetTrackGUID(tr)] = n
    in_pkg[tr] = true
  end

  local name_of = namer(pkg.audio, problems)
  local seen_plugin = {}
  for n, tr in ipairs(tracks) do
    -- nível = quantas pastas do pacote contêm a track
    local level, p = 0, reaper.GetParentTrack(tr)
    while p do
      if in_pkg[p] then level = level + 1 end
      p = reaper.GetParentTrack(p)
    end
    local _, raw = reaper.GetTrackStateChunk(tr, "", false)
    local chunk, _, plugins = M.filter_chunk(raw, song.start_pos, song.end_pos, index_of, name_of)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    pkg.tracks[n] = { name = name, level = level, chunk = chunk }
    for _, pl in ipairs(plugins) do
      if not seen_plugin[pl] then seen_plugin[pl] = true; pkg.plugins[#pkg.plugins + 1] = pl end
    end
  end

  -- Kontakt, parâmetros e linhas do Mapeamento (RF-183, RF-188, RF-211)
  local kontakt = layers.track_of(song)
  pkg.kontakt = kontakt and by_guid[reaper.GetTrackGUID(kontakt)] or nil
  if pkg.kontakt then
    local rows_seen = {}
    for _, p in ipairs(layer_params.list(song)) do
      local layer = by_guid[p.layer]
      if layer then
        pkg.params[#pkg.params + 1] = { row = p.row, layer = layer, name = p.name }
        local row = kcc.get(p.row)
        if row and not rows_seen[row.id] then
          rows_seen[row.id] = true
          pkg.mapping_rows[#pkg.mapping_rows + 1] = { id = row.id, name = row.name, cc = row.cc, kind = row.kind }
        end
      end
    end
  end
  return pkg, problems
end

return M
