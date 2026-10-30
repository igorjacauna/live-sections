local stub = require("stubs.reaper")

describe("tempo_align", function()
  local r, ta

  -- Música A (0–100 s) gravada sem grid; música B começa em 100 s a 128 BPM.
  local song_a = { start_pos = 0, end_pos = 100 }
  local song_b = { start_pos = 100, end_pos = 200 }

  local function markers()
    local out = {}
    for _, m in ipairs(r._tempo_markers) do out[#out + 1] = { m.time, m.bpm, m.num, m.denom } end
    return out
  end

  before_each(function()
    r = stub.install()
    package.loaded["core.tempo_align"] = nil
    ta = require("core.tempo_align")
  end)

  describe("tap", function()
    it("precisa de 4 toques e usa a média dos intervalos", function()
      assert.is_nil(ta.tap(10.0))
      assert.is_nil(ta.tap(10.62))
      assert.is_nil(ta.tap(11.27))
      assert.equal(95.24, ta.tap(11.89))          -- 3 intervalos, média 0,63 s
    end)

    it("arredonda para inteiro ou meio BPM", function()
      for _, t in ipairs({ 0, 0.63, 1.26 }) do ta.tap(t) end
      assert.equal(95, ta.tap(1.89, "int"))
      ta.reset_taps()
      for _, t in ipairs({ 0, 0.47, 0.94 }) do ta.tap(t) end
      assert.equal(127.5, ta.tap(1.41, "half"))   -- 127,66 → 127,5
    end)

    it("uma pausa longa recomeça a contagem", function()
      for _, t in ipairs({ 0, 0.5, 1.0, 1.5 }) do ta.tap(t) end
      assert.is_nil(ta.tap(5.0))
      assert.equal(1, ta.tap_count())
    end)
  end)

  describe("set_downbeat", function()
    it("cria o marcador no compasso 1 e preserva o tempo da música seguinte", function()
      r.set_tempo_map({ { measure = 0, bpm = 128, num = 4, denom = 4 } })
      local ok, bpm = ta.set_downbeat(song_a, song_b, 1.284, 95.3, "int")
      assert.same({ true, 95 }, { ok, bpm })
      assert.same({ { 1.284, 95, 4, 4 }, { 100, 128, 4, 4 } }, markers())
      assert.equal(1, #r.calls_to("Undo_BeginBlock"))
    end)

    it("substitui marcadores antigos dentro da música, sem tocar nos das outras", function()
      r.SetTempoTimeSigMarker(0, -1, 0.9, -1, -1, 90, 4, 4, false)
      r.SetTempoTimeSigMarker(0, -1, 40, -1, -1, 92, 4, 4, false)
      r.SetTempoTimeSigMarker(0, -1, 100, -1, -1, 128, 4, 4, false)
      r.SetTempoTimeSigMarker(0, -1, 150, -1, -1, 140, 7, 8, false)

      ta.set_downbeat(song_a, song_b, 1.2, 96)

      assert.same({ { 1.2, 96, 4, 4 }, { 100, 128, 4, 4 }, { 150, 140, 7, 8 } }, markers())
    end)

    it("a última música não cria marcador depois dela", function()
      ta.set_downbeat(song_b, nil, 100.5, 128)
      assert.same({ { 100.5, 128, 4, 4 } }, markers())
    end)

    it("posição fora da música ou BPM inválido não muda nada", function()
      assert.same({ false, "outside_song" }, { ta.set_downbeat(song_a, song_b, 120, 96) })
      assert.same({ false, "no_bpm" }, { ta.set_downbeat(song_a, song_b, 1, nil) })
      assert.same({}, markers())
    end)
  end)

  describe("nudge", function()
    before_each(function()
      r.set_tempo_map({ { measure = 0, bpm = 128, num = 4, denom = 4 } })
      ta.set_downbeat(song_a, song_b, 1.284, 95)
    end)

    it("ajusta BPM em ±0,01 e o compasso 1 em ±1 ms", function()
      local ok, bpm, time = ta.nudge(song_a, song_b, 0.01, -1)
      assert.same({ true, 95.01 }, { ok, bpm })
      assert.near(1.283, time, 1e-9)
      ta.nudge(song_a, song_b, -0.02, 0)
      assert.equal(94.99, markers()[1][2])
    end)

    it("não afeta a música seguinte", function()
      ta.nudge(song_a, song_b, 0.5, 3)
      assert.same({ 100, 128, 4, 4 }, markers()[2])
    end)

    it("sem compasso 1 marcado retorna erro", function()
      local song_c = { start_pos = 200, end_pos = 300 }
      assert.same({ false, "no_downbeat" }, { ta.nudge(song_c, nil, 0.01, 0) })
    end)
  end)
end)
