-- lua/dooing/ui/file_scratchpad.lua
--
-- File-backed scratchpads for dooing todos.
--
-- Each todo gets a dedicated markdown file on disk.  The directory tree lives
-- alongside the todos JSON so everything travels together:
--
--   <save_path_dir>/
--     dooing_todos.json
--     dooing_scratchpads/
--       <16-char sha256 prefix of todo text>/
--         scratch.md        (or whatever extension is configured)
--
-- The hash is derived from the raw todo text, so it is deterministic and
-- survives Neovim restarts.  Truncating to 16 hex chars keeps directory names
-- readable in a file browser while still being collision-proof in practice.

local M = {}
local state = require("dooing.state")

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

-- Return the config table lazily so we never capture a stale snapshot.
local function cfg()
	return require("dooing.config").options
end

local function scratchpads_root()
	return state.current_scratchpad_save_dir or cfg().scratchpad_save_dir
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Return the absolute path of the scratchpad file for *todo*.
--- Creates no files; purely a path computation.
---@param todo table  A dooing todo object (must have a `.text` field)
---@return string
function M.get_path(todo)
	return state.get_todo_scratchpad_path(todo)
end

--- Return the relative path of the scratchpad file for *todo*.
--- Creates no files; purely a path computation.
---@param todo table  A dooing todo object (must have a `.text` field)
---@return string
function M.get_relative_path(todo)
	local full_path = M.get_path(todo)
	local root = scratchpads_root()
	if not root then
		return full_path
	end
	-- Ensure root ends with /
	if not root:match("/$") then
		root = root .. "/"
	end
	return full_path:sub(#root + 1)
end

--- Return true when a scratchpad file already exists for *todo*.
---@param todo table
---@return boolean
function M.exists(todo)
	return vim.fn.filereadable(M.get_path(todo)) == 1
end

--- Open (creating if necessary) the scratchpad file for *todo*.
---
--- Behaviour:
---   • The dooing floating window is left open; the scratchpad opens in a
---     floating window centered on the screen.
---   • If the file is brand-new an automatic header comment is written so
---     the file is immediately useful even before the user types anything.
---   • The buffer is set to auto-save when focus leaves it, matching the
---     feel of the in-memory scratchpad.
---   • `<localleader>q`  (and plain `q` in normal mode) close the window.
---
---@param todo table
function M.open(todo)
	local path = M.get_path(todo)
	local dir = vim.fn.fnamemodify(path, ":h")
	-- Ensure the directory hierarchy exists.
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	-- Seed a new file with a header so it is not empty on first open.
	if vim.fn.filereadable(path) == 0 then
		local ext = (cfg().scratchpad and cfg().scratchpad.files_extension) or "md"
		local header
		if ext == "md" or ext == "markdown" then
			header = {
				"# " .. todo.text,
				"",
				"<!-- dooing scratchpad – edit freely -->",
				"",
			}
		else
			header = {
				"-- " .. todo.text,
				"-- dooing scratchpad",
				"",
			}
		end
		vim.fn.writefile(header, path)
	end

	-- Check whether the file is already open in an existing window; if so,
	-- just focus that window instead of opening a new floating window.
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		local bname = vim.api.nvim_buf_get_name(buf)
		if bname == path then
			vim.api.nvim_set_current_win(win)
			return
		end
	end

	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)

	local ui = vim.api.nvim_list_uis()[1]
	local width = math.floor(ui.width * 0.6)
	local height = math.floor(ui.height * 0.6)
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = cfg().window.border,
		title = " Scratchpad ",
		title_pos = "center",
		zindex = cfg().window.zindex + 1,
	})

	-- Apply syntax highlighting that matches the scratchpad config.
	local hl = (cfg().scratchpad and cfg().scratchpad.syntax_highlight) or "markdown"
	if hl and hl ~= "" then
		vim.bo[buf].filetype = hl
	end

	local function save_notes()
		todo.notes = M.get_relative_path(todo)
		state.save_todos()
	end
	-- Auto-save whenever the buffer loses focus.
	vim.api.nvim_create_autocmd({ "BufLeave", "FocusLost" }, {
		buffer = buf,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				-- Write without triggering autocmds recursively.
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("silent! write")
				end)
				save_notes()
			end
		end,
		desc = "dooing: auto-save scratchpad on leave",
	})

	-- Convenience close keymaps that feel like the rest of dooing.
	local close = function()
		if vim.api.nvim_win_is_valid(win) then
			-- Save before closing.
			if vim.bo[buf].modified then
				vim.cmd("silent! write")
			end
			vim.api.nvim_win_close(win, false)
			save_notes()
		end
	end

	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "dooing: close scratchpad" })
	vim.keymap.set("n", "<localleader>q", close, { buffer = buf, desc = "dooing: close scratchpad" })

	-- Jump to the end of the file so the user can start writing immediately.
	vim.cmd("normal! G")
end

--- Delete the scratchpad file (and its containing directory) for *todo*.
--- Silently does nothing when no file exists.
---@param todo table
function M.delete(todo)
	local path = M.get_path(todo)
	if vim.fn.filereadable(path) == 1 then
		vim.fn.delete(path)
		-- Remove the hash directory too if it is now empty.
		local dir = vim.fn.fnamemodify(path, ":h")
		if vim.fn.glob(dir .. "/*") == "" then
			vim.fn.delete(dir, "d")
		end
	end
end

--- List all scratchpad paths that exist on disk.
--- Useful for housekeeping / auditing from outside the plugin.
---@return string[]
function M.list_all()
	local root = scratchpads_root()
	if vim.fn.isdirectory(root) == 0 then
		return {}
	end
	return vim.fn.glob(root .. "/**/scratch.*", false, true)
end

return M
