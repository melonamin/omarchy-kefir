// KEF Connect HTTP API (port 80). Reads are GET /api/getData?path=<path>&roles=value
// returning a one-element JSON array whose item carries the value under a
// type-keyed field ("i32_", "string_", "bool_", "kefPhysicalSource",
// "kefSpeakerStatus", or a raw player object). Writes mirror it via
// /api/setData with a JSON-encoded "value" query param. Same protocol as
// SwiftKEF/Kefir (https://github.com/melonamin/SwiftKEF).

// Paths fetched by one poll, in the order parsePoll() expects the response
// lines back.
var POLL_PATHS = [
  "player:volume",
  "settings:/kef/play/physicalSource",
  "settings:/kef/host/speakerStatus",
  "settings:/mediaPlayer/mute",
  "player:player/data",
  "player:player/data/playTime",
  "settings:/deviceName"
]

// Physical sources accepted by settings:/kef/play/physicalSource. Which ones
// are wired up depends on the model (LS50 WII has no USB, LSX II has no
// coaxial); selecting an absent one is harmless, the speaker ignores it.
var SOURCES = [
  { key: "wifi", label: "Wi-Fi" },
  { key: "bluetooth", label: "Bluetooth" },
  { key: "tv", label: "TV" },
  { key: "optic", label: "Optical" },
  { key: "coaxial", label: "Coaxial" },
  { key: "analog", label: "Analog" },
  { key: "usb", label: "USB" }
]

function sourceLabel(key) {
  for (var i = 0; i < SOURCES.length; i++)
    if (SOURCES[i].key === key) return SOURCES[i].label
  return key ? key.charAt(0).toUpperCase() + key.slice(1) : ""
}

// Track transport only means something on the streaming sources; the rest are
// passthrough inputs.
function supportsPlayback(source) {
  return source === "wifi" || source === "bluetooth"
}

function clampVolume(v) {
  var n = Math.round(parseFloat(String(v)))
  if (isNaN(n)) return 0
  return Math.max(0, Math.min(100, n))
}

function getDataUrl(host, path) {
  return "http://" + host + "/api/getData?path=" + encodeURIComponent(path) + "&roles=value"
}

// One curl fetches every POLL_PATHS entry; -w "\n" terminates each response so
// the collector output is one JSON array per line, in POLL_PATHS order.
function pollCommand(host) {
  var cmd = ["curl", "-fsS", "--max-time", "3", "-w", "\n"]
  for (var i = 0; i < POLL_PATHS.length; i++) cmd.push(getDataUrl(host, POLL_PATHS[i]))
  return cmd
}

// Writes go as POST with a JSON body; current firmware (p20.x) answers GET
// setData with 405 even though older clients used query params.
function setCommand(host, path, roles, payload) {
  return [
    "curl", "-fsS", "--max-time", "3",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", JSON.stringify({ path: path, roles: roles, value: payload }),
    "http://" + host + "/api/setData"
  ]
}

function volumePayload(volume) {
  return { type: "i32_", i32_: clampVolume(volume) }
}

// Also carries the power pseudo-sources "powerOn" and "standby".
function sourcePayload(source) {
  return { type: "kefPhysicalSource", kefPhysicalSource: String(source) }
}

// command: "pause" (toggles play/pause), "next", "previous".
function controlPayload(command) {
  return { control: String(command) }
}

// Batched poll response -> state object, or null when the response is
// malformed or incomplete (treated as unreachable; the caller keeps its
// previous state visible).
function parsePoll(raw) {
  var lines = String(raw || "").trim().split("\n")
  if (lines.length !== POLL_PATHS.length) return null

  var items = []
  for (var i = 0; i < lines.length; i++) {
    try {
      var parsed = JSON.parse(lines[i])
      items.push(parsed && parsed.length ? parsed[0] : {})
    } catch (e) {
      return null
    }
  }

  var player = items[4] || {}
  var trackRoles = player.trackRoles || {}
  var mediaData = trackRoles.mediaData || {}
  var metaData = mediaData.metaData || {}
  var source = String(items[1].kefPhysicalSource || "")
  var title = String(trackRoles.title || "")

  // Passthrough inputs report a pseudo-track whose title is the service id
  // ("COAX", "OPT", ...) with audioType "audioBroadcast"; that is not a track.
  var serviceId = String(metaData.serviceID || "")
  var isRealTrack = title !== "" &&
    !(trackRoles.audioType === "audioBroadcast" && serviceId !== "" && title === serviceId)

  // Which transport actions the current source accepts. Older firmware omits
  // the controls object; fall back to "streaming sources can transport".
  var controls = player.controls
  var fallback = supportsPlayback(source)
  var position = typeof items[5].i64_ === "number" ? items[5].i64_ : -1
  var duration = player.status && typeof player.status.duration === "number"
    ? player.status.duration : 0

  return {
    volume: typeof items[0].i32_ === "number" ? items[0].i32_ : null,
    // physicalSource reports "standby"/"powerOn" around power transitions;
    // neither is a selectable input.
    source: source === "standby" || source === "powerOn" ? "" : source,
    status: String(items[2].kefSpeakerStatus || ""),
    muted: items[3].bool_ === true,
    playbackState: String(player.state || ""),
    trackTitle: isRealTrack ? title : "",
    trackArtist: String(metaData.artist || ""),
    trackAlbum: String(metaData.album || ""),
    coverUrl: isRealTrack ? String(trackRoles.icon || "") : "",
    canPrevious: controls ? controls.previous === true : fallback,
    canPause: controls ? controls.pause === true : fallback,
    canNext: controls ? controls.next_ === true : fallback,
    positionMs: position >= 0 ? position : -1,
    durationMs: duration > 0 ? duration : 0,
    deviceName: String(items[6].string_ || "")
  }
}

// Milliseconds -> "m:ss" (or "h:mm:ss" past the hour).
function formatTime(ms) {
  var total = Math.floor(parseFloat(String(ms)) / 1000)
  if (isNaN(total) || total < 0) return ""
  var s = total % 60
  var m = Math.floor(total / 60) % 60
  var h = Math.floor(total / 3600)
  var mm = h > 0 && m < 10 ? "0" + m : String(m)
  var ss = s < 10 ? "0" + s : String(s)
  return (h > 0 ? h + ":" : "") + mm + ":" + ss
}

function speakerIcon(configured, reachable, powered, muted) {
  if (!configured || !reachable || !powered) return "󰓄"
  return muted ? "󰝟" : "󰓃"
}

function statusLine(configured, reachable, powered, source, playbackState) {
  if (!configured) return "Not configured"
  if (!reachable) return "Unreachable"
  if (!powered) return "Standby"
  var label = source ? sourceLabel(source) : "On"
  if (supportsPlayback(source) && playbackState === "playing") return label + " · Playing"
  if (supportsPlayback(source) && playbackState === "paused") return label + " · Paused"
  return label
}

function tooltip(deviceName, statusText) {
  var name = deviceName || "KEF Speaker"
  return statusText ? name + " — " + statusText : name
}

if (typeof module !== "undefined") {
  module.exports = {
    POLL_PATHS: POLL_PATHS,
    SOURCES: SOURCES,
    sourceLabel: sourceLabel,
    supportsPlayback: supportsPlayback,
    clampVolume: clampVolume,
    getDataUrl: getDataUrl,
    pollCommand: pollCommand,
    setCommand: setCommand,
    volumePayload: volumePayload,
    sourcePayload: sourcePayload,
    controlPayload: controlPayload,
    parsePoll: parsePoll,
    formatTime: formatTime,
    speakerIcon: speakerIcon,
    statusLine: statusLine,
    tooltip: tooltip
  }
}
