-- Spike 10: dá para levar uma música inteira para outro projeto pelo chunk
-- das tracks? (base do "Exportar música" / "Montar setlist")
--
-- Pega a música do cursor (entre o marcador "SONG:" antes dele e o próximo) e:
--   1. junta as tracks: as que têm item começando na música + as SELECIONADAS
--      (selecione antes a track do Kontakt e as camadas);
--   2. lê o chunk de cada uma (GetTrackStateChunk), tira os GUIDs, deixa só os
--      itens da música com posição relativa, reescreve as rotas (AUXRECV) para
--      o índice no pacote e copia os áudios para uma pasta temporária, com
--      caminho relativo;
--   3. abre uma aba de projeto nova e recria as tracks a partir do pacote,
--      com as rotas e os áudios apontando para as cópias;
--   4. imprime o que conferir.
--
-- Não salva nada no projeto original. A aba nova pode ser fechada sem salvar.

local NEW_PROJECT_TAB = 40859   -- File: New project tab

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local function kb(n) return string.format("%.1f KB", n / 1024) end
local function now() return reaper.time_precise() end

local SEP = package.config:sub(1, 1)
local function join(a, b) return a:gsub("[\\/]$", "") .. SEP .. b end
local function is_abs(p) return p:match("^%a:[\\/]") or p:match("^[\\/]") end
local function base(p) return p:match("([^\\/]+)$") or p end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end

local function copy(src, dst)
  local i = io.open(src, "rb")
  if not i then return false, 0 end
  local o = io.open(dst, "wb")
  if not o then i:close(); return false, 0 end
  local n = 0
  while true do
    local block = i:read(1024 * 1024)
    if not block then break end
    o:write(block)
    n = n + #block
  end
  i:close(); o:close()
  return true, n
end

-- ------------------------------------------------------------------ música do cursor
local cursor = reaper.GetCursorPosition()
local song_start, song_end, song_name = 0, math.huge, "(sem marcador SONG:)"
local i = 0
while true do
  local ret, isrgn, pos, _, name = reaper.EnumProjectMarkers3(0, i)
  if ret == 0 then break end
  if not isrgn and name:match("^SONG:") then
    if pos <= cursor + 1e-6 then song_start, song_name = pos, name
    elseif pos < song_end then song_end = pos end
  end
  i = i + 1
end
if song_end == math.huge then song_end = reaper.GetProjectLength(0) end

out(string.format("\n== Spike 10 · REAPER %s ==", reaper.GetAppVersion()))
out(string.format("música: %s  (%.3f – %.3f s)", song_name, song_start, song_end))

-- ------------------------------------------------------------------ tracks
local picked, order = {}, {}
for t = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, t)
  local keep = reaper.IsTrackSelected(tr)
  for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local p = reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, k), "D_POSITION")
    if p >= song_start - 1e-6 and p < song_end - 1e-6 then keep = true end
  end
  if keep then picked[t] = #order + 1; order[#order + 1] = tr end
end
if #order == 0 then
  out("Nenhuma track: ponha o cursor dentro de uma música com itens, ou selecione as tracks.")
  return
end

-- ------------------------------------------------------------------ pasta temporária
local dir = join(join(reaper.GetResourcePath(), "Live Sections"), "spike10")
reaper.RecursiveCreateDirectory(join(dir, "audio"), 0)
local proj_dir = reaper.GetProjectPath("")

-- ------------------------------------------------------------------ chunk filtrado
local copied, copied_bytes, missing, used_names = {}, 0, {}, {}

local function audio_for(path)
  if not is_abs(path) then path = join(proj_dir, path) end
  if copied[path] then return copied[path] end
  local name = base(path)
  local stem, ext = name:match("^(.-)(%.[^.]*)$")
  stem, ext = stem or name, ext or ""
  local k = 1
  while used_names[name:lower()] do k = k + 1; name = stem .. " " .. k .. ext end
  used_names[name:lower()] = true
  local ok, n = copy(path, join(join(dir, "audio"), name))
  if not ok then missing[#missing + 1] = path end
  copied_bytes = copied_bytes + n
  copied[path] = "audio/" .. name
  return copied[path]
end

local function filter(chunk)
  local lines, kept = {}, 0
  local depth, skip_until, in_item, env_depth = 0, nil, false, nil
  local removed_guids, aux_kept, aux_dropped = 0, 0, 0
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local t = line:match("^%s*(.-)%s*$")
    local opens, closes = t:sub(1, 1) == "<", t == ">"
    -- item inteiro fora da música: pula
    if skip_until then
      if opens then depth = depth + 1 elseif closes then depth = depth - 1 end
      if depth < skip_until then skip_until = nil end
      goto continue
    end
    if opens and t:match("^<ITEM") then
      -- decide pelo POSITION, que vem logo depois: guarda e decide na linha seguinte
      in_item = { start = #lines + 1, depth = depth + 1 }
    end
    if opens and (t:match("ENV") ) then env_depth = depth + 1 end

    if t:match("^TRACKID ") or t:match("^FXID ") or t:match("^GUID ") or t:match("^IGUID ") then
      removed_guids = removed_guids + 1
      goto counted
    end
    if in_item and t:match("^POSITION ") then
      local p = tonumber(t:match("^POSITION ([%d%.%-e]+)"))
      if p and (p < song_start - 1e-6 or p >= song_end - 1e-6) then
        -- descarta o que já entrou do item e pula o resto dele
        for _ = in_item.start, #lines do table.remove(lines) end
        skip_until, in_item = in_item.depth, nil
        depth = depth + (opens and 1 or 0)
        goto continue
      end
      line = line:gsub("POSITION [%d%.%-e]+", "POSITION " .. string.format("%.10f", p - song_start), 1)
      kept = kept + 1
      in_item = nil
    end
    if env_depth and t:match("^PT ") then
      local tm = tonumber(t:match("^PT ([%d%.%-e]+)"))
      if tm and (tm < song_start - 1e-6 or tm >= song_end - 1e-6) then goto counted end
      line = line:gsub("PT [%d%.%-e]+", "PT " .. string.format("%.10f", tm - song_start), 1)
    end
    if t:match("^FILE ") then
      local path, rest = t:match('^FILE "(.-)"(.*)$')
      if not path then path, rest = t:match("^FILE (%S+)(.*)$") end
      if path then line = 'FILE "' .. audio_for(path) .. '"' .. (rest or "") end
    end
    if t:match("^AUXRECV ") then
      local src, rest = t:match("^AUXRECV (%d+)(.*)$")
      local idx = src and picked[tonumber(src)]
      if not idx then aux_dropped = aux_dropped + 1; goto counted end
      line = "AUXRECV " .. (idx - 1) .. rest      -- índice no pacote (0 = 1ª track)
      aux_kept = aux_kept + 1
    end
    lines[#lines + 1] = line
    ::counted::
    if opens then depth = depth + 1 elseif closes then
      if env_depth and depth == env_depth then env_depth = nil end
      depth = depth - 1
    end
    ::continue::
  end
  return table.concat(lines, "\n"), kept, removed_guids, aux_kept, aux_dropped
end

local pkg, t_get, t_filter, orig_guid = {}, 0, 0, {}
out(string.format("\n-- exportar (%d tracks) --", #order))
for n, tr in ipairs(order) do
  local t0 = now()
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local t1 = now()
  local filtered, items, guids, aux_k, aux_d = filter(chunk)
  local t2 = now()
  t_get, t_filter = t_get + (t1 - t0), t_filter + (t2 - t1)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  orig_guid[n] = reaper.GetTrackGUID(tr)
  local fx = {}
  for f = 0, reaper.TrackFX_GetCount(tr) - 1 do fx[#fx + 1] = select(2, reaper.TrackFX_GetFXName(tr, f, "")) end
  local rel = {}                         -- posições relativas esperadas, na ordem dos itens
  for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, k)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if p >= song_start - 1e-6 and p < song_end - 1e-6 then
      rel[#rel + 1] = { pos = p - song_start, beat = reaper.GetMediaItemInfo_Value(it, "C_BEATATTACHMODE") }
    end
  end
  pkg[n] = { name = name, chunk = filtered, fx = fx, sends_before = reaper.GetTrackNumSends(tr, -1), rel = rel }
  out(string.format("%2d. %-24s chunk %s → %s · leitura %.0f ms · itens %d · GUIDs tirados %d · rotas %d (fora: %d) · FX: %s",
    n, name, kb(#(ok and chunk or "")), kb(#filtered), (t1 - t0) * 1000, items, guids, aux_k, aux_d,
    #fx > 0 and table.concat(fx, ", ") or "—"))
end
local nfiles = 0
for _ in pairs(copied) do nfiles = nfiles + 1 end
out(string.format("áudios copiados: %d (%s) para %s", nfiles - #missing, kb(copied_bytes), join(dir, "audio")))
for _, m in ipairs(missing) do out("  FALTOU: " .. m) end
out(string.format("tempo total: leitura %.0f ms, filtro %.0f ms", t_get * 1000, t_filter * 1000))

-- tempo, fórmula e fase no início da música (o import real recria o tempo antes das tracks)
local start_bpm = reaper.TimeMap_GetDividedBpmAtTime(song_start)
local _, start_num, start_denom = reaper.TimeMap_GetTimeSigAtTime(0, song_start)
local beats_in_bar, measure = reaper.TimeMap2_timeToBeats(0, song_start)
out(string.format("início: %.2f BPM %d/%d · compasso %d, tempo %.3f (0 = no compasso)",
  start_bpm, start_num, start_denom, measure + 1, beats_in_bar))
out(string.format("timebase do projeto (itemtimelock): %s · timebase da aba nova vem do modelo de projeto",
  tostring(select(2, reaper.get_config_var_string("itemtimelock")))))

-- ------------------------------------------------------------------ importar numa aba nova
reaper.Main_OnCommand(NEW_PROJECT_TAB, 0)
local new_bpm = reaper.TimeMap_GetDividedBpmAtTime(0)
out(string.format("aba nova antes: %.2f BPM · itemtimelock %s", new_bpm,
  tostring(select(2, reaper.get_config_var_string("itemtimelock")))))
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, start_bpm, start_num, start_denom, false)
reaper.UpdateTimeline()
reaper.PreventUIRefresh(1)
local new, t_set = {}, 0
for n = 1, #pkg do
  reaper.InsertTrackAtIndex(n - 1, false)
  new[n] = reaper.GetTrack(0, n - 1)
end
for n, p in ipairs(pkg) do
  local chunk = p.chunk
  -- AUXRECV: índice no pacote → índice no projeto (aqui o mesmo, mas a conta é a do Live Sections)
  chunk = chunk:gsub("\nAUXRECV (%d+)", function(idx) return "\nAUXRECV " .. tonumber(idx) end)
  chunk = chunk:gsub('FILE "audio/', 'FILE "' .. join(dir, "audio"):gsub("%%", "%%%%") .. SEP)
  local t0 = now()
  reaper.SetTrackStateChunk(new[n], chunk, false)
  t_set = t_set + (now() - t0)
  reaper.SetMediaTrackInfo_Value(new[n], "I_FOLDERDEPTH", 0)
end
reaper.AddProjectMarker2(0, false, 0, 0, song_name, -1, 0)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.TrackList_AdjustWindows(false)

-- ------------------------------------------------------------------ conferir
out(string.format("\n-- importado numa aba nova (gravação dos chunks: %.0f ms) --", t_set * 1000))
local guids, dup, same_as_orig = {}, 0, 0
local offline = 0
for n, tr in ipairs(new) do
  local g = reaper.GetTrackGUID(tr)
  if guids[g] then dup = dup + 1 end
  guids[g] = true
  if g == orig_guid[n] then same_as_orig = same_as_orig + 1 end
  local fx = {}
  for f = 0, reaper.TrackFX_GetCount(tr) - 1 do fx[#fx + 1] = select(2, reaper.TrackFX_GetFXName(tr, f, "")) end
  local items = reaper.CountTrackMediaItems(tr)
  for k = 0, items - 1 do
    local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(tr, k))
    local src = take and reaper.GetMediaItemTake_Source(take)
    local file = src and reaper.GetMediaSourceFileName(src, "")
    if file and file ~= "" and not exists(file) then offline = offline + 1 end
  end
  out(string.format("%2d. %-24s itens %d · rotas recebidas %d (antes %d) · FX %d/%d%s",
    n, pkg[n].name, items, reaper.GetTrackNumSends(tr, -1), pkg[n].sends_before, #fx, #pkg[n].fx,
    #fx < #pkg[n].fx and "  ← FX A MENOS" or ""))
end
out(string.format("GUIDs de track repetidos: %d · iguais aos do original: %d · itens offline: %d", dup, same_as_orig, offline))

-- posição de cada item: esperada (relativa no original) × na aba nova
out("\n-- posições (s): esperada → na aba nova (diferença) · timebase do item --")
local worst = 0
for n, tr in ipairs(new) do
  for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, k)
    local got = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local exp = pkg[n].rel[k + 1]
    local diff = exp and (got - exp.pos) or 0
    if math.abs(diff) > math.abs(worst) then worst = diff end
    if k < 3 then
      out(string.format("%2d.%d %-20s %.4f → %.4f (%+.4f) · beat %s→%s", n, k + 1, pkg[n].name,
        exp and exp.pos or -1, got, diff, exp and exp.beat or "?",
        reaper.GetMediaItemInfo_Value(it, "C_BEATATTACHMODE")))
    end
  end
end
out(string.format("maior diferença: %+.4f s", worst))
out([[

Confira na aba nova:
  1. Arme a track do Kontakt (entrada do teclado) e toque: mesmo timbre e ajustes?
  2. As camadas recebem do Kontakt e tocam (medidores nelas)?
  3. Os áudios estão no lugar em relação ao marcador e tocam?
  4. Abra o FX do Kontakt: carregou rápido? Pediu amostras?
Mande este console e as respostas 1–4. Depois feche a aba sem salvar.]])
