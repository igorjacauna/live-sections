local stub = require("stubs.reaper")

-- 4/4 a 120 BPM: compasso = 2 s.
describe("validator", function()
  local r, model, validator

  local function check(ctx)
    model.refresh(0)
    return validator.check(model.songs(), ctx)
  end

  local function kinds(list)
    local out = {}
    for _, w in ipairs(list) do out[#out + 1] = w.kind end
    return out
  end

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.editor_ops", "core.validator", "core.layers" }) do package.loaded[m] = nil end
    model = require("core.project_model")
    validator = require("core.validator", "core.layers")
    r.set_project_length(64)
  end)

  describe("regiões", function()
    before_each(function()
      r.add_marker(4, "SONG: A")
      r.add_region(4, 12, "Intro")
      r.add_region(16, 24, "Verso")   -- buraco 12–16: não é problema
    end)

    it("projeto limpo, com buraco entre seções, não tem avisos", function()
      assert.same({}, check())
    end)

    it("detecta sobreposição e corrige cortando a primeira", function()
      r.add_region(22, 30, "Refrão")
      local list = check()
      assert.same({ "overlap" }, kinds(list))
      assert.equal("error", list[1].severity)
      assert.equal("A", list[1].song)

      r.calls = {}
      assert.is_true(validator.apply(list[1]))
      assert.same({ 16, 22, "Verso" }, r.regions()[2])
      assert.equal(1, #r.calls_to("Undo_BeginBlock"))
      assert.same({}, check())
    end)

    it("detecta região antes do primeiro SONG: e corrige removendo", function()
      r.add_region(0, 4, "Bis")
      local list = check()
      assert.same({ "outside_song" }, kinds(list))
      assert.matches('"Bis"', list[1].text)
      validator.apply(list[1])
      assert.same({}, check())
    end)

    it("sem marcador SONG:, nenhuma região está fora de música", function()
      local r2 = stub.install()
      r2.add_region(0, 4, "Intro")
      model.refresh(0)
      assert.same({}, validator.check(model.songs()))
    end)

    it("detecta início fora do compasso e alinha ao compasso mais próximo", function()
      r.add_region(32.5, 40, "Ponte")       -- compasso 17.2
      local list = check()
      assert.same({ "off_grid" }, kinds(list))
      assert.matches("17%.2", list[1].text)
      assert.equal("Alinhar ao compasso 17", list[1].fix_label)
      validator.apply(list[1])
      assert.same({ 32, 40, "Ponte" }, r.regions()[3])
      assert.same({}, check())
    end)
  end)

  describe("Kontakt", function()
    local links

    before_each(function()
      r.add_marker(0, "SONG: A")
      r.add_region(0, 8, "Intro")
      model.refresh(0)
      links = { [model.songs()[1].id] = { key = "kontakt:{SONG-A}", track_guid = "{KT-A}" } }
      r._ext.LiveSections = { ["kontakt:{SONG-A}"] = "{KT-A}" }
    end)

    it("com linhas no Mapeamento, avisa Kontakt sem o JSFX e instala", function()
      local kt = r.add_track("Kontakt A", "{KT-A}")
      kt.fx = { "VST3i: Kontakt 8" }
      assert.same({}, check({ links = links }))                     -- sem linhas, sem aviso
      local list = check({ links = links, mapping_rows = 2 })
      assert.same({ "kontakt_cc_missing" }, kinds(list))
      assert.equal("warning", list[1].severity)
      assert.matches("Kontakt A", list[1].text)
      assert.is_true(validator.apply(list[1]))
      assert.equal(0, require("core.kontakt_jsfx").find(kt))
      assert.same({}, check({ links = links, mapping_rows = 2 }))
    end)

    it("detecta track com All MIDI inputs e corrige para o teclado", function()
      local kt = r.add_track("Kontakt 7 · A", "{KT-A}")
      r.SetMediaTrackInfo_Value(kt, "I_RECINPUT", 4096 + (63 << 5))
      local list = check({ links = links, keyboard_input = 3 })
      assert.same({ "kontakt_all_inputs" }, kinds(list))
      assert.matches("Kontakt 7 · A", list[1].text)

      assert.is_true(validator.apply(list[1]))
      assert.equal(4096 + (3 << 5), r.GetMediaTrackInfo_Value(kt, "I_RECINPUT"))
      assert.same({}, check({ links = links, keyboard_input = 3 }))
    end)

    it("sem teclado configurado, a correção falha sem abrir undo", function()
      local kt = r.add_track("Kontakt 7 · A", "{KT-A}")
      r.SetMediaTrackInfo_Value(kt, "I_RECINPUT", 4096 + (63 << 5))
      local list = check({ links = links })
      r.calls = {}
      assert.same({ false, "no_keyboard" }, { validator.apply(list[1]) })
      assert.equal(0, #r.calls_to("Undo_BeginBlock"))
    end)

    it("entrada só no teclado não gera aviso", function()
      local kt = r.add_track("Kontakt 7 · A", "{KT-A}")
      r.SetMediaTrackInfo_Value(kt, "I_RECINPUT", 4096 + (3 << 5))
      assert.same({}, check({ links = links }))
    end)

    it("Kontakt saindo direto no master com camadas: corrige para sair só pelas camadas", function()
      local kt = r.add_track("Kontakt 7 · A", "{KT-A}")
      kt.info.B_MAINSEND = 1
      local piano = r.add_track("Piano")
      r.add_receive(kt, piano, 0)
      local list = check({ links = links })
      assert.same({ "kontakt_routing" }, kinds(list))
      assert.matches("direto ao master", list[1].text)
      assert.is_true(validator.apply(list[1]))
      assert.equal(0, kt.info.B_MAINSEND)
      assert.same({}, check({ links = links }))
    end)

    it("camadas em pasta do Kontakt: desfaz a pasta e cria os sends que faltam", function()
      local kt = r.add_track("Kontakt 7 · A", "{KT-A}")
      kt.info.I_FOLDERDEPTH = 1
      local piano = r.add_track("Piano")
      piano.info.I_FOLDERDEPTH = -1
      local list = check({ links = links })
      assert.same({ "kontakt_routing" }, kinds(list))
      assert.matches("numa pasta", list[1].text)
      validator.apply(list[1])
      assert.same({ 0, 0, 0 }, { kt.info.I_FOLDERDEPTH, piano.info.I_FOLDERDEPTH, kt.info.B_MAINSEND })
      assert.equal(piano, kt.sends[1].dst)
      assert.same({}, check({ links = links }))
    end)

    it("detecta vínculo quebrado e corrige desfazendo o vínculo", function()
      local list = check({ links = links })
      assert.same({ "kontakt_missing" }, kinds(list))
      validator.apply(list[1])
      assert.same({ 0, "" }, { r.GetProjExtState(0, "LiveSections", "kontakt:{SONG-A}") })
    end)
  end)
end)
