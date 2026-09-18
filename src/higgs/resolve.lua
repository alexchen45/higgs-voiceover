--- DaVinci Resolve integration: media pool, timeline placement, clip binding.
--
-- Every quirk handled here was observed on Resolve 20.3.2 Studio, not inferred
-- from documentation. The important ones, because they are all silent failures:
--
--   * Appending into a range already occupied on the target track does nothing
--     but still returns a truthy result. Every placement is therefore
--     collision-checked first and verified afterwards.
--   * Overwriting an audio file in place never refreshes Resolve's media cache.
--     Takes are always written to a new versioned filename.
--   * MediaPoolItem:ReplaceClip swaps the media but leaves the timeline item's
--     in/out untouched — longer audio truncates, shorter leaves dead air.
--   * There is no trim or move API. Re-timing a clip means delete + re-append.
--   * SetClipProperty returns false even when it succeeded; never branch on it.
--   * Metadata written without saving the project is lost on quit.

local P = require("higgs.platform")
local U = require("higgs.util")

local M = {}

--- Metadata keys stamped on every generated clip. These survive project save,
-- reload and a full Resolve restart, and are invisible in Resolve's UI.
M.KEY_SEGMENT = "hvo_segment_id"
M.KEY_VERSION = "hvo_version"
M.BIN_NAME = "Higgs VoiceOver"
-- Projects that already hold takes in the bin's earlier name keep using it,
-- so one project's clips never split across two bins.
M.LEGACY_BIN_NAMES = { "Higgs VO" }

--------------------------------------------------------------- connection

local api  -- the Resolve app object

--- Attach to Resolve. Works both as a Workspace script (where `resolve` is a
-- provided global) and from an external interpreter during development.
function M.connect()
  if api then return true end
  if type(_G.resolve) ~= "nil" and _G.resolve then
    api = _G.resolve
  elseif type(_G.bmd) == "table" and _G.bmd.scriptapp then
    api = _G.bmd.scriptapp("Resolve")
  end
  if not api then
    return false, "DaVinci Resolve is not reachable. Open Resolve, then run this from Workspace › Scripts."
  end
  return true
end

function M.app() return api end

function M.product()
  if not api then return nil end
  return api:GetProductName(), api:GetVersionString()
end

function M.project()
  if not api then return nil end
  local pm = api:GetProjectManager()
  return pm and pm:GetCurrentProject() or nil
end

function M.timeline()
  local proj = M.project()
  return proj and proj:GetCurrentTimeline() or nil
end

--- The open project's name, for the folder its clips are written to. Empty
-- when nothing is open, which callers read as "use the base folder".
function M.project_name()
  local proj = M.project()
  if not proj then return "" end
  local ok, name = pcall(function() return proj:GetName() end)
  return (ok and name) and tostring(name) or ""
end

function M.media_pool()
  local proj = M.project()
  return proj and proj:GetMediaPool() or nil
end

--- Persist metadata and markers. Resolve keeps these in memory until a save,
-- so any binding write must be followed by this or it is lost on quit.
function M.save()
  if not api then return false end
  local pm = api:GetProjectManager()
  return pm and pm:SaveProject() or false
end

--- Identify the current project and timeline (the draft is kept per project).
function M.ids()
  local proj, tl = M.project(), M.timeline()
  if not proj or not tl then return nil, nil end
  return proj:GetUniqueId(), tl:GetUniqueId()
end

------------------------------------------------------------------- timecode

--- Timeline frame rate as a number. Resolve may append "DF" for drop frame.
function M.fps()
  local tl = M.timeline()
  if not tl then return 24 end
  local raw = tostring(tl:GetSetting("timelineFrameRate") or "24")
  return tonumber((raw:gsub("[^%d%.]", ""))) or 24
end

--- Timelines rarely start at zero — 01:00:00:00 is the common default, which
-- makes every record frame an hour's worth of frames off if ignored.
function M.timeline_start()
  local tl = M.timeline()
  return tl and tl:GetStartFrame() or 0
end

--- Convert "HH:MM:SS:FF" (or "HH:MM:SS;FF" for drop frame) to absolute frames.
function M.tc_to_frames(tc, fps)
  fps = fps or M.fps()
  local h, m, s, f, sep
  h, m, s, sep, f = tostring(tc):match("^(%d+):(%d+):(%d+)([:;])(%d+)$")
  if not h then return nil end
  h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f)

  local drop = (sep == ";")
  local nominal = drop and math.floor(fps + 0.5) or math.floor(fps + 0.5)
  local total = ((h * 60 + m) * 60 + s) * nominal + f

  if drop then
    -- Drop-frame skips 2 frames (or 4 at 60fps) each minute except every tenth.
    local dropped = math.floor(nominal / 15 + 0.5) * 2 / 2
    dropped = (nominal == 30) and 2 or (nominal == 60) and 4 or 2
    local minutes = h * 60 + m
    total = total - dropped * (minutes - math.floor(minutes / 10))
  end
  return total
end

function M.frames_to_seconds(frames)
  return (tonumber(frames) or 0) / M.fps()
end

function M.seconds_to_frames(seconds)
  return math.floor((tonumber(seconds) or 0) * M.fps() + 0.5)
end

--- Absolute frame under the playhead, or the timeline start if unavailable.
function M.playhead_frame()
  local tl = M.timeline()
  if not tl then return 0 end
  local f = M.tc_to_frames(tl:GetCurrentTimecode())
  return f or M.timeline_start()
end

---------------------------------------------------------------------- tracks

--- Find the audio track carrying a given name, or nil.
-- Track index is never cached: users reorder and rename tracks freely, so it is
-- resolved fresh on every operation.
function M.find_track(name)
  local tl = M.timeline()
  if not tl then return nil end
  for i = 1, (tl:GetTrackCount("audio") or 0) do
    if tostring(tl:GetTrackName("audio", i)) == name then return i end
  end
  return nil
end

--- Return the index of the VO track, creating it if absent.
function M.ensure_track(name, subtype)
  local tl = M.timeline()
  if not tl then return nil, "No timeline is open." end

  local existing = M.find_track(name)
  if existing then return existing end

  if not tl:AddTrack("audio", subtype or "stereo") then
    return nil, "Could not add an audio track to this timeline."
  end
  local idx = tl:GetTrackCount("audio")
  tl:SetTrackName("audio", idx, name)
  return idx
end

--- Items on a track, always as a list (some versions return nil when empty).
function M.items_in_track(index)
  local tl = M.timeline()
  if not tl then return {} end
  return tl:GetItemListInTrack("audio", index) or {}
end

--- Is [from, to) free on this track?
function M.range_is_free(track_index, from, to, ignore_item)
  for _, item in ipairs(M.items_in_track(track_index)) do
    if item ~= ignore_item then
      local s, e = item:GetStart(), item:GetEnd()
      if s < to and e > from then return false, item end
    end
  end
  return true
end

--- Free gaps on a track after a given frame, as { {from=, to=, frames=} }.
function M.gaps_after(track_index, from)
  local items = M.items_in_track(track_index)
  table.sort(items, function(a, b) return a:GetStart() < b:GetStart() end)
  local gaps, cursor = {}, from
  for _, item in ipairs(items) do
    local s = item:GetStart()
    if s > cursor then gaps[#gaps + 1] = { from = cursor, to = s, frames = s - cursor } end
    cursor = math.max(cursor, item:GetEnd())
  end
  return gaps, cursor
end

------------------------------------------------------------------ media pool

--- Import one audio file into the plugin's bin.
function M.import(path, bin_name)
  local mp = M.media_pool()
  if not mp then return nil, "No project is open." end
  if not P.exists(path) then return nil, "Generated file is missing: " .. tostring(path) end

  local root = mp:GetRootFolder()
  local target
  local names = { bin_name or M.BIN_NAME }
  if not bin_name then for _, n in ipairs(M.LEGACY_BIN_NAMES) do names[#names + 1] = n end end
  local folders = root:GetSubFolderList() or {}
  for _, want in ipairs(names) do
    for _, folder in ipairs(folders) do
      if folder:GetName() == want then target = folder break end
    end
    if target then break end
  end
  if not target then target = mp:AddSubFolder(root, bin_name or M.BIN_NAME) end

  -- A file imported earlier (at generation) is reused, not duplicated.
  if target then
    for _, clip in ipairs(target:GetClipList() or {}) do
      local ok, existing = pcall(function() return clip:GetClipProperty("File Path") end)
      if ok and existing == path then return clip end
    end
  end

  local previous = mp:GetCurrentFolder()
  if target then mp:SetCurrentFolder(target) end
  local items = mp:ImportMedia({ path })
  if previous then mp:SetCurrentFolder(previous) end

  if not items or not items[1] then
    return nil, "Resolve would not import " .. P.basename(path)
  end
  -- The clip is named like the file, without the extension.
  local base = P.basename(path):gsub("%.[%w]+$", "")
  pcall(function() items[1]:SetClipProperty("Clip Name", base) end)
  return items[1]
end

--- Duration of a pool item in frames, from its timecode duration property.
function M.item_frames(mpi)
  local dur = tostring(mpi:GetClipProperty("Duration") or "")
  local frames = M.tc_to_frames(dur)
  if frames then return frames end
  return nil
end

------------------------------------------------------------------- placement

--- Place a pool item on a track at an absolute frame.
--
-- Returns the created timeline item, or nil plus a message. The collision check
-- and the post-placement verification are both required: Resolve reports
-- success for an append that silently did nothing.
function M.place(mpi, track_index, record_frame, duration_frames)
  local mp = M.media_pool()
  local tl = M.timeline()
  if not mp or not tl then return nil, "No timeline is open." end

  local frames = duration_frames or M.item_frames(mpi)
  if not frames or frames <= 0 then
    return nil, "Could not read the length of the generated clip."
  end

  local free, blocker = M.range_is_free(track_index, record_frame, record_frame + frames)
  if not free then
    return nil, string.format("There is already a clip at that position (%s).",
                              tostring(blocker and blocker:GetName() or "unknown"))
  end

  local before = #M.items_in_track(track_index)
  mp:AppendToTimeline({ {
    mediaPoolItem = mpi,
    startFrame = 0,
    endFrame = frames - 1,
    mediaType = 2,          -- audio only
    trackIndex = track_index,
    recordFrame = record_frame,
  } })

  -- Trust the timeline, not the return value.
  for _, item in ipairs(M.items_in_track(track_index)) do
    if item:GetStart() == record_frame then return item end
  end
  if #M.items_in_track(track_index) > before then
    return nil, "Resolve placed the clip somewhere unexpected. Check the VO track."
  end
  return nil, "Resolve did not place the clip. The track may be locked."
end

---------------------------------------------------------------------- tagging

--- Mark a generated clip as ours, so it can be recognised later.
function M.stamp(mpi, segment_id, version)
  if not mpi then return false end
  mpi:SetThirdPartyMetadata(M.KEY_SEGMENT, tostring(segment_id))
  mpi:SetThirdPartyMetadata(M.KEY_VERSION, tostring(version or 1))
  -- Comments is a visible fallback that survives formats third-party metadata
  -- may not; SetClipProperty's return value is unreliable, so it is ignored.
  mpi:SetMetadata("Comments", "higgs-vo:" .. tostring(segment_id))
  return true
end

return M
