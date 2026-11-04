-- Biblioteca de músicas na tela: o quadro Exportar (modo Editar) e a lista
-- para montar o setlist ("+ Da biblioteca", na Performance e no Editar).
--
-- Exportar (RF-177–RF-180, RF-189, RF-190): lista todas as tracks do
-- projeto, com as detectadas como da música já marcadas; o nome (padrão = o
-- da música), o número de itens e o tamanho dos áudios a copiar. Um nome que
-- já existe na biblioteca pede confirmação antes de substituir. No fim,
-- mostra onde salvou, quantos áudios copiou, os que faltaram e o aviso para
-- usar em outro computador.
--
-- Lista (RF-193–RF-195, RF-201, RF-202, RF-207, RF-210): músicas da
-- biblioteca com BPM, fórmula, compassos, seções e data; as que não abrem
-- aparecem sem poder ser escolhidas. A seleção é múltipla e a ordem é a dos
-- cliques, ajustável. Antes de adicionar, os plugins que faltam nesta
-- máquina são listados; dá para adicionar mesmo assim ou cancelar. Pasta
-- escolhida que sumiu: aviso com o caminho e o botão Padrão.
--
-- M.init({ ImGui, theme, kit, library, song_package, song_import })
-- M.open_export(song)
-- M.export_state() -> { song, name, tracks = { { track, label, on } },
--                       items, bytes, confirm, result? }
-- M.toggle(i); M.set_name(nome)
-- M.export() -> "done"|"confirm"|"error", mensagem
-- M.open_list(); M.list_state() -> { dir, dir_ok, items, picked = { pasta },
--                                     missing?, result? }
-- M.pick(pasta)                 marca/desmarca (só as que abrem)
-- M.move(i, d)                  sobe (-1) ou desce (+1) a escolhida i
-- M.use_default_dir()
-- M.add() -> "missing"|"done"|"none", texto   confere plugins e adiciona
-- M.add_anyway() -> "done", texto              adiciona com plugins faltando
-- M.draw(ctx) -> mensagem?      desenha o quadro aberto

local M = {}

local ImGui, theme, kit, library, song_package, song_import

local PROJ = 0
local EPS = 1e-6
local EXPORT = "Exportar música"
local LIST = "Biblioteca de músicas"
local OTHER_PC = "Para usar em outro computador, leve a pasta da biblioteca. Lá precisam estar instalados o Kontakt e as bibliotecas dele."

local ex = nil          -- quadro Exportar aberto
local want_open = false
local li = nil          -- lista da biblioteca aberta
local want_list = false

function M.init(deps)
  ImGui, theme, kit = deps.ImGui, deps.theme, deps.kit
  library, song_package, song_import = deps.library, deps.song_package, deps.song_import
  ex, want_open, li, want_list = nil, false, nil, false
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

-- ------------------------------------------------------------------ lista

local function load_list()
  local dir, ok = library.dir()
  li.dir, li.dir_ok = dir, ok
  li.items = ok and library.list() or {}
  local alive = {}
  for _, it in ipairs(li.items) do if it.ok then alive[it.folder] = true end end
  local picked = {}
  for _, f in ipairs(li.picked or {}) do if alive[f] then picked[#picked + 1] = f end end
  li.picked, li.missing, li.result = picked, nil, nil
end

function M.open_list()
  li = { picked = {} }
  load_list()
  want_list = true
end

function M.list_state() return li end

local function index_of(folder)
  for i, f in ipairs(li.picked) do if f == folder then return i end end
end

function M.pick(folder)
  local i = index_of(folder)
  if i then table.remove(li.picked, i); return end
  for _, it in ipairs(li.items) do
    if it.folder == folder and it.ok then li.picked[#li.picked + 1] = folder end
  end
end

function M.move(i, d)
  local j = i + d
  if not li.picked[i] or not li.picked[j] then return end
  li.picked[i], li.picked[j] = li.picked[j], li.picked[i]
end

function M.use_default_dir()
  library.set_dir(nil)
  load_list()
end

-- Resumo de uma música da lista: "129 BPM · 4/4 · 85 comp. · 6 seções · data".
function M.summary(it)
  if not it.ok then return "não dá para abrir" end
  local parts = {}
  if it.bpm then parts[#parts + 1] = string.format("%g BPM", math.floor(it.bpm * 100 + 0.5) / 100) end
  if it.signature then parts[#parts + 1] = it.signature end
  if it.bars then parts[#parts + 1] = it.bars .. " comp." end
  parts[#parts + 1] = it.sections .. (it.sections == 1 and " seção" or " seções")
  if it.exported_at then parts[#parts + 1] = it.exported_at end
  return table.concat(parts, " · ")
end

local function joined(list) return table.concat(list, ", ") end

local function add_all(pkgs)
  local learn, differs, offline = {}, {}, {}
  local seen = {}
  for _, pkg in ipairs(pkgs) do
    local _, report = song_import.add(pkg)
    for _, n in ipairs(report.learn) do
      if not seen[n] then seen[n] = true; learn[#learn + 1] = n end
    end
    for _, n in ipairs(report.cc_differs) do differs[#differs + 1] = n end
    for _, f in ipairs(report.offline) do offline[#offline + 1] = pkg.name .. ": " .. f end
  end
  local lines = { string.format("%d %s no fim do projeto.", #pkgs,
    #pkgs == 1 and "música adicionada" or "músicas adicionadas") }
  if #learn > 0 then
    lines[#lines + 1] = "Linhas novas no Mapeamento, sem controle físico (faça o Learn): " .. joined(learn)
  end
  if #differs > 0 then
    lines[#lines + 1] = "Já existiam com outro CC (ficou o desta máquina): " .. joined(differs)
  end
  if #offline > 0 then
    lines[#lines + 1] = "Áudios que não estão na biblioteca (itens offline):"
    for _, f in ipairs(offline) do lines[#lines + 1] = "  " .. f end
  end
  li.result = table.concat(lines, "\n")
  li.pending, li.missing = nil, nil
  return "done", lines[1]
end

function M.add()
  if #li.picked == 0 then return "none", "Escolha ao menos uma música." end
  local pkgs, missing, seen = {}, {}, {}
  for _, folder in ipairs(li.picked) do
    local pkg = library.read(folder)
    if pkg then
      pkgs[#pkgs + 1] = pkg
      for _, name in ipairs(library.missing_plugins(pkg)) do
        if not seen[name] then seen[name] = true; missing[#missing + 1] = name end
      end
    end
  end
  li.pending = pkgs
  if #missing > 0 then
    li.missing = missing
    return "missing", joined(missing)
  end
  return add_all(pkgs)
end

function M.add_anyway() return add_all(li.pending or {}) end

-- ------------------------------------------------------------------ desenho

-- Diálogo com largura fixa e altura ajustada ao conteúdo a cada quadro:
-- avisos e listas aumentam o diálogo em vez de esconder os botões, e os
-- textos quebram na borda.
local function begin_modal(ctx, name, w)
  ImGui.SetNextWindowSize(ctx, w, 0, ImGui.Cond_Always)
  if not ImGui.BeginPopupModal(ctx, name, true) then return false end
  ImGui.PushTextWrapPos(ctx, 0)
  return true
end

local function end_modal(ctx)
  ImGui.PopTextWrapPos(ctx)
  ImGui.EndPopup(ctx)
end

local function draw_export(ctx)
  if want_open then ImGui.OpenPopup(ctx, EXPORT); want_open = false end
  if not ex then return nil end
  if not begin_modal(ctx, EXPORT, 560) then return nil end
  local msg

  if ex.result then
    ImGui.TextColored(ctx, ex.result.ok and theme.C.text or theme.C.danger, ex.result.text)
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Abrir pasta") and ex.result.ok then library.open_folder((library.dir())) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Fechar") then ex = nil; ImGui.CloseCurrentPopup(ctx) end
    end_modal(ctx)
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
  if ImGui.Button(ctx, "Cancelar") then ex = nil; ImGui.CloseCurrentPopup(ctx); end_modal(ctx); return nil end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, ex.confirm and "Substituir" or "Exportar") then
    local res, text = M.export()
    if res == "done" then msg = text
    elseif res == "error" and not ex.result then msg = text end
  end
  end_modal(ctx)
  return msg
end

local function draw_list(ctx)
  if want_list then ImGui.OpenPopup(ctx, LIST); want_list = false end
  if not li then return nil end
  if not begin_modal(ctx, LIST, 620) then return nil end
  local msg

  if li.result then
    ImGui.TextColored(ctx, theme.C.text, li.result)
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Fechar") then li = nil; ImGui.CloseCurrentPopup(ctx) end
    end_modal(ctx)
    return nil
  end

  if li.missing then
    ImGui.TextColored(ctx, theme.C.queue, "Plugins que não estão instalados nesta máquina:")
    for _, name in ipairs(li.missing) do ImGui.Text(ctx, "  " .. name) end
    ImGui.TextColored(ctx, theme.C.faint, "Adicionando mesmo assim, eles abrem offline até serem instalados.")
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Cancelar") then li.missing, li.pending = nil, nil end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Adicionar mesmo assim") then msg = select(2, M.add_anyway()) end
    end_modal(ctx)
    return msg
  end

  ImGui.TextColored(ctx, theme.C.faint, li.dir)
  if not li.dir_ok then
    ImGui.TextColored(ctx, theme.C.danger, "A pasta da biblioteca não foi encontrada: " .. li.dir)
    if ImGui.Button(ctx, "Padrão") then M.use_default_dir() end
  elseif #li.items == 0 then
    ImGui.TextColored(ctx, theme.C.muted, "Nenhuma música ainda. No modo Editar, use Exportar em uma música configurada.")
  else
    if ImGui.BeginChild(ctx, "##lib_items", 0, math.min(300, 28 * #li.items + 8)) then
      for i, it in ipairs(li.items) do
        if it.ok then
          if ImGui.Checkbox(ctx, it.name .. "##lib_i" .. i, index_of(it.folder) ~= nil) then M.pick(it.folder) end
          ImGui.SameLine(ctx)
          ImGui.TextColored(ctx, theme.C.faint, M.summary(it))
        else
          ImGui.TextColored(ctx, theme.C.faint, it.name .. " — " .. M.summary(it))
        end
      end
      ImGui.EndChild(ctx)
    end
  end

  if #li.picked > 0 then
    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "Ordem no setlist")
    for i, folder in ipairs(li.picked) do
      if ImGui.Button(ctx, "Subir##lib_up" .. i) then M.move(i, -1) end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Descer##lib_dn" .. i) then M.move(i, 1) end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, i .. ". " .. folder)
    end
  end

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Abrir pasta") and li.dir_ok then library.open_folder(li.dir) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Cancelar") then li = nil; ImGui.CloseCurrentPopup(ctx); end_modal(ctx); return nil end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, #li.picked > 1 and ("Adicionar " .. #li.picked .. " músicas") or "Adicionar") then
    local res, text = M.add()
    if res == "done" then msg = text end
  end
  end_modal(ctx)
  return msg
end

function M.draw(ctx)
  local a = draw_export(ctx)
  local b = draw_list(ctx)
  return a or b
end

return M
