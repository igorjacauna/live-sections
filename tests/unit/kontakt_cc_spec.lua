local stub = require("stubs.reaper")

describe("kontakt_cc", function()
  local r, mappings, kcc, dir
  local SMC = "SMC-Mixer-bt"

  local function msg(msg_type, number, channel)
    return { port_name = SMC, msg_type = msg_type, channel = channel or 1, number = number }
  end

  local function reload()
    package.loaded["midi.mappings"] = nil
    package.loaded["core.kontakt_cc"] = nil
    mappings = require("midi.mappings")
    mappings.load()
    kcc = require("core.kontakt_cc")
    kcc.init({ mappings = mappings })
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

    it("recusa nome vazio, CC fora de 0–127 e tipo desconhecido", function()
      assert.same({ false, "empty_name" }, { kcc.update("k1", { name = "  " }) })
      assert.same({ false, "invalid_cc" }, { kcc.update("k1", { cc = 128 }) })
      assert.same({ false, "invalid_cc" }, { kcc.update("k1", { cc = 2.5 }) })
      assert.same({ false, "invalid_kind" }, { kcc.update("k1", { kind = "slider" }) })
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
end)
