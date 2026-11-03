-- Biblioteca de músicas na tela: o quadro Exportar (modo Editar).
--
-- Exportar (RF-177–RF-180, RF-189, RF-190): lista todas as tracks do
-- projeto, com as detectadas como da música já marcadas; o nome (padrão = o
-- da música), o número de itens e o tamanho dos áudios a copiar. Um nome que
-- já existe na biblioteca pede confirmação antes de substituir. No fim,
-- mostra onde salvou, quantos áudios copiou, os que faltaram e o aviso para
-- usar em outro computador.
--
-- M.init({ ImGui, theme, kit, library, song_package })
-- M.open_export(song)
-- M.export_state() -> { song, name, tracks = { { track, label, on } },
--                       items, bytes, confirm, result? }
-- M.toggle(i); M.set_name(nome)
-- M.export() -> "done"|"confirm"|"error", mensagem
-- M.draw(ctx) -> mensagem?      desenha o quadro aberto

local M = {}

local ImGui, theme, kit, library, song_package

local PROJ = 0
local EPS = 1e-6
local EXPORT = "Exportar música"
local OTHER_PC = "Para usar em outro computador, leve a pasta da biblioteca. Lá precisam estar instalados o Kontakt e as bibliotecas dele."

local ex = nil          -- quadro Exportar aberto
local want_open = false

function M.init(deps)
  ImGui, theme, kit = deps.ImGui, deps.theme, deps.kit
  library, song_package = deps.library, deps.song_package
  ex, want_open = nil, false
end

-- ------------------------------------------------------------------ exportar

local function label_of(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local n = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  return n .. ". " .. (name ~= "" and name or "(sem nome)")
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end") or 0
  f:close()
  return n
end

-- Itens que começam na música e tamanho dos arquivos deles (cada um uma vez).
local function summarize()
  local song, seen = ex.song, {}
  ex.items, ex.bytes = 0, 0
  for _, t in ipairs(ex.tracks) do
    if t.on then
      for k = 0, reaper.CountTrackMediaItems(t.track) - 1 do
        local it = reaper.GetTrackMediaItem(t.track, k)
        local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if p >= song.start_pos - EPS and p < song.end_pos - EPS then
          ex.items = ex.items + 1
          local take = reaper.GetActiveTake(it)
          local file = take and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(take), "")
          if file and file ~= "" and not seen[file] then
            seen[file] = true
            ex.bytes = ex.bytes + file_size(file)
          end
        end
      end
    end
  end
end

function M.open_export(song)
  local detected = {}
  for _, tr in ipairs(song_package.detect_tracks(song)) do detected[tr] = true end
  local tracks = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    tracks[#tracks + 1] = { track = tr, label = label_of(tr), on = detected[tr] == true }
  end
  ex = { song = song, name = song.name, tracks = tracks, confirm = false }
  summarize()
  want_open = true
end

function M.export_state() return ex end

function M.toggle(i)
  local t = ex and ex.tracks[i]
  if not t then return end
  t.on = not t.on
  summarize()
end

function M.set_name(name)
  if ex.name ~= name then ex.name, ex.confirm = name, false end
end

local function size_text(bytes)
  if bytes >= 1024 * 1024 * 1024 then return string.format("%.1f GB", bytes / 1024 ^ 3) end
  if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 ^ 2) end
  return string.format("%d KB", math.ceil(bytes / 1024))
end
M.size_text = size_text

function M.export()
  local name = (ex.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return "error", "Dê um nome à música." end
  if library.exists(name) and not ex.confirm then
    ex.confirm = true
    return "confirm", '"' .. name .. '" já está na biblioteca. Exportar de novo substitui.'
  end
  local tracks = {}
  for _, t in ipairs(ex.tracks) do
    if t.on then tracks[#tracks + 1] = t.track end
  end
  local pkg, problems = song_package.build(ex.song, tracks, { name = name })
  local ok, err, info = library.write(pkg)
  if not ok then
    local why = err == "no_dir" and "A pasta da biblioteca não foi encontrada: " or "Sem permissão para gravar em "
    ex.result = { ok = false, text = why .. tostring(info and info.path) }
    return "error", ex.result.text
  end
  local lines = {
    string.format('"%s" salva em %s.', name, info.path),
    string.format("%d %s de áudio %s (%s).", info.copied, info.copied == 1 and "arquivo" or "arquivos",
      info.copied == 1 and "copiado" or "copiados", size_text(info.bytes)),
  }
  if #problems.missing_audio > 0 then
    lines[#lines + 1] = "Não encontrados (a música vai sem eles):"
    for _, path in ipairs(problems.missing_audio) do lines[#lines + 1] = "  " .. path end
  end
  lines[#lines + 1] = OTHER_PC
  ex.result = { ok = true, text = table.concat(lines, "\n") }
  return "done", lines[1]
end

-- ------------------------------------------------------------------ desenho

local function draw_export(ctx)
  if want_open then ImGui.OpenPopup(ctx, EXPORT); want_open = false end
  if not ex then return nil end
  ImGui.SetNextWindowSize(ctx, 560, 0, ImGui.Cond_Appearing)
  if not ImGui.BeginPopupModal(ctx, EXPORT, true) then return nil end
  local msg

  if ex.result then
    ImGui.TextColored(ctx, ex.result.ok and theme.C.text or theme.C.danger, ex.result.text)
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Abrir pasta") and ex.result.ok then library.open_folder((library.dir())) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Fechar") then ex = nil; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
    return nil
  end

  ImGui.TextColored(ctx, theme.C.muted, "MÚSICA: " .. ex.song.name:upper())
  ImGui.Spacing(ctx)
  ImGui.Text(ctx, "Nome na biblioteca")
  ImGui.SetNextItemWidth(ctx, -1)
  local _, name = ImGui.InputText(ctx, "##ex_name", ex.name)
  M.set_name(name)
  ImGui.Spacing(ctx)

  ImGui.Text(ctx, "Tracks")
  ImGui.TextColored(ctx, theme.C.faint, "Marcadas: as que têm itens na música, o Kontakt, as camadas e as pastas delas. De tracks com outras músicas só vão os itens desta.")
  if ImGui.BeginChild(ctx, "##ex_tracks", 0, math.min(260, 26 * #ex.tracks + 8)) then
    for i, t in ipairs(ex.tracks) do
      if ImGui.Checkbox(ctx, t.label .. "##ex_t" .. i, t.on) then M.toggle(i) end
    end
    ImGui.EndChild(ctx)
  end
  ImGui.TextColored(ctx, theme.C.muted, string.format("%d %s · %s de áudio a copiar", ex.items,
    ex.items == 1 and "item" or "itens", size_text(ex.bytes)))
  ImGui.Spacing(ctx)

  if ex.confirm then
    ImGui.TextColored(ctx, theme.C.queue, '"' .. ex.name .. '" já está na biblioteca. Exportar de novo substitui.')
  end
  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Cancelar") then ex = nil; ImGui.CloseCurrentPopup(ctx); ImGui.EndPopup(ctx); return nil end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, ex.confirm and "Substituir" or "Exportar") then
    local res, text = M.export()
    if res == "done" then msg = text
    elseif res == "error" and not ex.result then msg = text end
  end
  ImGui.EndPopup(ctx)
  return msg
end

function M.draw(ctx)
  return draw_export(ctx)
end

return M
