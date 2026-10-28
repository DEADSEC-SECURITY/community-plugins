--!nonstrict
-- Existing media controls, presented in the Device tab.
local M = {}
function M.new(ctx)
local ui, noctalia, t, sendCmd = ctx.ui, ctx.api, ctx.t, ctx.send
local mediaDragState, volumeDragState, previousVolume = {}, {}, {}
local function fmtTime(ms)
    local seconds = math.floor(math.max(0, tonumber(ms) or 0) / 1000)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
local function mediaSection(d)
	local title = d.mediatitle
	if not title or title == "" then
		-- Left-aligned like the playing state (an earlier version centered
		-- this placeholder, which made the section flip between two layouts
		-- whenever media started/stopped or devices were switched).
		return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
			ui.row({ gap = 6, align = "center" }, {
				ui.glyph({ name = "music", size = 13, color = "primary" }),
				ui.label({ text = t("panel.now_playing"), fontSize = 10,
					color = "primary", fontWeight = "bold", flexGrow = 1 }),
			}),
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "music-off", size = 20, color = "on_surface_variant" }),
				ui.label({ text = t("panel.no_media"), fontSize = 11,
					color = "on_surface_variant" }),
			}),
		})
	end
	local artist = d.mediaartist or ""
	local album = d.mediaalbum or ""
	local playing = d.mediaisPlaying == true
	local length = tonumber(d.medialength) or 0
	local position = tonumber(d.mediaposition) or 0
	local canSeek = d.mediacanSeek == true
	local artUrl = d.mediaArtPath

	-- only use art if the file exists (phone path via SFTP mount)
	if artUrl and artUrl ~= "" and not noctalia.fileExists(artUrl) then
		artUrl = nil
	end

	local header = ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "music", size = 13, color = "primary" }),
		ui.label({ text = t("panel.now_playing"), fontSize = 10,
			color = "primary", fontWeight = "bold", flexGrow = 1 }),
	})

	local titleBlock
	if artUrl then
		titleBlock = ui.row({ gap = 8, align = "center" }, {
			ui.image({ path = artUrl, width = 36, height = 36, radius = 4, fit = "cover" }),
			ui.column({ gap = 1, flexGrow = 1 }, {
				ui.label({ text = title, fontSize = 12, fontWeight = "medium",
					color = "on_surface", maxLines = 1 }),
				ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
				ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
			}),
		})
	else
		titleBlock = ui.column({ gap = 1 }, {
			ui.label({ text = title, fontSize = 12, fontWeight = "medium",
				color = "on_surface", maxLines = 1 }),
			ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
			ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
		})
	end

	local transport = ui.row({ gap = 4, align = "center" }, {
		ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm",
			tooltip = t("media.previous"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Previous" }) end }),
		ui.button({ glyph = playing and "player-pause" or "player-play",
			variant = "primary", controlSize = "sm",
			tooltip = t(playing and "media.pause" or "media.play"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "PlayPause" }) end }),
		ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm",
			tooltip = t("media.next"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Next" }) end }),
		ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = t("media.stop"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Stop" }) end }),
	})

	local progress
	if canSeek and length > 0 then
		local st = mediaDragState[d.id]
		-- Freeze the thumb only while the user is actually dragging; a stale
		-- drag state (e.g. onDragEnd never fired) expires after 2s and the bar
		-- resumes tracking the live position.
		local frozen = st and st.dragging and (os.clock() - (st.at or 0)) < 2.0
		if st and st.dragging and not frozen then mediaDragState[d.id] = nil end
		local sliderValue = frozen and st.position or position
		progress = ui.column({ gap = 2 }, {
			ui.slider({ min = 0, max = length, step = 1000, value = sliderValue,
				controlSize = "sm",
				onChange = function(v)
					mediaDragState[d.id] = { dragging = true, position = tonumber(v) or position, at = os.clock() }
				end,
				onDragEnd = function()
					local st2 = mediaDragState[d.id]
					local target = (st2 and st2.position) or position
					mediaDragState[d.id] = nil
					sendCmd({ op = "media_seek", device = d.id, offset = tostring(target) })
				end }),
			ui.row({ justify = "space_between" }, {
				ui.label({ text = fmtTime(sliderValue), fontSize = 9, color = "on_surface_variant" }),
				ui.label({ text = fmtTime(length), fontSize = 9, color = "on_surface_variant" }),
			}),
		})
	end

	local children = { header, titleBlock, transport }
	if progress then table.insert(children, progress) end
	return ui.column({ gap = 6, padding = 10, radius = 8, fill = "primary/0.08" }, children)
end


return function(d)
    local children = {mediaSection(d)}
    local volume = tonumber(d.mediavolume)
    if volume and volume >= 0 then
        local frozen = volumeDragState[d.id]
        local shown = frozen or volume
        table.insert(children, ui.row({gap = 12, align = "center"}, {
            ui.button({glyph = shown == 0 and "volume-off" or "volume", variant = "ghost",
                tooltip = t(shown == 0 and "media.unmute" or "media.mute"), enabled = d.isReachable,
                onClick = function()
                    if volume > 0 then previousVolume[d.id] = volume end
                    sendCmd({op = "media_set_volume", device = d.id,
                        volume = volume == 0 and (previousVolume[d.id] or 50) or 0})
                end}),
            ui.slider({key = "volume-" .. d.id, min = 0, max = 100, step = 1, value = shown,
                enabled = d.isReachable, flexGrow = 1,
                onChange = function(v) volumeDragState[d.id] = tonumber(v) end,
                onDragEnd = function()
                    sendCmd({op = "media_set_volume", device = d.id, volume = volumeDragState[d.id] or volume})
                    volumeDragState[d.id] = nil
                end}),
            ui.label({text = tostring(math.floor(shown)) .. "%", width = 46}),
        }))
    end
    return ui.column({gap = 12}, children)
end
end
return M
