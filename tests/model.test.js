const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

// Captured verbatim from an LS50 Wireless II (fw p20.4.1.191) in standby.
const STANDBY_POLL = [
  '[{"type":"i32_","i32_":100}]',
  '[{"kefPhysicalSource":"standby","type":"kefPhysicalSource"}]',
  '[{"kefSpeakerStatus":"standby","type":"kefSpeakerStatus"}]',
  '[{"bool_":false,"type":"bool_"}]',
  '[{"state":"stopped","error":"","streamerError":{},"trackRoles":{},"playId":{"timestamp":6656748814,"systemMemberId":"kef_one-4310ba21-e3d6-4669-b25f-d5cea70e3aac"},"keepActive":false,"mediaRoles":{}}]',
  '[{"type":"i64_","i64_":-1}]',
  '[{"type":"string_","string_":"LS50 Wireless II"}]'
].join("\n") + "\n"

// Same shape with the speaker on and streaming (player object per the KEF
// Connect API / SwiftKEF field layout).
const PLAYING_POLL = [
  '[{"type":"i32_","i32_":42}]',
  '[{"kefPhysicalSource":"wifi","type":"kefPhysicalSource"}]',
  '[{"kefSpeakerStatus":"powerOn","type":"kefSpeakerStatus"}]',
  '[{"bool_":false,"type":"bool_"}]',
  '[{"state":"playing","controls":{"previous":true,"pause":true,"next_":true},"trackRoles":{"title":"Take Five","icon":"http://x/cover.jpg","mediaData":{"metaData":{"artist":"Dave Brubeck","album":"Time Out"}}},"status":{"duration":324000}}]',
  '[{"type":"i64_","i64_":123000}]',
  '[{"type":"string_","string_":"LS50 Wireless II"}]'
].join("\n") + "\n"

// Captured verbatim while playing coaxial passthrough: the pseudo-track's
// title is the service id and every transport control is off.
const COAX_POLL = [
  '[{"type":"i32_","i32_":60}]',
  '[{"kefPhysicalSource":"coaxial","type":"kefPhysicalSource"}]',
  '[{"kefSpeakerStatus":"powerOn","type":"kefSpeakerStatus"}]',
  '[{"bool_":false,"type":"bool_"}]',
  '[{"state":"playing","error":"","trackRoles":{"audioType":"audioBroadcast","mediaData":{"metaData":{"serviceID":"COAX","playLogicPath":"kef:/playlogic"}},"type":"audio","title":"COAX","path":"kef:/playlogic/COAX"},"playId":{"timestamp":7026867417,"systemMemberId":"kef_one-4310ba21-e3d6-4669-b25f-d5cea70e3aac"},"controls":{"previous":false,"pause":false,"next_":false},"mediaRoles":{"audioType":"audioBroadcast","mediaData":{"metaData":{"serviceID":"COAX","playLogicPath":"kef:/playlogic"}},"type":"audio","title":"COAX","path":"kef:/playlogic/COAX"}}]',
  '[{"type":"i64_","i64_":-1}]',
  '[{"type":"string_","string_":"LS50 Wireless II"}]'
].join("\n") + "\n"

test("parsePoll: standby snapshot", () => {
  const s = Model.parsePoll(STANDBY_POLL)
  assert.ok(s)
  assert.strictEqual(s.volume, 100)
  assert.strictEqual(s.source, "")  // "standby" is not a selectable input
  assert.strictEqual(s.status, "standby")
  assert.strictEqual(s.muted, false)
  assert.strictEqual(s.playbackState, "stopped")
  assert.strictEqual(s.trackTitle, "")
  assert.strictEqual(s.coverUrl, "")
  assert.strictEqual(s.canPause, false)
  assert.strictEqual(s.positionMs, -1)
  assert.strictEqual(s.durationMs, 0)
  assert.strictEqual(s.deviceName, "LS50 Wireless II")
})

test("parsePoll: playing snapshot", () => {
  const s = Model.parsePoll(PLAYING_POLL)
  assert.ok(s)
  assert.strictEqual(s.volume, 42)
  assert.strictEqual(s.source, "wifi")
  assert.strictEqual(s.status, "powerOn")
  assert.strictEqual(s.playbackState, "playing")
  assert.strictEqual(s.trackTitle, "Take Five")
  assert.strictEqual(s.trackArtist, "Dave Brubeck")
  assert.strictEqual(s.trackAlbum, "Time Out")
  assert.strictEqual(s.coverUrl, "http://x/cover.jpg")
  assert.strictEqual(s.canPrevious, true)
  assert.strictEqual(s.canPause, true)
  assert.strictEqual(s.canNext, true)
  assert.strictEqual(s.positionMs, 123000)
  assert.strictEqual(s.durationMs, 324000)
})

test("parsePoll: coaxial passthrough is not a track and has no transports", () => {
  const s = Model.parsePoll(COAX_POLL)
  assert.ok(s)
  assert.strictEqual(s.source, "coaxial")
  assert.strictEqual(s.playbackState, "playing")
  assert.strictEqual(s.trackTitle, "")   // "COAX" service pseudo-track filtered out
  assert.strictEqual(s.coverUrl, "")
  assert.strictEqual(s.canPrevious, false)
  assert.strictEqual(s.canPause, false)
  assert.strictEqual(s.canNext, false)
  assert.strictEqual(s.positionMs, -1)
  assert.strictEqual(s.durationMs, 0)
})

test("parsePoll: missing controls object falls back to streaming sources", () => {
  const noControls = PLAYING_POLL.replace('"controls":{"previous":true,"pause":true,"next_":true},', "")
  const wifi = Model.parsePoll(noControls)
  assert.strictEqual(wifi.canPause, true)

  const tv = Model.parsePoll(noControls.replace('"kefPhysicalSource":"wifi"', '"kefPhysicalSource":"tv"'))
  assert.strictEqual(tv.canPause, false)
})

test("formatTime", () => {
  assert.strictEqual(Model.formatTime(0), "0:00")
  assert.strictEqual(Model.formatTime(59000), "0:59")
  assert.strictEqual(Model.formatTime(123000), "2:03")
  assert.strictEqual(Model.formatTime(3723000), "1:02:03")
  assert.strictEqual(Model.formatTime(-1), "")
  assert.strictEqual(Model.formatTime("junk"), "")
})

test("parsePoll: rejects incomplete and malformed responses", () => {
  assert.strictEqual(Model.parsePoll(""), null)
  assert.strictEqual(Model.parsePoll(null), null)
  assert.strictEqual(Model.parsePoll("[{}]\n[{}]"), null)
  const truncated = STANDBY_POLL.split("\n").slice(0, 4).join("\n")
  assert.strictEqual(Model.parsePoll(truncated), null)
  const garbage = STANDBY_POLL.replace('[{"type":"i32_","i32_":100}]', "<html>error</html>")
  assert.strictEqual(Model.parsePoll(garbage), null)
})

test("pollCommand fetches every path in parse order", () => {
  const cmd = Model.pollCommand("10.0.0.5")
  assert.strictEqual(cmd[0], "curl")
  const urls = cmd.filter(a => a.indexOf("http://") === 0)
  assert.strictEqual(urls.length, Model.POLL_PATHS.length)
  Model.POLL_PATHS.forEach((path, i) => {
    assert.strictEqual(urls[i], Model.getDataUrl("10.0.0.5", path))
    assert.ok(urls[i].indexOf(encodeURIComponent(path)) !== -1)
  })
})

test("setCommand builds a JSON POST to setData", () => {
  const cmd = Model.setCommand("10.0.0.5", "player:volume", "value", Model.volumePayload(30))
  assert.strictEqual(cmd[cmd.length - 1], "http://10.0.0.5/api/setData")
  assert.ok(cmd.includes("POST"))
  const body = JSON.parse(cmd[cmd.indexOf("-d") + 1])
  assert.deepStrictEqual(body, {
    path: "player:volume",
    roles: "value",
    value: { type: "i32_", i32_: 30 }
  })
})

test("payloads match the KEF wire format", () => {
  assert.deepStrictEqual(Model.volumePayload(50), { type: "i32_", i32_: 50 })
  assert.deepStrictEqual(Model.volumePayload(150), { type: "i32_", i32_: 100 })
  assert.deepStrictEqual(Model.volumePayload(-5), { type: "i32_", i32_: 0 })
  assert.deepStrictEqual(
    Model.sourcePayload("bluetooth"),
    { type: "kefPhysicalSource", kefPhysicalSource: "bluetooth" }
  )
  assert.deepStrictEqual(
    Model.sourcePayload("standby"),
    { type: "kefPhysicalSource", kefPhysicalSource: "standby" }
  )
  assert.deepStrictEqual(Model.controlPayload("pause"), { control: "pause" })
})

test("clampVolume", () => {
  assert.strictEqual(Model.clampVolume(50.4), 50)
  assert.strictEqual(Model.clampVolume("70"), 70)
  assert.strictEqual(Model.clampVolume("junk"), 0)
  assert.strictEqual(Model.clampVolume(101), 100)
})

test("source labels and playback support", () => {
  assert.strictEqual(Model.sourceLabel("wifi"), "Wi-Fi")
  assert.strictEqual(Model.sourceLabel("optic"), "Optical")
  assert.strictEqual(Model.sourceLabel("mystery"), "Mystery")
  assert.ok(Model.supportsPlayback("wifi"))
  assert.ok(Model.supportsPlayback("bluetooth"))
  assert.ok(!Model.supportsPlayback("tv"))
  assert.ok(!Model.supportsPlayback(""))
})

test("bar icon and status line", () => {
  assert.strictEqual(Model.speakerIcon(false, false, false, false), "󰓄")
  assert.strictEqual(Model.speakerIcon(true, false, false, false), "󰓄")
  assert.strictEqual(Model.speakerIcon(true, true, false, false), "󰓄")
  assert.strictEqual(Model.speakerIcon(true, true, true, false), "󰓃")
  assert.strictEqual(Model.speakerIcon(true, true, true, true), "󰝟")

  assert.strictEqual(Model.statusLine(false, false, false, "", ""), "Not configured")
  assert.strictEqual(Model.statusLine(true, false, false, "", ""), "Unreachable")
  assert.strictEqual(Model.statusLine(true, true, false, "", ""), "Standby")
  assert.strictEqual(Model.statusLine(true, true, true, "tv", ""), "TV")
  assert.strictEqual(Model.statusLine(true, true, true, "wifi", "playing"), "Wi-Fi · Playing")
  assert.strictEqual(Model.statusLine(true, true, true, "bluetooth", "paused"), "Bluetooth · Paused")
  assert.strictEqual(Model.statusLine(true, true, true, "", ""), "On")
})

test("tooltip", () => {
  assert.strictEqual(Model.tooltip("LS50 Wireless II", "Standby"), "LS50 Wireless II — Standby")
  assert.strictEqual(Model.tooltip("", ""), "KEF Speaker")
})
