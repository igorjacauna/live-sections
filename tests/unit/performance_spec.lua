local stub = require("stubs.reaper")

-- 4/4 a 120 BPM: compasso = 2 s.
-- Música A (0–40): Intro 0–8, Verso 8–16, Refrão 16–24, sem seção 24–28, Outro 28–40.
-- Música B (40–80): Intro 40–48, Verso 48–64.
describe("performance", function()
  local r, perf

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.quantize", "core.queue", "core.transport", "core.performance" }) do
      package.loaded[m] = nil
    end
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_region(0, 8, "Intro")
    r.add_region(8, 16, "Verso")
    r.add_region(16, 24, "Refrão")
    r.add_region(28, 40, "Outro")
    r.add_marker(40, "SONG: B")
    r.add_region(40, 48, "Intro")
    r.add_region(48, 64, "Verso")
    r.set_config("smoothseekmeas", 1)
    perf = require("core.performance")
    perf.init()
    r.calls = {}
  end)

  local function last(name)
    local list = r.calls_to(name)
    return list[#list]
  end

  local function playing_at(pos)
    r.set_play(true, pos)
    perf.tick()
    r.calls = {}
  end

  describe("transporte parado", function()
    it("disparar uma seção move o cursor e toca na hora", function()
      assert.equal("started", perf.trigger_slot(2))
      assert.same({ 8, true, false, n = 3 }, last("SetEditCurPos"))
      assert.equal(1, #r.calls_to("OnPlayButton"))
      assert.is_nil(perf.queued())
    end)

    it("disparar uma seção a partir de um ponto dela começa dali", function()
      local song = require("core.project_model").songs()[1]
      assert.equal("started", perf.trigger_section(song.sections[2], 11))
      assert.same({ 11, true, false, n = 3 }, last("SetEditCurPos"))
      assert.equal(1, #r.calls_to("OnPlayButton"))
    end)

    it("slot sem seção é ignorado", function()
      assert.is_nil(perf.trigger_slot(9))
      assert.equal(0, #r.calls)
    end)

    it("ir para outra música só move o cursor para ela", function()
      perf.goto_song(2)
      assert.same({ 40, true, false, n = 3 }, last("SetEditCurPos"))
      assert.equal(0, #r.calls_to("OnPlayButton"))
      assert.equal("B", perf.current_song().name)
      assert.same({ 40, 80 }, { r.GetSet_LoopTimeRange2(0, false) })
    end)
  end)

  describe("tocando", function()
    it("sem disparo, o tick não mexe no transporte", function()
      playing_at(3.0)
      for _, p in ipairs({ 5.0, 9.0, 15.9, 17.0 }) do r.set_play(true, p); perf.tick() end
      assert.equal(0, #r.calls_to("SetEditCurPos"))
      assert.equal(0, #r.calls_to("GoToRegion"))
    end)

    it("disparar enfileira com o quantize e entrega no último compasso", function()
      playing_at(3.0)
      perf.set_quantize("4bar")
      assert.equal("queued", perf.trigger_slot(3))
      assert.near(8.0, perf.queued().jump_pos, 1e-9)

      r.set_play(true, 5.0); perf.tick()
      assert.equal(0, #r.calls_to("SetEditCurPos"))
      r.set_play(true, 6.1); perf.tick()
      assert.same({ 16, false, true, n = 3 }, last("SetEditCurPos"))
    end)

    it("disparar de novo a seção na fila depois da entrega desfaz o salto", function()
      playing_at(3.0)
      perf.trigger_slot(3)                               -- compasso: virada em 4 s
      r.set_play(true, 3.1); perf.tick()                 -- já no último compasso: entregue
      r.calls = {}
      assert.equal("cancelled", perf.trigger_slot(3))
      assert.same({ 4.0, false, true, n = 3 }, last("SetEditCurPos"))
    end)

    it("disparar outra seção com loop ligado desliga o loop e enfileira", function()
      playing_at(9.0)
      assert.is_true(perf.toggle_loop())
      assert.equal("Verso", perf.loop_section().name)
      assert.equal(1, r.GetSetRepeat(-1))

      assert.equal("queued", perf.trigger_slot(1))
      assert.is_nil(perf.loop_section())
      assert.equal(0, r.GetSetRepeat(-1))
      assert.same({ 0, 40 }, { r.GetSet_LoopTimeRange2(0, false) })
    end)

    it("loop num trecho sem seção não liga", function()
      playing_at(25.0)
      local ok, err = perf.toggle_loop()
      assert.is_nil(ok)
      assert.equal("no_section", err)
    end)

    it("trocar de música cai na 1ª seção dela, respeitando o quantize", function()
      playing_at(9.0)
      perf.set_quantize("2bar")
      assert.equal("queued", perf.next_song())
      local q = perf.queued()
      assert.same({ "song", "B" }, { q.target.kind, q.target.ref.name })
      assert.near(12.0, q.jump_pos, 1e-9)

      r.set_play(true, 10.2); perf.tick()
      assert.same({ 40, false, true, n = 3 }, last("SetEditCurPos"))

      r.set_play(true, 40.05); perf.tick()
      assert.equal("B", perf.current_song().name)
      assert.same({ 40, 80 }, { r.GetSet_LoopTimeRange2(0, false) })
    end)

    it("próxima seção num trecho sem seção vai para a que vem depois", function()
      playing_at(25.0)
      perf.next_section()
      assert.equal("Outro", perf.queued().target.ref.name)
    end)

    it("modo batida salta pelo script na virada da batida", function()
      playing_at(9.1)
      perf.set_quantize("beat")
      perf.trigger_slot(1)
      r.set_play(true, 9.3); perf.tick()
      assert.equal(0, #r.calls_to("SetEditCurPos"))
      r.set_play(true, 9.52); perf.tick()
      assert.same({ 0, false, true, n = 3 }, last("SetEditCurPos"))
    end)
  end)

  describe("fim da música", function()
    it("quando o motor para no fim, o cursor vai para o início da próxima música", function()
      playing_at(30.0)
      r.set_play(true, 39.9); perf.tick()
      r.set_play(false); r._cursor = 30.0
      perf.tick()
      assert.same({ 40, true, false, n = 3 }, last("SetEditCurPos"))
      assert.equal("B", perf.current_song().name)
    end)

    it("play no início exato de uma música: posição um pouco antes não troca de música", function()
      r.set_play(false); r._cursor = 40; perf.tick()
      assert.equal("B", perf.current_song().name)
      r.calls = {}
      r.set_play(true, 39.98)                       -- o REAPER informa 20 ms antes do cursor
      perf.tick()
      assert.equal("B", perf.current_song().name)
      assert.equal(0, #r.calls_to("GetSet_LoopTimeRange2"))
      r.set_play(true, 40.1)
      perf.tick()
      r.set_play(true, 39.9)                        -- depois de passar do início, vale a posição real
      perf.tick()
      assert.equal("A", perf.current_song().name)
    end)

    it("parar no meio da música não move o cursor", function()
      playing_at(10.0)
      r.set_play(false); perf.tick()
      assert.equal(0, #r.calls_to("SetEditCurPos"))
    end)
  end)

  describe("quantize, cancelar e panic", function()
    it("quantize muda por valor e por ciclo", function()
      assert.is_true(perf.set_quantize("8bar"))
      assert.is_false(perf.set_quantize("3bar"))
      assert.equal("section_end", perf.cycle_quantize(1))
      assert.equal("now", perf.cycle_quantize(1))
      assert.equal("section_end", perf.cycle_quantize(-1))
    end)

    it("cancelar esvazia a fila", function()
      playing_at(3.0)
      perf.set_quantize("8bar")
      perf.trigger_slot(4)
      assert.is_true(perf.cancel())
      assert.is_nil(perf.queued())
      assert.is_false(perf.cancel())
    end)

    it("panic para, solta as notas, limpa a fila e volta ao início da música", function()
      playing_at(50.0)
      perf.set_quantize("8bar")
      perf.trigger_slot(2)
      perf.panic()
      assert.equal(1, #r.calls_to("OnStopButton"))
      assert.equal(40345, last("Main_OnCommand")[1])
      assert.is_nil(perf.queued())
      assert.same({ 40, true, false, n = 3 }, last("SetEditCurPos"))
    end)
  end)
end)
