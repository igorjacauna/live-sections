local stub = require("stubs.reaper")

describe("actions.remote", function()
  local r, remote

  before_each(function()
    r = stub.install()
    package.loaded["actions.remote"] = nil
    remote = require("actions.remote")
  end)

  it("sem instância viva, a action avisa e não enfileira", function()
    remote.run_action("next_song")
    assert.equal(1, #r.calls_to("MB"))
    assert.matches("não está aberto", r.calls_to("MB")[1][1])
    assert.same({ false, "not_running" }, { remote.send("panic") })
  end)

  it("instância viva recebe os comandos em ordem, uma vez só", function()
    r.set_now(100)
    remote.heartbeat(100)
    r.set_now(101)
    remote.run_action("trigger_slot", 3)
    remote.run_action("set_quantize", "2bar")
    local got = remote.poll()
    assert.same({ { action = "trigger_slot", arg = 3 }, { action = "set_quantize", arg = "2bar" } }, got)
    assert.same({}, remote.poll())
    assert.equal(0, #r.calls_to("MB"))
  end)

  it("sinal de vida velho conta como instância fechada", function()
    r.set_now(100)
    remote.heartbeat(100)
    r.set_now(103)
    assert.same({ false, "not_running" }, { remote.send("panic") })
    remote.heartbeat(103)
    remote.shutdown()
    assert.same({ false, "not_running" }, { remote.send("panic") })
  end)

  it("volume de camada leva o valor do CC; sem MIDI, avisa", function()
    r.set_now(1)
    remote.heartbeat(1)
    remote.run_action("layer_volume", 2)
    assert.matches("fader ou knob", r.calls_to("MB")[1][1])
    r._midi_cc = { 127, 64 }
    remote.run_action("layer_volume", 2)
    local c = remote.poll()[1]
    assert.equal("layer_volume", c.action)
    assert.equal(2, c.arg)
    assert.near(64 / 127, c.value, 1e-3)
  end)

  it("cada script de actions/ é uma ação conhecida", function()
    local actions = require("midi.mappings").ACTIONS
    local p = io.popen("ls LiveSections/actions/")
    local n = 0
    for file in p:lines() do
      if file:match("^Live Sections %- .*%.lua$") then
        local f = assert(io.open("LiveSections/actions/" .. file))
        local src = f:read("a")
        f:close()
        local action = src:match('run_action%("([%w_]+)"')
        assert.is_not_nil(actions[action], file)
        n = n + 1
      end
    end
    p:close()
    assert.equal(75, n)
  end)
end)
