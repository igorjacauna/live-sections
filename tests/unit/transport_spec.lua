local stub = require("stubs.reaper")

describe("transport", function()
  local r, transport

  before_each(function()
    r = stub.install()
    package.loaded["core.transport"] = nil
    transport = require("core.transport")
  end)

  local function cmds()
    local out = {}
    for _, c in ipairs(r.calls_to("Main_OnCommand")) do out[#out + 1] = c[1] end
    return out
  end

  describe("ensure_setup", function()
    it("liga smooth seek e parada no fim do loop quando estão desligados", function()
      r.set_toggle(40390, 0); r.set_toggle(41834, 0); r.set_config("smoothseekmeas", 1)

      local warnings = transport.ensure_setup()

      assert.same({ 40390, 41834 }, cmds())
      assert.same({}, warnings)
      assert.equal(1, #r.calls_to("atexit"))
    end)

    it("não mexe no que já está ligado", function()
      r.set_toggle(40390, 1); r.set_toggle(41834, 1); r.set_config("smoothseekmeas", 1)
      transport.ensure_setup()
      assert.same({}, cmds())
    end)

    it("avisa quando o smooth seek não está em 1 compasso", function()
      r.set_toggle(40390, 1); r.set_toggle(41834, 1); r.set_config("smoothseekmeas", 2)
      local warnings = transport.ensure_setup()
      assert.equal(1, #warnings)
      assert.equal("smoothseekmeas", warnings[1].id)
      assert.matches("2 compassos", warnings[1].text)
      assert.same(warnings, transport.warnings())
    end)

    it("a restauração na saída desfaz só o que foi alterado, incluindo o repeat", function()
      r.set_toggle(40390, 0); r.set_toggle(41834, 1); r.set_config("smoothseekmeas", 1)
      r.GetSetRepeat(1)
      transport.ensure_setup()
      transport.arm_song_end({ start_pos = 0, end_pos = 40 })

      r.calls_to("atexit")[1][1]()

      assert.same({ 40390, 40390 }, cmds())
      assert.equal(1, r.GetToggleCommandState(41834))
      assert.equal(1, r.GetSetRepeat(-1))
    end)

    it("registra o atexit uma vez só", function()
      r.set_config("smoothseekmeas", 1)
      transport.ensure_setup(); transport.ensure_setup()
      assert.equal(1, #r.calls_to("atexit"))
    end)
  end)

  describe("hand_off e cancel_hand_off", function()
    it("modos de compasso usam o smooth seek", function()
      transport.hand_off(16, "4bar", 3)
      assert.same({ 16, false, true, n = 3 }, r.calls_to("SetEditCurPos")[1])
      assert.equal(0, #r.calls_to("GoToRegion"))
    end)

    it("fim da seção usa GoToRegion com a ordem da região na timeline", function()
      r.add_marker(0, "SONG: A")                 -- idx 1
      local verso = r.add_region(8, 16, "Verso") -- idx 2, 2ª na timeline
      r.add_region(0, 8, "Intro")                -- idx 3, 1ª na timeline

      transport.hand_off(8, "section_end", verso)

      assert.same({ 0, 2, true, n = 3 }, r.calls_to("GoToRegion")[1])
      assert.equal(0, #r.calls_to("SetEditCurPos"))
    end)

    it("fim da seção sem região conhecida cai no smooth seek", function()
      transport.hand_off(40, "section_end", nil)
      assert.equal(40, r.calls_to("SetEditCurPos")[1][1])
    end)

    it("cancelar depois da entrega faz seek para a própria virada", function()
      transport.cancel_hand_off(22)
      assert.same({ 22, false, true, n = 3 }, r.calls_to("SetEditCurPos")[1])
    end)
  end)

  describe("loop e fim da música", function()
    local song = { start_pos = 0, end_pos = 56 }
    local refrao = { start_pos = 16, end_pos = 24 }

    it("set_loop liga: loop points na seção e repeat ligado", function()
      transport.set_loop(refrao, true, song)
      assert.same({ 16, 24 }, { r.GetSet_LoopTimeRange2(0, false) })
      assert.equal(1, r.GetSetRepeat(-1))
    end)

    it("set_loop desliga: repeat desligado e loop points de volta na música", function()
      transport.set_loop(refrao, true, song)
      transport.set_loop(refrao, false, song)
      assert.same({ 0, 56 }, { r.GetSet_LoopTimeRange2(0, false) })
      assert.equal(0, r.GetSetRepeat(-1))
    end)

    it("arm_song_end coloca loop points na música com repeat desligado", function()
      r.GetSetRepeat(1)
      transport.arm_song_end({ start_pos = 56, end_pos = 120 })
      assert.same({ 56, 120 }, { r.GetSet_LoopTimeRange2(0, false) })
      assert.equal(0, r.GetSetRepeat(-1))
    end)
  end)
end)
