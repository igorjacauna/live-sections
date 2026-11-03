local stub = require("stubs.reaper")

-- Projeto: música A (0–40 s) a 120 BPM 4/4 (compasso = 2 s) e uma track.
-- Pacote "Igreja" a 129 BPM começando no tempo 3 do compasso (fase 2):
--   1 Banda (pasta) > 2 Guia;  3 Kontakt;  4 Piano e 5 Órgão (recebem do 3)
describe("song_import", function()
  local r, si, layers, lp, rows, created, jsfx_writes

  local fake_kcc = {
    get = function(id) return rows[id] end,
    ensure_row = function(row)
      if rows[row.id] then return rows[row.id].cc == row.cc and "exists" or "cc_differs" end
      rows[row.id] = row
      created[#created + 1] = row.id
      return "created"
    end,
  }
  local fake_jsfx = { write_file = function() jsfx_writes = jsfx_writes + 1 end }

  local function pkg()
    return {
      format = 1, name = "Igreja", length = 30, bpm = 129, signature = "4/4", phase_beats = 2,
      tempo = { { t = 0, bpm = 129, num = 4, denom = 4 }, { t = 20, bpm = 100, num = 0, denom = 0 } },
      regions = { { start = 0, ["end"] = 8, name = "Intro", color = 5 }, { start = 8, ["end"] = 20, name = "Verso", color = 6 } },
      chart = "[Intro]\nG D", note = "Tom G",
      kontakt = 3,
      params = { { row = "k1", layer = 4, name = "Sala" }, { row = "k2", layer = 5, name = "" } },
      mapping_rows = { { id = "k1", name = "Reverb", cc = 21, kind = "knob" }, { id = "k2", name = "Rotary", cc = 30, kind = "toggle" } },
      plugins = { "VSTi: Kontakt 7 (NI)", "JS: LiveSections/ls_kontakt_cc.jsfx" },
      folder = "/lib/Igreja",
      tracks = {
        { name = "Banda", level = 0, chunk = "<TRACK\nNAME Banda\nISBUS 0 0\n>" },
        { name = "Guia", level = 1, chunk = table.concat({
          "<TRACK", "NAME Guia",
          "<VOLENV2", "PT 0 0.5 0", "PT 4 1 0", ">",
          "<ITEM", "POSITION 4", "<VOLENV", "PT 0 1 0", ">",
          "<SOURCE WAVE", 'FILE "audio/Guia.wav"', ">", ">", ">" }, "\n") },
        { name = "Kontakt", level = 0, chunk = "<TRACK\nNAME Kontakt\n>" },
        { name = "Piano", level = 0, chunk = "<TRACK\nNAME Piano\nAUXRECV 2 0 1 0 0 0 0 0 0 -1:U 0 -1 ''\n>" },
        { name = "Órgão", level = 0, chunk = "<TRACK\nNAME Órgão\nAUXRECV 2 0 1 0 0 0 0 2 0 -1:U 0 -1 ''\n>" },
      },
      audio = {
        { file = "audio/Guia.wav", path = "/lib/Igreja/audio/Guia.wav" },
        { file = "audio/Click.wav", path = "/lib/Igreja/audio/Click.wav" },
      },
    }
  end

  local function has(chunk, line)
    for l in (chunk .. "\n"):gmatch("([^\n]*)\n") do if l == line then return true end end
    return false
  end

  local START = 42 + 2 * 60 / 129           -- linha do compasso 22 + 2 semínimas a 129

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.layers", "core.layer_params", "core.chart", "core.song_notes", "core.tempo_align", "core.song_import" }) do
      package.loaded[m] = nil
    end
    layers = require("core.layers")
    lp = require("core.layer_params")
    si = require("core.song_import")
    rows, created, jsfx_writes = { k2 = { id = "k2", name = "Rotary", cc = 22, kind = "toggle" } }, {}, 0
    lp.init({ layers = layers, kontakt_cc = fake_kcc })
    si.init({
      layers = layers, layer_params = lp, chart = require("core.chart"), song_notes = require("core.song_notes"),
      kontakt_cc = fake_kcc, tempo_align = require("core.tempo_align"), jsfx = fake_jsfx,
    })
    r.set_project_length(40)
    r.add_marker(0, "SONG: A")
    r.add_region(0, 40, "Tudo")
    r.add_track("Antiga", "{OLD}")
    r._files["/lib/Igreja/audio/Guia.wav"] = true
  end)

  describe("position", function()
    it("um compasso inteiro depois do fim, mais a fase", function()
      local bar, start = si.position(pkg())
      assert.near(42, bar, 1e-9)
      assert.near(START, start, 1e-9)
    end)

    it("fim no meio do compasso: pula para a linha seguinte e mais um", function()
      r.set_project_length(41)
      assert.near(44, (si.position(pkg())), 1e-9)
    end)

    it("projeto vazio: no início", function()
      r = stub.install()
      local p = pkg()
      p.phase_beats = 0
      assert.same({ 0, 0 }, { si.position(p) })
    end)
  end)

  describe("add", function()
    local ok, report

    before_each(function() ok, report = si.add(pkg()) end)

    it("tracks numa pasta com o nome da música, nos níveis do pacote", function()
      assert.is_true(ok)
      local names, depth = {}, {}
      for i, t in ipairs(r._tracks) do names[i], depth[i] = t.name, t.info.I_FOLDERDEPTH end
      assert.equal("Igreja", names[2])
      assert.same({ 1, 1, -1, 0, 0, -1 }, { table.unpack(depth, 2) })
      assert.equal(r._tracks[2], reaper.GetParentTrack(r._tracks[3]))
      assert.equal(r._tracks[3], reaper.GetParentTrack(r._tracks[4]))
      assert.equal(r._tracks[2], reaper.GetParentTrack(r._tracks[7]))
      assert.is_nil(reaper.GetParentTrack(r._tracks[2]))
    end)

    it("itens e automação da track na posição, FILE na biblioteca", function()
      local guia = r._tracks[4].chunk
      assert.is_true(has(guia, "POSITION " .. string.format("%.10f", START + 4):gsub("0+$", "")))
      assert.is_true(has(guia, "PT " .. string.format("%.10f", START):gsub("0+$", "") .. " 0.5 0"))
      assert.is_true(has(guia, "PT 0 1 0"))                 -- envelope do take não muda
      assert.is_true(has(guia, 'FILE "/lib/Igreja/audio/Guia.wav"'))
    end)

    it("rotas para o Kontakt novo; as camadas são reconhecidas", function()
      assert.is_true(has(r._tracks[6].chunk, "AUXRECV 4 0 1 0 0 0 0 0 0 -1:U 0 -1 ''"))
      local song = report.song
      assert.equal(r._tracks[5], layers.track_of(song))
      local l = layers.layers(song)
      assert.same({ "Piano", "Órgão" }, { l[1].name, l[2].name })
    end)

    it("marcador, regiões e tempo da música", function()
      local list = {}
      for _, m in ipairs(r._markers) do
        if m.pos > 40 then list[#list + 1] = { m.name, m.pos, m.rgnend, m.color } end
      end
      table.sort(list, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1]) end)
      assert.equal(3, #list)
      assert.same({ "Intro", "SONG: Igreja", "Verso" }, { list[1][1], list[2][1], list[3][1] })
      assert.near(START, list[2][2], 1e-9)
      assert.near(START + 20, list[3][3], 1e-9)
      assert.equal(6, list[3][4])
      local t = r._tempo_markers
      assert.same({ 42, 129, 4, 4 }, { t[1].time, t[1].bpm, t[1].num, t[1].denom })
      assert.near(START + 20, t[2].time, 1e-9)
    end)

    it("cifra, anotação e parâmetros com as tracks novas", function()
      local song = report.song
      assert.equal("[Intro]\nG D", require("core.chart").get_text(song))
      assert.equal("Tom G", require("core.song_notes").get(song))
      assert.same({
        { row = "k1", layer = r._tracks[6].guid, name = "Sala" },
        { row = "k2", layer = r._tracks[7].guid, name = "" },
      }, lp.list(song))
    end)

    it("relatório: Learn das linhas criadas, CC diferente e áudio offline", function()
      assert.same({ "Reverb" }, report.learn)
      assert.same({ "Rotary" }, report.cc_differs)
      assert.same({ "audio/Click.wav" }, report.offline)
      assert.equal(1, jsfx_writes)
    end)

    it("um passo de undo com a tela congelada no meio", function()
      local ends = r.calls_to("Undo_EndBlock")
      assert.same({ "Live Sections: adicionar música da biblioteca", -1 }, { ends[#ends][1], ends[#ends][2] })
      assert.same({ 1, -1 }, { r.calls_to("PreventUIRefresh")[1][1], r.calls_to("PreventUIRefresh")[2][1] })
    end)
  end)

  it("música sem Kontakt entra sem vínculo nem parâmetros", function()
    local p = pkg()
    p.kontakt, p.params, p.mapping_rows = nil, {}, {}
    local ok, report = si.add(p)
    assert.is_true(ok)
    assert.is_nil(layers.track_of(report.song))
    assert.same({}, report.learn)
  end)
end)
