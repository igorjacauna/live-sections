local stub = require("stubs.reaper")

describe("midi.learn", function()
  local r, mappings, learn, dir
  local MASTER = "SMC-Mixer-Master"

  local function ev(status, d1, d2) return { port_name = MASTER, status = status, data1 = d1, data2 = d2 } end

  before_each(function()
    r = stub.install()
    dir = os.tmpname()
    os.remove(dir)
    r._resource_path = dir
    package.loaded["midi.mappings"] = nil
    package.loaded["midi.learn"] = nil
    mappings = require("midi.mappings")
    learn = require("midi.learn")
    mappings.load()
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  it("por controle: a primeira mensagem aceita vira o mapeamento, é salva e o learn termina", function()
    learn.start({ action = "trigger_slot", arg = 3 })
    local m = learn.feed(ev(0x90, 8, 127))
    assert.same({ action = "trigger_slot", arg = 3, port_name = MASTER, msg_type = "note", channel = 1, number = 8 }, m)
    assert.is_nil(learn.state())
    assert.is_nil(learn.feed(ev(0x90, 9, 127)))

    package.loaded["midi.mappings"] = nil
    local reloaded = require("midi.mappings")
    reloaded.load()
    assert.equal(8, reloaded.get("trigger_slot", 3).number)
  end)

  it("aceita CC, Program Change e pitch bend", function()
    for _, case in ipairs({ { 0xB0, 7, 100, "cc" }, { 0xC0, 4, 0, "pc" }, { 0xE1, 0, 0x30, "pb" } }) do
      learn.start({ action = "panic" })
      assert.equal(case[4], learn.feed(ev(case[1], case[2], case[3])).msg_type)
    end
    assert.is_nil(mappings.get("panic").number)    -- pitch bend: só o canal
    assert.equal(2, mappings.get("panic").channel)
  end)

  it("ignora Note Off, aftertouch e sistema e continua esperando", function()
    learn.start({ action = "panic" })
    assert.is_nil(learn.feed(ev(0x80, 24, 0)))
    assert.is_nil(learn.feed(ev(0x90, 24, 0)))
    assert.is_nil(learn.feed(ev(0xD0, 30, 0)))
    assert.is_nil(learn.feed(ev(0xA0, 24, 30)))
    assert.is_nil(learn.feed(ev(0xF8, 0, 0)))
    assert.same({ mode = "control", control = { action = "panic" } }, learn.state())
    assert.equal(24, learn.feed(ev(0x90, 24, 127)).number)
  end)

  it("cancelar não muda nada", function()
    learn.start({ action = "panic" })
    learn.cancel()
    assert.is_nil(learn.feed(ev(0x90, 24, 127)))
    assert.same({}, mappings.all())
  end)

  it("global: mapeia em sequência o controle escolhido e segue ativo até cancelar", function()
    learn.start_global()
    assert.is_nil(learn.feed(ev(0x90, 24, 127)))           -- nenhum controle escolhido
    learn.select({ action = "trigger_slot", arg = 1 })
    assert.equal(24, learn.feed(ev(0x90, 24, 127)).number)
    assert.same({ mode = "global" }, learn.state())
    learn.select({ action = "layer_volume", arg = 1 })
    assert.equal("pb", learn.feed(ev(0xE0, 0, 0x40)).msg_type)
    learn.cancel()
    assert.is_nil(learn.state())
    assert.equal(2, #mappings.all())
  end)

  it("select fora do learn global não faz nada", function()
    learn.select({ action = "panic" })
    assert.is_nil(learn.state())
  end)
end)
