local stub = require("stubs.reaper")

-- 4/4 a 120 BPM (padrão do stub): batida = 0,5 s, compasso = 2 s.
describe("queue", function()
  local queue

  local verso = { name = "Verso", region_idx = 2, start_pos = 8, end_pos = 16 }
  local refrao = { name = "Refrão", region_idx = 3, start_pos = 16, end_pos = 24 }
  local song_b = { id = 7, name = "B", start_pos = 40, end_pos = 80, sections = {} }

  local function sec(ref) return { kind = "section", ref = ref } end
  local songs = { { id = 1, name = "A", start_pos = 0, end_pos = 40, sections = { verso, refrao } }, song_b }

  before_each(function()
    stub.install()
    package.loaded["core.quantize"] = nil
    package.loaded["core.queue"] = nil
    queue = require("core.queue")
  end)

  describe("enqueue", function()
    it("coloca na fila, substitui por outra seção e cancela com a mesma", function()
      assert.equal("queued", queue.enqueue(sec(verso), "bar", 1.0))
      assert.near(2.0, queue.current().jump_pos, 1e-9)

      local status, previous = queue.enqueue(sec(refrao), "bar", 1.2)
      assert.equal("replaced", status)
      assert.equal("Verso", previous.target.ref.name)
      assert.equal("Refrão", queue.current().target.ref.name)

      status, previous = queue.enqueue(sec(refrao), "bar", 1.3)
      assert.equal("cancelled", status)
      assert.equal("Refrão", previous.target.ref.name)
      assert.is_nil(queue.current())
    end)

    it("identifica a seção pelo índice da região, não pela tabela", function()
      queue.enqueue(sec(verso), "4bar", 1.0)
      local copia = { name = "Verso", region_idx = 2, start_pos = 8, end_pos = 16 }
      assert.equal("cancelled", queue.enqueue(sec(copia), "4bar", 1.1))
    end)

    it("cancel esvazia a fila e devolve a entrada", function()
      queue.enqueue(sec(verso), "bar", 1.0)
      assert.equal("Verso", queue.cancel().target.ref.name)
      assert.is_nil(queue.current())
      assert.is_nil(queue.tick(1.9))
    end)
  end)

  describe("tick nos modos nativos", function()
    it("só entrega ao REAPER quando entra no último compasso antes da virada", function()
      queue.enqueue(sec(refrao), "4bar", 0.5)          -- virada em 8 s; último compasso começa em 6 s
      assert.is_nil(queue.tick(3.0))
      assert.is_nil(queue.tick(5.99))

      local a = queue.tick(6.0)
      assert.same({ "hand_off", 8.0, "4bar" }, { a.type, a.jump_pos, a.mode })
      assert.is_true(queue.current().handed_to_reaper)
      assert.is_nil(queue.tick(7.5))                    -- entrega uma vez só
    end)

    it("disparo já dentro do último compasso entrega no próximo ciclo", function()
      queue.enqueue(sec(refrao), "bar", 4.5)
      assert.equal("hand_off", queue.tick(4.53).type)
    end)

    it("avisa a chegada quando o REAPER salta para trás", function()
      queue.enqueue(sec(verso), "bar", 20.5)            -- virada em 22 s, alvo em 8 s
      queue.tick(20.6)
      assert.is_nil(queue.tick(21.9))
      local a = queue.tick(8.02)
      assert.equal("arrived", a.type)
      assert.is_nil(queue.current())
    end)

    it("avisa a chegada quando o REAPER salta para a frente", function()
      queue.enqueue({ kind = "song", ref = song_b }, "bar", 1.0)
      queue.tick(1.1)
      assert.equal("arrived", queue.tick(40.03).type)
    end)

    it("fim da seção entrega no último compasso da seção", function()
      queue.enqueue(sec(refrao), "section_end", 9.0, { section = verso })
      assert.is_nil(queue.tick(13.9))
      local a = queue.tick(14.0)
      assert.same({ "hand_off", 16, "section_end" }, { a.type, a.jump_pos, a.mode })
    end)
  end)

  describe("tick nos modos do script", function()
    it("batida salta na virada da batida", function()
      queue.enqueue(sec(verso), "beat", 1.1)
      assert.is_nil(queue.tick(1.4))
      local a = queue.tick(1.51)
      assert.same({ "jump_now", 1.5 }, { a.type, a.jump_pos })
      assert.is_nil(queue.current())
    end)

    it("imediato salta no próximo ciclo", function()
      queue.enqueue(sec(verso), "now", 3.3)
      assert.equal("jump_now", queue.tick(3.3).type)
    end)

    it("disparo dentro da tolerância salta na hora, mesmo em modo nativo", function()
      queue.enqueue(sec(verso), "bar", 2.02, {}, 0.03)
      local a = queue.tick(2.03)
      assert.same({ "jump_now", 2.0 }, { a.type, a.jump_pos })
    end)
  end)

  describe("alvo removido do projeto", function()
    it("cancela a fila quando a seção some do modelo", function()
      queue.enqueue(sec(refrao), "4bar", 0.5)
      assert.is_nil(queue.tick(1.0, songs))

      local sem_refrao = { { id = 1, name = "A", start_pos = 0, end_pos = 40, sections = { verso } }, song_b }
      local a = queue.tick(1.5, sem_refrao)
      assert.same({ "cancelled", "target_removed", "Refrão" }, { a.type, a.reason, a.entry.target.ref.name })
      assert.is_nil(queue.current())
    end)

    it("atualiza a referência quando a seção só mudou", function()
      queue.enqueue(sec(refrao), "4bar", 0.5)
      local movido = { name = "Refrão", region_idx = 3, start_pos = 18, end_pos = 26 }
      queue.tick(1.0, { { id = 1, sections = { verso, movido } } })
      assert.equal(18, queue.current().target.ref.start_pos)
    end)
  end)
end)
