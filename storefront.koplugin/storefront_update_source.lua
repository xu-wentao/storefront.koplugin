-- Test-channel update source. Keep this isolated so the patch can be removed
-- cleanly before submitting the loading-state work upstream.
local StorefrontUpdateSource = {
    owner = "xu-wentao",
    repo = "storefront.koplugin",
    full_name = "xu-wentao/storefront.koplugin",
    branch = "test/plugin-loading-status",
    allow_prerelease = true,
}

function StorefrontUpdateSource.isStorefrontRecord(record)
    if type(record) ~= "table" then
        return false
    end
    return record.dirname == "storefront.koplugin"
        or (type(record.repo) == "string" and record.repo:lower() == "storefront.koplugin")
end

function StorefrontUpdateSource.applyToRecord(record)
    if not StorefrontUpdateSource.isStorefrontRecord(record) then
        return record
    end
    record.owner = StorefrontUpdateSource.owner
    record.repo = StorefrontUpdateSource.repo
    record.repo_full_name = StorefrontUpdateSource.full_name
    record.repo_id = nil
    record.branch = StorefrontUpdateSource.branch
    return record
end

return StorefrontUpdateSource
