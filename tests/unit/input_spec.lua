local stub = require("stubs.reaper")

-- SMC-Mixer do spike 04: porta Master no dev 4.
describe("midi.input", function()
  local r, input
  local MASTER = "SINCO - SMC-Mixer-Master"
  local CONTROL = 0x10000

  local function bytes(events)
    local out = {}
    for _, e in ipairs(events) do out[#out + 1] = { e.status, e.data1, e.data2 } end
    return out
  end

  before_each(function()
    r = stub.install()
    package.loaded["midi.input"] = nil
    input = require("midi.input")
    r.add_midi_input(3, "SINCO - SMC-Mixer-Private")
    r.add_midi_input(4, MASTER)
  end)

  describe("poll", function()
    it("ignora o que chegou antes do init e devolve só os eventos novos, em ordem", function()
      r.midi_in(4, 0x90, 24, 127)
      input.init()
      assert.same({}, input.poll())

      r.midi_in(4, 0x90, 0, 127, 1.5)
      r.midi_in(4, 0xE0, 0, 0x49)
      local events = input.poll()
      assert.same({ { 0x90, 0, 127 }, { 0xE0, 0, 0x49 } }, bytes(events))
      assert.same({ MASTER, 1.5, false }, { events[1].port_name, events[1].ts, events[1].control })
      assert.same({}, input.poll())
    end)

    it("no modo de controle a porta é devIdx & 0xFFFF e a cópia de cada evento é descartada", function()
      input.init()
      r.midi_in(4 | CONTROL, 0x90, 47, 127)
      r.midi_in(4 | CONTROL, 0x90, 47, 127)
      r.midi_in(4 | CONTROL, 0x80, 47, 0)
      r.midi_in(4 | CONTROL, 0x80, 47, 0)
      local events = input.poll()
      assert.same({ { 0x90, 47, 127 }, { 0x80, 47, 0 } }, bytes(events))
      assert.same({ MASTER, true }, { events[1].port_name, events[1].control })
    end)

    it("descarta cópias que chegam em blocos intercalados (fader do spike 04)", function()
      input.init()
      for _, v in ipairs({ 0x49, 0x4A, 0x49, 0x4A, 0x4B, 0x4C, 0x4B, 0x4C, 0x4B, 0x4A, 0x4B, 0x4A }) do
        r.midi_in(4 | CONTROL, 0xE0, 0, v)
      end
      local values = {}
      for _, e in ipairs(input.poll()) do values[#values + 1] = e.data2 end
      -- o fader subiu até 4C e voltou a 4A: cada valor uma vez
      assert.same({ 0x49, 0x4A, 0x4B, 0x4C, 0x4B, 0x4A }, values)
    end)

    it("a cópia pode chegar no ciclo seguinte", function()
      input.init()
      r.midi_in(4 | CONTROL, 0x90, 24, 127)
      assert.equal(1, #input.poll())
      r.midi_in(4 | CONTROL, 0x90, 24, 127)
      assert.equal(0, #input.poll())
    end)

    it("sem a cópia, a mensagem repetida depois da janela passa", function()
      input.init()
      r.midi_in(4 | CONTROL, 0x90, 24, 127)
      input.poll()
      r.set_now(0.5)
      r.midi_in(4 | CONTROL, 0x90, 24, 127)
      assert.equal(1, #input.poll())
    end)

    it("em Enable input nada é descartado", function()
      input.init()
      r.midi_in(4, 0xE0, 0, 0x49)
      r.midi_in(4, 0xE0, 0, 0x49)
      assert.equal(2, #input.poll())
    end)

    it("a mesma mensagem em portas diferentes não é cópia", function()
      input.init()
      r.midi_in(3 | CONTROL, 0x90, 24, 127)
      r.midi_in(4 | CONTROL, 0x90, 24, 127)
      local events = input.poll()
      assert.same({ "SINCO - SMC-Mixer-Private", MASTER }, { events[1].port_name, events[2].port_name })
    end)

    it("lê no máximo 256 eventos por ciclo", function()
      input.init()
      for i = 1, 300 do r.midi_in(4, 0xB0, 1, i % 128) end
      assert.equal(256, #input.poll())
    end)
  end)

  describe("portas", function()
    it("marca a porta que some como desconectada e a que volta como conectada", function()
      input.watch({ MASTER })
      assert.same({}, input.check_ports())
      assert.is_true(input.is_connected(MASTER))

      r.set_midi_present(4, false)
      assert.same({ { port_name = MASTER, connected = false } }, input.check_ports())
      assert.is_false(input.is_connected(MASTER))
      assert.same({}, input.check_ports())

      r.set_midi_present(4, true)
      assert.same({ { port_name = MASTER, connected = true } }, input.check_ports())
    end)

    it("a porta que volta com outro índice continua sendo lida pelo nome", function()
      input.watch({ MASTER })
      input.init()
      r.midi_in(4, 0x90, 24, 127)
      assert.equal(MASTER, input.poll()[1].port_name)

      r._midi_inputs[4] = nil
      input.check_ports()
      r.add_midi_input(6, MASTER)
      r.add_midi_input(4, "Outro")
      assert.same({ { port_name = MASTER, connected = true } }, input.check_ports())
      r.midi_in(6, 0x90, 24, 127)
      assert.equal(MASTER, input.poll()[1].port_name)
    end)

    it("porta acompanhada que nunca esteve presente aparece desconectada", function()
      input.watch({ "Launchpad" })
      assert.same({ { port_name = "Launchpad", connected = false } }, input.check_ports())
    end)

    it("watch mantém o estado das portas que continuam acompanhadas", function()
      input.watch({ MASTER })
      r.set_midi_present(4, false)
      input.check_ports()
      input.watch({ MASTER, "Outro" })
      assert.is_false(input.is_connected(MASTER))
    end)
  end)
end)
