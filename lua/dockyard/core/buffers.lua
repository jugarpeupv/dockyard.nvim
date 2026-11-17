local M = {}

local AUGROUP = "DockyardBuffers"

-- Every buffer owned by Dockyard uses a filetype in this namespace:
--   dockyard          - main UI
--   dockyard-files    - container file browser
--   dockyard-logs     - loglens
--   dockyard_popup    - help/hover popups
-- Using a glob keeps future dockyard-* / dockyard_* filetypes covered too.
M.filetype_pattern = "dockyard*"

---@param buf integer|nil
function M.mark_listed(buf)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if vim.bo[buf].buflisted then
		return
	end
	vim.api.nvim_set_option_value("buflisted", true, { buf = buf })
end

---@param filetype string|nil
---@return boolean
local function is_dockyard_filetype(filetype)
	return type(filetype) == "string" and filetype:match("^dockyard") ~= nil
end

---@param buf integer
---@return boolean
local function is_dockyard_buffer(buf)
	if is_dockyard_filetype(vim.bo[buf].filetype) then
		return true
	end
	-- Container files opened from the browser keep their real filetype but
	-- use the dockyard:// scheme.
	return vim.api.nvim_buf_get_name(buf):match("^dockyard://") ~= nil
end

function M.setup()
	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = M.filetype_pattern,
		callback = function(args)
			M.mark_listed(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = group,
		pattern = "dockyard://*",
		callback = function(args)
			M.mark_listed(args.buf)
		end,
	})

	-- Catch buffers created before setup ran (e.g. after a plugin reload).
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if is_dockyard_buffer(buf) then
			M.mark_listed(buf)
		end
	end
end

return M
