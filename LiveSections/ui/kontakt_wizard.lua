-- Assistente de Kontakt (RF-093, RF-094): vincula a track do Kontakt à música
-- atual e cria as tracks de camada a partir das saídas multi-out.
--
-- Cada camada é uma track filha direta da track do Kontakt (pasta), com um
-- send da mãe para a filha trazendo um par de canais: camada 1 = saídas 1/2,
-- camada 2 = 3/4, e assim por diante. Filhas que já existem continuam sendo as
-- primeiras camadas; o assistente só cria as que faltam. A track do Kontakt
-- ganha os canais necessários e, com o teclado configurado, a entrada MIDI
-- só dele (nunca "All MIDI inputs"). Tudo num passo de undo.
--
-- M.init(deps)                 ImGui, theme, layers, kit
-- M.open(song)                 abre o assistente para a música
-- M.draw(ctx) -> msg?          desenha o modal; mensagem de resultado ao aplicar
-- M.apply(song, track, names) -> ok, err   vínculo + camadas novas (`names`)
-- M.candidates() -> { { track, name, kontakt = bool } }

local M = {}

local ImGui, theme, layers, kit

local PROJ = 0
local MIDI_INPUT = 4096
local DEFAULT_LAYERS = 2
local POPUP = "Assistente de Kontakt"

local st = { song = nil, track = nil, names = {}, want_open = false }

function M.init(deps)
  ImGui, theme, layers, kit = deps.ImGui, deps.theme, deps.layers, deps.kit
  st.song, st.track, st.names, st.want_open = nil, nil, {}, false
end

-- ------------------------------------------------------------------ tracks

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local n = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  return name ~= "" and (n .. ". " .. name) or (n .. ". (sem nome)")
end

local function has_kontakt(tr)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, fx = reaper.TrackFX_GetFXName(tr, i, "")
    if fx:lower():find("kontakt", 1, true) then return true end
  end
  return false
end

function M.candidates()
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    out[#out + 1] = { track = tr, name = track_name(tr), kontakt = has_kontakt(tr) }
  end
  return out
end

local function children(parent)
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if reaper.GetParentTrack(tr) == parent then out[#out + 1] = tr end
  end
  return out
end

local function depth(tr) return math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")) end
local function index_of(tr) return math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1 end

-- Insere `n` tracks como filhas diretas de `parent`, depois das que já existem
-- (inclusive netas), acertando a profundidade das pastas. Retorna as tracks.
local function insert_children(parent, n)
  local p = index_of(parent)
  local d_parent = depth(parent)
  local at, last_new_depth
  if d_parent <= 0 then
    -- sem filhas: a track vira pasta e a última filha fecha o que ela fechava
    reaper.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
    at, last_new_depth = p + 1, d_parent - 1
  else
    -- última descendente: onde o nível volta a zero
    local level, j = 1, p + 1
    last_new_depth = 0     -- pasta aberta até o fim do projeto
    while j < reaper.CountTracks(PROJ) do
      local before = level
      level = level + depth(reaper.GetTrack(PROJ, j))
      if level <= 0 then
        -- ela fecha os níveis internos (before - 1) e mais os da pasta para fora
        local last = reaper.GetTrack(PROJ, j)
        local d_last = depth(last)
        reaper.SetMediaTrackInfo_Value(last, "I_FOLDERDEPTH", 1 - before)
        last_new_depth = d_last + (before - 1)
        break
      end
      j = j + 1
    end
    at = math.min(j + 1, reaper.CountTracks(PROJ))
  end
  local out = {}
  for k = 1, n do
    reaper.InsertTrackAtIndex(at + k - 1, true)
    local tr = reaper.GetTrack(PROJ, at + k - 1)
    reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", k == n and last_new_depth or 0)
    out[k] = tr
  end
  return out
end

-- ------------------------------------------------------------------ aplicar

function M.apply(song, track, names)
  if not song then return false, "no_song" end
  if not track then return false, "no_track" end
  local existing = #children(track)
  reaper.Undo_BeginBlock()
  layers.link(song, track)
  local kbd = layers.keyboard_input()
  if kbd then reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", MIDI_INPUT + (kbd << 5)) end
  if #names > 0 then
    local pairs_needed = existing + #names
    if reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") < pairs_needed * 2 then
      reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", pairs_needed * 2)
    end
    for k, tr in ipairs(insert_children(track, #names)) do
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", names[k], true)
      local send = reaper.CreateTrackSend(track, tr)
      reaper.SetTrackSendInfo_Value(track, 0, send, "I_SRCCHAN", (existing + k - 1) * 2)
      reaper.SetTrackSendInfo_Value(track, 0, send, "I_DSTCHAN", 0)
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Live Sections: vincular Kontakt e criar camadas", -1)
  return true
end

-- ------------------------------------------------------------------ modal

function M.open(song)
  st.song = song
  st.track = layers.track_of(song)
  if not st.track then
    local linked = {}
    for _, l in pairs(layers.links(require("core.project_model").songs())) do linked[l.track_guid] = true end
    for _, c in ipairs(M.candidates()) do
      if c.kontakt and not linked[reaper.GetTrackGUID(c.track)] then st.track = c.track; break end
    end
  end
  st.names = {}
  if not st.track or #children(st.track) == 0 then
    for i = 1, DEFAULT_LAYERS do st.names[i] = "Camada " .. i end
  end
  st.want_open = true
end

function M.draw(ctx)
  if st.want_open then ImGui.OpenPopup(ctx, POPUP); st.want_open = false end
  ImGui.SetNextWindowSize(ctx, 520, 0, ImGui.Cond_Appearing)
  if not ImGui.BeginPopupModal(ctx, POPUP, true) then return nil end
  local msg
  local song = st.song

  ImGui.TextColored(ctx, theme.C.muted, "MÚSICA: " .. (song and song.name or "—"):upper())
  ImGui.Spacing(ctx)

  -- 1. track do Kontakt
  ImGui.Text(ctx, "1. Track do Kontakt")
  ImGui.SetNextItemWidth(ctx, -1)
  if ImGui.BeginCombo(ctx, "##kz_track", st.track and track_name(st.track) or "Escolha a track") then
    for i, c in ipairs(M.candidates()) do
      local label = c.name .. (c.kontakt and "  · Kontakt" or "")
      if ImGui.Selectable(ctx, label .. "##t" .. i, c.track == st.track) then
        st.track = c.track
        st.names = {}
        if #children(c.track) == 0 then
          for k = 1, DEFAULT_LAYERS do st.names[k] = "Camada " .. k end
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.Spacing(ctx)

  -- 2. camadas: as filhas que já existem e as novas
  ImGui.Text(ctx, "2. Camadas (saídas multi-out)")
  ImGui.TextColored(ctx, theme.C.muted, "Cada par de canais vira uma track filha. Os faders seguem esta ordem.")
  local existing = st.track and children(st.track) or {}
  for i, tr in ipairs(existing) do
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    ImGui.TextColored(ctx, theme.C.faint, string.format("st. %d/%d   %s   (já existe)", i * 2 - 1, i * 2, name))
  end
  local remove
  for k, name in ipairs(st.names) do
    local pair = #existing + k
    ImGui.Text(ctx, string.format("st. %d/%d", pair * 2 - 1, pair * 2))
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 300)
    local _, v = ImGui.InputText(ctx, "##kz_name" .. k, name)
    st.names[k] = v
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Remover##kz_rm" .. k) then remove = k end
  end
  if remove then table.remove(st.names, remove) end
  if ImGui.Button(ctx, "+ Saída") then
    st.names[#st.names + 1] = "Camada " .. (#existing + #st.names + 1)
  end
  ImGui.Spacing(ctx)

  -- 3. teclado
  ImGui.Text(ctx, "3. Teclado")
  local kbd = layers.keyboard_port()
  ImGui.TextColored(ctx, kbd and theme.C.muted or theme.C.queue, kbd
    and ("A entrada MIDI do Kontakt fica só em " .. kbd .. ", nunca All MIDI inputs.")
    or "Nenhum teclado escolhido nas configurações: a entrada MIDI do Kontakt não será alterada.")
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)

  if ImGui.Button(ctx, "Cancelar") then ImGui.CloseCurrentPopup(ctx) end
  ImGui.SameLine(ctx)
  if song and layers.track_of(song) then
    if ImGui.Button(ctx, "Desfazer vínculo") then
      layers.unlink(song)
      msg = "Vínculo do Kontakt desfeito. As tracks não foram apagadas."
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
  end
  local names = {}
  for _, n in ipairs(st.names) do
    n = n:gsub("^%s+", ""):gsub("%s+$", "")
    names[#names + 1] = n ~= "" and n or ("Camada " .. (#existing + #names + 1))
  end
  local label = #names > 0 and "Vincular e criar camadas" or "Vincular"
  if ImGui.Button(ctx, label) and st.track then
    local ok, err = M.apply(song, st.track, names)
    msg = ok and string.format("Kontakt vinculado a %s com %d camadas.", song.name, #existing + #names)
      or ("Não foi possível: " .. tostring(err))
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndPopup(ctx)
  return msg
end

return M
