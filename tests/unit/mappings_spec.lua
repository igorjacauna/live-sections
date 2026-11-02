local stub = require("stubs.reaper")

describe("midi.mappings", function()
  local r, mappings, dir
  local MASTER, PRIVATE = "SMC-Mixer-Master", "SMC-Mixer-Private"

  local function ev(port, status, d1, d2) return { port_name = port, status = status, data1 = d1, data2 = d2 } end
  local function read_config()
    local f = assert(io.open(mappings.config_path(), "r"))
    local text = f:read("a")
    f:close()
    return require("vendor.json").decode(text)
  end
  local function write_config(text)
    reaper.RecursiveCreateDirectory(dir .. "/Data/LiveSections", 0)
    local f = assert(io.open(mappings.config_path(), "w"))
    f:write(text)
    f:close()
  end

  before_each(function()
    r = stub.install()
    dir = os.tmpname()
    os.remove(dir)
    r._resource_path = dir
    package.loaded["midi.mappings"] = nil
    mappings = require("midi.mappings")
    mappings.load()
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  describe("decode", function()
    it("reconhece Note On, Note Off, CC, Program Change e pitch bend", function()
      assert.same({ msg_type = "note", channel = 1, number = 24, value = 1 }, mappings.decode(ev(MASTER, 0x90, 24, 127)))
      assert.equal("note_off", mappings.decode(ev(MASTER, 0x90, 24, 0)).msg_type)
      assert.equal("note_off", mappings.decode(ev(MASTER, 0x80, 24, 0)).msg_type)
      assert.same({ msg_type = "cc", channel = 10, number = 7, value = 1 }, mappings.decode(ev(MASTER, 0xB9, 7, 127)))
      assert.same({ msg_type = "pc", channel = 1, number = 5, value = 1 }, mappings.decode(ev(MASTER, 0xC0, 5, 0)))
      local pb = mappings.decode(ev(MASTER, 0xE1, 0, 0x7F))     -- fader 2 do SMC-Mixer no topo
      assert.same({ "pb", 2 }, { pb.msg_type, pb.channel })
      assert.is_nil(pb.number)
      assert.near((0x7F << 7) / 16383, pb.value, 1e-9)
    end)

    it("aftertouch e sistema voltam nil", function()
      assert.is_nil(mappings.decode(ev(MASTER, 0xD0, 40, 0)))
      assert.is_nil(mappings.decode(ev(MASTER, 0xA0, 40, 10)))
      assert.is_nil(mappings.decode(ev(MASTER, 0xF8, 0, 0)))
    end)
  end)

  describe("match", function()
    before_each(function()
      mappings.set({ action = "trigger_slot", arg = 1, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
      mappings.set({ action = "layer_volume", arg = 1, port_name = MASTER, msg_type = "pb", channel = 1 })
    end)

    it("casa por porta, tipo, canal e número", function()
      local m = mappings.match(ev(MASTER, 0x90, 24, 127))
      assert.same({ "trigger_slot", 1 }, { m.action, m.arg })
      assert.is_nil(mappings.match(ev(MASTER, 0x91, 24, 127)))   -- outro canal
      assert.is_nil(mappings.match(ev(MASTER, 0x90, 25, 127)))   -- outra nota
      assert.is_nil(mappings.match(ev(MASTER, 0xB0, 24, 127)))   -- outro tipo
      assert.is_true(select(3, mappings.match(ev(MASTER, 0x80, 24, 0))))   -- soltar o botão
    end)

    it("a mesma mensagem por outra porta não dispara", function()
      assert.is_nil(mappings.match(ev(PRIVATE, 0x90, 24, 127)))
    end)

    it("pitch bend casa pelo canal e devolve o valor de 0 a 1", function()
      local m, value = mappings.match(ev(MASTER, 0xE0, 0, 0x40))
      assert.equal("layer_volume", m.action)
      assert.near(0x40 * 128 / 16383, value, 1e-9)
      assert.is_nil(mappings.match(ev(MASTER, 0xE1, 0, 0x40)))
    end)
  end)

  describe("Note Off", function()
    before_each(function()
      mappings.set({ action = "kontakt_cc", arg = "k1", port_name = MASTER, msg_type = "note", channel = 1, number = 30 })
      mappings.set({ action = "kontakt_cc", arg = "k2", port_name = MASTER, msg_type = "cc", channel = 1, number = 16 })
    end)

    it("soltar o botão casa com o mapeamento da nota e avisa que foi solto", function()
      local m, value, released = mappings.match(ev(MASTER, 0x80, 30, 0))
      assert.same({ "kontakt_cc", "k1", 0, true }, { m.action, m.arg, value, released })
      m, value, released = mappings.match(ev(MASTER, 0x90, 30, 0))
      assert.same({ "k1", true }, { m.arg, released })
    end)

    it("apertar não vem marcado como solto", function()
      local m, _, released = mappings.match(ev(MASTER, 0x90, 30, 100))
      assert.equal("k1", m.arg)
      assert.is_nil(released)
    end)

    it("Note Off sem mapeamento da nota, ou por outra porta, não casa", function()
      assert.is_nil(mappings.match(ev(MASTER, 0x80, 31, 0)))
      assert.is_nil(mappings.match(ev(PRIVATE, 0x80, 30, 0)))
    end)
  end)

  describe("set e remove", function()
    it("todas as ações do RF-037 são mapeáveis", function()
      local names = {}
      for name in pairs(mappings.ACTIONS) do names[#names + 1] = name end
      table.sort(names)
      assert.same({
        "cancel", "cycle_quantize", "goto_song", "kontakt_cc", "layer_mute", "layer_solo", "layer_volume", "next_section",
        "next_song", "panic", "play", "play_stop", "prev_section", "prev_song", "set_quantize", "stop", "tap_tempo", "toggle_loop",
        "toggle_setlist", "trigger_slot",
      }, names)
      assert.has_error(function() mappings.set({ action = "explode", port_name = MASTER, msg_type = "cc", channel = 1, number = 1 }) end)
    end)

    it("aprender de novo um controle substitui o mapeamento dele", function()
      mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 1 })
      mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 2 })
      assert.equal(1, #mappings.all())
      assert.equal(2, mappings.get("panic").number)
    end)

    it("a mensagem passa para o último controle que a aprendeu", function()
      mappings.set({ action = "trigger_slot", arg = 1, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
      mappings.set({ action = "trigger_slot", arg = 2, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
      assert.is_nil(mappings.get("trigger_slot", 1))
      assert.equal(2, mappings.match(ev(MASTER, 0x90, 24, 127)).arg)
    end)

    it("o argumento distingue controles da mesma ação", function()
      mappings.set({ action = "layer_volume", arg = 1, port_name = MASTER, msg_type = "pb", channel = 1 })
      mappings.set({ action = "layer_volume", arg = 2, port_name = MASTER, msg_type = "pb", channel = 2 })
      mappings.remove("layer_volume", 1)
      assert.same({ 2 }, { mappings.all()[1].arg })
    end)
  end)

  describe("arquivo", function()
    it("salva e recarrega de Data/LiveSections/config.json", function()
      mappings.set({ action = "trigger_slot", arg = 1, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
      mappings.set({ action = "layer_volume", arg = 1, port_name = MASTER, msg_type = "pb", channel = 1 })
      assert.is_true(mappings.save())
      assert.equal(dir .. "/Data/LiveSections/config.json", mappings.config_path())

      package.loaded["midi.mappings"] = nil
      mappings = require("midi.mappings")
      assert.is_true(mappings.load())
      assert.equal(2, #mappings.all())
      assert.equal("layer_volume", mappings.match(ev(MASTER, 0xE0, 0, 1)).action)
    end)

    it("preserva as outras chaves do arquivo", function()
      write_config('{"version":1,"settings":{"tolerance_ms":45},"mappings":[]}')
      mappings.load()
      mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 1 })
      mappings.save()
      local data = read_config()
      assert.equal(45, data.settings.tolerance_ms)
      assert.equal(1, #data.mappings)
    end)

    it("salva e recarrega as linhas do Mapeamento sem perder os mapeamentos", function()
      mappings.set({ action = "kontakt_cc", arg = "k1", port_name = MASTER, msg_type = "cc", channel = 1, number = 16 })
      local rows = { { id = "k1", name = "Cutoff", cc = 63, kind = "knob" }, { id = "k2", name = "Rotary", cc = 20, kind = "toggle" } }
      assert.is_true(mappings.save_kontakt_rows(rows))
      assert.equal("kontakt_cc", read_config().mappings[1].action)
      mappings.load()
      assert.same(rows, mappings.kontakt_rows())
      assert.equal("k1", mappings.get("kontakt_cc", "k1").arg)
    end)

    it("ignora linhas inválidas do Mapeamento", function()
      write_config([[{"kontakt_cc":[{"id":"k1","name":"A","cc":63,"kind":"knob"},{"id":"k2","name":"B","cc":200,"kind":"knob"},
        {"id":"k3","name":"C","cc":5,"kind":"slider"},{"name":"D","cc":5,"kind":"knob"}]}]])
      mappings.load()
      local rows = mappings.kontakt_rows()
      assert.equal(1, #rows)
      assert.equal("k1", rows[1].id)
    end)

    it("sem arquivo começa vazio", function()
      assert.is_true(mappings.load())
      assert.same({}, mappings.all())
    end)

    it("ignora mapeamentos inválidos e guarda um arquivo ilegível como .bak", function()
      write_config('{"mappings":[{"action":"explode","port_name":"x","msg_type":"cc","channel":1,"number":1},'
        .. '{"action":"panic","port_name":"x","msg_type":"note","channel":1,"number":2}]}')
      mappings.load()
      assert.equal(1, #mappings.all())

      write_config("{ quebrado")
      assert.same({ false, "invalid_config" }, { mappings.load() })
      assert.same({}, mappings.all())
      assert.is_not_nil(io.open(mappings.config_path() .. ".bak", "r"))
      assert.is_nil(io.open(mappings.config_path(), "r"))
    end)
  end)
end)
