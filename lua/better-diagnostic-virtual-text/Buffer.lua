local next = next

---@class LineDiagnostic The diagnostics in a line
---@field public [0] integer The number of diagnostics in the line
---@field public vim.Diagnostic vim.Diagnostic The diagnostic
---@field public ipairs  fun():integer, vim.Diagnostic @Iterate over the diagnostics in the line
---@field public pairs fun():integer, vim.Diagnostic @Iterate over the diagnostics in the line
---ex:
---{
---  [`0`] = 1, -- number of diagnostics in the line
---  [`vim.Diagnostic`] = vim.Diagnostic,
---  [`vim.Diagnostic`] = vim.Diagnostic,
---}

--- @class BufferDiagnostic The diagnostics in a buffer
--- @field public [number] table<integer, LineDiagnostic> The diagnostics in the buffer
--- @field public raw function Return the raw buffer cache
--- ex:
--- {
---  [`1`] = {
---    [`0`] = 1, -- number of diagnostics in the line
---    [`vim.Diagnostic`] = vim.Diagnostic,
---    [`vim.Diagnostic`] = vim.Diagnostic,
---  }
---  [`2`] = {
---    [`0`] = 1, -- number of diagnostics in the line
---    [`vim.Diagnostic`] = vim.Diagnostic,
---    [`vim.Diagnostic`] = vim.Diagnostic,
---  }
--- }
---

local Buffer = {}

--- Create a new buffer diagnostic cache.
--- @return BufferDiagnostic The new buffer diagnostic
Buffer.new = function()
	local buffer = {}

	---@type BufferDiagnostic
	local proxy_buffer = {
		-- This function is used to inspect the diagnostics cache for debug
		--- @return table<integer, LineDiagnostic>
		raw = function()
			return buffer
		end,
		pairs = function()
			return pairs(buffer)
		end,
	}

	return setmetatable(proxy_buffer, {
		__pairs = function(_)
			return pairs(buffer)
		end,

		__index = function(_, line)
			return buffer[line]
		end,

		--- Tracks the existence of diagnostics for a buffer at a line.
		--- @param line integer The lnum of the diagnostic being tracked in 1-based index. It's also the line where the diagnostic is located in the buffer
		--- @param diagnostic vim.Diagnostic|vim.Diagnostic[]|nil The diagnostic being tracked
		__newindex = function(t, line, diagnostic)
			if diagnostic == nil or not next(diagnostic) then
				-- Untrack this line if `diagnostic` is nil or an empty table.
				local diags = buffer[line]
				if diags then
					for _, d in diags.pairs() do
						local lnum = d.lnum + 1
						if line == lnum then
							local end_lnum = d.end_lnum + 1
							-- The line is the original line of the diagnostic so we need to remove all related lines
							-- If not the diagnostic still exists and should not be removed
							for i = lnum, end_lnum do
								local diags_i = buffer[i]
								if diags_i and diags_i[d] and (diags_i[0] or 0) > 1 then
									diags_i[d] = nil
									diags_i[0] = diags_i[0] - 1
								else
									buffer[i] = nil
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
					local diags_i = buffer[i]
					if not diags_i then
						local diags = {
							[0] = 1,
							[diagnostic] = diagnostic,
						}

						--- @type LineDiagnostic
						buffer[i] = setmetatable(diags, {
							__index = {
								-- This is a hack to make the diagnostics iterable work in lua 5.1
								ipairs = function()
									local k = nil
									local idx = 0
									return function(_, _, v)
										k, v = next(diags, k)
										if k == 0 then
											k, v = next(diags, k)
										end
										if k then
											idx = idx + 1
											return idx, v
										end
									end
								end,
								-- This is a hack to make the diagnostics iterable work in lua 5.1
								pairs = function()
									return function(_, k, v)
										k, v = next(diags, k)
										if k == 0 then
											return next(diags, k)
										end
										return k, v
									end
								end,
							},
							__len = function(t1)
								return t1[0]
							end,
							__pairs = function(t1)
								return t1.pairs()
							end,
							__ipairs = function(t1)
								return t1.ipairs()
							end,
						})
					elseif not diags_i[diagnostic] then
						diags_i[diagnostic] = diagnostic
						diags_i[0] = diags_i[0] + 1
					end
				end
			end
		end,
	})
end

return Buffer
