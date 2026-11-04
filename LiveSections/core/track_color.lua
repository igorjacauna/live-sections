-- Cor da track no REAPER (I_CUSTOMCOLOR), usada nas colunas das camadas e
-- das multitracks (RF-227, RF-228). O bit 0x1000000 diz que a track tem cor
-- própria; sem ele, vale a do tema do REAPER e a coluna fica neutra.
--
-- M.get(track) -> cor nativa | nil
-- M.set(track, "#RRGGBB" | nil)   nil = sem cor; um passo de undo só da
--                                 track, sem o estado dos plugins

local M = {}

local HAS_COLOR = 0x1000000

function M.get(track)
  local c = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR"))
  if c & HAS_COLOR == 0 then return nil end
  return c & 0xFFFFFF
end

function M.set(track, hex)
  local value = 0
  if hex then
    local v = tonumber(hex:gsub("^#", ""), 16)
    value = reaper.ColorToNative((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) | HAS_COLOR
  end
  reaper.Undo_BeginBlock()
  reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", value)
  reaper.Undo_EndBlock("Live Sections: cor da track", 1)
end

return M
