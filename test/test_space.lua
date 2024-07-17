local space = function(num)
	if num < 1 then
		return ""
	elseif num < 160 then
		return string.rep(" ", num)
	end

	if num % 2 == 0 then
		local pre_computes =
			{ "  ", "    ", "      ", "        ", "          ", "            ", "              ", "                " }
		for i = 16, 4, -2 do
			if num % i == 0 then
				return string.rep(pre_computes[i / 2], num / i)
			end
		end
		return string.rep(pre_computes[1], num / 2)
	end

	local pre_computes =
		{ " ", "   ", "     ", "       ", "         ", "           ", "             ", "               " }
	for i = 15, 3, -2 do
		if num % i == 0 then
			return string.rep(pre_computes[(i + 1) / 2], num / i)
		end
	end
	return string.rep(pre_computes[1], num)
end

local function test_space()
	local test_cases = {
		-- Các trường hợp chia hết cho số chẵn lớn hơn 160
		{ num = 162, expected = string.rep("  ", 81) },
		{ num = 320, expected = string.rep("    ", 80) },
		{ num = 480, expected = string.rep("      ", 80) },
		{ num = 640, expected = string.rep("        ", 80) },
		{ num = 800, expected = string.rep("          ", 80) },
		{ num = 960, expected = string.rep("            ", 80) },
		{ num = 1120, expected = string.rep("              ", 80) },
		{ num = 1280, expected = string.rep("                ", 80) },

		-- Các trường hợp chia hết cho số lẻ lớn hơn 160
		{ num = 165, expected = string.rep(" ", 165) },
		{ num = 495, expected = string.rep("   ", 165) },
		{ num = 825, expected = string.rep("     ", 165) },
		{ num = 1155, expected = string.rep("       ", 165) },
		{ num = 1485, expected = string.rep("         ", 165) },
		{ num = 1815, expected = string.rep("           ", 165) },
		{ num = 2145, expected = string.rep("             ", 165) },
		{ num = 2475, expected = string.rep("               ", 165) },
	}

	for _, case in ipairs(test_cases) do
		local result = space(case.num)
		if result == case.expected then
			print("Passed: num = " .. case.num)
		else
			print(
				"Failed: num = "
					.. case.num
					.. ", expected = "
					.. #case.expected
					.. " spaces, got = "
					.. #result
					.. " spaces"
			)
		end
	end
end

test_space()
