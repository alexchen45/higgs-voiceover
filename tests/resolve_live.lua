--- Live integration tests against a running DaVinci Resolve.
--
-- These need Resolve open. They work in a throwaway project named below and
-- never touch the user's own projects.
--
--   "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript" -l lua tests/resolve_live.lua
--
-- Run this against every Resolve release we claim to support: the placement and
-- metadata behaviours it checks have regressed between point versions before.

-- Load the bundle for its modules without launching the window.
_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")

local R = require("higgs.resolve")
local P = require("higgs.platform")
local U = require("higgs.util")

local PROJECT = "HiggsVO_LiveTest"
local TRACK = "Higgs VO"

local passed, failed = 0, 0
local function check(label, cond, detail)
  if cond then passed = passed + 1; print("  ok    " .. label)
  else failed = failed + 1; print("  FAIL  " .. label .. (detail and ("  -> " .. tostring(detail)) or "")) end
end
local function eq(label, got, want)
  check(label, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

--- Build short WAVs locally so the suite has no network dependency.
local function make_wav(path, seconds)
  local rate, amp = 24000, 6000
  local samples = math.floor(rate * seconds)
  local data = {}
  for i = 1, samples do
    -- A quiet 220 Hz tone: audible when auditioned, harmless if it escapes.
    local v = math.floor(amp * math.sin(2 * math.pi * 220 * i / rate))
    if v < 0 then v = v + 65536 end
    data[#data + 1] = string.char(v % 256, math.floor(v / 256) % 256)
  end
  local pcm = table.concat(data)
  local function le32(n) return string.char(n % 256, math.floor(n/256)%256, math.floor(n/65536)%256, math.floor(n/16777216)%256) end
  local function le16(n) return string.char(n % 256, math.floor(n/256)%256) end
  local header = "RIFF" .. le32(36 + #pcm) .. "WAVEfmt " .. le32(16) .. le16(1) .. le16(1)
              .. le32(rate) .. le32(rate * 2) .. le16(2) .. le16(16) .. "data" .. le32(#pcm)
  return U.write_file(path, header .. pcm)
end

print("\nconnection")
local ok, err = R.connect()
check("connects to Resolve", ok, err)
if not ok then print("\nResolve is not running — start it and try again.\n"); os.exit(1) end

local product, version = R.product()
print("  .. " .. tostring(product) .. " " .. tostring(version))

-- Work in a scratch project so nothing the user has open is touched.
local pm = R.app():GetProjectManager()
local proj = pm:CreateProject(PROJECT) or pm:LoadProject(PROJECT)
check("opens a scratch project", proj ~= nil)
if not proj then os.exit(1) end

local mp = proj:GetMediaPool()
local tl = proj:GetCurrentTimeline() or mp:CreateEmptyTimeline("LiveTest")
check("has a timeline", tl ~= nil)

print("\ntimecode")
local fps = R.fps()
check("frame rate is sane", fps > 0 and fps < 1000, fps)
eq("timecode round-trips at one hour", R.tc_to_frames(string.format("01:00:00:00"), fps), math.floor(fps + 0.5) * 3600)
check("timeline start is the hour mark or zero",
  R.timeline_start() == 0 or R.timeline_start() == math.floor(fps + 0.5) * 3600, R.timeline_start())
check("playhead reads back", type(R.playhead_frame()) == "number")

print("\ntracks")
local idx, terr = R.ensure_track(TRACK, "mono")
check("creates the VO track", idx ~= nil, terr)
eq("finds it again by name", R.find_track(TRACK), idx)
eq("creating twice is idempotent", R.ensure_track(TRACK, "mono"), idx)

print("\nplacement")
local dir = P.join(P.config_dir(), "tmp")
P.mkdirs(dir)
local a_path = P.join(dir, "live_a_" .. U.new_id() .. ".wav")
local b_path = P.join(dir, "live_b_" .. U.new_id() .. ".wav")
check("writes test audio", make_wav(a_path, 1.5) and make_wav(b_path, 3.0))

local a_item, ierr = R.import(a_path)
check("imports into the media pool", a_item ~= nil, ierr)

local start = R.timeline_start()
local at = start + math.floor(fps * 2)
local clip, perr = R.place(a_item, idx, at)
check("places at the requested frame", clip ~= nil, perr)
if clip then eq("lands exactly where asked", clip:GetStart(), at) end

local blocked, berr = R.place(a_item, idx, at)
check("refuses to place over an existing clip", blocked == nil)
check("and says why", berr and berr:find("already a clip") ~= nil, berr)

local free_at = start + math.floor(fps * 30)
check("reports a free range as free", R.range_is_free(idx, free_at, free_at + 10))

print("\ntagging")
check("stamps the clip as ours", R.stamp(a_item, "quick_" .. U.new_id(), 1))

print("\npersistence")
check("saves the project", R.save())

print("\ncleanup")
local items = R.items_in_track(idx)
if #items > 0 then tl:DeleteClips(items, false) end
check("test clips removed", #R.items_in_track(idx) == 0)
os.remove(a_path); os.remove(b_path)
print("  .. scratch project '" .. PROJECT .. "' left in place; delete it when you like")

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
