local M = setmetatable({}, {
	__index = function(_, k)
		return require("better-diagnostic-virtual-text.api")[k]
	end,
})

function M.setup(opts)
	vim.api.nvim_create_autocmd("LspAttach", {
		nested = true,
		callback = function(args)
			require("better-diagnostic-virtual-text.api").setup_buf(args.buf, opts)
		end,
	})
end

return M
