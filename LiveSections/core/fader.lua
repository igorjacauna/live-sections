-- Curva do fader de volume, a mesma do mixer do REAPER: posição 0–1 na tela
-- ou no controlador ↔ D_VOL da track. Usada pelas camadas e pelas
-- multitracks.
--
-- M.pos_of(track) -> 0–1      posição do fader para o volume atual
-- M.volume_of(pos) -> D_VOL   volume (amplitude linear) para a posição

local M = {}

function M.pos_of(track)
  local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
  if vol <= 0 then return 0 end
  return math.max(0, math.min(1, reaper.DB2SLIDER(20 * math.log(vol, 10)) / 1000))
end

function M.volume_of(pos)
  if pos <= 0 then return 0 end
  return 10 ^ (reaper.SLIDER2DB(pos * 1000) / 20)
end

return M
