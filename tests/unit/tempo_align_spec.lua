local stub = require("stubs.reaper")

-- O stub calcula compassos pelo mapa de _tempo, sem considerar os marcadores
-- criados: estes testes conferem os marcadores gerados e as contas da entrada.
describe("tempo_align", function()
  local r, ta

  -- Música A (0–100 s) gravada sem grid; música B começa em 100 s.
  local song_a = { start_pos = 0, end_pos = 100 }
  local song_b = { start_pos = 100, end_pos = 200 }

  local function markers()
    local out = {}
    for _, m in ipairs(r._tempo_markers) do out[#out + 1] = { m.time, m.bpm, m.num, m.denom } end
    return out
  end

  local function assert_markers(expected)
    local got = markers()
    assert.equal(#expected, #got)
    for i, e in ipairs(expected) do
      assert.near(e[1], got[i][1], 1e-9, "tempo do marcador " .. i)
      assert.near(e[2], got[i][2], 1e-6, "BPM do marcador " .. i)
      assert.same({ e[3], e[4] }, { got[i][3], got[i][4] })
    end
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
    it("prepara a entrada, marca o compasso 1 e guarda o tempo da música seguinte", function()
      r.set_tempo_map({ { measure = 0, bpm = 128, num = 4, denom = 4 } })
      local ok, bpm = ta.set_downbeat(song_a, song_b, 1.284, 95.3, "int")
      assert.same({ true, 95 }, { ok, bpm })
      -- entrada: 1 compasso de 4 batidas (1,875 s a 128) espremido em 1,284 s
      assert_markers({ { 0, 128 * 1.875 / 1.284, 0, 0 }, { 1.284, 95, 4, 4 }, { 100, 128, 0, 0 } })
      assert.equal(1, #r.calls_to("Undo_BeginBlock"))
    end)

    it("troca os marcadores da música e refaz a entrada da seguinte já alinhada", function()
      r.SetTempoTimeSigMarker(0, -1, 0.9, -1, -1, 90, 4, 4, false)
      r.SetTempoTimeSigMarker(0, -1, 40, -1, -1, 92, 0, 0, false)
      r.SetTempoTimeSigMarker(0, -1, 100, -1, -1, 130, 0, 0, false)   -- entrada antiga de B
      r.SetTempoTimeSigMarker(0, -1, 150, -1, -1, 140, 7, 8, false)   -- compasso 1 de B

      ta.set_downbeat(song_a, song_b, 1.2, 96)

      -- entrada de A: 1 compasso (2 s a 120) em 1,2 s; entrada de B: 36 compassos em 50 s a partir de 96
      assert_markers({
        { 0, 200, 0, 0 }, { 1.2, 96, 4, 4 }, { 100, 96 * 72 / 50, 0, 0 }, { 150, 140, 7, 8 },
      })
    end)

    it("a última música não cria marcador depois dela", function()
      ta.set_downbeat(song_b, nil, 101.5, 128)
      assert.equal(2, #markers())
      assert.same({ 101.5, 128, 4, 4 }, markers()[2])
    end)

    it("posição fora da música ou BPM inválido não muda nada", function()
      assert.same({ false, "outside_song" }, { ta.set_downbeat(song_a, song_b, 120, 96) })
      assert.same({ false, "no_bpm" }, { ta.set_downbeat(song_a, song_b, 1, nil) })
      assert.same({}, markers())
    end)

    it("recusa projeto em timebase de batidas", function()
      r.set_config("itemtimelock", 1)
      assert.same({ false, "timebase_beats", "itemtimelock" }, { ta.set_downbeat(song_a, song_b, 1, 96) })
      r.set_config("itemtimelock", 0)
      r.set_config("tempoenvtimelock", 1)
      assert.same({ false, "timebase_beats", "tempoenvtimelock" }, { ta.set_downbeat(song_a, song_b, 1, 96) })
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
      assert.near(1.283, markers()[2][1], 1e-9)
      assert.same({ 95.01, 4, 4 }, { markers()[2][2], markers()[2][3], markers()[2][4] })
      ta.nudge(song_a, song_b, -0.02, 0)
      assert.equal(94.99, markers()[2][2])
    end)

    it("usa o compasso 1, não a entrada nem outros marcadores", function()
      assert.equal(3, #markers())
      ta.nudge(song_a, song_b, 0, 2)
      assert.equal(3, #markers())
      assert.near(1.286, markers()[2][1], 1e-9)
    end)

    it("não afeta a música seguinte", function()
      ta.nudge(song_a, song_b, 0.5, 3)
      assert.same({ 100, 128, 0, 0 }, markers()[3])
    end)

    it("sem compasso 1 marcado retorna erro", function()
      local song_c = { start_pos = 200, end_pos = 300 }
      assert.same({ false, "no_downbeat" }, { ta.nudge(song_c, nil, 0.01, 0) })
    end)
  end)
end)
