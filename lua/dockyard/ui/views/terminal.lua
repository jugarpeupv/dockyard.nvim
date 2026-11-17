local M = {}

local statusline = require("dockyard.ui.statusline")

-- One Sessions per container. Those are for reference
local toggleterm_sessions = {}
local float_session = nil

-- Native terminal fallback (when toggleterm is not installed)
local native_float = nil
local native_sessions = {}

local function build_exec_cmd(container_id, shell)
	shell = shell or "sh"
	return string.format("docker exec -it %s %s", container_id, shell)
end

local function is_valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function mark_listed(buf)
	if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_set_option_value("buflisted", true, { buf = buf })
	end
end

---Build a recognizable terminal buffer name from the container name.
---@param label string|nil
---@param suffix string|nil
---@return string
local function term_buf_name(label, suffix)
	local base = (label ~= nil and label ~= "") and label or "dockyard"
	if suffix ~= nil and suffix ~= "" then
		return string.format("term://%s/%s", base, suffix)
	end
	return "term://" .. base
end

local function rename_term_buf(buf, label, suffix)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	pcall(vim.api.nvim_buf_set_name, buf, term_buf_name(label, suffix))
end

local function focus_term_if_open(term, source_win)
	if term == nil then
		return false
	end
	if not is_valid_win(term.window) then
		return false
	end

	statusline.inherit(term.window, source_win)
	vim.api.nvim_set_current_win(term.window)
	vim.cmd("startinsert")
	return true
end

local function open_panel_terminal(Terminal, container_id, shell, source_win, label)
	if float_session ~= nil and float_session.container_id ~= container_id then
		pcall(function()
			float_session.term:close()
		end)
		float_session = nil
	end

	if float_session == nil then
		local ok_new, term = pcall(Terminal.new, Terminal, {
			cmd = build_exec_cmd(container_id, shell),
			direction = "float",
			hidden = true,
			close_on_exit = true,
			display_name = label,
			float_opts = {
				border = "curved",
				zindex = 260,
				width = math.floor(vim.o.columns * 0.7),
				height = math.floor(vim.o.lines * 0.5),
			},
			on_open = function(t)
				mark_listed(t and t.bufnr)
				rename_term_buf(t and t.bufnr, label, "float")
				vim.cmd("startinsert")
			end,
			on_exit = function(t)
				vim.schedule(function()
					if t ~= nil and is_valid_win(t.window) then
						pcall(vim.api.nvim_win_close, t.window, true)
					end
				end)
				float_session = nil
			end,
		})
		if not ok_new then
			vim.notify("Dockyard: failed to create toggleterm session", vim.log.levels.ERROR)
			return false
		end

		float_session = {
			container_id = container_id,
			term = term,
		}
	end

	if focus_term_if_open(float_session.term, source_win) then
		return true
	end

	local ok_open = pcall(function()
		float_session.term:open()
	end)
	if not ok_open then
		vim.notify("Dockyard: failed to open toggleterm session", vim.log.levels.ERROR)
		return false
	end

	if is_valid_win(float_session.term.window) then
		statusline.inherit(float_session.term.window, source_win)
	end

	return true
end

local function open_full_terminal(Terminal, container_id, shell, target_win, source_win, label)
	local session = toggleterm_sessions[container_id]
	if session == nil then
		local ok_new, new_session = pcall(Terminal.new, Terminal, {
			cmd = build_exec_cmd(container_id, shell),
			direction = "horizontal",
			hidden = true,
			close_on_exit = true,
			size = 15,
			display_name = label,
			on_open = function(t)
				mark_listed(t and t.bufnr)
				rename_term_buf(t and t.bufnr, label)
				vim.cmd("startinsert")
			end,
			on_exit = function(t)
				vim.schedule(function()
					if t ~= nil and is_valid_win(t.window) then
						pcall(vim.api.nvim_win_close, t.window, true)
					end
				end)
				toggleterm_sessions[container_id] = nil
			end,
		})
		if not ok_new then
			vim.notify("Dockyard: failed to create toggleterm session", vim.log.levels.ERROR)
			return false
		end

		session = new_session
		toggleterm_sessions[container_id] = session
	end

	if focus_term_if_open(session, source_win) then
		return true
	end

	local ok_open = pcall(function()
		if is_valid_win(target_win) then
			vim.api.nvim_set_current_win(target_win)
		end
		session:open()
	end)
	if not ok_open then
		vim.notify("Dockyard: failed to open toggleterm session", vim.log.levels.ERROR)
		return false
	end

	if is_valid_win(session.window) then
		statusline.inherit(session.window, source_win)
	end

	return true
end

-- ----------------------------
-- Toggleterm backend
-- ----------------------------
local function open_with_toggleterm(container_id, shell, ctx)
	local ok, mod = pcall(require, "toggleterm.terminal")
	if not ok then
		return false
	end

	local Terminal = mod.Terminal
	local mode = (ctx and ctx.mode) or "panel"
	local target_win = ctx and ctx.win
	local source_win = is_valid_win(target_win) and target_win or vim.api.nvim_get_current_win()
	local label = (ctx and ctx.name) or container_id

	if mode == "panel" then
		return open_panel_terminal(Terminal, container_id, shell, source_win, label)
	end

	-- For all other modes (full/tab/split/vsplit/current/float alias) use a
	-- horizontal split. This keeps T working no matter how Dockyard was opened.
	return open_full_terminal(Terminal, container_id, shell, target_win, source_win, label)
end

-- ----------------------------
-- Native terminal backend (fallback when toggleterm is absent)
-- ----------------------------
local function open_native_float(container_id, shell, label)
	if native_float ~= nil and native_float.container_id ~= container_id then
		if is_valid_win(native_float.win) then
			pcall(vim.api.nvim_win_close, native_float.win, true)
		end
		if native_float.buf ~= nil and vim.api.nvim_buf_is_valid(native_float.buf) then
			pcall(vim.api.nvim_buf_delete, native_float.buf, { force = true })
		end
		native_float = nil
	end

	if native_float ~= nil and is_valid_win(native_float.win) and native_float.buf ~= nil and vim.api.nvim_buf_is_valid(native_float.buf) then
		vim.api.nvim_set_current_win(native_float.win)
		vim.cmd("startinsert")
		return true
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	mark_listed(buf)

	local width = math.floor(vim.o.columns * 0.7)
	local height = math.floor(vim.o.lines * 0.5)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 260,
	})
	vim.api.nvim_set_option_value("winblend", 0, { win = win })

	local cmd = build_exec_cmd(container_id, shell)
	-- Use termopen so we get on_exit handling; fall back to :terminal
	local ok = pcall(vim.fn.termopen, cmd, {
		on_exit = function()
			vim.schedule(function()
				if is_valid_win(win) then
					pcall(vim.api.nvim_win_close, win, true)
				end
				if vim.api.nvim_buf_is_valid(buf) then
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
				end
				if native_float and native_float.buf == buf then
					native_float = nil
				end
			end)
		end,
	})
	if not ok then
		-- Fallback: :terminal (Neovim 0.10+ always has it)
		vim.api.nvim_win_set_buf(win, buf)
		vim.fn.termopen(cmd)
	end
	rename_term_buf(buf, label, "float")
	vim.cmd("startinsert")
	native_float = { container_id = container_id, buf = buf, win = win }
	return true
end

local function open_native_split(container_id, shell, target_win, label)
	local sess = native_sessions[container_id]
	if sess ~= nil and is_valid_win(sess.win) and sess.buf ~= nil and vim.api.nvim_buf_is_valid(sess.buf) then
		vim.api.nvim_set_current_win(sess.win)
		vim.cmd("startinsert")
		return true
	end

	if is_valid_win(target_win) then
		vim.api.nvim_set_current_win(target_win)
	end
	vim.cmd("15split")
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	mark_listed(buf)

	local cmd = build_exec_cmd(container_id, shell)
	local ok = pcall(vim.fn.termopen, cmd, {
		on_exit = function()
			vim.schedule(function()
				if is_valid_win(win) then
					pcall(vim.api.nvim_win_close, win, true)
				end
				if vim.api.nvim_buf_is_valid(buf) then
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
				end
				if native_sessions[container_id] and native_sessions[container_id].buf == buf then
					native_sessions[container_id] = nil
				end
			end)
		end,
	})
	if not ok then
		vim.fn.termopen(cmd)
	end
	rename_term_buf(buf, label)
	vim.cmd("startinsert")
	native_sessions[container_id] = { buf = buf, win = win }
	return true
end

local function open_with_native(container_id, shell, ctx)
	local mode = (ctx and ctx.mode) or "panel"
	local target_win = ctx and ctx.win
	local label = (ctx and ctx.name) or container_id
	-- Mirror toggleterm's mode split: panel -> float, otherwise -> split.
	-- For all non-panel modes (full/tab/split/vsplit/current) a horizontal split is the
	-- most predictable native fallback and matches toggleterm's full behaviour.
	if mode == "panel" then
		return open_native_float(container_id, shell, label)
	end
	return open_native_split(container_id, shell, target_win, label)
end

function M.open(container_id, shell, ctx)
	if container_id == nil or container_id == "" then
		vim.notify("Dockyard: no container selected", vim.log.levels.WARN)
		return
	end

	if open_with_toggleterm(container_id, shell, ctx) then
		return
	end

	if open_with_native(container_id, shell, ctx) then
		return
	end

	vim.notify("Dockyard: failed to open terminal", vim.log.levels.ERROR)
end

return M