local state_factory = require("dockyard.core.stream.loglens.state")
local renderer = require("dockyard.ui.loglens.renderer")
local ui_state = require("dockyard.ui.state")
local keymaps = require("dockyard.ui.loglens.keymaps")
local window = require("dockyard.ui.loglens.window")
local log_core = require("dockyard.core.stream.loglens.core")
local loglens_config = require("dockyard.core.stream.loglens.config")
local statusline = require("dockyard.ui.statusline")

local M = {}

---@class LogLensSession
---@field container Container
---@field state LogLensState
---@field stream LogStreamInstance|nil

---@type table<string, LogLensSession>
local sessions = {}

---@param container Container
---@return string
local function session_key(container)
	local name = loglens_config.normalize_container_name(container.name)
	if name ~= "" then
		return name
	end
	return tostring(container.id or "")
end

---@param session LogLensSession
---@return LogStreamInstance
local function ensure_stream(session)
	if session.stream then
		return session.stream
	end

	session.stream = log_core.create({
		on_entries = function(entries)
			session.state.entries = entries
			renderer.render(session.state)
		end,
	})

	return session.stream
end

---@param state LogLensState
---@param inst LogStreamInstance
local function sync_state_from_instance(state, inst)
	state.container = inst.container
	state.container_name = inst.container_name
	state.entries = inst.entries
	state.active_source = inst.active_source
	state.sources = inst.sources or {}
	state.max_lines = inst.max_lines
	state.parser_sessions = inst._parser_sessions
	state.job_ids = inst._job_ids
end

---@param session LogLensSession
local function stop_stream(session)
	if session.stream then
		session.stream:stop()
		session.stream = nil
	end
end

---@param session LogLensSession
---@param buf integer
local function attach_cleanup(session, buf)
	local group = vim.api.nvim_create_augroup("DockyardLogLensCleanup" .. tostring(buf), { clear = true })
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = buf,
		callback = function()
			-- Stop the background stream when the buffer is killed outside
			-- M.close(), so it does not keep running headless.
			stop_stream(session)
			if session.state.buf_id == buf then
				session.state.buf_id = nil
			end

			-- If the window is gone too, drop the session entirely. Defer so
			-- window teardown has finished.
			vim.schedule(function()
				local win = session.state.win_id
				if not (win and vim.api.nvim_win_is_valid(win)) then
					local key = session_key(session.container)
					if sessions[key] == session then
						sessions[key] = nil
					end
				end
			end)
		end,
	})
end

---@param session LogLensSession
---@param buf integer
local function attach_handlers(session, buf)
	local state = session.state

	keymaps.attach(buf, state, {
		close = function()
			M.close(buf)
		end,
		refresh = function()
			renderer.render(state)
		end,
		open_detail = function()
			local lnum = vim.api.nvim_win_get_cursor(state.win_id)[1]
			local entry = state.line_map and state.line_map[lnum] or nil
			if not entry then
				vim.notify("LogLens: no entry at cursor", vim.log.levels.WARN)
				return
			end
			require("dockyard.ui.loglens.popup").open(entry)
		end,
	})

	attach_cleanup(session, buf)
end

---@param session LogLensSession
---@return boolean
local function is_attached(session)
	local state = session.state
	return state.is_open()
		and state.has_valid_buffer()
		and vim.api.nvim_win_get_buf(state.win_id) == state.buf_id
end

---Attach the buffer to the session's window, reusing the window when possible.
---@param session LogLensSession
---@param buf integer
---@param mode string
---@return boolean
local function attach_window(session, buf, mode)
	local state = session.state
	if state.is_open() then
		-- The window survived but its buffer was killed or replaced.
		-- Reattach the LogLens buffer instead of opening another split.
		vim.api.nvim_win_set_buf(state.win_id, buf)
		return true
	end

	local win
	if mode == "split" then
		win = window.create_window_split(buf)
	elseif mode == "floating" then
		win = window.create_window_floating(buf)
	elseif mode == "fullscreen" then
		win = window.create_window_fullscreen(buf, ui_state)
	elseif ui_state.mode == "panel" then
		win = window.create_window_floating(buf)
	else
		win = window.create_window_fullscreen(buf, ui_state)
	end
	if not win then
		return false
	end

	state.win_id = win
	return true
end

---@param session LogLensSession
local function close_session(session)
	stop_stream(session)

	local state = session.state
	if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
		pcall(vim.api.nvim_win_close, state.win_id, true)
	end
	if state.buf_id and vim.api.nvim_buf_is_valid(state.buf_id) then
		pcall(vim.api.nvim_buf_delete, state.buf_id, { force = true })
	end

	local key = session_key(session.container)
	if sessions[key] == session then
		sessions[key] = nil
	end
end

---Open LogLens for a container.
---@param container Container|nil
---@param opts? { mode?: "auto"|"split"|"floating"|"fullscreen" }
function M.open(container, opts)
	if not container or not container.id then
		vim.notify("LogLens: No valid container selected", vim.log.levels.WARN)
		return
	end

	local source_win = vim.api.nvim_get_current_win()
	local mode = opts and opts.mode or "auto"
	local key = session_key(container)
	local session = sessions[key]

	if not session then
		session = {
			container = container,
			state = state_factory.new(),
			stream = nil,
		}
		sessions[key] = session
	end

	session.container = container
	session.state.container = container
	session.state.container_name = loglens_config.normalize_container_name(container.name)

	if not is_attached(session) then
		local buf = window.create_buffer(session.state)
		if not attach_window(session, buf, mode) then
			return
		end
		attach_handlers(session, buf)
	end

	local inst = ensure_stream(session)
	local current_id = inst.container and inst.container.id or nil
	if current_id ~= container.id then
		session.state.line_map = nil
		session.state.filter = nil
		session.state.active_source_idx = 0

		local ok, err = inst:start(container)
		if not ok then
			vim.notify("LogLens: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
	end

	-- Always repaint from the stream state: the buffer may have been
	-- recreated even though the container (and stream) did not change.
	sync_state_from_instance(session.state, inst)
	renderer.render(session.state)

	statusline.inherit(session.state.win_id, source_win)
	vim.api.nvim_set_current_win(session.state.win_id)
end

---Close the LogLens session for a buffer, or the current one when omitted.
---@param buf integer|nil
function M.close(buf)
	local target = nil

	if buf ~= nil then
		for _, session in pairs(sessions) do
			if session.state.buf_id == buf then
				target = session
				break
			end
		end
	else
		local current = vim.api.nvim_get_current_buf()
		for _, session in pairs(sessions) do
			if session.state.buf_id == current then
				target = session
				break
			end
		end
	end

	if target == nil then
		-- Fall back to the only session, if there is exactly one.
		local only = nil
		local count = 0
		for _, session in pairs(sessions) do
			only = session
			count = count + 1
		end
		if count == 1 then
			target = only
		end
	end

	if target ~= nil then
		close_session(target)
	end
end

---Close every open LogLens session.
function M.close_all()
	local all = {}
	for _, session in pairs(sessions) do
		table.insert(all, session)
	end
	for _, session in ipairs(all) do
		close_session(session)
	end
	sessions = {}
end

return M
