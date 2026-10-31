-- Animação por frame: valores que se aproximam do alvo com o delta time do
-- frame (ImGui.GetDeltaTime), sem timers (RF-077). Com movimento reduzido,
-- tudo vai direto ao alvo e os pulsos ficam parados.
--
-- M.approach(current, target, dt, speed) -> valor   aproximação exponencial
-- M.value(id, target, dt, speed?) -> valor           guarda o estado por id
-- M.pulse(t, period) -> 0–1                          onda suave (fila piscando)
-- M.set_reduced(on); M.reduced()
-- M.forget(id); M.reset()

local M = {}

local DEFAULT_SPEED = 12      -- 1/s: ~95% do caminho em 0,25 s
local SNAP = 1e-3

local reduced = false
local values = {}

function M.set_reduced(on) reduced = on and true or false end
function M.reduced() return reduced end

function M.approach(current, target, dt, speed)
  if reduced or current == nil then return target end
  local k = 1 - math.exp(-(speed or DEFAULT_SPEED) * math.max(0, dt))
  local v = current + (target - current) * k
  if math.abs(target - v) < SNAP then return target end
  return v
end

function M.value(id, target, dt, speed)
  values[id] = M.approach(values[id], target, dt, speed)
  return values[id]
end

function M.pulse(t, period)
  if reduced then return 1 end
  return 0.5 - 0.5 * math.cos(2 * math.pi * t / period)
end

function M.forget(id) values[id] = nil end
function M.reset() values = {} end

return M
