# Better Diagnostic Virtual Text

A Neovim plugin for enhanced diagnostic virtual text display, aiming to provide better performance and customization options.

Note: document is not enough.

## Features

- **Ease of Use**: Simple setup and configuration.
- **Beautiful UI**: Customizable colors, icons, and more.
- **Toggleable**: Enable and disable with vim.diagnostic.enable/disable commands.

## Installation

Add the following to your `init.lua` or `init.vim`:

```lua
-- lazy.nvim
{
    'sontungexpt/better-diagnostic-virtual-text',
    "LspAttach"
    config = function(_)
        require('better-diagnostic-virtual-text').setup()
    end
}

-- or better ways configure in on_attach of lsp client
M.on_attach = function(client, bufnr)
    -- nil can replace with the options of each buffer
	require("better-diagnostic-virtual-text").setup_buf(bufnr, nil)
	lsp.handlers["textDocument/signatureHelp"] = lsp.with(lsp.handlers.signature_help, {
		border = "single",
		focusable = false,
		relative = "cursor",
	})

	lsp.handlers["textDocument/hover"] = lsp.with(lsp.handlers.hover, { border = "single" })
end
```

## Configuration

```lua
-- Can be applied to each buffer separately

local default_options = {
	ui = {
		wrap_line_after = false,
		left_kept_space = 3, --- The number of spaces kept on the left side of the virtual text, make sure it enough to custom for each line
		right_kept_space = 3, --- The number of spaces kept on the right side of the virtual text, make sure it enough to custom for each line
		arrow = "  ",
		up_arrow = "  ",
		above = false,
	},
	inline = true,
}



```

### Customize ui

UI will has 4 parts: arrow, left_kept_space, message, right_kept_space orders:

| arrow | left_kept_space | message | right_kept_space |

Override this function before setup the plugin.

```lua

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
require("better-diagnostic-virtual-text").format_line_chunks = function(
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
    -- replace with your logic to get chunks for each line

    -- default logic
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

```

## Preview

https://github.com/sontungexpt/better-diagnostic-virtual-text/assets/92097639/ef3d49fb-1a47-46c3-81ba-d23df70eced9

## License

MIT[License]

## Contributors

- [sontungexpt](https://github.com/sontungexpt)