local ReleaseFallback = {}

local TEST_OWNER = "xu-wentao"
local TEST_REPO = "storefront.koplugin"
local TEST_ASSET = "storefront.koplugin.zip"

local function decodeXml(value)
    if type(value) ~= "string" then return value end
    return value
        :gsub("&#x([0-9a-fA-F]+);", function(hex)
            local code = tonumber(hex, 16)
            return code and code < 128 and string.char(code) or ""
        end)
        :gsub("&#([0-9]+);", function(decimal)
            local code = tonumber(decimal, 10)
            return code and code < 128 and string.char(code) or ""
        end)
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&amp;", "&")
end

local function decodeUrl(value)
    if type(value) ~= "string" then return value end
    return value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function encodePathSegment(value)
    return tostring(value):gsub("([^%w%-._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function htmlToText(value)
    value = decodeXml(value or "")
    return value
        :gsub("<[Bb][Rr]%s*/?>", "\n")
        :gsub("</[Pp]%s*>", "\n\n")
        :gsub("<[^>]+>", "")
        :gsub("\r", "")
        :gsub("\n\n\n+", "\n\n")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

function ReleaseFallback.isTestSource(owner, repo)
    return owner == TEST_OWNER and repo == TEST_REPO
end

function ReleaseFallback.buildRelease(tag, fields)
    if type(tag) ~= "string" or tag == "" then return nil end
    fields = fields or {}
    local encoded_tag = encodePathSegment(tag)
    local release_url = string.format("https://github.com/%s/%s/releases/tag/%s", TEST_OWNER, TEST_REPO, encoded_tag)
    return {
        id = fields.id or tag,
        tag_name = tag,
        name = fields.name or tag,
        body = fields.body or "",
        published_at = fields.published_at,
        html_url = fields.html_url or release_url,
        draft = false,
        prerelease = tag:find("-", 1, true) ~= nil,
        assets = {
            {
                name = TEST_ASSET,
                browser_download_url = string.format(
                    "https://github.com/%s/%s/releases/download/%s/%s",
                    TEST_OWNER,
                    TEST_REPO,
                    encoded_tag,
                    TEST_ASSET
                ),
            },
        },
    }
end

function ReleaseFallback.parseAtom(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty feed"
    end
    local releases = {}
    for entry in body:gmatch("<entry[^>]*>(.-)</entry>") do
        local link = entry:match('<link[^>]-href="([^"]+)"')
        local encoded_tag = link and link:match("/releases/tag/([^%s%?]+)")
        local tag = encoded_tag and decodeUrl(decodeXml(encoded_tag))
        if tag and tag ~= "" then
            local title = entry:match("<title[^>]*>(.-)</title>")
            local content = entry:match("<content[^>]*>(.-)</content>")
            local updated = entry:match("<updated[^>]*>(.-)</updated>")
            local id = entry:match("<id[^>]*>(.-)</id>")
            local release = ReleaseFallback.buildRelease(tag, {
                id = decodeXml(id),
                name = decodeXml(title),
                body = htmlToText(content),
                published_at = decodeXml(updated),
                html_url = decodeXml(link),
            })
            if release then
                releases[#releases + 1] = release
            end
        end
    end
    if #releases == 0 then
        return nil, "no releases in feed"
    end
    return releases, nil
end

return ReleaseFallback
