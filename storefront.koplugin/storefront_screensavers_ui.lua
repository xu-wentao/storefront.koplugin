local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Localization = require("localization_storefront")
local _ = function(key, ...) return Localization:t(key, ...) end

local StorefrontScreensavers = {}

local DEFAULT_SCREENSAVER_CATALOG_URLS = {
    "https://raw.githubusercontent.com/ultimatejimmy/storefront-screensavers/main/screensavers.json",
    "https://github.com/ultimatejimmy/storefront-screensavers/raw/refs/heads/main/screensavers.json",
    "https://cdn.jsdelivr.net/gh/ultimatejimmy/storefront-screensavers@main/screensavers.json",
}

local function getPluginDir()
    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return source:match("^(.*[/\\])") or "./"
end

local BUNDLED_SCREENSAVER_CATALOG_PATH = getPluginDir() .. "screensavers_catalog.json"

local function getHttpModule(url)
    if url and url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    return require("socket.http")
end

local function requestWithRedirects(target_url, sink_fn)
    local ltn12 = require("ltn12")
    local current_url = target_url
    local max_redirects = 5
    local redirect_count = 0

    local last_code = 0
    local last_error

    while redirect_count <= max_redirects do
        local is_https = current_url:match("^https://") ~= nil
        local http_req = getHttpModule(current_url)
        local headers = {
            ["User-Agent"] = "KOReader-Storefront",
        }

        local sink = sink_fn()
        if not sink then return false, 0, nil end

        local params = {
            url = current_url,
            method = "GET",
            headers = headers,
            sink = sink,
        }
        if not is_https then params.redirect = true end

        local ok_req, res_code, response_headers = pcall(function()
            local _, c, h = http_req.request(params)
            return c, h
        end)

        local code = tonumber(res_code) or 0
        last_code = code
        if not ok_req then
            last_error = tostring(res_code)
        end
        if ok_req and code == 200 then
            return true, 200, response_headers
        elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            local loc = response_headers and (response_headers.location or response_headers.Location)
            if loc and loc ~= "" then
                current_url = loc
                redirect_count = redirect_count + 1
            else
                break
            end
        else
            break
        end
    end
    return false, last_code, nil, last_error
end

local function buildUrlCandidates(target_url)
    local candidates = {}
    local seen = {}
    local function add(url)
        if url and url ~= "" and not seen[url] then
            seen[url] = true
            candidates[#candidates + 1] = url
        end
    end

    add(target_url)
    local owner, repo, branch, path = tostring(target_url or ""):match(
        "^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)$"
    )
    if not owner then
        owner, repo, branch, path = tostring(target_url or ""):match(
            "^https://github%.com/([^/]+)/([^/]+)/raw/refs/heads/([^/]+)/(.*)$"
        )
    end
    if owner and repo and branch and path then
        add(string.format("https://github.com/%s/%s/raw/refs/heads/%s/%s", owner, repo, branch, path))
        add(string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo, branch, path))
        add(string.format("https://cdn.jsdelivr.net/gh/%s/%s@%s/%s", owner, repo, branch, path))
    end
    return candidates
end

local function requestWithFallbacks(target_url, sink_fn)
    local last_code = 0
    local last_error
    for _, candidate in ipairs(buildUrlCandidates(target_url)) do
        local ok, code, headers, err = requestWithRedirects(candidate, sink_fn)
        if ok then
            return true, code, headers, nil, candidate
        end
        last_code = code or last_code
        last_error = err or last_error
        logger.warn("Storefront screensaver request failed: " .. candidate .. " (HTTP " .. tostring(code or 0) .. ")")
    end
    return false, last_code, nil, last_error
end

local function isValidImageData(data)
    if type(data) ~= "string" or #data < 8 then
        return false
    end
    return data:sub(1, 2) == "\255\216"
        or data:sub(1, 8) == "\137PNG\r\n\26\n"
        or data:sub(1, 4) == "RIFF"
        or data:sub(1, 2) == "BM"
end

local cached_catalog_mem = nil

local function loadCatalogFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, parsed = pcall(json.decode, content)
    if ok and type(parsed) == "table" and #parsed > 0 then
        return parsed
    end
    return nil
end

function StorefrontScreensavers.getBundledCatalog()
    return loadCatalogFile(BUNDLED_SCREENSAVER_CATALOG_PATH)
end

function StorefrontScreensavers.getCachedCatalog()
    if cached_catalog_mem and type(cached_catalog_mem) == "table" and #cached_catalog_mem > 0 then
        return cached_catalog_mem
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local cat_file = DataStorage:getDataDir() .. "/cache/storefront_screensavers_catalog.json"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(cat_file, "mode") == "file" then
            local parsed = loadCatalogFile(cat_file)
            if parsed then
                cached_catalog_mem = parsed
                return parsed
            end
        end
    end
    local bundled = StorefrontScreensavers.getBundledCatalog()
    if bundled then
        cached_catalog_mem = bundled
        return bundled
    end
    return nil
end

function StorefrontScreensavers.fetchCatalog(callback)
    local ltn12 = require("ltn12")
    local last_error = "unknown error"

    for _, catalog_url in ipairs(DEFAULT_SCREENSAVER_CATALOG_URLS) do
        local response_body = {}
        local sink_fn = function()
            response_body = {}
            return ltn12.sink.table(response_body)
        end

        local ok, code = requestWithRedirects(catalog_url, sink_fn)
        if ok and code == 200 then
            local body_str = table.concat(response_body)
            local parsed_ok, data = pcall(json.decode, body_str)
            if parsed_ok and type(data) == "table" and #data > 0 then
                cached_catalog_mem = data
                pcall(function()
                    local ok_ds, DataStorage = pcall(require, "datastorage")
                    if ok_ds and DataStorage and DataStorage.getDataDir then
                        local cache_dir = DataStorage:getDataDir() .. "/cache"
                        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
                        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
                        if ok_lfs and lfs and lfs.attributes and not lfs.attributes(cache_dir) then
                            pcall(function() lfs.mkdir(cache_dir) end)
                        end
                        local cat_file = cache_dir .. "/storefront_screensavers_catalog.json"
                        local f = io.open(cat_file, "w")
                        if f then
                            f:write(body_str)
                            f:close()
                        end
                    end
                end)
                logger.info("Storefront screensaver catalog loaded: " .. tostring(#data) .. " items from " .. catalog_url)
                callback(true, data, "network")
                return
            end
            last_error = "invalid JSON/catalog payload from " .. catalog_url
            logger.warn("Storefront screensaver catalog parse failed: " .. last_error)
        else
            last_error = "HTTP " .. tostring(code or 0) .. " from " .. catalog_url
            logger.warn("Storefront screensaver catalog fetch failed: " .. last_error)
        end
    end

    local local_cached = StorefrontScreensavers.getCachedCatalog()
    if local_cached and #local_cached > 0 then
        logger.warn("Storefront screensaver catalog network fetch failed; using cached catalog with " .. tostring(#local_cached) .. " items")
        callback(true, local_cached, "cache")
        return
    end

    local bundled = StorefrontScreensavers.getBundledCatalog()
    if bundled and #bundled > 0 then
        cached_catalog_mem = bundled
        logger.warn("Storefront screensaver catalog network fetch failed; using bundled catalog with " .. tostring(#bundled) .. " items")
        callback(true, bundled, "bundled")
        return
    end

    logger.warn("Storefront screensaver catalog unavailable: " .. tostring(last_error))
    callback(false, {}, last_error)
end

function StorefrontScreensavers.fetchThumbnail(item, callback)
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local lfs = require("libs/libkoreader-lfs")
    if lfs and lfs.attributes and not lfs.attributes(cache_dir) then
        lfs.mkdir(cache_dir)
    end

    -- Safely check if item is in Transparent category
    local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
    local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil

    -- Use matching extension from URL or category
    local raw_url = tostring(item.thumbnailUrl or ""):lower()
    local ext = (is_transparent or raw_url:find("%.png")) and ".png" or ".jpg"
    local thumb_path = cache_dir .. "/" .. tostring(item.id) .. ext

    if lfs and lfs.attributes and lfs.attributes(thumb_path, "mode") == "file" then
        if callback then callback(thumb_path) end
        return thumb_path
    end

    local fetch_url = (is_transparent and item.pluginThumbnailUrl) or item.thumbnailUrl
    if not fetch_url or item._thumb_failed then return nil end

    local ltn12 = require("ltn12")
    local img_data = {}
    local sink_fn = function()
        img_data = {}
        return ltn12.sink.table(img_data)
    end

    local ok, code = requestWithFallbacks(fetch_url, sink_fn)
    if ok and code == 200 then
        local payload = table.concat(img_data)
        if not isValidImageData(payload) then
            logger.warn("Storefront screensaver thumbnail returned invalid image data: " .. tostring(fetch_url))
            item._thumb_failed = true
            return nil
        end
        local tmp_path = thumb_path .. ".tmp"
        local file = io.open(tmp_path, "wb")
        if file then
            file:write(payload)
            file:close()
            os.remove(thumb_path)
            local ok_ren = os.rename(tmp_path, thumb_path)
            if ok_ren then
                if callback then callback(thumb_path) end
                return thumb_path
            end
        end
    end

    item._thumb_failed = true
    return nil
end

StorefrontScreensavers.requestWithRedirects = requestWithRedirects
StorefrontScreensavers.requestWithFallbacks = requestWithFallbacks
StorefrontScreensavers.isValidImageData = isValidImageData

function StorefrontScreensavers.downloadAsSingle(item, callback)
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local StorefrontToast = require("storefront_toast")
    local title_str = item.title or item.name or ""
    StorefrontToast.show(title_str ~= "" and string.format(_("Downloading '%s'..."), title_str) or _("Downloading screensaver..."), 2)

    StorefrontScreensaverMgr.downloadWallpaper(item, function(ok, result)
        if ok and result then
            local cat_str = type(item.category) == "table" and table.concat(item.category, " ") or tostring(item.category or "")
            local is_transparent = cat_str:lower():find("transparent", 1, true) ~= nil
            local params = { file = result }
            if is_transparent then
                params.background = "none"
            end
            StorefrontScreensaverMgr.setScreensaverMode("single", params)
            StorefrontToast.show(_("Wallpaper set as active KOReader screensaver!"), 3)
            if callback then callback(true, result) end
        else
            StorefrontToast.show(_("Failed to download screensaver."), 3)
            if callback then callback(false, result) end
        end
    end)
end

function StorefrontScreensavers.downloadToShufflePool(item, callback)
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local StorefrontToast = require("storefront_toast")
    local title_str = item.title or item.name or ""
    StorefrontToast.show(title_str ~= "" and string.format(_("Downloading '%s'..."), title_str) or _("Downloading to shuffle pool..."), 2)

    StorefrontScreensaverMgr.downloadWallpaper(item, function(ok, result)
        if ok and result then
            StorefrontScreensaverMgr.setScreensaverMode("shuffle")
            StorefrontToast.show(_("Added to shuffle pool & Folder Shuffle enabled!"), 3)
            if callback then callback(true, result) end
        else
            StorefrontToast.show(_("Failed to download screensaver."), 3)
            if callback then callback(false, result) end
        end
    end)
end

function StorefrontScreensavers.downloadOnly(item, callback)
    local StorefrontScreensaverMgr = require("storefront_screensaver_mgr")
    local StorefrontToast = require("storefront_toast")
    local title_str = item.title or item.name or ""
    StorefrontToast.show(title_str ~= "" and string.format(_("Downloading '%s'..."), title_str) or _("Downloading screensaver..."), 2)

    StorefrontScreensaverMgr.downloadWallpaper(item, function(ok, result)
        if ok and result then
            StorefrontToast.show(_("Wallpaper saved to collection!"), 3)
            if callback then callback(true, result) end
        else
            StorefrontToast.show(_("Failed to download screensaver."), 3)
            if callback then callback(false, result) end
        end
    end)
end

function StorefrontScreensavers.downloadAndSetScreensaver(item, callback)
    StorefrontScreensavers.downloadAsSingle(item, callback)
end

function StorefrontScreensavers.showDetails(item, parent_storefront)
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local ImageWidget = require("ui/widget/imagewidget")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Blitbuffer = require("ffi/blitbuffer")

    local sc = function(val) return Device.screen:scaleBySize(val) end

    local thumb_file = StorefrontScreensavers.fetchThumbnail(item)

    local StorefrontUtils = require("storefront_utils")
    local cat_str = table.concat(StorefrontUtils.getMappedScreensaverCategories(item.category), ", ")
    local meta_txt = TextWidget:new{
        text = string.format("%s  ·  %s", item.author or _("Community"), cat_str),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local preview_widget
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

    if thumb_file and ok_lfs and lfs and lfs.attributes and lfs.attributes(thumb_file, "mode") == "file" then
        local ok_c, res_c = pcall(function()
            return StorefrontScreensavers.createCoverImageWidget(thumb_file, sc(180), sc(240))
        end)
        if ok_c and res_c then
            preview_widget = res_c
        end
    end

    if not preview_widget then
        preview_widget = TextWidget:new{
            text = _("[ Wallpaper Preview Loading... ]"),
            face = Font:getFace("cfont", 16),
        }
    end

    local tags_str = ""
    if item.tags then
        if type(item.tags) == "table" and #item.tags > 0 then
            local display_tags = {}
            for i = 1, math.min(#item.tags, 5) do
                table.insert(display_tags, "#" .. tostring(item.tags[i]))
            end
            tags_str = table.concat(display_tags, "  ")
        elseif type(item.tags) == "string" and item.tags ~= "" then
            tags_str = item.tags
        end
    end

    local dialog_vg = VerticalGroup:new{
        align = "center",
        meta_txt,
    }

    if tags_str ~= "" then
        table.insert(dialog_vg, VerticalSpan:new{ width = sc(3) })
        table.insert(dialog_vg, TextWidget:new{
            text = tags_str,
            face = Font:getFace("cfont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = sc(260),
        })
    end

    table.insert(dialog_vg, VerticalSpan:new{ width = sc(8) })
    table.insert(dialog_vg, preview_widget)

    local dialog
    dialog = ButtonDialog:new{
        title = item.title or item.name or _("Screensaver Details"),
        widgets = {
            CenterContainer:new{
                dimen = require("ui/geometry"):new{ w = sc(280), h = sc(320) },
                dialog_vg
            }
        },
        buttons = {
            {
                {
                    text = _("Download & Set Active"),
                    is_primary = true,
                    callback = function()
                        UIManager:close(dialog)
                        StorefrontScreensavers.downloadAndSetScreensaver(item)
                    end,
                },
            },
            {
                {
                    text = _("Rate Wallpaper"),
                    callback = function()
                        if parent_storefront and parent_storefront.showRatingDialog then
                            parent_storefront:showRatingDialog(item)
                        end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function StorefrontScreensavers.createCoverImageWidget(file_path, target_w, target_h)
    local ImageWidget = require("ui/widget/imagewidget")
    local RenderImage = require("ui/renderimage")
    local Blitbuffer  = require("ffi/blitbuffer")

    if not file_path or not target_w or not target_h then return nil end

    local ok, orig_bb = pcall(function()
        return RenderImage:renderImageFile(file_path, false)
    end)

    if not ok or not orig_bb then
        return nil
    end

    local orig_w = orig_bb:getWidth()
    local orig_h = orig_bb:getHeight()

    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        if orig_bb.free then pcall(function() orig_bb:free() end) end
        return nil
    end

    -- Scale with cover mode (fill target box edge-to-edge, center-cropped)
    local scale = math.max(target_w / orig_w, target_h / orig_h)
    local scaled_w = math.max(1, math.ceil(orig_w * scale))
    local scaled_h = math.max(1, math.ceil(orig_h * scale))

    local ok_scale, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(orig_bb, scaled_w, scaled_h, false)
    end)
    if orig_bb.free then pcall(function() orig_bb:free() end) end
    if not ok_scale or not scaled_bb then return nil end

    local crop_x = math.max(0, math.floor((scaled_bb:getWidth() - target_w) / 2))
    local crop_y = math.max(0, math.floor((scaled_bb:getHeight() - target_h) / 2))

    -- Create destination buffer matching source buffer color type
    local bb_type = (scaled_bb.getType and scaled_bb:getType()) or Blitbuffer.TYPE_BPP24
    local dest_bb = Blitbuffer.new(target_w, target_h, bb_type)
    pcall(function() dest_bb:fill(Blitbuffer.COLOR_WHITE) end)

    pcall(function()
        dest_bb:blitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)
    end)

    if scaled_bb.free then
        pcall(function() scaled_bb:free() end)
    end

    return ImageWidget:new{
        image = dest_bb,
        image_disposable = true,
        width = target_w,
        height = target_h,
    }
end

function StorefrontScreensavers.getThumbnailsCacheStats()
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local files = 0
    local bytes = 0
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(cache_dir, "mode") == "directory" then
        for entry in lfs.dir(cache_dir) do
            if entry ~= "." and entry ~= ".." then
                local full = cache_dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == "file" then
                    files = files + 1
                    bytes = bytes + (attr.size or 0)
                end
            end
        end
    end
    return {
        files = files,
        bytes = bytes,
    }
end

function StorefrontScreensavers.clearThumbnailsCache()
    local cache_dir = DataStorage:getDataDir() .. "/cache/storefront_thumbs"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local removed = 0
    local bytes = 0
    local errors = {}
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(cache_dir, "mode") == "directory" then
        for entry in lfs.dir(cache_dir) do
            if entry ~= "." and entry ~= ".." then
                local full = cache_dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == "file" then
                    local sz = attr.size or 0
                    if os.remove(full) then
                        removed = removed + 1
                        bytes = bytes + sz
                    else
                        table.insert(errors, full)
                    end
                end
            end
        end
    end
    return { removed = removed, bytes = bytes, errors = errors }
end

return StorefrontScreensavers
