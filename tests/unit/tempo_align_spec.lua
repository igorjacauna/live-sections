local stub = require("stubs.reaper")

-- O tempo do projeto vem do primeiro segmento do mapa de _tempo do stub. As
-- contas da entrada usam só a lista de marcadores de tempo.
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

  -- Semínimas de `a` a `b` pelos marcadores criados (tempo constante entre eles).
  local function qn_between(a, b)
    local total, bpm, t = 0, nil, a
    for _, m in ipairs(r._tempo_markers) do
      if m.time > a and m.time < b then total = total + (m.time - t) * bpm / 60; t = m.time end
      if m.time < b then bpm = m.bpm end
    end
    return total + (b - t) * bpm / 60
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

      -- entrada de A: 1 compasso (4 semínimas) em 1,2 s. De 1,2 s a 100 s a 96
      -- BPM são 158,08 semínimas: 100 s cai 2,08 dentro do compasso. A entrada
      -- de B completa o compasso (1,92) e mais 29 compassos em 50 s.
      assert_markers({
        { 0, 200, 0, 0 }, { 1.2, 96, 4, 4 }, { 100, 60 * (1.92 + 29 * 4) / 50, 0, 0 }, { 150, 140, 7, 8 },
      })
      assert.near(0, qn_between(1.2, 150) % 4, 1e-6)
    end)

    it("alinhar a música anterior mantém o compasso 1 da seguinte (spike 06)", function()
      local song_a6 = { start_pos = 0, end_pos = 60 }
      local song_b6 = { start_pos = 60, end_pos = 120 }
      ta.set_downbeat(song_b6, nil, 61.5, 120)
      assert.near(160, markers()[1][2], 1e-9)

      ta.set_downbeat(song_a6, song_b6, 3.1, 97.3)

      assert.near(240 / 3.1, markers()[1][2], 1e-9)
      -- de 3,1 s a 60 s a 97,3 BPM: 60 s cai no meio do compasso; a entrada de B
      -- completa esse compasso em 1,5 s (≈149 BPM, não os 160 de antes)
      assert.near(60 * (4 - (56.9 * 97.3 / 60) % 4) / 1.5, markers()[3][2], 1e-9)
      assert.near(0, qn_between(3.1, 61.5) % 4, 1e-6)
      ta.nudge(song_a6, song_b6, 0.01, 1)
      assert.near(0, qn_between(3.101, 61.5) % 4, 1e-6)
      assert.same({ 61.5, 120, 4, 4 }, markers()[4])
    end)

    it("marcador só de tempo com fórmula -1 (como o REAPER devolve) também é refeito", function()
      ta.set_downbeat({ start_pos = 60, end_pos = 120 }, nil, 61.5, 120)
      for _, m in ipairs(r._tempo_markers) do
        if m.num == 0 then m.num, m.denom = -1, -1 end
      end
      ta.set_downbeat({ start_pos = 0, end_pos = 60 }, { start_pos = 60, end_pos = 120 }, 3.1, 97.3)
      assert.near(60 * (4 - (56.9 * 97.3 / 60) % 4) / 1.5, markers()[3][2], 1e-9)
      assert.same({ 0, 0 }, { markers()[3][3], markers()[3][4] })
    end)

    it("não lê o TimeMap: o REAPER devolve o mapa antigo durante a operação", function()
      r.SetTempoTimeSigMarker(0, -1, 100, -1, -1, 130, 0, 0, false)
      r.SetTempoTimeSigMarker(0, -1, 150, -1, -1, 140, 7, 8, false)
      r.calls = {}
      ta.set_downbeat(song_a, song_b, 1.2, 96)
      for _, c in ipairs(r.calls) do assert.is_nil(c.name:match("^TimeMap"), c.name) end
      assert.equal(1, #r.calls_to("UpdateTimeline"))
    end)

    it("conta a rampa de um marcador linear pelo tempo médio", function()
      r.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 100, 4, 4, true)
      r.SetTempoTimeSigMarker(0, -1, 6, -1, -1, 140, 0, 0, false)    -- 0–6 s: 12 semínimas
      local song_c = { start_pos = 7.5, end_pos = 100 }               -- +3,5 semínimas: 15,5
      ta.set_downbeat(song_c, nil, 8, 140)
      -- 15,5 % 4 = 3,5: faltam 0,5 semínima até a linha de compasso, em 0,5 s
      assert.near(60, markers()[3][2], 1e-9)
    end)

    it("todos os itens ficam em timebase de tempo durante a operação e voltam ao modo original", function()
      local beats = r.add_item(70, 5, 1)
      local pos_only = r.add_item(80, 5, 2)
      local default = r.add_item(90, 5, -1)
      local seen
      local set = r.SetTempoTimeSigMarker
      r.SetTempoTimeSigMarker = function(...)
        seen = seen or { beats.info.C_BEATATTACHMODE, pos_only.info.C_BEATATTACHMODE, default.info.C_BEATATTACHMODE }
        return set(...)
      end

      ta.set_downbeat(song_a, song_b, 1.2, 96)

      assert.same({ 0, 0, 0 }, seen)
      assert.same({ 1, 2, -1 }, { beats.info.C_BEATATTACHMODE, pos_only.info.C_BEATATTACHMODE, default.info.C_BEATATTACHMODE })
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

    it("funciona no timebase padrão do REAPER (batidas)", function()
      r.set_config("itemtimelock", 1)
      r.set_config("tempoenvtimelock", 1)
      assert.same({ true, 96 }, { ta.set_downbeat(song_a, song_b, 1.2, 96) })
    end)

    it("devolve marcadores e regiões à posição em segundos que tinham antes", function()
      local song_mk = r.add_marker(100, "SONG: B")
      local verso = r.add_region(20, 30, "Verso A", 0x1000004)
      -- simula o REAPER arrastando tudo quando o tempo muda
      local add = r.SetTempoTimeSigMarker
      r.SetTempoTimeSigMarker = function(...)
        for _, m in ipairs(r._markers) do m.pos = m.pos + 13; if m.isrgn then m.rgnend = m.rgnend + 13 end end
        return add(...)
      end

      ta.set_downbeat(song_a, song_b, 1.2, 96)

      assert.same({ { 20, 30, "Verso A" } }, r.regions())
      for _, m in ipairs(r._markers) do
        if m.idx == song_mk then assert.equal(100, m.pos) end
        if m.idx == verso then assert.equal(0x1000004, m.color) end
      end
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
