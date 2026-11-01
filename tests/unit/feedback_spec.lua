local stub = require("stubs.reaper")

describe("midi.feedback", function()
  local r, fb
  local MASTER = "SMC-Mixer-Master"
  local VEL = { idle = 1, playing = 21, queued = 13, loop = 45, empty = 0 }

  local verso = { name = "Verso", region_idx = 2 }
  local refrao = { name = "Refrão", region_idx = 3 }
  local function slot(n, number) return { action = "trigger_slot", arg = n, port_name = MASTER, msg_type = "note", channel = 1, number = number } end

  local function sent()
    local out = {}
    for _, c in ipairs(r.calls_to("StuffMIDIMessage")) do out[#out + 1] = { c[1], c[2], c[3], c[4] } end
    r.calls = {}
    return out
  end

  before_each(function()
    r = stub.install()
    package.loaded["midi.feedback"] = nil
    fb = require("midi.feedback")
    r.add_midi_output(3, "SMC-Mixer-Private")
    r.add_midi_output(4, MASTER)
    fb.configure({ led_velocity = VEL })
  end)

  describe("state_for", function()
    local ctx = { sections = { verso, refrao }, playing = verso, queued = refrao }

    it("pad de seção: tocando, na fila, loop, parado; sem seção fica vazio", function()
      assert.equal("playing", fb.state_for(slot(1), ctx))
      assert.equal("queued", fb.state_for(slot(2), ctx))
      assert.equal("empty", fb.state_for(slot(3), ctx))
      assert.equal("loop", fb.state_for(slot(1), { sections = { verso }, playing = verso, looping = verso }))
      assert.equal("idle", fb.state_for(slot(2), { sections = { verso, refrao }, playing = verso }))
    end)

    it("compara seções pelo índice da região", function()
      assert.equal("playing", fb.state_for(slot(1), { sections = { { region_idx = 2 } }, playing = { region_idx = 2 } }))
    end)

    it("botão de loop acende com loop ligado; os outros ficam parados", function()
      local loop = { action = "toggle_loop", port_name = MASTER, msg_type = "note", channel = 1, number = 95 }
      assert.equal("loop", fb.state_for(loop, { looping = verso }))
      assert.equal("idle", fb.state_for(loop, {}))
      assert.equal("idle", fb.state_for({ action = "panic" }, ctx))
    end)

    it("mute e solo de camada acendem quando ligados", function()
      local layer = function(slot) return ({ { mute = true, solo = false }, { mute = false, solo = true } })[slot] end
      local mute = function(n) return { action = "layer_mute", arg = n } end
      local solo = function(n) return { action = "layer_solo", arg = n } end
      local c = { layer = layer }
      assert.same({ "playing", "idle", "idle", "playing", "idle" },
        { fb.state_for(mute(1), c), fb.state_for(mute(2), c), fb.state_for(solo(1), c), fb.state_for(solo(2), c),
          fb.state_for(mute(3), c) })
    end)

    it("Play e Play/Stop acendem com o transporte tocando", function()
      assert.equal("playing", fb.state_for({ action = "play" }, { transport = true }))
      assert.equal("playing", fb.state_for({ action = "play_stop" }, { transport = true }))
      assert.equal("idle", fb.state_for({ action = "play" }, {}))
      assert.equal("idle", fb.state_for({ action = "stop" }, { transport = true }))
    end)
  end)

  describe("flush", function()
    it("envia a velocity do estado pelo mesmo mapeamento, na saída de mesmo nome", function()
      fb.set_state(slot(1, 24), "playing")
      fb.set_state({ action = "panic", port_name = MASTER, msg_type = "cc", channel = 2, number = 7 }, "idle")
      fb.flush(0)
      local out = sent()
      table.sort(out, function(a, b) return a[2] < b[2] end)
      assert.same({ { 20, 0x90, 24, 21 }, { 20, 0xB1, 7, 1 } }, out)
    end)

    it("só envia quando o estado muda", function()
      fb.set_state(slot(1, 24), "idle")
      fb.flush(0)
      sent()
      fb.set_state(slot(1, 24), "idle")
      fb.flush(0.1)
      assert.same({}, sent())
      fb.set_state(slot(1, 24), "loop")
      fb.flush(0.2)
      assert.same({ { 20, 0x90, 24, 45 } }, sent())
    end)

    it("na fila pisca alternando com a velocity de parado", function()
      fb.set_state(slot(2, 25), "queued")
      fb.flush(0.1)
      assert.same({ { 20, 0x90, 25, 13 } }, sent())
      fb.flush(0.3)
      assert.same({}, sent())
      fb.flush(0.6)
      assert.same({ { 20, 0x90, 25, 1 } }, sent())
      fb.flush(1.1)
      assert.same({ { 20, 0x90, 25, 13 } }, sent())
    end)

    it("piscar pode ser desligado", function()
      fb.configure({ led_velocity = VEL, led_blink = false })
      fb.set_state(slot(2, 25), "queued")
      fb.flush(0.1)
      fb.flush(0.6)
      assert.same({ { 20, 0x90, 25, 13 } }, sent())
    end)

    it("a saída escolhida nas configurações substitui a de mesmo nome", function()
      fb.configure({ led_velocity = VEL, feedback_out_port = "SMC-Mixer-Private" })
      fb.set_state(slot(1, 24), "playing")
      fb.flush(0)
      assert.same({ { 19, 0x90, 24, 21 } }, sent())
    end)

    it("sem saída com o nome, não envia e tenta de novo no próximo flush", function()
      fb.set_state({ action = "panic", port_name = "Launchpad", msg_type = "note", channel = 1, number = 1 }, "idle")
      fb.flush(0)
      assert.same({}, sent())
      r.add_midi_output(7, "Launchpad")
      fb.flush(0.1)
      assert.same({ { 23, 0x90, 1, 1 } }, sent())
    end)

    it("reenvia tudo a cada 2 s, para um LED aceso por fora não ficar preso", function()
      fb.set_state(slot(1, 24), "idle")
      fb.flush(0)
      sent()
      fb.flush(1.9)
      assert.same({}, sent())
      fb.flush(2.0)
      assert.same({ { 20, 0x90, 24, 1 } }, sent())
    end)

    it("reenvia o LED de um botão tocado", function()
      fb.set_state(slot(1, 24), "idle")
      fb.flush(0)
      sent()
      fb.touch(slot(1, 24))
      fb.flush(0.1)
      assert.same({ { 20, 0x90, 24, 1 } }, sent())
    end)

    it("clear apaga os LEDs mapeados com velocity 0", function()
      fb.set_state(slot(1, 24), "playing")
      fb.flush(0)
      sent()
      fb.clear()
      assert.same({ { 20, 0x90, 24, 0 } }, sent())
    end)

    it("lista as portas sem saída até a saída aparecer", function()
      fb.set_state({ action = "panic", port_name = "Launchpad", msg_type = "note", channel = 1, number = 1 }, "idle")
      fb.flush(0)
      assert.same({ "Launchpad" }, fb.missing_outputs())
      r.add_midi_output(7, "Launchpad")
      fb.flush(0.1)
      assert.same({}, fb.missing_outputs())
    end)

    it("aceita a saída com o mesmo nome em outra caixa", function()
      r.add_midi_output(7, "LAUNCHPAD")
      fb.set_state({ action = "panic", port_name = "Launchpad", msg_type = "note", channel = 1, number = 1 }, "idle")
      fb.flush(0)
      assert.same({ { 23, 0x90, 1, 1 } }, sent())
    end)

    it("Program Change e pitch bend não têm feedback", function()
      fb.set_state({ action = "panic", port_name = MASTER, msg_type = "pc", channel = 1, number = 1 }, "idle")
      fb.set_state({ action = "layer_volume", arg = 1, port_name = MASTER, msg_type = "pb", channel = 1 }, "idle")
      fb.flush(0)
      assert.same({}, sent())
    end)

    it("velocities que faltam nas configurações usam o padrão", function()
      fb.configure({ led_velocity = { playing = 5 } })
      fb.set_state(slot(1, 24), "playing")
      fb.set_state(slot(2, 25), "loop")
      fb.flush(0)
      local out = sent()
      table.sort(out, function(a, b) return a[3] < b[3] end)
      assert.same({ { 20, 0x90, 24, 5 }, { 20, 0x90, 25, 127 } }, out)
    end)

    it("reset e configure reenviam tudo; forget para de enviar", function()
      fb.set_state(slot(1, 24), "playing")
      fb.flush(0)
      sent()
      fb.reset()
      fb.flush(0.1)
      assert.equal(1, #sent())
      fb.forget(slot(1, 24))
      fb.reset()
      fb.flush(0.2)
      assert.same({}, sent())
    end)
  end)
end)
