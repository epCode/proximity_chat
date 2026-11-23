-- A tiny test helper shared by the unit tests.
local t = {passed = 0, failed = 0}

local function show(v)
	if type(v) == "string" then
		return ("%q"):format(v)
	end
	return tostring(v)
end

function t.section(name)
	print("\n== " .. name)
end

function t.ok(cond, msg)
	if cond then
		t.passed = t.passed + 1
		print("  ok   " .. msg)
	else
		t.failed = t.failed + 1
		print("  FAIL " .. msg)
	end
	return cond
end

function t.eq(got, want, msg)
	if got == want then
		return t.ok(true, msg)
	end
	t.ok(false, msg .. ("\n         got  %s\n         want %s"):format(show(got), show(want)))
	return false
end

function t.finish()
	print(("\n%d passed, %d failed"):format(t.passed, t.failed))
	return t.failed == 0 and 0 or 1
end

return t
