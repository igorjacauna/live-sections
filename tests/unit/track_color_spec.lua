local stub = require("stubs.reaper")

describe("track_color", function()
  local r, tc, tr

  before_each(function()
    r = stub.install()
    package.loaded["core.track_color"] = nil
    tc = require("core.track_color")
    tr = r.add_track("Bateria")
  end)

  it("sem o bit de cor própria não tem cor", function()
    assert.is_nil(tc.get(tr))
    tr.info.I_CUSTOMCOLOR = 0x3366CC                  -- cor do tema, sem o bit
    assert.is_nil(tc.get(tr))
  end)

  it("com o bit devolve a cor nativa", function()
    tr.info.I_CUSTOMCOLOR = 0x1000000 | 0x3366CC
    assert.equal(0x3366CC, tc.get(tr))
  end)

  it("grava uma cor da paleta e volta a sem cor, num passo de undo só da track", function()
    tc.set(tr, "#E5566B")
    assert.equal(0x1000000 | 0x6B56E5, tr.info.I_CUSTOMCOLOR)   -- nativa: BGR no stub
    assert.equal(0x6B56E5, tc.get(tr))
    tc.set(tr, nil)
    assert.equal(0, tr.info.I_CUSTOMCOLOR)
    assert.is_nil(tc.get(tr))
    local ends = r.calls_to("Undo_EndBlock")
    assert.same({ "Live Sections: cor da track", 1 }, { ends[1][1], ends[1][2] })
    assert.equal(2, #ends)
  end)
end)
