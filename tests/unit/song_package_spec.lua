local stub = require("stubs.reaper")

-- Música A (0–40) e B (40–80). Tracks (índice no projeto):
--   0 Banda (pasta) > 1 Guia (itens de A e de B), 2 Bateria (só itens de B)
--   3 Kontakt A > camadas 4 Piano e 5 Órgão (sends do Kontakt)
--   6 Kontakt B
describe("song_package", function()
  local r, model, layers, sp, a, b
  local banda, guia, bateria, kt, piano, orgao, kt_b
  local params, rows

  local fake_lp = { list = function() return params end }
  local fake_kcc = { get = function(id) return rows[id] end }

  local function lines(chunk)
    local out = {}
    for l in (chunk .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l:match("^%s*(.-)%s*$") end
    return out
  end

  local function has(chunk, line)
    for _, l in ipairs(lines(chunk)) do if l == line then return true end end
    return false
  end

  local function count(chunk, pattern)
    local n = 0
    for _, l in ipairs(lines(chunk)) do if l:match(pattern) then n = n + 1 end end
    return n
  end

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.layers", "core.chart", "core.song_notes", "core.tempo_align", "core.song_package" }) do
      package.loaded[m] = nil
    end
    model = require("core.project_model")
    layers = require("core.layers")
    sp = require("core.song_package")
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_region(0, 8, "Intro", 111)
    r.add_region(8, 24, "Verso", 222)
    r.add_marker(40, "SONG: B")
    r.add_region(40, 48, "Intro")
    banda = r.add_track("Banda", "{BANDA}"); banda.info.I_FOLDERDEPTH = 1
    guia = r.add_track("Guia", "{GUIA}")
    bateria = r.add_track("Bateria", "{BAT}"); bateria.info.I_FOLDERDEPTH = -1
    kt = r.add_track("Kontakt A", "{KT}")
    piano = r.add_track("Piano", "{PIANO}")
    orgao = r.add_track("Órgão", "{ORGAO}")
    kt_b = r.add_track("Kontakt B", "{KT-B}")
    r.add_receive(kt, piano, 0)
    r.add_receive(kt, orgao, 2)
    r.add_item(4, 30, -1, guia)
    r.add_item(44, 30, -1, guia)
    r.add_item(41, 10, -1, bateria)
    model.refresh(0)
    a, b = model.songs()[1], model.songs()[2]
    layers.link(a, kt)
    layers.link(b, kt_b)
    params, rows = {}, {
      k1 = { id = "k1", name = "Reverb", cc = 21, kind = "knob" },
      k2 = { id = "k2", name = "Rotary", cc = 22, kind = "toggle" },
    }
    sp.init({
      layers = layers, layer_params = fake_lp, chart = require("core.chart"),
      song_notes = require("core.song_notes"), kontakt_cc = fake_kcc,
      tempo_align = require("core.tempo_align"),
    })
  end)

  describe("detect_tracks", function()
    it("pega tracks com item na música, o Kontakt, as camadas e as pastas", function()
      assert.same({ banda, guia, kt, piano, orgao }, sp.detect_tracks(a))
    end)

    it("itens de outra música não puxam a track", function()
      assert.same({ banda, guia, bateria, kt_b }, sp.detect_tracks(b))
    end)

    it("música sem Kontakt fica só com as tracks dos itens", function()
      layers.unlink(a)
      assert.same({ banda, guia }, sp.detect_tracks(a))
    end)
  end)

  describe("filter_chunk", function()
    local CHUNK = table.concat({
      "<TRACK {AAAA-1111}",
      "  NAME Guia",
      "  TRACKID {AAAA-1111}",
      "  ISBUS 1 1",
      "  AUXRECV 3 0 1 0 0 0 0 0 0 -1:U 0 -1 ''",
      "  AUXRECV 6 0 1 0 0 0 0 0 0 -1:U 0 -1 ''",
      "  <VOLENV2",
      "    ACT 1 -1",
      "    PT 98 0.5 0",
      "    PT 112 0.8 0",
      "    PT 145 1 0",
      "  >",
      "  <FXCHAIN",
      "    <VST \"VSTi: Kontakt 7 (Native Instruments)\" Kontakt.vst3 0 \"\" 123<abc> \"\"",
      "      QUJDRA==",
      "    >",
      "    FXID {F-1}",
      "    <JS utility/volume \"\"",
      "    >",
      "  >",
      "  <ITEM",
      "    POSITION 104",
      "    IGUID {I-1}",
      "    <SOURCE WAVE",
      "      FILE \"C:\\audio\\Guia.wav\"",
      "    >",
      "  >",
      "  <ITEM",
      "    POSITION 110.5",
      "    IGUID {I-2}",
      "    <VOLENV",
      "      PT 0 1 0",
      "    >",
      "    GUID {T-2}",
      "    <SOURCE WAVE",
      "      FILE \"Guia.wav\" 1",
      "    >",
      "  >",
      "  <ITEM",
      "    POSITION 150",
      "    <SOURCE WAVE",
      "      FILE \"C:\\audio\\Outra.wav\"",
      "    >",
      "  >",
      ">",
    }, "\n")

    local function filter(name_of)
      return sp.filter_chunk(CHUNK, 100, 140, { [3] = 2 }, name_of)
    end

    it("tira os GUIDs e o GUID da linha da track", function()
      local chunk = filter()
      assert.equal(0, count(chunk, "^TRACKID") + count(chunk, "^FXID") + count(chunk, "^GUID") + count(chunk, "^IGUID"))
      assert.equal("<TRACK", lines(chunk)[1])
    end)

    it("deixa só os itens que começam na música, com posição relativa", function()
      local chunk = filter()
      assert.equal(2, count(chunk, "^<ITEM"))
      assert.is_true(has(chunk, "POSITION 4"))
      assert.is_true(has(chunk, "POSITION 10.5"))
      assert.is_false(has(chunk, 'FILE "C:\\audio\\Outra.wav"'))
    end)

    it("automação da track só dentro da música, com o valor de antes no início", function()
      local chunk = filter()
      assert.is_true(has(chunk, "PT 0 0.5 0"))
      assert.is_true(has(chunk, "PT 12 0.8 0"))
      assert.equal(0, count(chunk, "^PT 45") + count(chunk, "^PT 98"))
      assert.is_true(has(chunk, "PT 0 1 0"))   -- envelope do take não muda
    end)

    it("rotas: índice no pacote; de fora do pacote saem", function()
      local chunk = filter()
      assert.is_true(has(chunk, "AUXRECV 1 0 1 0 0 0 0 0 0 -1:U 0 -1 ''"))
      assert.equal(1, count(chunk, "^AUXRECV"))
    end)

    it("FILE: devolve os arquivos e reescreve pelo nome dado", function()
      local chunk, files = filter(function(p) return p == "Guia.wav" and "audio/Guia 2.wav" or "audio/Guia.wav" end)
      assert.same({ "C:\\audio\\Guia.wav", "Guia.wav" }, files)
      assert.is_true(has(chunk, 'FILE "audio/Guia.wav"'))
      assert.is_true(has(chunk, 'FILE "audio/Guia 2.wav" 1'))
    end)

    it("devolve os plugins e mantém o estado do FX", function()
      local chunk, _, plugins = filter()
      assert.same({ "VSTi: Kontakt 7 (Native Instruments)", "JS: utility/volume" }, plugins)
      assert.is_true(has(chunk, "QUJDRA=="))
      assert.is_true(has(chunk, "ISBUS 0 0"))
    end)
  end)

  describe("build", function()
    before_each(function()
      guia.chunk = table.concat({
        "<TRACK", "NAME Guia",
        "<ITEM", "POSITION 4", "<SOURCE WAVE", 'FILE "Guia.wav"', ">", ">",
        "<ITEM", "POSITION 20", "<SOURCE WAVE", 'FILE "/outro/Guia.wav"', ">", ">",
        "<ITEM", "POSITION 44", "<SOURCE WAVE", 'FILE "/b.wav"', ">", ">",
        ">",
      }, "\n")
      piano.chunk = "<TRACK\nNAME Piano\nAUXRECV 3 0 1 0 0 0 0 0 0 -1:U 0 -1 ''\n>"
      orgao.chunk = "<TRACK\nNAME Órgão\nAUXRECV 3 0 1 2 0 0 0 0 0 -1:U 0 -1 ''\n>"
      kt.chunk = '<TRACK\nNAME Kontakt A\n<FXCHAIN\n<VST "VSTi: Kontakt 7 (NI)" k.vst3 0 ""\nAAAA\n>\n>\n>'
      banda.chunk = "<TRACK\nNAME Banda\nISBUS 1 1\n>"
      r._files["/proj/Guia.wav"] = true
      require("core.chart").set_text(a, "[Intro]\nG D")
      require("core.song_notes").set(a, "Tom G")
      params = {
        { row = "k1", layer = "{PIANO}", name = "Sala" },
        { row = "k2", layer = "{ORGAO}", name = "" },
        { row = "k1", layer = "{OUTRA}", name = "x" },
      }
    end)

    it("marcador, regiões, cifra e anotação relativos à música", function()
      local pkg = sp.build(a, sp.detect_tracks(a), { name = "Igreja" })
      assert.equal(1, pkg.format)
      assert.equal("Igreja", pkg.name)
      assert.equal(40, pkg.length)
      assert.same({
        { start = 0, ["end"] = 8, name = "Intro", color = 111 },
        { start = 8, ["end"] = 24, name = "Verso", color = 222 },
      }, pkg.regions)
      assert.equal("[Intro]\nG D", pkg.chart)
      assert.equal("Tom G", pkg.note)
    end)

    it("tempo, fórmula e fase da música", function()
      r._tempo_markers = { { time = 41, bpm = 129, num = 4, denom = 4 } }
      local pkg = sp.build(b, sp.detect_tracks(b))
      assert.equal(129, pkg.bpm)
      assert.equal("4/4", pkg.signature)
      assert.same({ { t = 0, bpm = 120, num = 4, denom = 4 }, { t = 1, bpm = 129, num = 4, denom = 4 } }, pkg.tempo)
      assert.near(0, pkg.phase_beats, 1e-9)          -- 40 s a 120 BPM: 80 semínimas
    end)

    it("regiões da música B ficam relativas ao início dela", function()
      local pkg = sp.build(b, sp.detect_tracks(b))
      assert.equal("B", pkg.name)
      assert.same({ { start = 0, ["end"] = 8, name = "Intro", color = 0 } }, pkg.regions)
    end)

    it("tracks com nível normalizado, rotas pelo índice do pacote e plugins", function()
      local pkg = sp.build(a, sp.detect_tracks(a))
      local names, levels = {}, {}
      for i, t in ipairs(pkg.tracks) do names[i], levels[i] = t.name, t.level end
      assert.same({ "Banda", "Guia", "Kontakt A", "Piano", "Órgão" }, names)
      assert.same({ 0, 1, 0, 0, 0 }, levels)
      assert.is_true(has(pkg.tracks[4].chunk, "AUXRECV 2 0 1 0 0 0 0 0 0 -1:U 0 -1 ''"))
      assert.is_true(has(pkg.tracks[1].chunk, "ISBUS 0 0"))
      assert.same({ "VSTi: Kontakt 7 (NI)" }, pkg.plugins)
    end)

    it("áudios em audio/ sem nome repetido; o ausente fica marcado", function()
      local pkg, problems = sp.build(a, sp.detect_tracks(a))
      assert.same({
        { file = "audio/Guia.wav", from = "/proj/Guia.wav" },
        { file = "audio/Guia 2.wav", from = "/outro/Guia.wav", missing = true },
      }, pkg.audio)
      assert.same({ "/outro/Guia.wav" }, problems.missing_audio)
      assert.is_true(has(pkg.tracks[2].chunk, 'FILE "audio/Guia 2.wav"'))
      assert.is_false(has(pkg.tracks[2].chunk, 'FILE "/b.wav"'))
    end)

    it("Kontakt, parâmetros e linhas do Mapeamento por índice", function()
      local pkg = sp.build(a, sp.detect_tracks(a))
      assert.equal(3, pkg.kontakt)
      assert.same({
        { row = "k1", layer = 4, name = "Sala" },
        { row = "k2", layer = 5, name = "" },
      }, pkg.params)
      assert.same({
        { id = "k1", name = "Reverb", cc = 21, kind = "knob" },
        { id = "k2", name = "Rotary", cc = 22, kind = "toggle" },
      }, pkg.mapping_rows)
    end)

    it("sem o Kontakt no pacote: sem camadas nem parâmetros", function()
      local pkg = sp.build(a, { banda, guia })
      assert.is_nil(pkg.kontakt)
      assert.same({}, pkg.params)
      assert.same({}, pkg.mapping_rows)
    end)
  end)
end)
