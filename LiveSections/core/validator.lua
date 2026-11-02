-- Painel de avisos: problemas criados por edição manual na régua do REAPER
-- ou por configuração, cada um com uma correção de um clique. Inclui o
-- roteamento do Kontakt: o som tem que sair só pelas camadas.
--
-- Trechos sem seção (buracos) não são problema.
--
-- M.check(songs, ctx) -> Warning[]
--   songs: lista do project_model
--   ctx.links: { [song_id] = { key = <chave no ProjExtState>, track_guid = "…" } }
--   ctx.keyboard_input: índice do dispositivo MIDI do teclado (para corrigir
--     a entrada do Kontakt); sem ele, a correção de "All MIDI inputs" falha.
--   ctx.mapping_rows: quantas linhas a tela Mapeamento tem; com alguma, o
--     Kontakt de cada música precisa do JSFX do Mapeamento (RF-136).
-- Warning = { kind, severity = "error"|"warning", song = nome?, text, fix_label,
--             fix = function, precheck = function? (falha antes de abrir o undo) }
-- M.apply(warning) -> ok, err   aplica a correção num único passo de undo

local editor_ops = require("core.editor_ops")
local layers = require("core.layers")
local kontakt_jsfx = require("core.kontakt_jsfx")

local M = {}

local PROJ = 0
local EPS = 1e-6
local EXT_SECTION = "LiveSections"

local MIDI_INPUT = 4096
local ALL_DEVICES = 63

local function fmt_pos(pos) return reaper.format_timestr_pos(pos, "", 2) end

local function add(list, w) list[#list + 1] = w end

local function read_regions()
  local out, i = {}, 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = reaper.EnumProjectMarkers3(PROJ, i)
    if ret == 0 then return out end
    if isrgn then out[#out + 1] = { pos = pos, rgnend = rgnend, name = name, idx = idx, color = color } end
    i = i + 1
  end
end

local function track_by_guid(guid)
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end

local function check_regions(list, songs)
  local first_song = songs[1]
  local has_markers = first_song and first_song.marker_idx ~= nil
  for _, rgn in ipairs(read_regions()) do
    if has_markers and rgn.pos < first_song.start_pos - EPS then
      add(list, {
        kind = "outside_song", severity = "warning",
        text = string.format('A região "%s" está antes do primeiro marcador SONG:.', rgn.name),
        fix_label = "Remover a região",
        fix = function() reaper.DeleteProjectMarker(PROJ, rgn.idx, true) end,
      })
    end
  end

  for _, song in ipairs(songs) do
    for i, sec in ipairs(song.sections) do
      local snapped = editor_ops.snap(sec.start_pos)
      if math.abs(snapped - sec.start_pos) > EPS then
        add(list, {
          kind = "off_grid", severity = "warning", song = song.name,
          text = string.format('A região "%s" começa fora do compasso (%s).', sec.name, fmt_pos(sec.start_pos)),
          fix_label = "Alinhar ao compasso " .. fmt_pos(snapped):match("^(%d+)"),
          fix = function()
            reaper.SetProjectMarker3(PROJ, sec.region_idx, true, snapped, sec.end_pos, sec.name, sec.color)
          end,
        })
      end
      local nxt = song.sections[i + 1]
      if nxt and sec.end_pos > nxt.start_pos + EPS then
        add(list, {
          kind = "overlap", severity = "error", song = song.name,
          text = string.format('"%s" e "%s" se sobrepõem.', sec.name, nxt.name),
          fix_label = string.format('Cortar "%s" onde "%s" começa', sec.name, nxt.name),
          fix = function()
            reaper.SetProjectMarker3(PROJ, sec.region_idx, true, sec.start_pos, nxt.start_pos, sec.name, sec.color)
          end,
        })
      end
    end
  end
end

local function check_kontakt(list, songs, ctx)
  local links = ctx.links or {}
  for _, song in ipairs(songs) do
    local link = links[song.id]
    if link then
      local tr = track_by_guid(link.track_guid)
      if not tr then
        add(list, {
          kind = "kontakt_missing", severity = "error", song = song.name,
          text = "A track do Kontakt vinculada a esta música não existe mais.",
          fix_label = "Desfazer o vínculo",
          fix = function() reaper.SetProjExtState(PROJ, EXT_SECTION, link.key, "") end,
        })
      else
        local problem = layers.routing_problem(tr)
        if problem then
          local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
          add(list, {
            kind = "kontakt_routing", severity = "error", song = song.name,
            text = problem == "folder"
              and string.format('As camadas de "%s" estão numa pasta: o som sai pela track do Kontakt e o fader da camada não controla o instrumento.', tname)
              or string.format('A track "%s" também manda o som direto ao master: o fader da camada não controla o instrumento.', tname),
            fix_label = "Sair só pelas camadas",
            fix = function() layers.repair(tr) end,
          })
        end
        local input = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")
        local is_midi = math.floor(input) & MIDI_INPUT ~= 0
        if is_midi and (math.floor(input) >> 5) & 63 == ALL_DEVICES then
          local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
          add(list, {
            kind = "kontakt_all_inputs", severity = "warning", song = song.name,
            text = string.format('A track "%s" recebe All MIDI inputs: os pads do controlador também tocariam notas.', tname),
            fix_label = "Usar só o teclado",
            precheck = function()
              if not ctx.keyboard_input then return false, "no_keyboard" end
              return true
            end,
            fix = function()
              reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", MIDI_INPUT + (ctx.keyboard_input << 5))
            end,
          })
        end
        if (ctx.mapping_rows or 0) > 0 and kontakt_jsfx.find(tr) < 0 then
          local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
          add(list, {
            kind = "kontakt_cc_missing", severity = "warning", song = song.name,
            text = string.format('A track "%s" não tem o JSFX do Mapeamento: os controles mapeados não chegam a este Kontakt.', tname),
            fix_label = "Instalar o JSFX",
            fix = function() kontakt_jsfx.install(tr) end,
          })
        end
      end
    end
  end
end

function M.check(songs, ctx)
  ctx = ctx or {}
  local list = {}
  check_regions(list, songs)
  check_kontakt(list, songs, ctx)
  return list
end

function M.apply(warning)
  if warning.precheck then
    local ok, err = warning.precheck()
    if not ok then return false, err end
  end
  reaper.Undo_BeginBlock()
  warning.fix()
  reaper.Undo_EndBlock("Live Sections: " .. warning.fix_label, -1)
  return true
end

return M
