-- Próximo ponto de salto para cada modo de quantize.
--
-- Todas as contas passam pelo TimeMap do REAPER, então mudanças de BPM e de
-- fórmula de compasso no meio da música são respeitadas. "Batida" segue o
-- denominador da fórmula (em 7/8, uma batida é uma colcheia).
--
-- Modos: "now", "beat", "bar", "2bar", "4bar", "8bar", "section_end".
-- ctx (opcional): { proj, song = Song, section = Section } do project_model.
-- Os blocos de N compassos contam a partir do início da música.

local M = {}

local EPS = 1e-6

M.MODES = { "now", "beat", "bar", "2bar", "4bar", "8bar", "section_end" }

local BARS = { bar = 1, ["2bar"] = 2, ["4bar"] = 4, ["8bar"] = 8 }

local function measure_at(proj, pos)
  local beat, measure, cml = reaper.TimeMap2_timeToBeats(proj, pos)
  return measure, beat, cml
end

local function measure_start(proj, measure)
  return reaper.TimeMap2_beatsToTime(proj, 0, measure)
end

local function next_beat(proj, pos)
  local measure, beat, cml = measure_at(proj, pos)
  local nb = math.floor(beat + EPS) + 1
  if nb >= cml - EPS then return measure_start(proj, measure + 1) end
  return reaper.TimeMap2_beatsToTime(proj, nb, measure)
end

local function next_bars(proj, pos, n, song)
  local measure = measure_at(proj, pos)
  local first = song and measure_at(proj, song.start_pos) or 0
  local target = first + (math.floor((measure - first) / n) + 1) * n
  return measure_start(proj, target)
end

-- Posição (segundos) do próximo salto a partir de `pos`, sempre depois dela,
-- exceto no modo "now". Sem seção atual, "section_end" cai no próximo compasso.
function M.next_jump(pos, mode, ctx)
  ctx = ctx or {}
  local proj = ctx.proj or 0
  local jump
  if mode == "now" then
    return pos
  elseif mode == "beat" then
    jump = next_beat(proj, pos)
  elseif BARS[mode] then
    jump = next_bars(proj, pos, BARS[mode], ctx.song)
  elseif mode == "section_end" then
    jump = ctx.section and ctx.section.end_pos or next_bars(proj, pos, 1, ctx.song)
  else
    error("quantize: modo desconhecido: " .. tostring(mode), 2)
  end
  if ctx.song and jump > ctx.song.end_pos then jump = ctx.song.end_pos end
  return jump
end

-- Um disparo em `pos` até `tol_s` depois da virada em `boundary` conta como
-- se tivesse chegado antes dela.
function M.within_tolerance(pos, boundary, tol_s)
  return pos >= boundary - EPS and pos - boundary <= tol_s + EPS
end

-- Ponto de salto de um disparo em `pos`, já aplicando a tolerância.
-- Retorna jump_pos e `late` = true quando o disparo chegou logo depois de uma
-- virada: nesse caso jump_pos é a virada que acabou de passar e o salto deve
-- ser feito na hora.
function M.resolve(pos, mode, ctx, tol_s)
  ctx = ctx or {}
  if mode ~= "now" and tol_s and tol_s > 0 then
    local boundary
    if mode == "section_end" then
      boundary = ctx.section and ctx.section.start_pos
    else
      boundary = M.next_jump(math.max(pos - tol_s, 0) - EPS, mode, ctx)
    end
    if boundary and boundary > EPS and M.within_tolerance(pos, boundary, tol_s) then
      return boundary, true
    end
  end
  return M.next_jump(pos, mode, ctx), false
end

return M
