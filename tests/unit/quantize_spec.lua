local stub = require("stubs.reaper")

describe("quantize", function()
  local r, q

  before_each(function()
    r = stub.install()
    package.loaded["core.quantize"] = nil
    q = require("core.quantize")
  end)

  describe("4/4 a 120 BPM (batida = 0,5 s, compasso = 2 s)", function()
    local cases = {
      { "now", 4.3, 4.3 },
      { "beat", 4.3, 4.5 },
      { "beat", 5.6, 6.0 },   -- última batida do compasso vira o próximo compasso
      { "bar", 4.3, 6.0 },
      { "bar", 4.0, 6.0 },    -- exatamente na virada: vai para a próxima
      { "2bar", 4.3, 8.0 },
      { "4bar", 4.3, 8.0 },
      { "8bar", 4.3, 16.0 },
    }
    for _, c in ipairs(cases) do
      it(string.format("%s em %.1f s salta em %.1f s", c[1], c[2], c[3]), function()
        assert.near(c[3], q.next_jump(c[2], c[1]), 1e-9)
      end)
    end
  end)

  describe("7/8 a 210 colcheias por minuto (compasso = 2 s)", function()
    before_each(function() r.set_tempo_map({ { measure = 0, bpm = 210, num = 7, denom = 8 } }) end)

    it("batida é uma colcheia", function()
      local eighth = 60 / 210
      assert.near(2 + eighth, q.next_jump(2.1, "beat"), 1e-9)
      assert.near(4.0, q.next_jump(2 + 6.5 * eighth, "beat"), 1e-9)
    end)

    it("compasso e blocos de compassos", function()
      assert.near(4.0, q.next_jump(2.1, "bar"), 1e-9)
      assert.near(8.0, q.next_jump(2.1, "4bar"), 1e-9)
    end)
  end)

  describe("mudança de BPM no meio da música", function()
    -- compassos 0-1 a 120 (2 s cada), a partir do compasso 2 a 60 (4 s cada)
    before_each(function()
      r.set_tempo_map({ { measure = 0, bpm = 120, num = 4, denom = 4 }, { measure = 2, bpm = 60, num = 4, denom = 4 } })
    end)

    it("compasso, batida e blocos seguem o tempo novo", function()
      assert.near(4.0, q.next_jump(3.0, "bar"), 1e-9)
      assert.near(8.0, q.next_jump(4.5, "bar"), 1e-9)
      assert.near(5.0, q.next_jump(4.5, "beat"), 1e-9)
      assert.near(12.0, q.next_jump(4.5, "4bar"), 1e-9) -- compasso 4 = 4 + 2*4 s
    end)
  end)

  describe("contexto da música", function()
    it("blocos de N compassos contam a partir do início da música", function()
      local song = { start_pos = 2.0, end_pos = 40 } -- começa no compasso 1
      assert.near(10.0, q.next_jump(4.3, "4bar", { song = song }), 1e-9)
    end)

    it("o salto não passa do fim da música", function()
      local song = { start_pos = 0, end_pos = 7.0 }
      assert.near(7.0, q.next_jump(4.3, "8bar", { song = song }), 1e-9)
    end)

    it("section_end retorna o fim da seção atual, mesmo com trecho sem seção em seguida", function()
      local song = { start_pos = 0, end_pos = 40, gaps = { { start_pos = 16, end_pos = 20 } } }
      local section = { start_pos = 8, end_pos = 16 }
      assert.equal(16, q.next_jump(9.3, "section_end", { song = song, section = section }))
    end)

    it("section_end num trecho sem seção cai no próximo compasso", function()
      assert.near(18.0, q.next_jump(17.1, "section_end", { song = { start_pos = 0, end_pos = 40 } }), 1e-9)
    end)

    it("modo desconhecido gera erro", function()
      assert.has_error(function() q.next_jump(0, "3bar") end)
    end)
  end)

  describe("tolerância", function()
    it("within_tolerance aceita até tol depois da virada, nunca antes", function()
      assert.is_true(q.within_tolerance(6.0, 6.0, 0.03))
      assert.is_true(q.within_tolerance(6.029, 6.0, 0.03))
      assert.is_false(q.within_tolerance(6.031, 6.0, 0.03))
      assert.is_false(q.within_tolerance(5.99, 6.0, 0.03))
    end)

    it("resolve trata um disparo logo depois da virada como anterior a ela", function()
      local jump, late = q.resolve(6.02, "bar", {}, 0.03)
      assert.near(6.0, jump, 1e-9)
      assert.is_true(late)
    end)

    it("resolve fora da tolerância espera a próxima virada", function()
      local jump, late = q.resolve(6.05, "bar", {}, 0.03)
      assert.near(8.0, jump, 1e-9)
      assert.is_false(late)
    end)

    it("resolve em section_end usa o início da seção que acabou de começar", function()
      local section = { start_pos = 16, end_pos = 24 }
      local jump, late = q.resolve(16.01, "section_end", { section = section }, 0.03)
      assert.same({ 16, true }, { jump, late })
    end)

    it("resolve no início do projeto não volta para trás", function()
      local jump, late = q.resolve(0.01, "bar", {}, 0.03)
      assert.near(2.0, jump, 1e-9)
      assert.is_false(late)
    end)
  end)
end)
