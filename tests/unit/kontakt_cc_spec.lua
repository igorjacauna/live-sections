local stub = require("stubs.reaper")

describe("kontakt_cc", function()
  local r, mappings, kcc, dir, jsfx
  local SMC = "SMC-Mixer-bt"
  local fake_layers = { track_of = function(song) return song.track end }

  local function msg(msg_type, number, channel)
    return { port_name = SMC, msg_type = msg_type, channel = channel or 1, number = number }
  end

  local function reload()
    package.loaded["midi.mappings"] = nil
    package.loaded["core.kontakt_cc"] = nil
    mappings = require("midi.mappings")
    mappings.load()
    package.loaded["core.kontakt_jsfx"] = nil
    jsfx = require("core.kontakt_jsfx")
    kcc = require("core.kontakt_cc")
    kcc.init({ mappings = mappings, jsfx = jsfx, layers = fake_layers })
  end

  before_each(function()
    r = stub.install()
    dir = os.tmpname()
    os.remove(dir)
    r._resource_path = dir
    reload()
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  describe("aprender", function()
    it("knob vira knob com o nome do controle e o primeiro CC livre", function()
      local row = kcc.add_from_learn(msg("cc", 16))
      assert.same({ id = "k1", name = "Knob CC16", cc = 2, kind = "knob" }, row)
      local m = kcc.mapping("k1")
      assert.same({ "kontakt_cc", "k1", "cc", 16, SMC }, { m.action, m.arg, m.msg_type, m.number, m.port_name })
    end)

    it("nota vira botão liga/desliga com o nome da nota", function()
      local row = kcc.add_from_learn(msg("note", 0))
      assert.same({ "Botão C-2", "toggle" }, { row.name, row.kind })
      assert.equal("Botão A#-1", kcc.add_from_learn(msg("note", 22)).name)
    end)

    it("fader (pitch bend) vira knob com o número do canal", function()
      local row = kcc.add_from_learn({ port_name = SMC, msg_type = "pb", channel = 3 })
      assert.same({ "Fader 3", "knob" }, { row.name, row.kind })
    end)

    it("CC que chega com o passo de um knob sem fim vira knob sem fim", function()
      local function kind(v) local m = msg("cc", 16); m.value = v; return kcc.add_from_learn(m).kind end
      assert.same({ "encoder", "encoder", "encoder", "knob", "knob" }, { kind(1), kind(127), kind(65), kind(40), kind(nil) })
    end)

    it("o CC sugerido pula os reservados e os já usados", function()
      local ccs = {}
      for n = 16, 30 do ccs[#ccs + 1] = kcc.add_from_learn(msg("cc", n)).cc end
      assert.same({ 2, 3, 4, 5, 6, 8, 9, 12, 13, 14, 15, 16, 17, 18, 19 }, ccs)
    end)

    it("não reaproveita o id de uma linha removida", function()
      kcc.add_from_learn(msg("cc", 16))
      kcc.add_from_learn(msg("cc", 17))
      kcc.remove("k1")
      assert.equal("k3", kcc.add_from_learn(msg("cc", 18)).id)
    end)

    it("salva na hora: as linhas e o controle voltam ao recarregar", function()
      kcc.add_from_learn(msg("cc", 16))
      reload()
      assert.equal("Knob CC16", kcc.get("k1").name)
      assert.equal(16, kcc.mapping("k1").number)
    end)
  end)

  describe("editar", function()
    before_each(function() kcc.add_from_learn(msg("cc", 16)) end)

    it("muda nome, CC e tipo e salva", function()
      assert.is_true(kcc.update("k1", { name = "  Cutoff ", cc = 63, kind = "momentary" }))
      reload()
      assert.same({ id = "k1", name = "Cutoff", cc = 63, kind = "momentary" }, kcc.get("k1"))
    end)

    it("a sensibilidade é salva; 1× não grava nada", function()
      kcc.update("k1", { kind = "encoder", speed = 8 })
      reload()
      assert.equal(8, kcc.get("k1").speed)
      kcc.update("k1", { speed = 1 })
      reload()
      assert.is_nil(kcc.get("k1").speed)
    end)

    it("recusa nome vazio, CC fora de 0–127 e tipo desconhecido", function()
      assert.same({ false, "empty_name" }, { kcc.update("k1", { name = "  " }) })
      assert.same({ false, "invalid_cc" }, { kcc.update("k1", { cc = 128 }) })
      assert.same({ false, "invalid_cc" }, { kcc.update("k1", { cc = 2.5 }) })
      assert.same({ false, "invalid_kind" }, { kcc.update("k1", { kind = "slider" }) })
      assert.same({ false, "invalid_speed" }, { kcc.update("k1", { speed = 3 }) })
      assert.same({ false, "not_found" }, { kcc.update("k9", { name = "X" }) })
      assert.equal("Knob CC16", kcc.get("k1").name)
    end)

    it("remover tira a linha e o controle físico", function()
      kcc.remove("k1")
      assert.equal(0, #kcc.rows())
      assert.is_nil(kcc.mapping("k1"))
      reload()
      assert.equal(0, #kcc.rows())
    end)
  end)

  describe("avisos", function()
    it("CC repetido avisa nas duas linhas, mas deixa salvar", function()
      kcc.add_from_learn(msg("cc", 16))
      kcc.add_from_learn(msg("cc", 17))
      assert.is_true(kcc.update("k2", { cc = 2 }))
      local w = kcc.warnings()
      assert.same({ "duplicate", "k2" }, { w.k1[1].kind, w.k1[1].other.id })
      assert.same({ "duplicate", "k1" }, { w.k2[1].kind, w.k2[1].other.id })
    end)

    it("CC reservado avisa", function()
      kcc.add_from_learn(msg("cc", 16))
      kcc.update("k1", { cc = 64 })
      assert.equal("reserved", kcc.warnings().k1[1].kind)
    end)

    it("linha cujo controle foi aprendido por uma ação fica sem controle", function()
      kcc.add_from_learn(msg("cc", 16))
      mappings.set({ action = "layer_volume", arg = 1, port_name = SMC, msg_type = "cc", channel = 1, number = 16 })
      assert.equal("unmapped", kcc.warnings().k1[1].kind)
    end)

    it("sem problemas, sem avisos", function()
      kcc.add_from_learn(msg("cc", 16))
      assert.is_nil(kcc.warnings().k1)
    end)
  end)

  describe("ao vivo", function()
    local kt_a, kt_b, song_a, song_b, sem

    local function kontakt(name)
      local t = r.add_track(name)
      t.fx = { "VST3i: Kontakt 8" }
      jsfx.install(t)
      return t
    end
    local function cc_of(t, cc) return jsfx.value(t, cc) end
    local function m(id) return kcc.mapping(id) end

    before_each(function()
      kt_a, kt_b = kontakt("A"), kontakt("B")
      song_a, song_b, sem = { track = kt_a }, { track = kt_b }, {}
      kcc.add_from_learn(msg("cc", 16))      -- k1 knob → CC 2
      kcc.add_from_learn(msg("note", 0))     -- k2 liga/desliga → CC 3
      kcc.add_from_learn(msg("note", 1))     -- k3 → CC 4
      kcc.update("k3", { kind = "momentary" })
      kcc.on_song(song_a)
    end)

    it("knob segue o valor e vai só para o Kontakt da música atual", function()
      kcc.handle(m("k1"), 100 / 127, nil, 1)
      assert.equal(100, kcc.value("k1"))
      assert.equal(100, cc_of(kt_a, 2))
      assert.equal(0, cc_of(kt_b, 2))
    end)

    it("knob sem fim soma os passos e para em 0 e 127", function()
      kcc.update("k1", { kind = "encoder" })
      for _ = 1, 5 do kcc.handle(m("k1"), 1 / 127, nil, 1) end
      assert.equal(5, cc_of(kt_a, 2))
      kcc.handle(m("k1"), 127 / 127, nil, 1)   -- complemento de dois: -1
      kcc.handle(m("k1"), 66 / 127, nil, 1)    -- bit de sinal: -2
      assert.equal(2, kcc.value("k1"))
      kcc.handle(m("k1"), 120 / 127, nil, 1)   -- -8
      assert.equal(0, kcc.value("k1"))
      for _ = 1, 30 do kcc.handle(m("k1"), 7 / 127, nil, 1) end
      assert.equal(127, cc_of(kt_a, 2))
    end)

    it("a sensibilidade multiplica o passo do knob sem fim", function()
      kcc.update("k1", { kind = "encoder", speed = 4 })
      kcc.handle(m("k1"), 2 / 127, nil, 1)
      assert.equal(8, kcc.value("k1"))
      kcc.handle(m("k1"), 127 / 127, nil, 1)
      assert.equal(4, kcc.value("k1"))
    end)

    it("abre e fecha a janela do Kontakt da música atual, não a do JSFX", function()
      assert.is_true(kcc.has_kontakt())
      assert.is_true(kcc.open_kontakt())
      local ki = 1                                -- o JSFX fica no índice 0
      assert.is_true(reaper.TrackFX_GetOpen(kt_a, ki))
      assert.is_false(reaper.TrackFX_GetOpen(kt_a, 0))
      kcc.open_kontakt()
      assert.is_false(reaper.TrackFX_GetOpen(kt_a, ki))
      kcc.on_song(sem)
      assert.is_false(kcc.has_kontakt())
      assert.same({ false, "no_kontakt" }, { kcc.open_kontakt() })
    end)

    it("fader (pitch bend) é escalado para 0–127", function()
      kcc.handle(m("k1"), 0.5, nil, 1)
      assert.equal(64, kcc.value("k1"))
    end)

    it("liga/desliga alterna só ao apertar", function()
      kcc.handle(m("k2"), 1, nil, 1)
      assert.equal(127, cc_of(kt_a, 3))
      assert.is_true(kcc.is_on("k2"))
      kcc.handle(m("k2"), 0, true, 1)          -- soltar não muda
      assert.is_true(kcc.is_on("k2"))
      kcc.handle(m("k2"), 1, nil, 2)
      assert.equal(0, cc_of(kt_a, 3))
      assert.is_false(kcc.is_on("k2"))
    end)

    it("liga/desliga por CC alterna só na subida", function()
      kcc.update("k1", { kind = "toggle" })
      kcc.handle(m("k1"), 1, nil, 1)
      kcc.handle(m("k1"), 1, nil, 1)          -- o mesmo toque repetido
      assert.is_true(kcc.is_on("k1"))
      kcc.handle(m("k1"), 0, nil, 1)
      kcc.handle(m("k1"), 1, nil, 2)
      assert.is_false(kcc.is_on("k1"))
    end)

    it("segurar manda 127 ao apertar e 0 ao soltar", function()
      kcc.handle(m("k3"), 1, nil, 1)
      assert.equal(127, cc_of(kt_a, 4))
      kcc.handle(m("k3"), 0, true, 1)
      assert.equal(0, cc_of(kt_a, 4))
    end)

    it("música sem Kontakt não recebe nada, mas o valor muda", function()
      kcc.on_song(sem)
      local before = #r.calls
      kcc.handle(m("k1"), 1, nil, 1)
      assert.equal(127, kcc.value("k1"))
      for i = before + 1, #r.calls do assert.not_equal("TrackFX_SetParam", r.calls[i].name) end
    end)

    it("Kontakt sem o JSFX não recebe nada", function()
      reaper.TrackFX_Delete(kt_a, 0)
      kcc.on_song(song_a)
      kcc.handle(m("k1"), 1, nil, 1)
      assert.equal(127, kcc.value("k1"))
      assert.equal(1, #kt_a.fx)
    end)

    it("ao trocar de música lê os valores dela e pede o reenvio", function()
      kcc.handle(m("k1"), 1, nil, 1)
      jsfx.set_cc(kt_b, 2, 40)
      jsfx.set_cc(kt_b, 3, 127)
      kcc.on_song(song_b)
      assert.same({ 40, true }, { kcc.value("k1"), kcc.is_on("k2") })
      assert.equal(1, reaper.TrackFX_GetParam(kt_b, 0, 128))
      kcc.on_song(song_a)
      assert.equal(127, kcc.value("k1"))
    end)

    it("Testar varre de 0 a 127 em 2 s e volta ao valor", function()
      kcc.handle(m("k1"), 50 / 127, nil, 0)
      kcc.test("k1", 10)
      assert.equal(0, cc_of(kt_a, 2))
      kcc.tick(11)
      assert.equal(63, cc_of(kt_a, 2))
      kcc.tick(12)
      assert.equal(50, cc_of(kt_a, 2))
      assert.equal(50, kcc.value("k1"))
    end)

    it("Enviar p/ Learn manda uma variação e volta", function()
      kcc.handle(m("k1"), 20 / 127, nil, 0)
      kcc.send_learn("k1", 10)
      assert.equal(127, cc_of(kt_a, 2))
      kcc.tick(10.05)
      assert.equal(127, cc_of(kt_a, 2))
      kcc.tick(10.2)
      assert.equal(20, cc_of(kt_a, 2))
    end)

    it("a luz da linha acende quando o contador do JSFX sobe", function()
      kcc.handle(m("k1"), 1, nil, 1)
      kcc.tick(1)
      assert.is_false(kcc.flashed("k1", 1))
      reaper.TrackFX_SetParam(kt_a, 0, 129, 1)  -- o JSFX mandou
      kcc.tick(1.1)
      assert.is_true(kcc.flashed("k1", 1.2))
      assert.is_false(kcc.flashed("k2", 1.2))
      assert.is_false(kcc.flashed("k1", 1.5))
    end)

    it("LED só nos botões liga/desliga, seguindo a música atual", function()
      assert.is_false(kcc.led("k2"))
      kcc.handle(m("k2"), 1, nil, 1)
      assert.is_true(kcc.led("k2"))
      assert.is_nil(kcc.led("k1"))
      assert.is_nil(kcc.led("k3"))
      kcc.on_song(song_b)
      assert.is_false(kcc.led("k2"))
    end)

    it("o último toque vale por 2 s", function()
      kcc.update("k1", { name = "Cutoff" })
      kcc.handle(m("k1"), 64 / 127, nil, 5)
      local t = kcc.last_touch(6)
      assert.same({ "Cutoff", 64 }, { t.row.name, t.value })
      assert.is_nil(kcc.last_touch(7.1))
    end)
  end)
end)
