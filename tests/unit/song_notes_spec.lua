local stub = require("stubs.reaper")

describe("core.song_notes", function()
  local r, model, notes

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.chart", "core.song_notes" }) do package.loaded[m] = nil end
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_marker(40, "SONG: B")
    model, notes = require("core.project_model"), require("core.song_notes")
    model.refresh(0)
  end)

  it("cada música guarda a sua anotação no projeto, sem espaços nas pontas", function()
    local a, b = model.songs()[1], model.songs()[2]
    assert.equal("", notes.get(a))
    assert.is_true(notes.set(a, "  Tom: G\nIntro: piano sozinho  "))
    assert.equal("Tom: G\nIntro: piano sozinho", notes.get(a))
    assert.equal("", notes.get(b))
    local saved = false
    for k in pairs(r._ext.LiveSections) do if k:match("^note:") then saved = true end end
    assert.is_true(saved)
  end)

  it("corta no limite sem quebrar acento", function()
    local a = model.songs()[1]
    notes.set(a, string.rep("a", notes.MAX_CHARS - 1) .. "ção")
    local got = notes.get(a)
    assert.is_true(#got <= notes.MAX_CHARS)
    assert.is_nil(got:find("[\xC0-\xFF]$"))
  end)

  it("lines: uma por linha, ignorando as vazias", function()
    assert.same({ "Tom: G", "Intro: piano" }, notes.lines("Tom: G\n\n  Intro: piano \r\n"))
    assert.same({}, notes.lines(nil))
  end)
end)
