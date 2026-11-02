describe("core.diag", function()
  local diag

  before_each(function()
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
end)
