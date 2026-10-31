describe("ui.anim", function()
  local anim

  before_each(function()
    package.loaded["ui.anim"] = nil
    anim = require("ui.anim")
  end)

  it("aproxima o alvo pelo delta time e chega nele", function()
    local v = anim.approach(0, 1, 1 / 60)
    assert.is_true(v > 0 and v < 1)
    local slow = anim.approach(0, 1, 1 / 120)
    assert.is_true(slow < v)                     -- frame mais curto anda menos
    for _ = 1, 120 do v = anim.approach(v, 1, 1 / 60) end
    assert.equal(1, v)
  end)

  it("o mesmo tempo total dá o mesmo resultado a 30 ou 60 fps", function()
    local a, b = 0, 0
    for _ = 1, 3 do a = anim.approach(a, 1, 1 / 30) end
    for _ = 1, 6 do b = anim.approach(b, 1, 1 / 60) end
    assert.near(a, b, 1e-9)
  end)

  it("value guarda o estado por id e começa no alvo", function()
    assert.equal(5, anim.value("card", 5, 1 / 60))
    local v = anim.value("card", 10, 1 / 60)
    assert.is_true(v > 5 and v < 10)
    anim.forget("card")
    assert.equal(10, anim.value("card", 10, 1 / 60))
  end)

  it("pulse oscila entre 0 e 1 no período", function()
    assert.near(0, anim.pulse(0, 1), 1e-9)
    assert.near(1, anim.pulse(0.5, 1), 1e-9)
    assert.near(0, anim.pulse(1, 1), 1e-9)
  end)

  it("movimento reduzido vai direto ao alvo e não pulsa", function()
    anim.set_reduced(true)
    assert.equal(1, anim.approach(0, 1, 1 / 60))
    assert.equal(1, anim.pulse(0.25, 1))
    assert.is_true(anim.reduced())
  end)
end)
