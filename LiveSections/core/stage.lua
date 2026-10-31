-- Estado de palco: o que a janela de cifra e a página do celular/tablet
-- mostram — música, seção, próxima seção, contagem, compasso e as linhas da
-- cifra acompanhando o compasso.
--
-- A página do celular é servida pela Web Interface do próprio REAPER
-- (Preferences → Control/OSC/web) e lê o estado em JSON por ExtState
-- ("LiveSections", "stage"), publicado só quando muda.
--
-- M.build(snap, opts) -> state   opts = { max_lines }
-- M.publish(state, now)          grava o JSON no ExtState se mudou
-- M.shutdown()                   apaga o estado (a página mostra "fechado")

local chart = require("core.chart")
local json = require("vendor.json")

local M = {}

local PROJ = 0
local SECTION, KEY = "LiveSections", "stage"
local PUBLISH_S = 0.1

local last_json, last_at = nil, -math.huge

local function bar_pos(t)
  local beat, measure, cml = reaper.TimeMap2_timeToBeats(PROJ, t)
  return measure + (cml > 0 and beat / cml or 0)
end

local function hex(native)
  if not native or native == 0 then return "#6C9AB0" end
  local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return string.format("#%02X%02X%02X", r, g, b)
end

local function next_section(song, section, queued)
  if queued then return queued end
  if section then return song.sections[section.slot + 1] end
end

function M.build(snap, opts)
  opts = opts or {}
  local song, section = snap.song, snap.section
  local state = { open = true, playing = snap.playing == true }
  if not song then return state end
  state.song = song.name
  local nxt = next_section(song, section, snap.queued_section)
  state.next = nxt and nxt.name or nil
  state.queued = snap.queued_section ~= nil or snap.queued_song ~= nil
  state.beats_left = state.queued and snap.beats_left or nil
  if snap.queued_song then state.next = snap.queued_song.name end
  state.looping = snap.looping ~= nil

  local parsed = chart.for_song(song)
  state.has_chart = parsed ~= nil
  if not section then return state end
  state.section = section.name
  state.color = hex(section.color)
  local start = bar_pos(section.start_pos)
  local bars = math.max(1, math.floor(bar_pos(section.end_pos) - start + 0.5))
  local bar = math.max(0, math.min(bars - 1e-6, bar_pos(snap.pos or section.start_pos) - start))
  state.bar, state.bars = math.floor(bar) + 1, bars

  local units = chart.units_for(parsed, section)
  if units then
    local next_units = nxt and not snap.queued_song and chart.units_for(parsed, nxt) or nil
    state.rows = chart.view(units, bar, bars, opts.max_lines or 6, state.next, next_units)
  end
  return state
end

function M.publish(state, now)
  local s = json.encode(state)
  if s == last_json or now - last_at < PUBLISH_S then return false end
  last_json, last_at = s, now
  reaper.SetExtState(SECTION, KEY, s, false)
  return true
end

function M.shutdown()
  last_json = nil
  reaper.SetExtState(SECTION, KEY, json.encode({ open = false }), false)
end

return M
