local vim, type, pairs, ipairs = vim, type, pairs, ipairs
local api, fn, diag = vim.api, vim.fn, vim.diagnostic
local autocmd, augroup, strdisplaywidth, get_cursor, tbl_insert =
	api.nvim_create_autocmd, api.nvim_create_augroup, fn.strdisplaywidth, api.nvim_win_get_cursor, table.insert
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
-- @type table<integer, table<integer, table<string, table>>>>
-- bufnr -> line -> address of diagnostic -> diagnostic
local diagnostics_cache = {}
do
	local real_diagnostics_cache = {}
	function diagnostics_cache:exist(bufnr)
		return real_diagnostics_cache[bufnr] ~= nil
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
				real_diagnostics_cache[bufnr] = setmetatable(proxy_table, {
					---@diagnostic disable-next-line: redundant-return-value
					__pairs = function(_)
						return pairs(lines)
					end,

					__index = function(_, line)
						return lines[line]
					end,

					--- Tracks the existence of diagnostics for a buffer at a line.
					--- @param line integer The lnum of the diagnostic being tracked in 1-based index. It's also the line where the diagnostic is located in the buffer
					--- @param diagnostic table The diagnostic being tracked
					__newindex = function(t, line, diagnostic)
						if diagnostic == nil or not next(diagnostic) then -- untrack this line if nil or empty table
							local line_value = lines[line]
							if line_value then
								lines[line] = nil
								line_value[0] = nil -- make sure never loop over this key
								for _, d in pairs(line_value) do
									local lnum = d.lnum + 1
									local line_lnum_value = lines[lnum]
									if line_lnum_value and line_lnum_value[d] and line_lnum_value[0] > 1 then
										line_lnum_value[d] = nil
										line_lnum_value[0] = line_lnum_value[0] - 1
									else
										lines[lnum] = nil
									end
								end
							end
						elseif type(diagnostic[1]) == "table" then -- track multiple diagnostics
							t[line] = nil -- call the __newindex in case nil
							for _, d in ipairs(diagnostic) do
								t[d.lnum + 1] = d -- call the __newindex in case track diagnostic
							end
						elseif diagnostic.end_lnum then -- make sure the diagnostic is not an empty table
							local end_lnum = diagnostic.end_lnum + 1 -- change to 1-based
							for i = line, end_lnum do
								local line_value = lines[i]
								if not line_value then
									lines[line] = setmetatable({
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
								elseif not line_value[diagnostic] then
									line_value[diagnostic] = diagnostic
									line_value[0] = line_value[0] + 1
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
					real_diagnostics_cache[bufnr] = nil
					api.nvim_del_augroup_by_name(make_group_name(bufnr))
				end,
			})
			rawset(t, bufnr, value)
		end,
	})
end

--- Tracks the diagnostics for a buffer.
--- @param bufnr integer The buffer number.
--- @param diagnostics table The list of diagnostics to track.
local function track_diagnostics(bufnr, diagnostics)
	diagnostics_cache[bufnr] = {} -- clear all diagnostics for this buffer
	local exists_diags_bufnr = diagnostics_cache[bufnr]
	for _, d in ipairs(diagnostics) do
		exists_diags_bufnr[d.lnum + 1] = d
	end
end

--- Updates the diagnostics cache
--- @param bufnr integer The buffer number
--- @param line integer The line number
--- @param diagnostic table The new diagnostic to track or list of diagnostics in a line to update
function M.update_diagnostics_cache(bufnr, line, diagnostic)
	diagnostics_cache[bufnr][line] = diagnostic
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
--- checking if the length is divisible by numbers from 10 to 2, using precomputed
--- substrings to minimize the number of calls to `string.rep`.
--- @param num number The total number of spaces to generate.
--- @return string A string consisting of `num` spaces.
local space = function(num)
	local reps = { " ", "  ", "   ", "    ", "     ", "      ", "       ", "        ", "         ", "          " }
	local rep = string.rep
	for i = 10, 2, -1 do
		if num % i == 0 then
			return rep(reps[i], num / i)
		end
	end
	return rep(" ", num)
end

--- Retrieves diagnostics at the line position in the specified buffer.
--- Diagnostics are filtered and sorted by severity, with the most severe ones first.
---
--- @param bufnr integer The buffer number
--- @param line integer The line number
--- @param computed ? boolean Whether the diagnostics are computed
--- @return table The full list of diagnostics for the line sorted by severity
--- @return integer The number of diagnostics in the line
function M.fetch_diagnostics(bufnr, line, computed)
	local diagnostics
	local diagnostics_size

	if computed then
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
--- @param computed ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @return table A table containing diagnostics at the cursor position sorted by severity.
--- @return integer The number of diagnostics at the cursor position in the line sorted by severity.
--- @return table The full list of diagnostics for the line sorted by severity.
--- @return integer The number of diagnostics in the line sorted by severity.
function M.fetch_cursor_diagnostics(bufnr, current_line, current_col, computed)
	if type(current_line) ~= "number" then
		current_line = get_cursor(0)[1]
	end
	local diagnostics, diagnostics_size = M.fetch_diagnostics(bufnr, current_line, computed)

	if type(current_col) ~= "number" then
		current_col = get_cursor(0)[2]
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
--- @param computed ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @return table A table of diagnostics for the current position and the current line number.
--- @return table The full list of diagnostics for the line.
--- @return integer The number of diagnostics in the list.
function M.fetch_top_cursor_diagnostic(bufnr, current_line, current_col, computed)
	local cursor_diags, _, diags, diags_size = M.fetch_cursor_diagnostics(bufnr, current_line, current_col, computed)
	return cursor_diags[1], diags, diags_size
end

--- Format line chunks for virtual text display.
---
--- This function formats the line chunks for virtual text display, considering various options such as severity,
--- underline symbol, text offsets, and parts to be removed.
---
--- @param ui_opts table - The table of UI options. Should contain:
---     - arrow: string - The symbol used as the left arrow.
---     - up_arrow: string - The symbol used as the up arrow.
---     - right_kept_space: number - The space to keep on the right side.
---     - left_kept_space: number - The space to keep on the left side.
--- @param line_idx number - The index of the current line (1-based).
--- @param line_msg string - The message to display on the line.
--- @param severity number - The severity level of the diagnostic (1 = Error, 2 = Warn, 3 = Info, 4 = Hint).
--- @param max_line_length number - The maximum length of the line.
--- @param lasted_line boolean - Whether this is the last line of the diagnostic message.
--- @param virt_text_offset number - The offset for virtual text positioning.
--- @param should_under_line boolean - Whether to use the underline arrow symbol.
--- @param removed_parts table - A table indicating which parts should be removed (e.g., arrow, left_kept_space, right_kept_space).
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
	should_under_line,
	removed_parts
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

	if should_under_line then
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
--- @return boolean is_under_min_length Whether the line length is under the minimum wrap length.
--- @return number begin_offset The offset of the virtual text.
--- @return number wrap_length The calculated wrap length.
--- @return table removed_parts A table indicating which parts were removed to fit within the wrap length.
local function evaluate_extmark(ui_opts)
	local window_info = fn.getwininfo(api.nvim_get_current_win())[1] -- First entry
	local text_area_width = window_info.width - window_info.textoff
	local current_line = api.nvim_get_current_line()
	local offset = strdisplaywidth(current_line)

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
		local init_spaces, only_space = count_initial_spaces(current_line)
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
--- @return table The list of virtual texts.
--- @return table The list of virtual lines.
local function generate_virtual_texts(opts, diagnostic)
	local ui = opts.ui
	local should_display_below, offset, wrap_length, removed_parts = evaluate_extmark(ui)
	local msgs, size = wrap_text(diagnostic.message, wrap_length)
	if size == 0 then
		return {}, {}
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
		removed_parts
	)
	if should_display_below then
		if size == 1 then
			return {}, { virt_text }
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
					removed_parts
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
					removed_parts
				)
			)
		end
	end

	return virt_text, virt_lines
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
	if lines_or_diagnostic == nil then
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
--- @param opts  table|nil Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param diagnostic table The diagnostic to show.
--- @param clean_opts  number|table|nil Options for cleaning diagnostics before showing the new one.
---                     If a number is provided, it is treated as an extmark ID to delete.
---                     If a table is provided, it should contain line numbers or a range to clear.
--- @return integer The start line of the diagnostic where it was shown.
--- @return table The diagnostic that was shown.
function M.show_diagnostic(opts, bufnr, diagnostic, clean_opts)
	if clean_opts then
		M.clean_diagnostics(bufnr, clean_opts)
	end
	local virt_text, virt_lines = generate_virtual_texts(opts or default_options, diagnostic)
	local virtline = diagnostic.lnum
	local shown_line = api.nvim_buf_set_extmark(bufnr, ns, virtline, 0, {
		id = virtline + 1,
		virt_text = virt_text,
		virt_lines = virt_lines,
		virt_lines_above = opts.ui.above,
		virt_text_pos = "eol",
		line_hl_group = "CursorLine",
	})
	return shown_line, diagnostic
end

--- Shows the highest severity diagnostic at the line for a buffer, optionally cleaning existing diagnostics before showing the new one.
---
--- @param opts table|nil Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param current_line  integer|nil The current line number. Defaults to the cursor line.
--- @param computed  boolean|nil Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @param clean_opts number|table|nil Options for cleaning diagnostics before showing the new one.
--- @return integer The line number where the diagnostic was shown.
--- @return table|nil The diagnostic that was shown. nil if no diagnostics were shown.
--- @return table The list of diagnostics at the line.
--- @return integer The size of the diagnostics list.
function M.show_top_severity_diagnostic(opts, bufnr, current_line, computed, clean_opts)
	local diags, diags_size = M.fetch_diagnostics(bufnr, current_line, computed)
	if not diags[1] then
		if clean_opts then
			M.clean_diagnostics(bufnr, clean_opts)
		end
		return -1, nil, {}, 0
	end
	local shown_line, shown_diagnostic = M.show_diagnostic(opts, bufnr, diags[1], clean_opts)
	return shown_line, shown_diagnostic, diags, diags_size
end

--- Shows the highest severity diagnostic at the cursor position in a buffer.
---
--- @param opts table|nil Options for displaying the diagnostic. If not provided, the default options are used.
--- @param bufnr integer The buffer number.
--- @param current_line ? integer The current line number. Defaults to the cursor line.
--- @param current_col ? integer The current column number. Defaults to the cursor column.
--- @param computed ? boolean Computes the diagnostics if true else uses the cache diagnostics. Defaults to false.
--- @param clean_opts ? number|table Options for cleaning diagnostics before showing the new one.
--- @return integer The line number where the diagnostic was shown.
--- @return table|nil The diagnostic that was shown. nil if no diagnostics were shown.
--- @return table The list of diagnostics at the cursor position.
--- @return integer The size of the diagnostics list.
function M.show_cursor_diagnostic(opts, bufnr, current_line, current_col, computed, clean_opts)
	local highest_diag, diags, diags_size = M.fetch_top_cursor_diagnostic(bufnr, current_line, current_col, computed)
	highest_diag = highest_diag or diags[1]
	if not highest_diag then
		if clean_opts then
			M.clean_diagnostics(bufnr, clean_opts)
		end
		return -1, nil, {}, 0
	end
	local shown_line, shown_diagnostic = M.show_diagnostic(opts, bufnr, highest_diag, clean_opts)
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

	local autocmd_group = augroup(make_group_name(bufnr), { clear = true })
	opts = opts and vim.tbl_deep_extend("force", default_options, opts) or default_options

	local prev_line = 1 -- The previous line that cursor was on.
	local text_changing = false
	local prev_cursor_diagnostic = nil
	local lines_count_changed = false
	local prev_diag_changed_trigger_line = -1

	if not diagnostics_cache:exist(bufnr) then
		track_diagnostics(bufnr, diag.get(bufnr))
	end

	local function clean_diagnostics(lines_or_diagnostic)
		M.clean_diagnostics(bufnr, lines_or_diagnostic)
	end

	local function show_diagnostic(diagnostic)
		if diagnostic then
			M.show_diagnostic(opts, bufnr, diagnostic) -- re-render last shown diagnostic
		end
	end

	local function show_cursor_diagnostic(current_line, current_col, computed, clean_opts)
		_, prev_cursor_diagnostic =
			M.show_cursor_diagnostic(opts, bufnr, current_line, current_col, computed, clean_opts)
	end

	local function exists_any_diagnostics(line)
		return M.exists_any_diagnostics(bufnr, line)
	end

	local function show_top_severity_diagnostic(line, computed, clean_opts)
		return M.show_top_severity_diagnostic(opts, bufnr, line, computed, clean_opts)
	end

	local function show_diagnostics(current_line, current_col)
		clean_diagnostics(true)
		for line, diagnostics in meta_pairs(diagnostics_cache[bufnr]) do
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
			if buffers_disabled[bufnr] then
				track_diagnostics(bufnr, args.data.diagnostics) -- still need to track the diagnostics in case the buffer is disabled
				return
			end

			local cursor_pos = get_cursor(0)
			local current_line, current_col = cursor_pos[1], cursor_pos[2]

			if not lines_count_changed and (text_changing or prev_diag_changed_trigger_line == current_line) then
				show_cursor_diagnostic(current_line, current_col, true, prev_cursor_diagnostic)
			else
				-- If text is not currently changing, it implies that the cursor moved before the diagnostics changed event.
				-- Therefore, we need to re-track the diagnostics because multiple diagnostics across different lines may have changed simultaneously.
				track_diagnostics(bufnr, args.data.diagnostics)
				if opts.inline then
					show_cursor_diagnostic(current_line, current_col, false, prev_cursor_diagnostic)
				else
					show_diagnostics(current_line, current_col)
				end
				lines_count_changed = false
			end

			text_changing = false
			prev_diag_changed_trigger_line = current_line
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

			local cursor_pos = get_cursor(0)
			local current_line, current_col = cursor_pos[1], cursor_pos[2]

			if exists_any_diagnostics(current_line) then
				if current_line == prev_line then
					if
						prev_cursor_diagnostic
						and (
							prev_cursor_diagnostic.col > current_col
							or prev_cursor_diagnostic.end_col - 1 < current_col
						)
					then
						show_cursor_diagnostic(current_line, current_col)
					end
				else
					show_cursor_diagnostic(current_line, current_col, false, prev_cursor_diagnostic)
				end
			elseif opts.inline then
				clean_diagnostics(prev_cursor_diagnostic)
				prev_cursor_diagnostic = nil
			end

			if prev_diag_changed_trigger_line ~= current_line then
				prev_diag_changed_trigger_line = -1
			end
			prev_line = current_line
			lines_count_changed = false
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

			if opts.inline then
				if prev_cursor_diagnostic then
					show_diagnostic(prev_cursor_diagnostic)
				end
			else
				local cursor_pos = get_cursor(0)
				local current_line, current_col = cursor_pos[1], cursor_pos[2]
				show_diagnostics(current_line, current_col)
			end
		end,
	})

	-- Attach to the buffer to rerender diagnostics virtual text when text changes.
	api.nvim_buf_attach(bufnr, false, {
		on_lines = function(
			event,
			_,
			changedtick,
			first_line_changed,
			last_line_changed,
			last_line_updated_range,
			prev_byte_count
		)
			if buffers_disabled[bufnr] then
				return
			end
			text_changing = true
			if last_line_changed ~= last_line_updated_range then -- added or removed line
				lines_count_changed = true
				local cursor_pos = get_cursor(0)
				local current_line, current_col = cursor_pos[1], cursor_pos[2]
				show_cursor_diagnostic(current_line, current_col, false, prev_cursor_diagnostic)
			elseif prev_cursor_diagnostic then
				show_diagnostic(prev_cursor_diagnostic)
			end
		end,
	})

	autocmd("User", {
		group = autocmd_group,
		pattern = { "BetterDiagnosticVirtualTextEnabled", "BetterDiagnosticVirtualTextDisabled" },
		callback = function(args)
			if bufnr == args.data then
				if args.match == "BetterDiagnosticVirtualTextEnabled" then
					local cursor_pos = get_cursor(0)
					local current_line, current_col = cursor_pos[1], cursor_pos[2]
					if opts.inline then
						if exists_any_diagnostics(current_line) then
							show_cursor_diagnostic(current_line, current_col)
						end
					else
						show_diagnostics(current_line, current_col)
					end
				else
					clean_diagnostics(true)
					prev_cursor_diagnostic = nil
				end
			end
		end,
	})
end

if not vim.g.loaded_better_diagnostic_virtual_text_toggle then
	-- overwrite diagnostic.enable
	local raw_enable = diag.enable
	---@diagnostic disable-next-line: duplicate-set-field
	diag.enable = function(enabled, filter)
		raw_enable(enabled, filter)
		local bufnr = filter and filter.bufnr
		if not bufnr then
			return
		end
		local bufnr_disabled = buffers_disabled[bufnr] == true

		if not enabled then
			if not bufnr_disabled then -- already disabled
				buffers_disabled[bufnr] = true
				api.nvim_exec_autocmds("User", {
					pattern = "BetterDiagnosticVirtualTextDisabled",
					data = bufnr,
				})
			end
		else
			if bufnr_disabled then
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

function M.setup(opts)
	autocmd("LspAttach", {
		nested = true,
		callback = function(args)
			M.setup_buf(args.buf, opts)
		end,
	})
end

return M
