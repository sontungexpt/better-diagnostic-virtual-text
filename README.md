# Better Diagnostic Virtual Text

A Neovim plugin for enhanced diagnostic virtual text display, aiming to provide better performance and customization options.

**NOTE**: This code is currently in the testing phase and may contain bugs. If you encounter any issues, please let me know.
I can't found it alone, so please help me to improve it.

## Features

- **Ease of Use**: Effortless setup and configuration.
- **Beautiful UI**: Customizable colors, icons, and more for an aesthetically pleasing interface.
- **Auto-fix Capability**: Automatically adjusts to fit the current window size for seamless display.
- **Toggleable**: Easily enable or disable using `vim.diagnostic.enable/disable` commands.
- **Performance**: Optimized for speed and efficiency, updating virtual text only when necessary.

## Preview

- opts.inline = false. Show all diagnostics

https://github.com/sontungexpt/better-diagnostic-virtual-text/assets/92097639/67212285-6534-4758-a943-5938500e0077

- opts.inline = true. Show only current line diagnostic

https://github.com/sontungexpt/better-diagnostic-virtual-text/assets/92097639/ef3d49fb-1a47-46c3-81ba-d23df70eced9

- opts.ui.above = true. Show the diagnostic above the line

https://github.com/sontungexpt/better-diagnostic-virtual-text/assets/92097639/c2c30f61-6e9b-4986-a27f-21c916f7e1bd

- Test with tokyonight theme

https://github.com/sontungexpt/better-diagnostic-virtual-text/assets/92097639/4e0f6306-0fc4-4fb4-b46f-107b8c40e46c

## Installation

You need to set vim.diagnostic.config({ virtual_text = false }), to not have all diagnostics in the buffer displayed conflict.
May be in the future we will integrate it with native vim.diagnostic

Add the following to your `init.lua` or `init.vim`:

```lua
-- lazy.nvim
{
    'sontungexpt/better-diagnostic-virtual-text',
    "LspAttach"
    config = function(_)
        require('better-diagnostic-virtual-text').setup(opts)
    end
}

-- or better ways configure in on_attach of lsp client
-- if use this way don't need to call setup function
{
    'sontungexpt/better-diagnostic-virtual-text',
    lazy = true,
}
M.on_attach = function(client, bufnr)
    -- nil can replace with the options of each buffer
	require("better-diagnostic-virtual-text.api").setup_buf(bufnr, {})

    --- ... other config for lsp client
end
```

## Configuration

```lua
-- Can be applied to each buffer separately

local default_options = {
    ui = {
        wrap_line_after = false, -- wrap the line after this length to avoid the virtual text is too long
        left_kept_space = 3, --- the number of spaces kept on the left side of the virtual text, make sure it enough to custom for each line
        right_kept_space = 3, --- the number of spaces kept on the right side of the virtual text, make sure it enough to custom for each line
        arrow = "  ",
        up_arrow = "  ",
        down_arrow = "  ",
        above = false, -- the virtual text will be displayed above the line
    },
    priority = 2003, -- the priority of virtual text
    inline = true,
}
```

### Customize ui

UI will has 4 parts: arrow, left_kept_space, message, right_kept_space orders:

| arrow | left_kept_space | message | right_kept_space |

- arrow: This part is the arrow symbol that indicates the severity of the diagnostic message.
- left_kept_space: The space to keep on the left side of the virtual text. Please make sure it enough to custom for each line.
  Default this part is the tree in virtual text.
- message: The message at the current line.
- right_kept_space: The space to keep on the right side of the virtual text. Please make sure it enough to custom for each line.

Override this function before setup the plugin.

```lua
--- Format line chunks for virtual text display.
---
--- This function formats the line chunks for virtual text display, considering various options such as severity,
--- underline symbol, text offsets, and parts to be removed.
---
--- @param ui_opts table - The table of UI options. Should contain:
---     - arrow: The symbol used as the left arrow.
---     - up_arrow: The symbol used as the up arrow.
---     - down_arrow: The symbol used as the down arrow.
---     - left_kept_space: The space to keep on the left side.
---     - right_kept_space: The space to keep on the right side.
---     - wrap_line_after: The maximum line length to wrap after.
--- @param line_idx number - The index of the current line (1-based). It start from the cursor line to above or below depend on the above option.
--- @param line_msg string - The message to display on the line.
--- @param severity number - The severity level of the diagnostic (1 = Error, 2 = Warn, 3 = Info, 4 = Hint).
--- @param max_line_length number - The maximum length of the line.
--- @param lasted_line boolean - Whether this is the last line of the diagnostic message. Please check line_idx == 1 to know the first line before checking lasted_line because the first line can be the lasted line if the message has only one line.
--- @param virt_text_offset number - The offset for virtual text positioning.
--- @param should_display_below boolean - Whether to display the virtual text below the line. If above is true, this option will be whether the virtual text should be above
--- @param above_instead boolean - Display above or below
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
	above_instead,
	removed_parts,
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

```

## Toggle

You can enable and disable the plugin using the following commands:

```lua
    vim.diagnostic.enable(true, { bufnr = vim.api.nvim_get_current_buf() }) -- Enable the plugin for the current buffer.
    vim.diagnostic.enable(false, { bufnr = vim.api.nvim_get_current_buf() }) -- Disable the plugin for the current buffer.
```

## Highlight Names

### Default

The default highlight names for each severity level are:

- `DiagnosticVirtualTextError`
- `DiagnosticVirtualTextWarn`
- `DiagnosticVirtualTextInfo`
- `DiagnosticVirtualTextHint`

### Custom Overrides

You can override the default highlight names with:

- `BetterDiagnosticVirtualTextError`
- `BetterDiagnosticVirtualTextWarn`
- `BetterDiagnosticVirtualTextInfo`
- `BetterDiagnosticVirtualTextHint`

### Arrow Highlights

For the arrow highlights, use:

- `BetterDiagnosticVirtualTextArrow` for all severity levels.
- `BetterDiagnosticVirtualTextArrowError`
- `BetterDiagnosticVirtualTextArrowWarn`
- `BetterDiagnosticVirtualTextArrowInfo`
- `BetterDiagnosticVirtualTextArrowHint`

### Tree Highlights

For the tree highlights, use:

- `BetterDiagnosticVirtualTextTree` for all severity levels.
- `BetterDiagnosticVirtualTextTreeError`
- `BetterDiagnosticVirtualTextTreeWarn`
- `BetterDiagnosticVirtualTextTreeInfo`
- `BetterDiagnosticVirtualTextTreeHint`

## Public API Functions

**Replace `M` with the `require("better-diagnostic-virtual-text.api")`.**

NOTE : I was too lazy to write the complete API documentation, so I used ChatGPT to generate it. If there are any inaccuracies, please refer to the source for verification.

### `M.inspect_cache()`

- **Description**: Inspects the diagnostics cache for debugging purposes.
- **Parameters**: None
- **Returns**: None

### `M.foreach_line(bufnr, callback)`

Iterates through each line of diagnostics in a specified buffer and invokes a callback function for each line. Ensures compatibility with Lua versions older than 5.2 by using the default `pairs` function directly, or with a custom `pairs` function that handles diagnostic metadata.

### Example

```lua
local meta_pairs = function(t)
  local metatable = getmetatable(t)
  if metatable and metatable.__pairs then
      return metatable.__pairs(t)
  end
  return pairs(t)
end
```

usage:

```lua
require("better-diagnostic-virtual-text.api").foreach_line(bufnr, function(line, diagnostics)
  for _, diagnostic in meta_pairs(diagnostics) do
    print(diagnostic.message)
  end
end)
```

### `M.clear_extmark_cache(bufnr)`

Clears the diagnostics extmarks for a buffer.

- **Parameters:**
  - `bufnr` (integer): The buffer number to clear the diagnostics for.

### `M.update_diagnostics_cache(bufnr, line, diagnostic)`

- **Description**: Updates the diagnostics cache for a specific buffer and line.
- **Parameters**:
  - `bufnr` (`integer`): The buffer number.
  - `line` (`integer`): The line number.
  - `diagnostic` (`table`): The new diagnostic to track or list of diagnostics to update.
- **Returns**: None

### `M.fetch_diagnostics(bufnr, line, recompute, comparator, finish_soon)`

- **Description**: Retrieves diagnostics at a specific line in the specified buffer.
- **Parameters**:
  - `bufnr` (`integer`): The buffer number.
  - `line` (`integer`): The line number.
  - `recompute` (`boolean|nil`): Whether to recompute the diagnostics.
  - `comparator` (`function|nil`): The comparator function to sort the diagnostics. If not provided, the diagnostics are not sorted.
  - `finish_soon` (`boolean|function|nil`): If true, stops processing sort when a finish_soon(d) return true or finish_soon is boolean and severity 1 diagnostic is found. When stop immediately the return value is the list with only found diagnostic. This parameter only work if `comparator` is provided or `recompute`` = false
    .
- **Returns**:

  - `table`: List of diagnostics sorted by severity.
  - `integer`: Number of diagnostics.

  **Note: if finish_soon == true, the list will only has one diagnostic fit the condition.**

### `M.fetch_cursor_diagnostics(bufnr, current_line, current_col, recompute, comparator, finish_soon)`

- **Description**: Retrieves diagnostics at the cursor position in the specified buffer.
- **Parameters**:
  - `bufnr` (`integer`): The buffer number.
  - `current_line` (`integer`): Optional. The current line number. Defaults to cursor line.
  - `current_col` (`integer`): Optional. The current column number. Defaults to cursor column.
  - `recompute` (`boolean`): Optional. Whether to recompute diagnostics or use cached diagnostics. Defaults to false.
  - `comparator` (`function|nil`): The comparator function to sort the diagnostics. If not provided, the diagnostics are not sorted.
  - `finish_soon` (`boolean|function|nil`): If true, stops processing sort when a finish_soon(d) return true or finish_soon is boolean and severity 1 diagnostic is found under cursor. When stop immediately the return value is the list with only found diagnostic. This parameter only work if `comparator` is provided or `recompute`` = false
- **Returns**:

  - `table`: Diagnostics at the cursor position sorted by severity.
  - `integer`: Number of diagnostics at the cursor position.
  - `table`: Full list of diagnostics for the line sorted by severity.
  - `integer`: Number of diagnostics in the line sorted by severity.

  **Note: if finish_soon == true, the list will only has one diagnostic fit the condition.**

### `M.fetch_top_cursor_diagnostic(bufnr, current_line, current_col, recompute)`

- **Description**: Retrieves the diagnostic with the highest severity at the cursor position in the specified buffer.
- **Parameters**:
  - `bufnr` (`integer`): The buffer number.
  - `current_line` (`integer`): Optional. The current line number. Defaults to cursor line.
  - `current_col` (`integer`): Optional. The current column number. Defaults to cursor column.
  - `recompute` (`boolean`): Optional. Whether to recompute diagnostics or use cached diagnostics. Defaults to false.
- **Returns**:
  - `table`: Diagnostic at the cursor position.
  - `table`: Full list of diagnostics for the line.
  - `integer`: Number of diagnostics in the list.

### `M.format_line_chunks(ui_opts, line_idx, line_msg, severity, max_line_length, lasted_line, virt_text_offset, should_display_below, removed_parts, diagnostic)`

- **Description**: Formats line chunks for virtual text display based on severity and UI options.
- **Parameters**:
  - `ui_opts` (`table`): Table of UI options.
  - `line_idx` (`number`): Index of the current line (1-based).
  - `line_msg` (`string`): Message to display on the line.
  - `severity` (`number`): Severity level of the diagnostic.
  - `max_line_length` (`number`): Maximum length of the line.
  - `lasted_line` (`boolean`): Whether this is the last line of the diagnostic message.
  - `virt_text_offset` (`number`): Offset for virtual text positioning.
  - `should_display_below` (`boolean`): Whether to display virtual text below the line.
  - `removed_parts` (`table`): Table indicating parts to delete to make room for message.
  - `diagnostic` (`table`): The diagnostic to display.
- **Returns**:
  - `table`: List of formatted chunks for virtual text display.

### `M.exists_any_diagnostics(bufnr, line)`

Checks if diagnostics exist for a buffer at a line.

- **Parameters:**

  - `bufnr` (integer): The buffer number to check.
  - `line` (integer): The line number to check.

- **Returns:**
  - `exists` (boolean): True if diagnostics exist, false otherwise.

### `M.clean_diagnostics(bufnr, lines_or_diagnostic)`

Cleans diagnostics for a buffer.

- **Parameters:**

  - `bufnr` (integer): The buffer number.
  - `lines_or_diagnostic` (number|table): Specifies the lines or diagnostic to clean.

- **Returns:**
  - `cleared` (boolean): True if any diagnostics were cleared, false otherwise.

### `M.show_diagnostic(opts, bufnr, diagnostic, clean_opts)`

Displays a diagnostic for a buffer, optionally cleaning existing diagnostics before showing the new one.

- **Parameters:**

  - `opts` (table): Options for displaying the diagnostic.
  - `bufnr` (integer): The buffer number.
  - `diagnostic` (table): The diagnostic to show.
  - `clean_opts` (number|table|nil): Options for cleaning diagnostics before showing the new one.
  - `recompute_ui` (boolean|nil) Whether to recompute the diagnostics. Defaults to false.

- **Returns:**
  - `shown_line` (integer): The start line of the diagnostic where it was shown.
  - `diagnostic` (table): The diagnostic that was shown.

### `M.show_top_severity_diagnostic(opts, bufnr, current_line, recompute, clean_opts)`

Shows the highest severity diagnostic at the line for a buffer.

- **Parameters:**

  - `opts` (table): Options for displaying the diagnostic.
  - `bufnr` (integer): The buffer number.
  - `current_line` (integer): The current line number.
  - `recompute` (boolean): Whether to recompute the diagnostics.
  - `clean_opts` (number|table): Options for cleaning diagnostics before showing the new one.
  - `recompute_ui` (boolean|nil) Whether to recompute the diagnostics. Defaults to false.

- **Returns:**
  - `line_number` (integer): The line number where the diagnostic was shown.
  - `diagnostic` (table): The diagnostic that was shown.
  - `diagnostics_list` (table): The list of diagnostics at the line.
  - `size` (integer): The size of the diagnostics list.

### `M.show_cursor_diagnostic(opts, bufnr, current_line, current_col, recompute, clean_opts)`

Shows the highest severity diagnostic at the cursor position in a buffer.

- **Parameters:**

  - `opts` (table): Options for displaying the diagnostic.
  - `bufnr` (integer): The buffer number.
  - `current_line` (integer): The current line number.
  - `current_col` (integer): The current column number.
  - `recompute` (boolean): Whether to recompute the diagnostics.
  - `clean_opts` (number|table): Options for cleaning diagnostics before showing the new one.
  - `recompute_ui` (boolean|nil) Whether to recompute the diagnostics. Defaults to false.

- **Returns:**
  - `line_number` (integer): The line number where the diagnostic was shown.
  - `diagnostic` (table): The diagnostic that was shown.
  - `diagnostics_list` (table): The list of diagnostics at the cursor position.
  - `size` (integer): The size of the diagnostics list.

### `M.get_line_shown(diagnostic)`

Returns the line number where the diagnostic was shown.

- **Parameters:**

  - `diagnostic` (table): The diagnostic.

- **Returns:**
  - `line_shown` (integer): The line number where the diagnostic was shown.

### `M.setup_buf(bufnr, opts)`

Sets up the buffer to handle diagnostic rendering and interaction.

- **Parameters:**
  - `bufnr` (integer): The buffer number.
  - `opts` (table): Options for setting up the buffer.

### `M.setup(opts)`

Sets up the module to handle diagnostic rendering and interaction globally.

- **Parameters:**
  - `opts` (table): Options for setting up the module.

## License

MIT [License](./LICENSE)

## Contributors

- [sontungexpt](https://github.com/sontungexpt)
