-- Fila de saltos: guarda o salto pendente e decide quando agir.
--
-- Nos modos de compasso e "fim da seção" o salto é entregue ao REAPER
-- (smooth seek / GoToRegion) só quando a reprodução entra no último compasso
-- antes da virada. Até lá, cancelar é só limpar a fila. Nos modos "batida" e
-- "imediato" o REAPER não ajuda, então o próprio script salta na virada.
--
-- target = { kind = "section"|"song", ref = Section|Song } do project_model.
-- Ações devolvidas por tick:
--   { type = "hand_off", target, jump_pos, mode }  entregar ao REAPER agora
--   { type = "jump_now", target, jump_pos, mode }  saltar agora (script)
--   { type = "arrived",  target, jump_pos }        o salto entregue aconteceu
--   { type = "cancelled", reason = "target_removed", entry }  alvo sumiu

local quantize = require("core.quantize")

local M = {}

local EPS = 1e-6

-- Modos em que o REAPER executa o salto sozinho.
local NATIVE = { bar = true, ["2bar"] = true, ["4bar"] = true, ["8bar"] = true, section_end = true }

local entry = nil   -- Queue = { target, quantize, jump_pos, hand_off_pos, handed_to_reaper, late, enqueued_at }
local last_pos = nil

local function same_target(a, b)
  if a.kind ~= b.kind then return false end
  if a.kind == "section" then return a.ref.region_idx == b.ref.region_idx end
  return a.ref.id == b.ref.id
end

-- Início do compasso que termina na virada.
local function last_measure_start(proj, jump_pos)
  local _, measure = reaper.TimeMap2_timeToBeats(proj, jump_pos - EPS)
  return reaper.TimeMap2_beatsToTime(proj, 0, measure)
end

-- Coloca `target` na fila. Retorna "queued", "replaced" (havia outro alvo) ou
-- "cancelled" (o mesmo alvo já estava na fila), mais a entrada que saiu da
-- fila, para o transporte desfazer uma entrega já feita.
function M.enqueue(target, mode, now_pos, ctx, tol_s)
  ctx = ctx or {}
  local previous = entry
  if previous and same_target(previous.target, target) then
    entry = nil
    return "cancelled", previous
  end
  local jump_pos, late = quantize.resolve(now_pos, mode, ctx, tol_s)
  entry = {
    target = target, quantize = mode, jump_pos = jump_pos, late = late,
    hand_off_pos = NATIVE[mode] and not late and last_measure_start(ctx.proj or 0, jump_pos) or nil,
    handed_to_reaper = false, enqueued_at = now_pos,
  }
  last_pos = now_pos
  return previous and "replaced" or "queued", previous
end

-- Esvazia a fila. Retorna a entrada cancelada (ou nil).
function M.cancel()
  local previous = entry
  entry = nil
  return previous
end

function M.current() return entry end

local function find_target(target, songs)
  for _, song in ipairs(songs) do
    if target.kind == "song" and song.id == target.ref.id then return song end
    if target.kind == "section" then
      for _, sec in ipairs(song.sections) do
        if sec.region_idx == target.ref.region_idx then return sec end
      end
    end
  end
  return nil
end

-- Chamado a cada ciclo com a posição de reprodução. `songs` (opcional) é o
-- modelo atual: se o alvo sumiu dele, a fila é cancelada.
function M.tick(play_pos, songs)
  if not entry then return nil end
  local e = entry

  if songs then
    local ref = find_target(e.target, songs)
    if not ref then
      entry = nil
      return { type = "cancelled", reason = "target_removed", entry = e }
    end
    e.target.ref = ref
  end

  local prev = last_pos or play_pos
  last_pos = play_pos

  if e.handed_to_reaper then
    -- O REAPER saltou: a posição passou da virada ou voltou para trás.
    if play_pos >= e.jump_pos - EPS or play_pos < prev - EPS then
      entry = nil
      return { type = "arrived", target = e.target, jump_pos = e.jump_pos }
    end
    return nil
  end

  if e.hand_off_pos then
    if play_pos >= e.hand_off_pos - EPS then
      e.handed_to_reaper = true
      return { type = "hand_off", target = e.target, jump_pos = e.jump_pos, mode = e.quantize }
    end
    return nil
  end

  if e.late or play_pos >= e.jump_pos - EPS then
    entry = nil
    return { type = "jump_now", target = e.target, jump_pos = e.jump_pos, mode = e.quantize }
  end
  return nil
end

return M
