local vim, type, ipairs = vim, type, ipairs
local api, fn, diag = vim.api, vim.fn, vim.diagnostic
local autocmd, strdisplaywidth, tbl_insert = api.nvim_create_autocmd, fn.strdisplaywidth, table.insert
local ns = api.nvim_create_namespace("better-diagnostic-virtual-text")

local SEVERITY_SUFFIXS = { "Error", "Warn", "Info", "Hint" }
local TAB_LENGTH = strdisplaywidth("\t")

local meta_pairs = function(t)
	local metatable = getmetatable(t)
	if metatable and metatable.__pairs then
		return metatable.__pairs(t)
	end
	return pairs(t)
end

local make_group_name = function(bufnr)
	return "BetterDiagnosticVirtualText" .. bufnr
end

local M = {}

local default_options = {
	ui = {
		wrap_line_after = false,
		left_kept_space = 3, --- The number of spaces kept on the left side of the virtual text, make sure it enough to custom for each line
		right_kept_space = 3, --- The number of spaces kept on the right side of the virtual text, make sure it enough to custom for each line
		arrow = "  ",
		up_arrow = "  ",
		down_arrow = "  ",
		above = false,
	},
	inline = true,
}

local buffers_attached = {}
local buffers_disabled = {}

-- extmark_cache: bufnr -> key: diagnostic table, value: { should_display_below, offset, wrap_length, removed_parts, msgs, size }
local extmark_cache = setmetatable({}, {
	__index = function(t, bufnr)
		t[bufnr] = {}
		return t[bufnr]
	end,
})
-- @type table<integer, table<integer, table<string, table>>>>
-- bufnr -> line -> address of diagnostic -> diagnostic
local diagnostics_cache = {}
do
	local real_diagnostics_cache = {}

	--- This function is used to inspect the diagnostics cache for debug
	function diagnostics_cache.inspect()
		local clone_table = {}
		for bufnr, diagnostics in pairs(real_diagnostics_cache) do
			clone_table[bufnr] = diagnostics.real()
		end
		return clone_table
	end

	function diagnostics_cache.foreach_line(bufnr, callback)
		local buf_diagnostics = real_diagnostics_cache[bufnr]
		if not buf_diagnostics then
			return
		end
		local raw_pairs = pairs
		pairs = meta_pairs
		for line, diagnostics in meta_pairs(buf_diagnostics.real()) do
			callback(line, diagnostics)
		end
		pairs = raw_pairs
	end

	function diagnostics_cache.exist(bufnr)
		return real_diagnostics_cache[bufnr] ~= nil
	end

	--- Update the diagnostics cache for a buffer.
	--- @param bufnr integer The buffer number.
	--- @param diagnostics ? table The list of diagnostics to update. If not provided it will get all diagnostics of current bufnr
	function diagnostics_cache.update(bufnr, diagnostics)
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
	--- @param diagnostic table The new diagnostic to add to cache, or a list to update the line
	function diagnostics_cache.update_line(bufnr, line, diagnostic)
		local exists_diags_bufnr = diagnostics_cache[bufnr]
		exists_diags_bufnr[line] = diagnostic
	end

	setmetatable(diagnostics_cache, {
		--- Just for removal the key from the cache
		__newindex = function(_, bufnr, _)
			real_diagnostics_cache[bufnr] = nil
		end,

		--- @param bufnr integer The buffer number being accessed
		--- @return table The table of diagnostics for the buffer
		__index = function(_, bufnr)
			if real_diagnostics_cache[bufnr] then
				return real_diagnostics_cache[bufnr]
			else
				local lines = {}
				local proxy_table = {}

				-- This function is used to inspect the diagnostics cache for debug
				function proxy_table.real()
					return lines
				end

				real_diagnostics_cache[bufnr] = setmetatable(proxy_table, {
					__pairs = function(_)
						---@diagnostic disable: redundant-return-value
						return pairs(lines)
					end,

					__index = function(_, line)
						return lines[line]
					end,

					--- Tracks the existence of diagnostics for a buffer at a line.
					--- @param line integer The lnum of the diagnostic being tracked in 1-based index. It's also the line where the diagnostic is located in the buffer
					--- @param diagnostic table The diagnostic being tracked
					__newindex = function(t, line, diagnostic)
						if diagnostic == nil or not next(diagnostic) then
							-- Untrack this line if `diagnostic` is nil or an empty table.
							local line_diags = lines[line]
							if line_diags then
								for _, d in meta_pairs(line_diags) do
									local lnum, end_lnum = d.lnum + 1, d.end_lnum + 1
									-- The line is the original line of the diagnostic so we need to remove all related lines
									-- If not the diagnostic still exists and should not be removed
									if line == lnum then
										for i = lnum, end_lnum do
											local line_i_diags = lines[i]
											if line_i_diags and line_i_diags[d] and line_i_diags[0] > 1 then
												line_i_diags[d] = nil
												line_i_diags[0] = line_i_diags[0] - 1
											else
												lines[i] = nil
											end
										end
									end
								end
							end
						elseif type(diagnostic[1]) == "table" then
							-- Replace the line with the new diagnostics
							t[line] = nil -- call the __newindex in case nil
							for _, d in ipairs(diagnostic) do
								t[d.lnum + 1] = d -- call the __newindex in case track diagnostic
							end
						elseif diagnostic.end_lnum then
							-- Ensure the diagnostic is not an empty table.
							local end_lnum = diagnostic.end_lnum + 1 -- change to 1-based
							for i = line, end_lnum do
								local line_i_diags = lines[i]
								if not line_i_diags then
									lines[i] = setmetatable({
										[0] = 1,
										[diagnostic] = diagnostic,
									}, {
										__len = function(t1)
											return t1[0]
										end,
										__pairs = function(t1)
											return function(_, k, v)
												k, v = next(t1, k)
												if k == 0 then
													return next(t1, k)
												end
												return k, v
											end
										end,
									})
								elseif not line_i_diags[diagnostic] then
									line_i_diags[diagnostic] = diagnostic
									line_i_diags[0] = line_i_diags[0] + 1
								end
							end
						end
					end,
				})
				return proxy_table
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
function M.inspect_cache()
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
--- @param callback function The callback function to call for each line of diagnostics, with parameters `(line, diagnostics)`.
function M.foreach_diagnostics_line(bufnr, callback)
	diagnostics_cache.foreach_line(bufnr, callback)
end

--- Updates the diagnostics cache
--- @param bufnr integer The buffer number
--- @param line integer The line number
--- @param diagnostic table The new diagnostic to track or list of diagnostics in a line to update
function M.update_diagnostics_cache(bufnr, line, diagnostic)
	diagnostics_cache[bufnr][line] = diagnostic
end

--- Clears the diagnostics extmarks for a buffer.
--- @param bufnr integer The buffer number to clear the diagnostics for.
function M.clear_extmark_cache(bufnr)
	extmark_cache[bufnr] = {}
end

--- Gets the cursor position in the buffer and returns the line and column numbers.
--- @param bufnr integer The buffer number
--- @return integer The line number
--- @return integer The column number
local function get_cursor(bufnr)
	local cursor_pos = api.nvim_win_get_cursor(bufnr)
	return cursor_pos[1], cursor_pos[2]
end

--- Wraps text into lines with maximum length
--- @param text string the text to wrap
--- @param max_length integer the maximum length of each line
--- @return table the wrapped text
--- @return integer the number of lines
local function wrap_text(text, max_length)
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
---
--- @param str string The string to count the leading spaces in.
--- @return number The number of leading spaces in the string.
--- @return boolean Whether the string is all spaces.
local function count_initial_spaces(str)
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

--- This function modifies the original list.
--- @param list table The list to sort.
--- @param comparator function The comparator function.
--- @param list_size ? integer The size of the list. Defaults to the length of the list.
--- @return table The sorted list.
local function insertion_sort(list, comparator, list_size)
	list_size = list_size or #list
	for i = 2, list_size do
		for j = i, 2, -1 do
			if comparator(list[j], list[j - 1]) then
				list[j], list[j - 1] = list[j - 1], list[j]
			else
				break
			end
		end
	end
	return list
end

---
--- Inserts a value into a sorted list using a comparator function.
--- The list remains sorted after the insertion.
---
--- @param list table The sorted list to insert the value into.
--- @param value any The value to insert into the list.
--- @param comparator function A function that takes two values and returns true if the first is less than the second.
--- @param list_size integer|nil The current size of the list. If not provided, it is calculated.
--- @return table The list with the new value inserted and sorted.
--- @return integer The new size of the list.
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
--- This function optimizes the process of generating a string of spaces by
--- checking if the length is divisible by numbers from 10 to 2.
--- substrings to minimize the number of calls to `string.rep`.
--- @param num number The total number of spaces to generate.
--- @return string A string consisting of `num` spaces.
local space = function(num)
	if num < 1 then
		return ""
	elseif num < 160 then
		return string.rep(" ", num)
	end

	if num % 2 == 0 then
		-- 2, 4, 6, 8, 10, 12, 14, 16
		local pre_computes =
			{ "  ", "    ", "      ", "        ", "          ", "            ", "              ", "                " }
		for i = 16, 4, -2 do
			if num % i == 0 then
				return string.rep(pre_computes[i], num / i / 2)
			end
		end
		return string.rep(pre_computes[1], num / 2)
	else
		-- 1, 3, 5, 7, 9, 11, 13, 15
		local pre_computes =
			{ " ", "   ", "     ", "       ", "         ", "           ", "             ", "               " }
		for i = 15, 3, -2 do
			if num % i == 0 then
				return string.rep(pre_computes[i], (num / i - 1) / 2)
			end
		end
		return string.rep(pre_computes[1], num)
	end
end

--- Retrieves diagnostics at the line position in the specified buffer.
--- Diagnostics are filtered and sorted by severity, with the most severe ones first.
---
--- @param bufnr integer The buffer number
--- @param line  integer The line number
--- @param recompute  boolean|nil Whether the diagnostics are recompute
--- @return table The full list of diagnostics for the line sorted by severity
--- @return integer The number of diagnostics in the line
function M.fetch_diagnostics(bufnr, line, recompute)
	local diagnostics
	local diagnostics_size

	if recompute then
		diagnostics = diag.get(bufnr, { lnum = line - 1 })
		diagnostics_size = #diagnostics
		diagnostics_cache[bufnr][line] = diagnostics
		if diagnostics_size == 0 then
			return diagnostics, diagnostics_size
		end
		insertion_sort(diagnostics, function(d1, d2)
			return d1.severity < d2.severity
		end, diagnostics_size)
	else
		local dc = diagnostics_cache[bufnr][line]
		if not dc then
			return {}, 0
		end
		diagnostics = {}
		diagnostics_size = 0

		for k, d in meta_pairs(dc) do
			diagnostics, diagnostics_size = insert_sorted(diagnostics, d, function(d1, d2)
				return d1.severity < d2.severity
			end, diagnostics_size)
		end
	end

	return diagnostics, diagnostics_size
end

---
--- Retrieves diagnostics at the current cursor position in the specified buffer.
--- Diagnostics are filtered and sorted by severity, with the most severe ones first.
---
--- @param bufnr integer The buffer number to get diagnostics for.
--- @param current_line ? integer The current line number. Defaults to the cursor line.
--- @param current_col ? integer The current column number. Defaults to the cursor column.
--- @param recompute ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @return table A table containing diagnostics at the cursor position sorted by severity.
--- @return integer The number of diagnostics at the cursor position in the line sorted by severity.
--- @return table The full list of diagnostics for the line sorted by severity.
--- @return integer The number of diagnostics in the line sorted by severity.
function M.fetch_cursor_diagnostics(bufnr, current_line, current_col, recompute)
	if type(current_line) ~= "number" then
		current_line = api.nvim_win_get_cursor(0)[1]
	end
	local diagnostics, diagnostics_size = M.fetch_diagnostics(bufnr, current_line, recompute)

	if type(current_col) ~= "number" then
		current_col = api.nvim_win_get_cursor(0)[2]
	end
	local cursor_diagnostics = {}
	local cursor_diagnostics_size = 0
	for _, d in ipairs(diagnostics) do
		if current_col >= d.col and current_col < d.end_col then
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
--- @return table A table of diagnostics for the current position and the current line number.
--- @return table The full list of diagnostics for the line.
--- @return integer The number of diagnostics in the list.
function M.fetch_top_cursor_diagnostic(bufnr, current_line, current_col, recompute)
	local cursor_diags, _, diags, diags_size = M.fetch_cursor_diagnostics(bufnr, current_line, current_col, recompute)
	return cursor_diags[1], diags, diags_size
end

--- Format line chunks for virtual text display.
---
--- This function formats the line chunks for virtual text display, considering various options such as severity,
--- underline symbol, text offsets, and parts to be removed.
---
--- @param ui_opts table - The table of UI options. Should contain:
---     - arrow: The symbol used as the left arrow.
---     - up_arrow: The symbol used as the up arrow.
---     - left_kept_space: The space to keep on the left side.
---     - right_kept_space: The space to keep on the right side.
---     - wrap_line_after: The maximum line length to wrap after.
---     - above: Whether to display the virtual text above the line.
--- @param line_idx number - The index of the current line (1-based). It start from the cursor line to above or below depend on the above option.
--- @param line_msg string - The message to display on the line.
--- @param severity number - The severity level of the diagnostic (1 = Error, 2 = Warn, 3 = Info, 4 = Hint).
--- @param max_line_length number - The maximum length of the line.
--- @param lasted_line boolean - Whether this is the last line of the diagnostic message. Please check line_idx == 1 to know the first line before checking lasted_line because the first line can be the lasted line if the message has only one line.
--- @param virt_text_offset number - The offset for virtual text positioning.
--- @param should_display_below boolean - Whether to display the virtual text below the line. If above is true, this option will be whether the virtual text should be above
--- @param removed_parts table - A table indicating which parts should be deleted and make room for message (e.g., arrow, left_kept_space, right_kept_space).
--- @param diagnostic table - The diagnostic to display. see `:help vim.Diagnostic.` for more information.
--- @return table - A list of formatted chunks for virtual text display.
--- @see vim.api.nvim_buf_set_extmark
function M.format_line_chunks(
	ui_opts,
	line_idx,
	line_msg,
	severity,
	max_line_length,
	lasted_line,
	virt_text_offset,
	should_display_below,
	removed_parts,
	diagnostic
)
	local chunks = {}
	local first_line = line_idx == 1
	local above_instead = ui_opts.above
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
		local arrow_symbol = (above_instead and ui_opts.down_arrow or ui_opts.up_arrow):gsub("^%s*", "")
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

	tbl_insert(chunks, { line_msg, message_highlight })

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
--- @param ui_opts table A table containing UI settings, including:
---     - arrow: The symbol used as the left arrow.
---     - up_arrow: The symbol used as the up arrow.
---     - left_kept_space: The space to keep on the left side.
---     - right_kept_space: The space to keep on the right side.
---     - wrap_line_after: The maximum line length to wrap after.
---     - above: Whether to display the virtual text above the line.
--- @param line_num ? integer The line number to evaluate. If not provided, the current line is used.
--- @return boolean is_under_min_length Whether the line length is under the minimum wrap length.
--- @return number begin_offset The offset of the virtual text.
--- @return number wrap_length The calculated wrap length.
--- @return table removed_parts A table indicating which parts were removed to fit within the wrap length.
local function evaluate_extmark(ui_opts, line_num)
	local window_info = fn.getwininfo(api.nvim_get_current_win())[1] -- First entry
	local text_area_width = window_info.width - window_info.textoff
	local line_text = line_num and api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]
		or api.nvim_get_current_line()
	local offset = strdisplaywidth(line_text)

	-- Minimum length to be able to create beautiful virtual text
	-- Get the text_area_width in case the window is too narrow
	local MIN_WRAP_LENGTH = math.min(text_area_width, 14)

	local left_arrow_length = strdisplaywidth(ui_opts.arrow)
	local up_arrow_length = strdisplaywidth(ui_opts.up_arrow)
	local is_under_min_length = text_area_width - offset
		< MIN_WRAP_LENGTH
			+ ui_opts.left_kept_space
			+ ui_opts.right_kept_space
			+ math.max(left_arrow_length, up_arrow_length)

	local free_space
	local arrow_length
	if is_under_min_length then
		local init_spaces, only_space = count_initial_spaces(line_text)
		offset = only_space and 0 or init_spaces
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

	if wrap_length < MIN_WRAP_LENGTH then
		for _, value in ipairs(removed_parts) do
			removed_parts[value] = true
			wrap_length = value == "arrow" and wrap_length + arrow_length or wrap_length + ui_opts[value]

			if wrap_length >= MIN_WRAP_LENGTH then
				break
			end
		end
	end

	return is_under_min_length, offset, wrap_length, removed_parts
end

--- Generates virtual texts and virtual lines for a diagnostic message.
---
--- This function creates virtual texts and lines for a given diagnostic message based on the provided options.
--- It wraps the diagnostic message if necessary and formats the lines according to the severity and UI settings.
---
--- @param opts table A table of options, which includes the UI settings and signs to use for the virtual texts.
--- @param diagnostic table The diagnostic message to generate the virtual texts for.
--- @param recompute_ui ? boolean Whether to recompute the virtual texts UI. Defaults to false.
--- @return table The list of virtual texts.
--- @return table The list of virtual lines.
--- @return number The offset of the virtual text.
local function generate_virtual_texts(opts, bufnr, diagnostic, recompute_ui)
	local ui = opts.ui
	local should_display_below, offset, wrap_length, removed_parts, msgs, size
	local cache = extmark_cache[bufnr][diagnostic]
	if recompute_ui or not cache then
		should_display_below, offset, wrap_length, removed_parts = evaluate_extmark(ui, diagnostic.lnum + 1)
		msgs, size = wrap_text(diagnostic.message, wrap_length)
		extmark_cache[bufnr][diagnostic] = { should_display_below, offset, wrap_length, removed_parts, msgs, size }
	else
		should_display_below, offset, wrap_length, removed_parts, msgs, size =
			cache[1], cache[2], cache[3], cache[4], cache[5], cache[6]
	end
	if size == 0 then
		return {}, {}, offset
	end

	local severity = diagnostic.severity
	local above_instead = ui.above

	local virt_lines = {}

	local initial_idx = above_instead and size or 1

	local virt_text = M.format_line_chunks(
		ui,
		1,
		msgs[initial_idx],
		severity,
		wrap_length,
		size == 1,
		offset,
		should_display_below,
		removed_parts,
		diagnostic
	)
	if should_display_below then
		if size == 1 then
			return {}, { virt_text }, offset
		end
		virt_lines[initial_idx] = virt_text
		virt_text = {}
	end

	if above_instead then
		for i = 1, size - 1 do -- -1 for virt_text
			tbl_insert(
				virt_lines,
				M.format_line_chunks(
					ui,
					size - i + 1,
					msgs[i],
					severity,
					wrap_length,
					i == 1,
					offset,
					should_display_below,
					removed_parts,
					diagnostic
				)
			)
		end
	else
		for i = 2, size do -- start from 2 for virt_text
			tbl_insert(
				virt_lines,
				M.format_line_chunks(
					ui,
					i,
					msgs[i],
					severity,
					wrap_length,
					i == size,
					offset,
					should_display_below,
					removed_parts,
					diagnostic
				)
			)
		end
	end

	return virt_text, virt_lines, offset
end

--- Checks if diagnostics exist for a buffer at a line.
--- @param bufnr integer The buffer number to check.
--- @param line integer The line number to check.
--- @return boolean True if the line is diagnosed, false otherwise.
function M.exists_any_diagnostics(bufnr, line)
	return diagnostics_cache[bufnr][line] ~= nil
end

---
--- Cleans diagnostics for a buffer.
---
--- @param bufnr integer The buffer number.
--- @param lines_or_diagnostic number|table|boolean|nil Specifies the lines or diagnostic to clean, If nil,
--- do nothin
---   - If a number (line number): Clears diagnostics at the specified line.
---   - If a table:
---     - If `lines_or_diagnostic` is `vim.Diagnostic`: Clears diagnostic.
---     - If `lines_or_diagnostic` is an array of numbers: Clears diagnostics at each line number in the array.
---     - Optional `lines_or_diagnostic.range`: Clears diagnostics within the specified range `[start, end]`.
---
--- @return boolean Returns `true` if any diagnostics were cleared, `false` if none were cleared, or `nil`.
function M.clean_diagnostics(bufnr, lines_or_diagnostic)
	if not lines_or_diagnostic then
		return false
	elseif type(lines_or_diagnostic) == "number" then
		return api.nvim_buf_del_extmark(bufnr, ns, lines_or_diagnostic)
	elseif type(lines_or_diagnostic) == "table" then -- clean all diagnostics at line numbers
		if lines_or_diagnostic.lnum then
			return api.nvim_buf_del_extmark(bufnr, ns, lines_or_diagnostic.lnum + 1)
		end

		local cleared = 0
		for _, line in ipairs(lines_or_diagnostic) do
			if api.nvim_buf_del_extmark(bufnr, ns, line) then
				cleared = cleared + 1
			end
		end
		local range = lines_or_diagnostic.range
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
--- @param opts ? table Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param diagnostic table The diagnostic to show.
--- @param clean_opts  boolean|number|table|nil Options for cleaning diagnostics before showing the new one.
---                     If a number is provided, it is treated as an extmark ID to delete.
---                     If a table is provided, it should contain line numbers or a range to clear.
--- @param recompute_ui ? boolean Whether to recompute the diagnostics. Defaults to false.
--- @return integer The start line of the diagnostic where it was shown.
--- @return table The diagnostic that was shown.
function M.show_diagnostic(opts, bufnr, diagnostic, clean_opts, recompute_ui)
	if clean_opts then
		M.clean_diagnostics(bufnr, clean_opts)
	end
	opts = opts or default_options
	local virt_text, virt_lines, offset = generate_virtual_texts(opts, bufnr, diagnostic, recompute_ui)
	local virtline = diagnostic.lnum
	local max_buf_line = api.nvim_buf_line_count(bufnr)
	if virtline + 1 > max_buf_line then
		virtline = max_buf_line
	end

	local shown_line = api.nvim_buf_set_extmark(bufnr, ns, virtline, 0, {
		id = virtline + 1,
		virt_text = virt_text,
		virt_text_win_col = offset,
		virt_lines = virt_lines,
		virt_lines_above = opts.ui.above,
		invalidate = virtline + 1 > max_buf_line,
		priority = 2003,
		line_hl_group = "CursorLine",
	})
	return shown_line, diagnostic
end

--- Shows the highest severity diagnostic at the line for a buffer, optionally cleaning existing diagnostics before showing the new one.
---
--- @param opts table|nil Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param current_line  integer The current line number. Defaults to the cursor line.
--- @param recompute_diags  boolean|nil Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @param clean_opts boolean|number|table|nil Options for cleaning diagnostics before showing the new one.
--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
--- @return integer The line number where the diagnostic was shown.
--- @return table|nil The diagnostic that was shown. nil if no diagnostics were shown.
--- @return table The list of diagnostics at the line.
--- @return integer The size of the diagnostics list.
function M.show_top_severity_diagnostic(opts, bufnr, current_line, recompute_diags, clean_opts, recompute_ui)
	local diags, diags_size = M.fetch_diagnostics(bufnr, current_line, recompute_diags)
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
--- @param opts table|nil Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param current_line ? integer The current line number. Defaults to the cursor line.
--- @param current_col ? integer The current column number. Defaults to the cursor column.
--- @param recompute_diags ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @param clean_opts ? boolean|number|table Options for cleaning diagnostics before showing the new one.
--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
--- @return integer The line number where the diagnostic was shown.
--- @return table|nil The diagnostic that was shown. nil if no diagnostics were shown.
--- @return table The list of diagnostics at the cursor position.
--- @return integer The size of the diagnostics list.
function M.show_cursor_diagnostic(opts, bufnr, current_line, current_col, recompute_diags, clean_opts, recompute_ui)
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

function M.get_line_shown(diagnostic)
	return diagnostic.lnum + 1
end

--- @param opts table|nil Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
function M.setup_buf(bufnr, opts)
	if buffers_attached[bufnr] then
		return
	end
	buffers_attached[bufnr] = true

	local autocmd_group = api.nvim_create_augroup(make_group_name(bufnr), { clear = true })
	opts = opts and vim.tbl_deep_extend("force", default_options, opts) or default_options

	local prev_line = 1 -- The previous line that cursor was on.
	local text_changing = false
	local prev_cursor_diagnostic = nil
	local scheduled_update = false
	local new_diagnostics = nil
	-- local multiple_lines_changed = false

	if not diagnostics_cache.exist(bufnr) then
		diagnostics_cache.update(bufnr)
	end

	--- @param lines_or_diagnostic number|table|boolean|nil Specifies the lines or diagnostic to clean, If nil, do nothing
	local function clean_diagnostics(lines_or_diagnostic)
		M.clean_diagnostics(bufnr, lines_or_diagnostic)
	end

	local function disable()
		prev_line = 1 -- The previous line that cursor was on.
		text_changing = false
		prev_cursor_diagnostic = nil
		extmark_cache[bufnr] = nil
		-- multiple_lines_changed = false
		clean_diagnostics(true)
	end

	--- @param diagnostic table The diagnostic to show.
	--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
	local function show_diagnostic(diagnostic, recompute_ui)
		if diagnostic then
			M.show_diagnostic(opts, bufnr, diagnostic, false, recompute_ui) -- re-render last shown diagnostic
		end
	end

	--- @param current_line integer The current line number.
	--- @param current_col integer The current column number.
	--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
	local function show_cursor_diagnostic(current_line, current_col, recompute_ui)
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
	local function exists_any_diagnostics(line)
		return M.exists_any_diagnostics(bufnr, line)
	end

	--- @param line integer The line number to show the top severity diagnostic for.
	--- @param recompute_ui ? boolean Whether to recompute the ui of the diagnostics. Defaults to false.
	--- @return integer The line number where the diagnostic was shown.
	local function show_top_severity_diagnostic(line, recompute_ui)
		return M.show_top_severity_diagnostic(opts, bufnr, line, false, false, recompute_ui)
	end

	--- @param current_line integer The current line number.
	--- @param current_col integer The current column number.
	local function show_diagnostics(current_line, current_col)
		clean_diagnostics(true)
		for line, _ in meta_pairs(diagnostics_cache[bufnr]) do
			if line == current_line then
				show_cursor_diagnostic(current_line, current_col)
			else
				show_top_severity_diagnostic(line)
			end
		end
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
				scheduled_update = false

				diagnostics_cache.update(bufnr, new_diagnostics)

				if buffers_disabled[bufnr] then
					-- still need to update the cache for the buffer
					return
				end

				local current_line, current_col = get_cursor(0)

				if opts.inline then
					show_cursor_diagnostic(current_line, current_col)
				else
					show_diagnostics(current_line, current_col)
				end

				-- multiple_lines_changed = false
				text_changing = false
			end, 300)
		end,
	})

	autocmd({ "CursorMovedI", "CursorMoved", "ModeChanged" }, {
		group = autocmd_group,
		buffer = bufnr,
		---@diagnostic disable-next-line: redefined-local
		callback = function()
			if buffers_disabled[bufnr] then
				return
			end

			if text_changing then -- we had another event for text changing
				text_changing = false
				return
			end

			--- just moving cursor, no need to re calculate diagnostics virtual text position so we can use cache
			local current_line, current_col = get_cursor(0)
			if exists_any_diagnostics(current_line) then
				if current_line == prev_line and prev_cursor_diagnostic then
					if prev_cursor_diagnostic.col > current_col or prev_cursor_diagnostic.end_col - 1 < current_col then
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
		end,
	})

	-- Attach to the buffer to rerender diagnostics virtual text when the window is resized.
	autocmd("VimResized", {
		buffer = bufnr,
		group = autocmd_group,
		callback = function()
			if buffers_disabled[bufnr] then
				return
			end

			extmark_cache[bufnr] = nil -- clear cache to recompute the virtual text
			if opts.inline then
				if prev_cursor_diagnostic then
					show_diagnostic(prev_cursor_diagnostic)
				end
			else
				local current_line, current_col = get_cursor(0)
				show_diagnostics(current_line, current_col)
			end
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
			if buffers_disabled[bufnr] then
				return
			end
			text_changing = true
			if last_line_changed ~= last_line_updated_range then -- added or removed line
				-- multiple_lines_changed = true
				local current_line, current_col = get_cursor(0)
				show_cursor_diagnostic(current_line, current_col, true)
			elseif prev_cursor_diagnostic then
				show_diagnostic(prev_cursor_diagnostic, true)
			end
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
