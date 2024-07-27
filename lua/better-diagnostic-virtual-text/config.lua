local M = {}

--- @class UIConfig UI configuration
--- @field wrap_line_after integer|boolean  Wrap the line after this length to avoid the virtual text is too long
--- @field left_kept_space integer The number of spaces kept on the left side of the virtual text, make sure it enough to custom for each line
--- @field right_kept_space integer The number of spaces kept on the right side of the virtual text, make sure it enough to custom for each line
--- @field arrow string The arrow symbol if the virtual text is in the current line
--- @field up_arrow string The arrow symbol if the virtual text is below the current line
--- @field down_arrow string The arrow symbol if the virtual text is above the current line
--- @field above boolean The virtual text is above the current line

--- @class Config Config options
--- @field ui UIConfig The UI configuration
--- @field priority integer The priority of the virtual text
--- @field inline boolean Only show the virtual text in the current line

--- @type Config
local default = {
	ui = {
		wrap_line_after = false,
		left_kept_space = 3,
		right_kept_space = 2,
		arrow = "  ",
		up_arrow = "  ",
		down_arrow = "  ",
		above = false,
	},
	priority = 2003,
	inline = true,
}

---
--- Creates a shallow clone of a table.
--- Copies all key-value pairs from the input table `tbl` to a new table.
--- If `tbl` contains nested tables, they are shallow cloned recursively.
--- @param tbl table The table to clone.
--- @return table: A new table containing shallow copies of all key-value pairs from `tbl`.
local function clone(tbl)
	local clone_tbl = {}
	if type(tbl) == "table" then
		for k, v in pairs(tbl) do
			clone_tbl[k] = clone(v)
		end
	else
		clone_tbl = tbl -- des[k] = v
	end
	return clone_tbl
end

---
--- Merges two tables recursively, copying key-value pairs from `t2` into `t1`.
--- If both `t1` and `t2` have tables as values for the same key, they are merged recursively.
--- If `force` is `true`, `t1` is overwritten with `t2` even if `t1` is not `nil`.
--- @param t1 table The destination table to merge into.
--- @param t2 table The source table to merge from.
--- @param force boolean Optional. If `true`, overwrites `t1` with `t2` even if `t1` is not `nil`.
--- @return table: The merged table `t1`.
local function merge(t1, t2, force)
	if type(t1) == "table" and type(t2) == "table" then
		for k, v in pairs(t2) do
			t1[k] = merge(t1[k], v, force)
		end
	elseif force or t1 == nil then
		t1 = t2
	end
	return t1
end

--- Gets the merged options from the default options and the user options.
--- @param user_options ? Config The user options.
--- @return table: The merged options.
M.get = function(user_options)
	return user_options and merge(clone(default), user_options, true) or default
end

return M
