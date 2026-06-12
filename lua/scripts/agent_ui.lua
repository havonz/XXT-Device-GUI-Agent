local M = {}

local TOAST_OPTIONS = {
    allow_screenshot = true,
}

function M.toast(message)
    sys.toast(tostring(message or ""), TOAST_OPTIONS)
end

return M
