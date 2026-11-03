-- JSFX do Mapeamento: leva ao Kontakt os CCs dos controles mapeados.
--
-- Fica no início da cadeia de FX da track do Kontakt de cada música (spike
-- 08). Um slider por CC guarda o último valor (-1 = nunca enviado); quando um
-- slider muda, o JSFX manda aquele CC no canal 1. Como os sliders ficam
-- salvos no projeto, cada música lembra os valores dos seus controles
-- (RF-132). Não chama midirecv: o MIDI do teclado passa direto (RF-131).
--
-- Params (0-based): 0–127 = valor do CC n; 128 = "reenviar" (contador: mudou
-- → manda todos os CCs ≥ 0); 129 = "enviados" (contador de mensagens). A
-- ordem dos sliders não pode mudar entre versões: só acrescentar no fim.
--
-- M.FX_NAME                         nome para TrackFX_AddByName
-- M.text() -> código do JSFX
-- M.write_file() -> ok, err, path   grava em <REAPER>/Effects/LiveSections/
-- M.find(track) -> índice do FX ou -1
-- M.install(track) -> índice (0) ou -1, err   no início, sem duplicar (RF-130)
-- M.coverage(songs, track_of) -> { total, installed, missing = { song } }
-- M.set_cc(track, cc, value) -> bool          value 0–127
-- M.resend(track) -> bool
-- M.sent_count(track) -> n?
-- M.value(track, cc) -> -1..127?

local diag = require("core.diag")

local M = {}

local DIR = "LiveSections"
local FILE = "ls_kontakt_cc.jsfx"
local DESC = "Live Sections - Mapeamento para o Kontakt"
local RESEND, SENT = 128, 129

M.FX_NAME = "JS:" .. DIR .. "/" .. FILE

function M.text()
  local lines = {
    "desc:" .. DESC,
    "// Gerado pelo Live Sections. Cada slider guarda o valor de um CC (-1 =",
    "// nunca enviado); quando muda, o CC vai para o próximo FX (o Kontakt).",
    "// Não lê o MIDI que chega: o teclado passa direto.",
  }
  for cc = 0, 127 do
    lines[#lines + 1] = string.format("slider%d:-1<-1,127,1>-CC %d", cc + 1, cc)
  end
  lines[#lines + 1] = string.format("slider%d:0<0,1000000,1>-Reenviar", RESEND + 1)
  lines[#lines + 1] = string.format("slider%d:0<0,1000000,1>-Enviados", SENT + 1)
  lines[#lines + 1] = [[
in_pin:none
out_pin:none

@init
// last[i]: o que já foi mandado do CC i; seen: último "reenviar" atendido
i = 0;
loop(128, last[i] = -1; i += 1);
seen = -1;
pending = 1;

@slider
pending = 1;

@block
pending ? (
  slider(129) != seen ? (
    seen = slider(129);
    i = 0;
    loop(128, last[i] = -1; i += 1);
  );
  i = 0;
  loop(128,
    v = floor(slider(i + 1) + 0.5);
    v >= 0 && v != last[i] ? (
      midisend(0, 0xB0, i, v);
      last[i] = v;
      slider130 = (slider130 + 1) % 1000000;
    );
    i += 1;
  );
  pending = 0;
);
]]
  return table.concat(lines, "\n")
end

function M.write_file()
  local dir = reaper.GetResourcePath() .. "/Effects/" .. DIR
  local path = dir .. "/" .. FILE
  reaper.RecursiveCreateDirectory(dir, 0)
  local f, err = io.open(path, "w")
  if not f then return false, err, path end
  local ok, werr = f:write(M.text())
  f:close()
  if not ok then return false, werr, path end
  return true, nil, path
end

-- Pelo arquivo (fx_ident), que não muda se o usuário renomear o FX; o nome
-- é a reserva para quando o REAPER não informa o arquivo.
local function is_ours(track, i)
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(track, i, "fx_ident")
  if ok and ident:find(FILE, 1, true) then return true end
  local _, name = reaper.TrackFX_GetFXName(track, i, "")
  return name:find(DESC, 1, true) ~= nil
end

function M.find(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    if is_ours(track, i) then return i end
  end
  return -1
end

function M.install(track)
  local i = M.find(track)
  if i < 0 then
    i = reaper.TrackFX_AddByName(track, M.FX_NAME, false, -1000)
    if i < 0 then return -1, "add_failed" end
  elseif i > 0 then
    reaper.TrackFX_CopyToTrack(track, i, track, 0, true)
  end
  -- cópias a mais (colagem manual) saem: duas mandariam o CC em dobro
  for k = reaper.TrackFX_GetCount(track) - 1, 1, -1 do
    if is_ours(track, k) then reaper.TrackFX_Delete(track, k) end
  end
  return 0
end

function M.coverage(songs, track_of)
  local out = { total = 0, installed = 0, missing = {} }
  for _, song in ipairs(songs) do
    local track = track_of(song)
    if track then
      out.total = out.total + 1
      if M.find(track) >= 0 then out.installed = out.installed + 1
      else out.missing[#out.missing + 1] = song end
    end
  end
  return out
end

function M.set_cc(track, cc, value)
  local fx = M.find(track)
  if fx < 0 then return false end
  reaper.TrackFX_SetParam(track, fx, cc, value)
  diag.note("FX param")
  return true
end

function M.resend(track)
  local fx = M.find(track)
  if fx < 0 then return false end
  local n = reaper.TrackFX_GetParam(track, fx, RESEND)
  reaper.TrackFX_SetParam(track, fx, RESEND, (math.floor(n + 0.5) + 1) % 1000000)
  diag.note("FX reenvio")
  return true
end

function M.sent_count(track)
  local fx = M.find(track)
  if fx < 0 then return nil end
  return math.floor(reaper.TrackFX_GetParam(track, fx, SENT) + 0.5)
end

function M.value(track, cc)
  local fx = M.find(track)
  if fx < 0 then return nil end
  return math.floor(reaper.TrackFX_GetParam(track, fx, cc) + 0.5)
end

return M
