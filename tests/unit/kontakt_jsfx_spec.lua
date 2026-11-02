local stub = require("stubs.reaper")

describe("kontakt_jsfx", function()
  local r, jsfx

  before_each(function()
    r = stub.install()
    package.loaded["core.kontakt_jsfx"] = nil
    jsfx = require("core.kontakt_jsfx")
  end)

  local function kontakt(name)
    local t = r.add_track(name or "Kontakt")
    t.fx = { "VST3i: Kontakt 8 (Native Instruments) (64 out)" }
    return t
  end

  describe("texto", function()
    it("tem um slider oculto por CC, mais reenviar e enviados", function()
      local text = jsfx.text()
      assert.matches("slider1:%-1<%-1,127,1>%-CC 0\n", text)
      assert.matches("slider128:%-1<%-1,127,1>%-CC 127\n", text)
      assert.matches("slider129:0<0,1000000,1>%-Reenviar", text)
      assert.matches("slider130:0<0,1000000,1>%-Enviados", text)
      assert.matches("midisend%(0, 0xB0, i, v%)", text)
    end)

    it("não lê o MIDI que chega: o teclado passa direto", function()
      assert.is_nil(jsfx.text():find("midirecv", 1, true))
    end)
  end)

  describe("arquivo", function()
    it("grava em Effects/LiveSections da pasta do REAPER", function()
      r._resource_path = os.tmpname() .. "_dir"
      local ok, err, path = jsfx.write_file()
      assert.is_true(ok, err)
      assert.equal(r._resource_path .. "/Effects/LiveSections/ls_kontakt_cc.jsfx", path)
      local f = assert(io.open(path, "r"))
      assert.equal(jsfx.text(), f:read("a"))
      f:close()
    end)

    it("devolve o erro e o caminho quando não consegue gravar", function()
      local file = os.tmpname()   -- um arquivo no lugar da pasta
      r._resource_path = file
      local ok, err, path = jsfx.write_file()
      assert.is_false(ok)
      assert.is_string(err)
      assert.equal(file .. "/Effects/LiveSections/ls_kontakt_cc.jsfx", path)
      os.remove(file)
    end)
  end)

  describe("instalação", function()
    it("instala no início da cadeia, antes do Kontakt", function()
      local t = kontakt()
      assert.equal(0, jsfx.install(t))
      assert.equal(2, #t.fx)
      assert.equal(0, jsfx.find(t))
      assert.matches("Kontakt 8", t.fx[2])
    end)

    it("instalar de novo não duplica", function()
      local t = kontakt()
      jsfx.install(t)
      assert.equal(0, jsfx.install(t))
      assert.equal(2, #t.fx)
    end)

    it("move para o início um JSFX que estava depois do Kontakt", function()
      local t = kontakt()
      reaper.TrackFX_AddByName(t, jsfx.FX_NAME, false, -1)
      assert.equal(1, jsfx.find(t))
      assert.equal(0, jsfx.install(t))
      assert.equal(0, jsfx.find(t))
      assert.matches("Kontakt 8", t.fx[2])
    end)

    it("tira cópias a mais", function()
      local t = kontakt()
      reaper.TrackFX_AddByName(t, jsfx.FX_NAME, false, -1)
      reaper.TrackFX_AddByName(t, jsfx.FX_NAME, false, -1)
      jsfx.install(t)
      assert.equal(2, #t.fx)
      assert.equal(0, jsfx.find(t))
    end)

    it("reconhece pelo nome quando o REAPER não informa o arquivo", function()
      local t = r.add_track("Kontakt")
      t.fx = { "JS: Live Sections - Mapeamento para o Kontakt", "VST3i: Kontakt 8" }
      assert.equal(0, jsfx.find(t))
    end)

    it("devolve erro quando o REAPER não acha o JSFX", function()
      r._js_missing = true
      local idx, err = jsfx.install(kontakt())
      assert.equal(-1, idx)
      assert.equal("add_failed", err)
    end)
  end)

  describe("cobertura", function()
    it("conta músicas com Kontakt com e sem o JSFX, e um JSFX apagado à mão", function()
      local a, b = kontakt("A"), kontakt("B")
      local songs = { { name = "A" }, { name = "B" }, { name = "Sem Kontakt" } }
      local tracks = { A = a, B = b }
      local function track_of(song) return tracks[song.name] end
      jsfx.install(a)
      jsfx.install(b)
      local cov = jsfx.coverage(songs, track_of)
      assert.same({ 2, 2, 0 }, { cov.total, cov.installed, #cov.missing })

      reaper.TrackFX_Delete(b, 0)
      cov = jsfx.coverage(songs, track_of)
      assert.equal(1, cov.installed)
      assert.equal("B", cov.missing[1].name)
    end)
  end)

  describe("valores", function()
    it("muda o slider do CC e conta o pedido de reenvio", function()
      local t = kontakt()
      jsfx.install(t)
      assert.is_true(jsfx.set_cc(t, 63, 100))
      assert.equal(100, jsfx.value(t, 63))
      assert.is_true(jsfx.resend(t))
      assert.is_true(jsfx.resend(t))
      assert.equal(2, reaper.TrackFX_GetParam(t, 0, 128))
    end)

    it("lê o contador de enviados", function()
      local t = kontakt()
      jsfx.install(t)
      reaper.TrackFX_SetParam(t, 0, 129, 7)
      assert.equal(7, jsfx.sent_count(t))
    end)

    it("sem o JSFX não faz nada", function()
      local t = kontakt()
      assert.is_false(jsfx.set_cc(t, 63, 100))
      assert.is_false(jsfx.resend(t))
      assert.is_nil(jsfx.sent_count(t))
      assert.is_nil(jsfx.value(t, 63))
      assert.equal(1, #t.fx)
    end)
  end)
end)
