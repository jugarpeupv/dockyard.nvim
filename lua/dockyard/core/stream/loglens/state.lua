---@class LogLensEntry
---@field raw string
---@field formatted string
---@field data table<string, any>
---@field _source_idx? number
---@field _source_name? string

---@class LogLensParserSession
---@field push fun(self: LogLensParserSession, chunk: string): LogLensEntry[]
---@field flush fun(self: LogLensParserSession): LogLensEntry[]

---@class LogLensStateData
---@field win_id number|nil
---@field buf_id number|nil
---@field container Container|nil
---@field container_name string|nil
---@field follow boolean
---@field raw boolean
---@field filter string|nil
---@field entries LogLensEntry[]
---@field line_map table|nil
---@field job_ids number[]
---@field active_source LogSource|nil
---@field sources LogSource[]
---@field active_source_idx number
---@field max_lines number
---@field parser_sessions LogLensParserSession[]

---@class LogLensState: LogLensStateData
---@field reset fun()
---@field is_open fun(): boolean
---@field has_valid_buffer fun(): boolean

local M = {}

---@return LogLensState
function M.new()
	---@type LogLensState
	local state = {
		win_id = nil,
		buf_id = nil,
		container = nil,
		container_name = nil,

		follow = true,
		raw = false,
		filter = nil,

		entries = {},
		line_map = nil,

		job_ids = {},
		active_source = nil,
		sources = {},
		active_source_idx = 0,
		max_lines = 2000,
		parser_sessions = {},
	}

	function state.reset()
		state.win_id = nil
		state.buf_id = nil
		state.container = nil
		state.container_name = nil

		state.follow = true
		state.raw = false
		state.filter = nil

		state.entries = {}
		state.line_map = nil

		state.job_ids = {}
		state.active_source = nil
		state.sources = {}
		state.active_source_idx = 0
		state.max_lines = 2000
		state.parser_sessions = {}
	end

	---@return boolean
	function state.is_open()
		return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
	end

	---@return boolean
	function state.has_valid_buffer()
		return state.buf_id ~= nil and vim.api.nvim_buf_is_valid(state.buf_id)
	end

	return state
end

return M
