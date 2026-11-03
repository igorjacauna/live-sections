local stub = require("stubs.reaper")

describe("core.diag", function()
  local diag, r

  before_each(function()
    r = stub.install()
    package.loaded["core.diag"] = nil
    diag = require("core.diag")
  end)

  it("sem medição, não mostra nada", function()
    assert.is_nil(diag.stats(0))
  end)

  it("ciclos por segundo, média, máximo e mensagens MIDI por segundo", function()
    for i = 0, 10 do
      diag.events(i == 5 and 30 or 0)
      local t = i * 0.1
      diag.cycle(t, t + (i == 5 and 0.08 or 0.002))
    end
    local s = diag.stats(1.1)
    assert.near(10, s.fps, 0.5)
    assert.near(80, s.max_ms, 1e-6)
    assert.near(30 / 1.0, s.midi_per_s, 1)
    assert.is_true(s.avg_ms > 2 and s.avg_ms < 10)
  end)

  it("esquece o que passou da janela", function()
    diag.cycle(0, 0.5)
    diag.cycle(1, 1.001)
    diag.cycle(5, 5.001)
    assert.is_nil(diag.stats(5.001))
  end)

  it("engasgo: pausa grande entre ciclos, com partes e o que o ciclo anterior mexeu", function()
    diag.set_info(function() return "performance · tocando" end)
    diag.cycle(0, 0.002)
    r.set_now(0.010)
    diag.part("LEDs", 0.004)
    diag.note("FX param"); diag.note("FX param"); diag.note("LED")
    diag.cycle(0.033, 0.040)
    diag.cycle(0.066, 0.068)                   -- normal
    assert.equal(0, #diag.hitches())
    diag.cycle(0.400, 0.402)                   -- 334 ms depois do anterior
    local h = diag.hitches()
    assert.equal(1, #h)
    assert.near(334, h[1].gap_ms, 1e-6)
    assert.near(2, h[1].script_ms, 1e-6)
    assert.equal("performance · tocando", h[1].info)
    diag.cycle(0.700, 0.701)
    assert.equal(2, #diag.hitches())
    local line = diag.line(diag.hitches()[1])
    assert.matches("pausa · ciclo 334 ms", line)
    assert.matches("script 2 ms", line)
  end)

  it("as notas do ciclo antes da pausa entram no relatório", function()
    diag.cycle(0, 0.001)
    diag.note("FX param"); diag.note("FX param")
    r.set_now(0.01)
    diag.part("camadas", 0.004)
    diag.cycle(0.033, 0.034)
    diag.cycle(0.5, 0.501)
    local line = diag.line(diag.hitches()[1])
    assert.matches("FX param x2", line)
    assert.matches("camadas 6", line)
    assert.matches("ciclo 467 ms", diag.report())
    diag.reset()
    assert.matches("Nenhum engasgo", diag.report())
  end)

  it("falha de áudio do REAPER vira engasgo mesmo sem pausa da tela, com o que mudou há pouco", function()
    local audio = 0
    reaper.GetUnderrunTime = function() return audio, 0, 0 end
    diag.cycle(0, 0.001)
    diag.note("LED")
    diag.cycle(0.033, 0.034)
    diag.note("FX param")
    diag.cycle(0.066, 0.067)
    assert.equal(0, #diag.hitches())
    audio = 12345
    diag.cycle(0.099, 0.100)
    local h = diag.hitches()
    assert.equal(1, #h)
    assert.equal("falha de áudio", h[1].kind)
    local line = diag.line(h[1])
    assert.matches("FX param", line)
    assert.matches("LED", line)
    diag.cycle(0.132, 0.133)
    assert.equal(1, #diag.hitches())          -- o mesmo carimbo não conta de novo
  end)
end)
