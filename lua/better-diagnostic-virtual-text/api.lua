local vim, type, ipairs = vim, type, ipairs
local api, fn, diag = vim.api, vim.fn, vim.diagnostic
local autocmd, strdisplaywidth, tbl_insert = api.nvim_create_autocmd, fn.strdisplaywidth, table.insert

local ns = api.nvim_create_namespace("better-diagnostic-virtual-text")
local config = require("better-diagnostic-virtual-text.config")

local SEVERITY_SUFFIXS = { "Error", "Warn", "Info", "Hint" }
local TAB_LENGTH = strdisplaywidth("\t")

--- Creates a new group name for a buffer.
--- @param bufnr integer The buffer number
local make_group_name = function(bufnr)
	return "BetterDiagnosticVirtualText" .. bufnr
end

local M = {}

--- @type table<integer, boolean> Buffers that are attached.
local buffers_attached = {}

--- @type table<integer, boolean> Buffers that are disabled.
local buffers_disabled = {}

--- @type table<integer, table<table, table>> Extmark cache for diagnostics.
--- Key: buffer number
--- Value: table with diagnostic table as key, and another table as value containing:
---  - should_display_below: boolean
---  - offset: integer
---  - wrap_length: integer
---  - removed_parts: ExtmarkRemovedPart
---  - msgs: table
---  - size: integer
local extmark_cache = setmetatable({}, {
	__index = function(t, bufnr)
		t[bufnr] = {}
		return t[bufnr]
	end,
})

local diagnostics_cache = {}

do
	---@type table<integer, BufferDiagnostic> Real diagnostics cache.
	--- ex:
	--- {
	---   [`1`] = {
	---     [`1`] = {
	---       [`0`] = 1, -- number of diagnostics in the line
	---       [`vim.Diagnostic`] = vim.Diagnostic,
	---       [`vim.Diagnostic`] = vim.Diagnostic,
	---     }
	---   [`2`] = {
	---   ...
	---   }
	--- }
	local real_diagnostics_cache = {}

	--- Inspects the diagnostics cache for debugging purposes.
	--- @return table: A clone of the diagnostics cache.
	diagnostics_cache.inspect = function()
		local clone_table = {}
		for bufnr, diagnostics in pairs(real_diagnostics_cache) do
			clone_table[bufnr] = diagnostics.raw()
		end
		return clone_table
	end

	--- Iterates through each line of diagnostics in a specified buffer and invokes a callback function for each line.
	--- @param bufnr integer The buffer number for which to iterate through diagnostics.
	--- @param callback fun(lnum: integer, diagnostics: table<vim.Diagnostic, vim.Diagnostic>)
	diagnostics_cache.foreach_line = function(bufnr, callback)
		local buf_diagnostics = real_diagnostics_cache[bufnr]
		if not buf_diagnostics then
			return
		end
		local raw_pairs = pairs
		pairs = function(t)
			local metatable = getmetatable(t)
			if metatable and metatable.__pairs then
				return metatable.__pairs(t)
			end
			return raw_pairs(t)
		end
		for lnum, diagnostics in pairs(buf_diagnostics.raw()) do
			callback(lnum, diagnostics)
		end
		pairs = raw_pairs
	end

	--- Check if the diagnostics cache exist for a buffer
	--- @param bufnr integer The buffer number
	diagnostics_cache.exist = function(bufnr)
		return real_diagnostics_cache[bufnr] ~= nil
	end

	--- Update the diagnostics cache for a buffer.
	--- @param bufnr integer The buffer number.
	--- @param diagnostics ? vim.Diagnostic[] The list of diagnostics to update. If not provided it will get all diagnostics of current bufnr
	diagnostics_cache.update = function(bufnr, diagnostics)
		extmark_cache[bufnr] = {}
		real_diagnostics_cache[bufnr] = nil -- no need to call __newindex from the diagnostics_cache
		local exists_diags_bufnr = diagnostics_cache[bufnr]
		for _, d in ipairs(diagnostics or diag.get(bufnr)) do
			exists_diags_bufnr[d.lnum + 1] = d
		end
	end

	--- Updates the diagnostics cache for the buffer at a line
	--- @param bufnr integer The buffer number
	--- @param line integer The line number
	--- @param diagnostic vim.Diagnostic The new diagnostic to add to cache, or a list to update the line
	diagnostics_cache.update_line = function(bufnr, line, diagnostic)
		diagnostics_cache[bufnr][line] = diagnostic
	end

	setmetatable(diagnostics_cache, {
		--- Just for removal the key from the cache
		__newindex = function(_, bufnr, _)
			real_diagnostics_cache[bufnr] = nil
		end,

		--- @param bufnr integer The buffer number being accessed
		--- @return table: The table of diagnostics for the buffer
		__index = function(_, bufnr)
			if real_diagnostics_cache[bufnr] then
				return real_diagnostics_cache[bufnr]
			else
				local buffer = require("better-diagnostic-virtual-text.Buffer").new()
				real_diagnostics_cache[bufnr] = buffer
				return buffer
			end
		end,
	})

	setmetatable(buffers_attached, {
		__newindex = function(t, bufnr, value)
			autocmd("BufWipeout", {
				once = true,
				buffer = bufnr,
				callback = function()
					rawset(t, bufnr, nil)
					buffers_disabled[bufnr] = nil
					extmark_cache[bufnr] = nil
					real_diagnostics_cache[bufnr] = nil
					api.nvim_del_augroup_by_name(make_group_name(bufnr))
				end,
			})
			rawset(t, bufnr, value)
		end,
	})

	if not vim.g.loaded_better_diagnostic_virtual_text_toggle then
		-- overwrite diagnostic.enable
		local raw_enable = diag.enable
		---@diagnostic disable-next-line: duplicate-set-field
		diag.enable = function(enabled, filter)
			raw_enable(enabled, filter)
			local bufnr = filter and filter.bufnr
			if not bufnr or bufnr == 0 then
				bufnr = api.nvim_get_current_buf()
			end

			if not enabled then
				if not buffers_disabled[bufnr] then -- already disabled
					buffers_disabled[bufnr] = true
					api.nvim_exec_autocmds("User", {
						pattern = "BetterDiagnosticVirtualTextDisabled",
						data = bufnr,
					})
				end
			else
				if buffers_disabled[bufnr] then
					buffers_disabled[bufnr] = nil
					api.nvim_exec_autocmds("User", {
						pattern = "BetterDiagnosticVirtualTextEnabled",
						data = bufnr,
					})
				end
			end
		end

		vim.g.loaded_better_diagnostic_virtual_text_toggle = true
	end
end

--- This function is used to inspect the diagnostics cache for debug
M.inspect_cache = function()
	vim.schedule(function()
		vim.notify(vim.inspect(diagnostics_cache.inspect()), vim.log.levels.INFO, { title = "Diagnostics Cache" })
	end)
end

---
--- Iterates through each line of diagnostics in a specified buffer and invokes a callback function for each line.
--- Ensures compatibility with Lua versions older than 5.2 by using the default `pairs` function directly, or with a custom `pairs` function that handles diagnostic metadata.
---
--- Example:
--- ```lua
--- local meta_pairs = function(t)
---   local metatable = getmetatable(t)
---   if metatable and metatable.__pairs then
---       return metatable.__pairs(t)
---   end
---   return pairs(t)
--- end
--- ```
---
--- If you choose not to use the above custom `meta_pairs` function, ensure that you check and skip the key `0` in the loop of diagnostics within the callback function to avoid errors.
--- The key `0` is used to store the number of diagnostics in the line.
---
--- @param bufnr integer The buffer number for which to iterate through diagnostics.
--- @param callback fun(lnum: integer, diagnostics: table<vim.Diagnostic, vim.Diagnostic>)
M.foreach_line = function(bufnr, callback)
	diagnostics_cache.foreach_line(bufnr, callback)
end

--- Updates the diagnostics cache
--- @param bufnr integer The buffer number
--- @param line integer The line number
--- @param diagnostic vim.Diagnostic The new diagnostic to track or list of diagnostics in a line to update
M.update_diagnostics_cache = function(bufnr, line, diagnostic)
	diagnostics_cache[bufnr][line] = diagnostic
end

--- Clears the diagnostics extmarks for a buffer.
--- @param bufnr integer The buffer number to clear the diagnostics for.
M.clear_extmark_cache = function(bufnr)
	extmark_cache[bufnr] = {}
end

--- Gets the cursor position in the buffer and returns the line and column numbers.
--- @param bufnr integer The buffer number
--- @return integer: The line number of the cursor
--- @return integer: The column number of the cursor
local get_cursor = function(bufnr)
	local cursor_pos = api.nvim_win_get_cursor(bufnr)
	return cursor_pos[1], cursor_pos[2]
end

--- Wraps text into lines with maximum length
--- @param text string the text to wrap
--- @param max_length integer the maximum length of each line
--- @return string[]: The wrapped lines
--- @return integer: The number of lines
local wrap_text = function(text, max_length)
	local lines = {}
	local num_line = 0

	local text_length = #text
	local line_start = 1
	local line_end = line_start + max_length - 1

	while line_end < text_length do
		-- Find the last space before line_end to split the line
		while line_end > line_start and text:byte(line_end) ~= 32 do
			line_end = line_end - 1
		end

		num_line = num_line + 1
		if line_end > line_start then -- space found
			lines[num_line] = text:sub(line_start, line_end - 1) -- not included space
		else
			line_end = line_start + max_length - 1 - 1 -- get old line_end minus 1 for add "-" char
			lines[num_line] = text:sub(line_start, line_end) .. "-"
		end

		line_start = line_end + 1
		line_end = line_start + max_length - 1
	end

	if line_start < text_length then
		num_line = num_line + 1
		lines[num_line] = text:sub(line_start, text_length)
	end
	return lines, num_line
end

--- Counts the number of leading spaces in a string. Converts tabs to corresponding spaces.
--- @param str string The string to count the leading spaces in.
--- @return integer: The number of leading spaces in the string.
--- @return boolean: Whether the string is all spaces.
local count_indent_spaces = function(str)
	local i = 1
	local sum = 0
	local byte = str:byte(i)
	while byte == 32 or byte == 9 do
		sum = sum + (byte == 32 and 1 or TAB_LENGTH)
		i = i + 1
		byte = str:byte(i)
	end
	return sum, byte == nil
end

-- --- This function modifies the original list.
-- --- @param list table The list to sort.
-- --- @param comparator function The comparator function.
-- --- @param list_size ? integer The size of the list. Defaults to the length of the list.
-- --- @return table The sorted list.
-- local function insertion_sort(list, comparator, list_size)
-- 	list_size = list_size or #list
-- 	for i = 2, list_size do
-- 		for j = i, 2, -1 do
-- 			if comparator(list[j], list[j - 1]) then
-- 				list[j], list[j - 1] = list[j - 1], list[j]
-- 			else
-- 				break
-- 			end
-- 		end
-- 	end
-- 	return list
-- end

--- Inserts a value into a sorted list using a comparator function.
--- The list remains sorted after the insertion.
--- @generic T
--- @param list T[] The sorted list to insert the value into.
--- @param value T The value to insert into the list.
--- @param comparator fun(a: T, b: T): boolean The comparator function to sort the list.
--- @param list_size ? integer The current size of the list. If not provided, it is calculated.
--- @return T[]: The list with the value inserted.
--- @return integer: The new size of the list.
local function insert_sorted(list, value, comparator, list_size)
	local new_size = (list_size or #list) + 1
	local i = new_size

	while i > 1 and comparator(value, list[i - 1]) do
		list[i] = list[i - 1]
		i = i - 1
	end
	list[i] = value
	return list, new_size
end

--- Generates a string of spaces of the specified length.
--- @param num integer The total number of spaces to generate.
--- @return string: A string consisting of `num` spaces.
local space = function(num)
	if num < 1 then
		return ""
	elseif num < 160 then
		return string.rep(" ", num)
	end

	if num % 2 == 0 then
		-- 2, 4, 6, 8, 10, 12, 14, 16
		local presets =
			{ "  ", "    ", "      ", "        ", "          ", "            ", "              ", "                " }
		for i = 16, 4, -2 do
			if num % i == 0 then
				return string.rep(presets[i / 2], num / i)
			end
		end
		return string.rep(presets[1], num / 2)
	end

	-- 1, 3, 5, 7, 9, 11, 13, 15
	local presets = { " ", "   ", "     ", "       ", "         ", "           ", "             ", "               " }
	for i = 15, 3, -2 do
		if num % i == 0 then
			return string.rep(presets[(i + 1) / 2], num / i)
		end
	end
	return string.rep(presets[1], num)
end

--- Compare the severity of two objects in ascending order.
--- @param d1 vim.Diagnostic The first object with a `severity` attribute.
--- @param d2 vim.Diagnostic The second object with a `severity` attribute.
--- @return boolean: Whether the first object has a higher severity than the second.
local compare_severity = function(d1, d2)
	return d1.severity < d2.severity
end

--- Retrieves diagnostics at the line position in the specified buffer.
--- Diagnostics are filtered and sorted by severity, with the most severe ones first.
---
--- @param bufnr integer The buffer number
--- @param line  integer The line number
--- @param recompute ? boolean Whether the diagnostics are recompute
--- @param comparator ? fun(a: vim.Diagnostic, b: vim.Diagnostic): boolean The comparator function to sort the diagnostics. If not provided, the diagnostics are not sorted.
--- @param finish_soon ? boolean|fun(diagnostic: vim.Diagnostic) If true, stops processing sort when a finish_soon(d) return true or finish_soon is boolean and severity 1 diagnostic is found under the cursor. When stop immediately the return value is the list with only found diagnostic. This parmater only work if comparator is provided
--- @return vim.Diagnostic[]: A table containing diagnostics in the line
--- @return integer: The number of diagnostics in the line
M.fetch_diagnostics = function(bufnr, line, recompute, comparator, finish_soon)
	local has_cb_finish_soon = type(finish_soon) == "function"

	if recompute then
		local diagnostics = diag.get(bufnr, { lnum = line - 1 })
		diagnostics_cache[bufnr][line] = diagnostics
		local diagnostics_size = #diagnostics
		if diagnostics_size == 0 or type(comparator) ~= "function" then
			return diagnostics, diagnostics_size
		end
		local sorted_diagnostics = {}
		for i = 1, diagnostics_size do
			local d = diagnostics[i]
			---@diagnostic disable-next-line: need-check-nil
			if has_cb_finish_soon and finish_soon(d) or (finish_soon and d.severity == 1) then
				return { d }, 1
			end
			sorted_diagnostics = insert_sorted(sorted_diagnostics, d, comparator, i - 1)
		end
		return sorted_diagnostics, diagnostics_size
	else
		local dc = diagnostics_cache[bufnr][line]
		if not dc then
			return {}, 0
		end
		local diagnostics = {}
		if type(comparator) ~= "function" then
			for i, d in dc.ipairs() do
				---@diagnostic disable-next-line: need-check-nil
				if (has_cb_finish_soon and finish_soon(d)) or (finish_soon and d.severity == 1) then
					return { d }, 1
				end
				diagnostics[i] = d
			end
			return diagnostics, dc[0]
		else
			local diagnostics_size = 0
			for _, d in dc.pairs() do
				---@diagnostic disable-next-line: need-check-nil
				if (has_cb_finish_soon and finish_soon(d)) or (finish_soon and d.severity == 1) then
					return { d }, 1
				end
				diagnostics, diagnostics_size = insert_sorted(diagnostics, d, comparator, diagnostics_size)
			end
			return diagnostics, diagnostics_size
		end
	end
end

---
--- Retrieves diagnostics at the current cursor position in the specified buffer.
--- Diagnostics are filtered and sorted by severity, with the most severe ones first.
---
--- @param bufnr integer The buffer number to get diagnostics for.
--- @param current_line ? integer The current line number. Defaults to the cursor line.
--- @param current_col ? integer The current column number. Defaults to the cursor column.
--- @param recompute ? boolean Whether the diagnostics are recompute
--- @param comparator ? fun(a: vim.Diagnostic, b: vim.Diagnostic): boolean The comparator function to sort the diagnostics. If not provided, the diagnostics are not sorted.
--- @param finish_soon ? boolean|fun(diagnostic: vim.Diagnostic) If true, stops processing sort when a finish_soon(d) return true or finish_soon is boolean and severity 1 diagnostic is found under the cursor. When stop immediately the return value is the list with only found diagnostic. This parmater only work if comparator is provided
--- @return vim.Diagnostic[]: The diagnostics at the cursor position in the line.
--- @return integer: The number of diagnostics at the cursor position in the line.
--- @return vim.Diagnostic[]: The full list of diagnostics in the line.
--- @return integer: The number of diagnostics in the line.
M.fetch_cursor_diagnostics = function(bufnr, current_line, current_col, recompute, comparator, finish_soon)
	if type(current_line) ~= "number" then
		current_line = api.nvim_win_get_cursor(0)[1]
	end
	local diagnostics, diagnostics_size = M.fetch_diagnostics(bufnr, current_line, recompute, comparator)

	if type(current_col) ~= "number" then
		current_col = api.nvim_win_get_cursor(0)[2]
	end
	local cursor_diagnostics = {}
	local cursor_diagnostics_size = 0
	for _, d in ipairs(diagnostics) do
		local has_cb_finish_soon = type(finish_soon) == "function"
		if current_col >= d.col and current_col < d.end_col then
			---@diagnostic disable-next-line: need-check-nil
			if (has_cb_finish_soon and finish_soon(d)) or (finish_soon and d.severity == 1) then
				return { d }, 1, diagnostics, diagnostics_size
			end
			cursor_diagnostics_size = cursor_diagnostics_size + 1
			cursor_diagnostics[cursor_diagnostics_size] = d
		end
	end

	return cursor_diagnostics, cursor_diagnostics_size, diagnostics, diagnostics_size
end

--- Function to get the diagnostic under the cursor with the highest severity.
---
--- @param bufnr integer The buffer number to get the diagnostics for.
--- @param current_line ? integer The current line number. Defaults to the cursor line.
--- @param current_col ? integer The current column number. Defaults to the cursor column.
--- @param recompute ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @return vim.Diagnostic: The diagnostic with the highest severity at the cursor position.
--- @return vim.Diagnostic[]: The full list of diagnostics at the cursor position.
--- @return integer: The number of diagnostics at the cursor position.
M.fetch_top_cursor_diagnostic = function(bufnr, current_line, current_col, recompute)
	local cursor_diags, _, diags, diags_size =
		M.fetch_cursor_diagnostics(bufnr, current_line, current_col, recompute, compare_severity, true)
	return cursor_diags[1], diags, diags_size
end

--- Format line chunks for virtual text display.
---
--- This function formats the line chunks for virtual text display, considering various options such as severity,
--- underline symbol, text offsets, and parts to be removed.
---
--- @param ui_opts UIConfig The table of UI options.
--- @param line_idx number The index of the current line (1-based). It start from the cursor line to above or below depend on the above option.
--- @param line_msg string The message to display on the line.
--- @param severity ? vim.diagnostic.Severity The severity level of the diagnostic (1 = Error, 2 = Warn, 3 = Info, 4 = Hint).
--- @param max_line_length number The maximum length of the line.
--- @param lasted_line boolean  Whether this is the last line of the diagnostic message. Please check line_idx == 1 to know the first line before checking lasted_line because the first line can be the lasted line if the message has only one line.
--- @param virt_text_offset number  The offset for virtual text positioning.
--- @param should_display_below boolean  Whether to display the virtual text below the line. If above is true, this option will be whether the virtual text should be above
--- @param above_instead boolean  Display above or below
--- @param removed_parts ExtmarkRemovedPart  A table indicating which parts should be deleted and make room for message (e.g., arrow, left_kept_space, right_kept_space).
--- @param diagnostic vim.Diagnostic  The diagnostic to display. see `:help vim.Diagnostic.` for more information.
--- @return table<string,string[]>: Chunks of the line to display as virtual text.
--- @see vim.api.nvim_buf_set_extmark
M.format_line_chunks = function(
	ui_opts,
	line_idx,
	line_msg,
	severity,
	max_line_length,
	lasted_line,
	virt_text_offset,
	should_display_below,
	above_instead,
	removed_parts,
	---@diagnostic disable-next-line: unused-local
	diagnostic
)
	local chunks = {}
	local first_line = line_idx == 1
	local severity_suffix = SEVERITY_SUFFIXS[severity]

	local function hls(extend_hl_groups)
		local default_groups = {
			"DiagnosticVirtualText" .. severity_suffix,
			"BetterDiagnosticVirtualText" .. severity_suffix,
		}
		if extend_hl_groups then
			for i, hl in ipairs(extend_hl_groups) do
				default_groups[2 + i] = hl
			end
		end
		return default_groups
	end

	local message_highlight = hls()

	if should_display_below then
		local arrow_symbol = (above_instead and ui_opts.down_arrow or ui_opts.up_arrow):match("^%s*(.*)")
		local space_offset = space(virt_text_offset)
		if first_line then
			if not removed_parts.arrow then
				tbl_insert(chunks, {
					space_offset .. arrow_symbol,
					hls({ "BetterDiagnosticVirtualTextArrow", "BetterDiagnosticVirtualTextArrow" .. severity_suffix }),
				})
			end
		else
			tbl_insert(chunks, {
				space_offset .. space(strdisplaywidth(arrow_symbol)),
				message_highlight,
			})
		end
	else
		local arrow_symbol = ui_opts.arrow
		if first_line then
			if not removed_parts.arrow then
				tbl_insert(chunks, {
					arrow_symbol,
					hls({ "BetterDiagnosticVirtualTextArrow", "BetterDiagnosticVirtualTextArrow" .. severity_suffix }),
				})
			end
		else
			tbl_insert(chunks, {
				space(virt_text_offset + strdisplaywidth(arrow_symbol)),
				message_highlight,
			})
		end
	end

	if not removed_parts.left_kept_space then
		local tree_symbol = "   "
		if first_line then
			if not lasted_line then
				tree_symbol = above_instead and " └ " or " ┌ "
			end
		elseif lasted_line then
			tree_symbol = above_instead and " ┌ " or " └ "
		else
			tree_symbol = " │ "
		end
		tbl_insert(chunks, {
			tree_symbol,
			hls({ "BetterDiagnosticVirtualTextTree", "BetterDiagnosticVirtualTextTree" .. severity_suffix }),
		})
	end

	tbl_insert(chunks, {
		line_msg,
		message_highlight,
	})

	if not removed_parts.right_kept_space then
		local last_space = space(max_line_length - strdisplaywidth(line_msg) + ui_opts.right_kept_space)
		tbl_insert(chunks, { last_space, message_highlight })
	end

	return chunks
end

--- Calculates the offset and wrap length of virtual text based on UI options.
---
--- This function evaluates whether the current line length is under the minimum wrap length
--- and calculates the appropriate wrap length for virtual text. It also determines which parts
--- of the text (e.g., arrows, spaces) should be removed to fit within the wrap length.
---
--- @param ui_opts UIConfig A table containing UI settings
--- @param line_num ? integer The line number to evaluate. If not provided, the current line is used.
--- @return boolean: Whether to display the virtual text above or below the line.
--- @return number: The offset of the virtual text from the left edge of the window.
--- @return number: The wrap length for the virtual text.
--- @return ExtmarkRemovedPart: A table indicating which parts should be removed to fit the virtual text within the wrap length.
local evaluate_extmark = function(ui_opts, line_num)
	local window_info = fn.getwininfo(api.nvim_get_current_win())[1] -- First entry
	local text_area_width = window_info.width - window_info.textoff
	local line_text = line_num and api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]
		or api.nvim_get_current_line()
	local leftcol = fn.winsaveview().leftcol
	local offset = strdisplaywidth(line_text) - leftcol

	-- Minimum length to be able to create beautiful virtual text
	-- Get the text_area_width in case the window is too narrow
	local MIN_WRAP_LENGTH = math.min(text_area_width, 14)

	local left_arrow_length = strdisplaywidth(ui_opts.arrow)
	local up_arrow_length = strdisplaywidth(ui_opts.above and ui_opts.down_arrow or ui_opts.up_arrow)

	local should_display_below = text_area_width - offset
		< MIN_WRAP_LENGTH
			+ ui_opts.left_kept_space
			+ ui_opts.right_kept_space
			+ math.max(left_arrow_length, up_arrow_length)

	local free_space
	local arrow_length
	if should_display_below then
		local indent_space, only_space = count_indent_spaces(line_text)
		offset = only_space and 0 or leftcol > indent_space and 0 or indent_space - leftcol
		free_space = text_area_width
		arrow_length = up_arrow_length
	else
		offset = offset + 1 -- 1 for eol char
		free_space = text_area_width - offset
		arrow_length = left_arrow_length
	end

	local wrap_length = free_space - ui_opts.left_kept_space - ui_opts.right_kept_space - arrow_length
	local wrap_line_after = ui_opts.wrap_line_after

	if type(wrap_line_after) == "number" and wrap_line_after >= MIN_WRAP_LENGTH then
		wrap_length = math.min(wrap_line_after, wrap_length)
	end

	--- @type ExtmarkRemovedPart
	local removed_parts = {
		"right_kept_space",
		"left_kept_space",
		"arrow",
		right_kept_space = false, -- check if right_kept_space is removed
		left_kept_space = false, -- check if left_kept_space is removed
		arrow = false, -- check if arrow is removed
	}

	local removed_order = 1
	local part = removed_parts[removed_order]
	while wrap_length < MIN_WRAP_LENGTH and part do
		removed_parts[part] = true
		wrap_length = part == "arrow" and wrap_length + arrow_length or wrap_length + ui_opts[part]
		removed_order = removed_order + 1
		part = removed_parts[removed_order]
	end

	return should_display_below, offset, wrap_length, removed_parts
end

--- Generates virtual texts and virtual lines for a diagnostic message.
---
--- This function creates virtual texts and lines for a given diagnostic message based on the provided options.
--- It wraps the diagnostic message if necessary and formats the lines according to the severity and UI settings.
---
--- @param opts Config A table of options, which includes the UI settings and signs to use for the virtual texts.
--- @param diagnostic vim.Diagnostic The diagnostic message to generate the virtual texts for.
--- @param recompute_ui ? boolean Whether to recompute the virtual texts UI. Defaults to false.
--- @return table<string,string[]>[]: The list of virtual text chunks.
--- @return table<string,string[]>[]: The list of virtual lines chunks.
--- @return number: The offset of the virtual text from the left edge of the window.
--- @return boolean: Whether to display the virtual text above or below the line.
local generate_virtual_texts = function(opts, bufnr, diagnostic, recompute_ui)
	local ui_opts = opts.ui
	local should_display_below, offset, wrap_length, removed_parts, msgs, size
	local cache = extmark_cache[bufnr][diagnostic]
	if recompute_ui or not cache then
		should_display_below, offset, wrap_length, removed_parts = evaluate_extmark(ui_opts, diagnostic.lnum + 1)
		msgs, size = wrap_text(diagnostic.message, wrap_length)
		extmark_cache[bufnr][diagnostic] = { should_display_below, offset, wrap_length, removed_parts, msgs, size }
	else
		should_display_below, offset, wrap_length, removed_parts, msgs, size =
			cache[1], cache[2], cache[3], cache[4], cache[5], cache[6]
	end

	local severity = diagnostic.severity
	local above_instead = diagnostic.lnum > 0 and ui_opts.above -- force below if on top of buffer

	local virt_text = M.format_line_chunks(
		ui_opts,
		1,
		msgs[above_instead and size or 1],
		severity,
		wrap_length,
		size == 1,
		offset,
		should_display_below,
		above_instead,
		removed_parts,
		diagnostic
	)

	if size == 1 then
		if should_display_below then
			return {}, { virt_text }, offset, above_instead
		else
			return virt_text, {}, offset, above_instead
		end
	end

	local virt_lines = {}

	if above_instead then
		for i = 1, size - 1 do -- -1 for virt_text
			virt_lines[i] = M.format_line_chunks(
				ui_opts,
				size - i + 1,
				msgs[i],
				severity,
				wrap_length,
				i == 1,
				offset,
				should_display_below,
				above_instead,
				removed_parts,
				diagnostic
			)
		end
		if should_display_below then
			virt_lines[size] = virt_text
			virt_text = {}
		end
	else
		if should_display_below then
			virt_lines[1] = virt_text
			virt_text = {}
		end
		for i = 2, size do -- start from 2 for virt_text
			tbl_insert(
				virt_lines,
				M.format_line_chunks(
					ui_opts,
					i,
					msgs[i],
					severity,
					wrap_length,
					i == size,
					offset,
					should_display_below,
					above_instead,
					removed_parts,
					diagnostic
				)
			)
		end
	end

	return virt_text, virt_lines, offset, above_instead
end

--- Checks if diagnostics exist for a buffer at a line.
--- @param bufnr integer The buffer number to check.
--- @param line integer The line number to check.
--- @return boolean: Whether diagnostics exist at the line.
M.exists_any_diagnostics = function(bufnr, line)
	return diagnostics_cache[bufnr][line] ~= nil
end

---
--- Cleans diagnostics for a buffer.
---
--- @param bufnr integer The buffer number.
--- @param target number|table|boolean|nil Specifies the lines or diagnostic to clean, If nil,
--- do nothin
---   - If a number (line number): Clears diagnostics at the specified line.
---   - If a table:
---     - If `target` is `vim.Diagnostic`: Clears diagnostic.
---     - If `target` is an array of numbers: Clears diagnostics at each line number in the array.
---     - Optional `target.range`: Clears diagnostics within the specified range `[start, end]`.
--- @return boolean: Whether the diagnostics were cleaned.
M.clean_diagnostics = function(bufnr, target)
	if not target then
		return false
	elseif type(target) == "number" then
		return api.nvim_buf_del_extmark(bufnr, ns, target)
	elseif type(target) == "table" then -- clean all diagnostics at line numbers
		if target.lnum then
			return api.nvim_buf_del_extmark(bufnr, ns, target.lnum + 1)
		end

		local cleared = 0
		for _, line in ipairs(target) do
			if api.nvim_buf_del_extmark(bufnr, ns, line) then
				cleared = cleared + 1
			end
		end
		local range = target.range
		if type(range) == "table" then
			api.nvim_buf_clear_namespace(bufnr, ns, range[0] or 0, range[1] or -1)
			return true
		end
		return cleared > 0
	else
		api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		return true
	end
end

--- Displays a diagnostic for a buffer, optionally cleaning existing diagnostics before showing the new one.
--- This function sets virtual text and lines for the diagnostic and highlights the line where the diagnostic is shown.
--- The line where the diagnostic is shown is also the start line of the diagnostic.
--- @param opts ? Config Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param diagnostic vim.Diagnostic The diagnostic to show.
--- @param clean_opts  boolean|number|table|nil Options for cleaning diagnostics before showing the new one.
---                     If a number is provided, it is treated as an extmark ID to delete.
---                     If a table is provided, it should contain line numbers or a range to clear.
--- @param recompute_ui ? boolean Whether to recompute the diagnostics. Defaults to false.
--- @return integer: The line number where the diagnostic was shown.
--- @return vim.Diagnostic: The diagnostic that was shown.
M.show_diagnostic = function(opts, bufnr, diagnostic, clean_opts, recompute_ui)
	if clean_opts then
		M.clean_diagnostics(bufnr, clean_opts)
	end
	opts = opts or config.get()

	local virt_text, virt_lines, offset, above_instead = generate_virtual_texts(opts, bufnr, diagnostic, recompute_ui)
	local virtline = diagnostic.lnum

	local max_buf_line = api.nvim_buf_line_count(bufnr)
	if virtline + 1 > max_buf_line then
		virtline = max_buf_line
	end

	local shown_line = api.nvim_buf_set_extmark(bufnr, ns, virtline, 0, {
		id = virtline + 1,
		virt_text = virt_text,
		hl_eol = true,
		virt_text_win_col = offset,
		virt_text_pos = "overlay",
		virt_lines = virt_lines,
		virt_lines_above = above_instead,
		priority = opts.priority,
		line_hl_group = "CursorLine",
	})
	return shown_line, diagnostic
end

--- Shows the highest severity diagnostic at the line for a buffer, optionally cleaning existing diagnostics before showing the new one.
---
--- @param opts ? Config Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param current_line  integer The current line number. Defaults to the cursor line.
--- @param recompute_diags  boolean|nil Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @param clean_opts boolean|number|table|nil Options for cleaning diagnostics before showing the new one.
--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
--- @return integer: The line number where the diagnostic was shown.
--- @return vim.Diagnostic|nil: The diagnostic that was shown.
--- @return vim.Diagnostic[]: The list of diagnostics at line.
--- @return integer: The size of the diagnostics list.
M.show_top_severity_diagnostic = function(opts, bufnr, current_line, recompute_diags, clean_opts, recompute_ui)
	local diags, diags_size = M.fetch_diagnostics(bufnr, current_line, recompute_diags, compare_severity, true)
	if not diags[1] then
		if clean_opts then
			M.clean_diagnostics(bufnr, clean_opts)
		end
		return -1, nil, {}, 0
	end
	local shown_line, shown_diagnostic = M.show_diagnostic(opts, bufnr, diags[1], clean_opts, recompute_ui)
	return shown_line, shown_diagnostic, diags, diags_size
end

--- Shows the highest severity diagnostic at the cursor position in a buffer.
---
--- @param opts ? Config Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param current_line ? integer The current line number. Defaults to the cursor line.
--- @param current_col ? integer The current column number. Defaults to the cursor column.
--- @param recompute_diags ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @param clean_opts ? boolean|number|table Options for cleaning diagnostics before showing the new one.
--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
--- @return integer: The line number where the diagnostic was shown.
--- @return vim.Diagnostic|nil: The diagnostic that was shown at the cursor position.
--- @return vim.Diagnostic[]: The list of diagnostics at the cursor position.
--- @return integer: The size of the diagnostics list.
M.show_cursor_diagnostic = function(opts, bufnr, current_line, current_col, recompute_diags, clean_opts, recompute_ui)
	local highest_diag, diags, diags_size =
		M.fetch_top_cursor_diagnostic(bufnr, current_line, current_col, recompute_diags)
	highest_diag = highest_diag or diags[1]
	if not highest_diag then
		if clean_opts then
			M.clean_diagnostics(bufnr, clean_opts)
		end
		return -1, nil, {}, 0
	end
	local shown_line, shown_diagnostic = M.show_diagnostic(opts, bufnr, highest_diag, clean_opts, recompute_ui)
	return shown_line, shown_diagnostic, diags, diags_size
end

--- Retrieves the line number to show for a diagnostic.
--- @param diagnostic vim.Diagnostic The diagnostic to get the line number for.
--- @return integer: The line number to show the diagnostic on.
M.get_shown_line_num = function(diagnostic)
	return diagnostic.lnum + 1
end

--- Invokes a callback function when the plugin is enabled for a buffer.
--- @param bufnr integer The buffer number.
--- @param cb function The function to call when the buffer is enabled.
M.when_enabled = function(bufnr, cb)
	if not buffers_disabled[bufnr] then
		cb()
	end
end

--- Sets up diagnostic virtual text for a buffer.
--- @param bufnr integer The buffer number.
--- @param opts ? Config Options for displaying the diagnostic. If not provided, the default options are used.
M.setup_buf = function(bufnr, opts)
	if buffers_attached[bufnr] then
		return
	elseif not diag.is_enabled({
		bufnr = bufnr,
	}) then -- check if the buffer is disabled before attaching
		buffers_disabled[bufnr] = true
	end

	buffers_attached[bufnr] = true

	local autocmd_group = api.nvim_create_augroup(make_group_name(bufnr), { clear = true })
	opts = config.get(opts)

	local prev_line = 1 -- The previous line that cursor was on.
	local text_changing = false
	local prev_cursor_diagnostic = nil
	local scheduled_update = false
	local new_diagnostics = nil
	-- local multiple_lines_changed = false

	if not diagnostics_cache.exist(bufnr) then
		diagnostics_cache.update(bufnr)
	end

	--- @param target number|table|boolean|nil Specifies the lines or diagnostic to clean, If nil, do nothing
	local clean_diagnostics = function(target)
		M.clean_diagnostics(bufnr, target)
	end

	local disable = function()
		prev_line = 1 -- The previous line that cursor was on.
		text_changing = false
		prev_cursor_diagnostic = nil
		extmark_cache[bufnr] = nil
		-- multiple_lines_changed = false
		clean_diagnostics(true)
	end

	--- @param diagnostic vim.Diagnostic The diagnostic to show.
	--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
	local show_diagnostic = function(diagnostic, recompute_ui)
		if diagnostic then
			M.show_diagnostic(opts, bufnr, diagnostic, false, recompute_ui) -- re-render last shown diagnostic
		end
	end

	--- @param current_line integer The current line number.
	--- @param current_col integer The current column number.
	--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
	local show_cursor_diagnostic = function(current_line, current_col, recompute_ui)
		_, prev_cursor_diagnostic = M.show_cursor_diagnostic(
			opts,
			bufnr,
			current_line,
			current_col,
			false,
			prev_cursor_diagnostic,
			recompute_ui
		)
	end

	--- @param line integer The line number to check for diagnostics.
	--- @return boolean True if diagnostics exist at the line, false otherwise.
	local exists_any_diagnostics = function(line)
		return M.exists_any_diagnostics(bufnr, line)
	end

	--- @param line integer The line number to show the top severity diagnostic for.
	--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
	local show_top_severity_diagnostic = function(line, recompute_ui)
		return M.show_top_severity_diagnostic(opts, bufnr, line, false, false, recompute_ui)
	end

	--- @param current_line integer The current line number.
	--- @param current_col integer The current column number.
	local show_diagnostics = function(current_line, current_col, recompute_ui)
		clean_diagnostics(true)
		local shown_lines = {}
		for line, _ in diagnostics_cache[bufnr].pairs() do
			if not shown_lines[line] then
				shown_lines[line] = true
				if line == current_line then
					show_cursor_diagnostic(current_line, current_col, recompute_ui)
				else
					show_top_severity_diagnostic(line, recompute_ui)
				end
			end
		end
	end

	local function when_enabled(cb)
		M.when_enabled(bufnr, cb)
	end

	autocmd("DiagnosticChanged", {
		group = autocmd_group,
		buffer = bufnr,
		desc = "Main event tracker for diagnostics changes",
		callback = function(args)
			new_diagnostics = args.data.diagnostics

			if scheduled_update then
				return
			end

			scheduled_update = true
			-- delay the update to prevent multiple updates in a short time
			vim.defer_fn(function()
				-- If an buffer is closed before the update is executed then buffer will be invalid
				if api.nvim_buf_is_valid(bufnr) then
					scheduled_update = false
					diagnostics_cache.update(bufnr, new_diagnostics)

					when_enabled(function()
						local current_line, current_col = get_cursor(0)

						if opts.inline then
							show_cursor_diagnostic(current_line, current_col)
						else
							show_diagnostics(current_line, current_col)
						end

						-- multiple_lines_changed = false
						text_changing = false
					end)
				end
			end, 300)
		end,
	})

	autocmd({ "CursorMovedI", "CursorMoved", "ModeChanged" }, {
		group = autocmd_group,
		buffer = bufnr,
		callback = function()
			when_enabled(function()
				if text_changing then -- we had another event for text changing
					text_changing = false
					return
				end

				--- just moving cursor, no need to re calculate diagnostics virtual text position so we can use cache
				local current_line, current_col = get_cursor(0)
				if exists_any_diagnostics(current_line) then
					if current_line == prev_line and prev_cursor_diagnostic then
						if
							prev_cursor_diagnostic.col > current_col
							or prev_cursor_diagnostic.end_col - 1 < current_col
						then
							show_cursor_diagnostic(current_line, current_col)
						end
					elseif opts.inline then
						show_cursor_diagnostic(current_line, current_col)
					else -- opts.inline is false
						prev_cursor_diagnostic = nil -- remove previous cursor diagnostic cache to make sure this diagnostic is shown
						show_cursor_diagnostic(current_line, current_col)
						if exists_any_diagnostics(prev_line) then
							show_top_severity_diagnostic(prev_line) -- change last line diagnostic to top severity diagnostic
						end
					end
				elseif opts.inline then
					clean_diagnostics(prev_cursor_diagnostic)
					prev_cursor_diagnostic = nil
				elseif current_line ~= prev_line then -- opts.inline is false
					if exists_any_diagnostics(prev_line) then
						show_top_severity_diagnostic(prev_line)
					end
				end

				prev_line = current_line
				-- multiple_lines_changed = false
			end)
		end,
	})

	-- Attach to the buffer to rerender diagnostics virtual text when the window is resized.
	autocmd({ "WinScrolled" }, {
		buffer = bufnr,
		group = autocmd_group,
		callback = function()
			when_enabled(function()
				extmark_cache[bufnr] = nil -- clear cache to recompute the virtual text
				if opts.inline then
					if prev_cursor_diagnostic then
						show_diagnostic(prev_cursor_diagnostic)
					end
				else
					local current_line, current_col = get_cursor(0)
					show_diagnostics(current_line, current_col)
				end
			end)
		end,
	})

	-- Attach to the buffer to rerender diagnostics virtual text when text changes.
	api.nvim_buf_attach(bufnr, false, {
		on_lines = function(
			---@diagnostic disable-next-line: unused-local
			event,
			---@diagnostic disable-next-line: unused-local
			buffer_handle,
			---@diagnostic disable-next-line: unused-local
			changedtick,
			---@diagnostic disable-next-line: unused-local
			first_line_changed,
			last_line_changed,
			last_line_updated_range,
			---@diagnostic disable-next-line: unused-local
			prev_byte_count
		)
			when_enabled(function()
				text_changing = true
				if last_line_changed ~= last_line_updated_range then -- added or removed line
					-- multiple_lines_changed = true
					local current_line, current_col = get_cursor(0)
					show_cursor_diagnostic(current_line, current_col, true)
				elseif prev_cursor_diagnostic then
					show_diagnostic(prev_cursor_diagnostic, true)
				end
			end)
		end,
	})

	autocmd("User", {
		group = autocmd_group,
		pattern = { "BetterDiagnosticVirtualTextEnabled", "BetterDiagnosticVirtualTextDisabled" },
		callback = function(args)
			if bufnr == args.data then
				if args.match == "BetterDiagnosticVirtualTextEnabled" then
					local current_line, current_col = get_cursor(0)
					if opts.inline then
						if exists_any_diagnostics(current_line) then
							show_cursor_diagnostic(current_line, current_col)
						end
					else
						show_diagnostics(current_line, current_col)
					end
				else
					disable()
				end
			end
		end,
	})
end

return M
