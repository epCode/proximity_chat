-- proximity_chat: how well one place can hear another.
--
-- The model, in one sentence: every wall between two people counts as extra
-- distance. Sound goes in a straight line from mouth to ear, each solid node
-- on the way adds `wall_penalty` nodes to the distance (half as much for
-- leaves, glass, fences and liquids), and the result is compared with the
-- range of the way the message was said. Inside `clear` of the range a message
-- is heard perfectly; between there and the range it fades out.

local acoustics = {}

-- Clarity steps. Listeners are rounded down to one of these so that people
-- standing near each other read exactly the same words, in chat and in the
-- speech bubble, and so a message is garbled at most this many ways.
acoustics.BANDS = {1, 0.8, 0.6, 0.4, 0.2}

-- Continuous clarity for an effective distance: 1 up to `clear`, falling
-- linearly to 0 at `range`. nil when it's out of earshot entirely.
function acoustics.clarity(effective, range, clear)
	if effective > range then
		return nil
	end
	if effective <= clear or range <= clear then
		return 1
	end
	return math.max(0, 1 - (effective - clear) / (range - clear))
end

-- Round a clarity down to a band.
function acoustics.band(clarity)
	local bands = acoustics.BANDS
	for i = 1, #bands do
		if clarity >= bands[i] - 1e-9 then
			return bands[i], i
		end
	end
	return bands[#bands], #bands
end

-- Where the speaker is, seen from the listener: "ahead", "right", "behind",
-- "left", "above" or "below". yaw is the listener's get_look_horizontal().
function acoustics.direction(from, yaw, to)
	local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
	local flat = math.sqrt(dx * dx + dz * dz)
	if math.abs(dy) > math.max(2, flat * 1.5) then
		return dy > 0 and "above" or "below"
	end
	if flat < 1e-6 then
		return "ahead"
	end
	-- Looking along yaw 0 means looking at +Z; yaw grows turning left.
	local fx, fz = -math.sin(yaw), math.cos(yaw)
	local ahead = dx * fx + dz * fz
	local right = dx * fz - dz * fx
	local angle = math.deg(math.atan2 and math.atan2(right, ahead) or math.atan(right, ahead))
	if angle >= -45 and angle <= 45 then
		return "ahead"
	elseif angle > 45 and angle < 135 then
		return "right"
	elseif angle < -45 and angle > -135 then
		return "left"
	end
	return "behind"
end

--------------------------------------------------------------------------------
-- Walls
--------------------------------------------------------------------------------

-- How much one node blocks sound: 1 for a solid block, less for things sound
-- gets through or around, 0 for air and anything you can walk through.
-- Nodes can say for themselves with the group `soundproof` (in tenths: 10 is
-- an ordinary block, 20 blocks twice as much, 0 not at all).
local PARTIAL = {
	glasslike = true, glasslike_framed = true, glasslike_framed_optional = true,
	allfaces = true, allfaces_optional = true, -- leaves
	fencelike = true, nodebox = true, mesh = true, plantlike_rooted = true,
	torchlike = true, signlike = true, raillike = true, plantlike = true,
	firelike = true,
}

function acoustics.node_weight(def)
	if not def then
		return 1 -- unknown nodes: assume solid
	end
	local groups = def.groups or {}
	if groups.soundproof then
		return groups.soundproof / 10
	end
	if def.liquidtype and def.liquidtype ~= "none" then
		return 0.5
	end
	if def.walkable == false or def.drawtype == "airlike" then
		return 0
	end
	if groups.wool then
		return 2 -- soft and thick: soaks sound up
	end
	if PARTIAL[def.drawtype] then
		return 0.5
	end
	return 1
end

local weights = {air = 0, ignore = 0}

local function weight_of(name)
	local w = weights[name]
	if not w then
		w = acoustics.node_weight(core.registered_nodes[name])
		weights[name] = w
	end
	return w
end

local scratch = {x = 0, y = 0, z = 0}
local function weight_at(x, y, z)
	scratch.x, scratch.y, scratch.z = x, y, z
	local node = core.get_node_or_nil(scratch)
	return node and weight_of(node.name) or 0
end

-- Add up how much the nodes on the straight line from p1 to p2 block sound,
-- not counting the nodes p1 and p2 are in. Stops early once the total passes
-- `limit` (nothing beyond it changes the outcome). Walks the line through the
-- node grid exactly (Amanatides & Woo), so it sees every node the line
-- crosses, pointable or not.
function acoustics.obstruction(p1, p2, limit, weight_fn)
	weight_fn = weight_fn or weight_at
	limit = limit or math.huge
	local floor = math.floor
	-- Nodes span [n - 0.5, n + 0.5); shift so they span [n, n + 1).
	local x0, y0, z0 = p1.x + 0.5, p1.y + 0.5, p1.z + 0.5
	local dx, dy, dz = p2.x + 0.5 - x0, p2.y + 0.5 - y0, p2.z + 0.5 - z0
	local ix, iy, iz = floor(x0), floor(y0), floor(z0)
	local ex, ey, ez = floor(p2.x + 0.5), floor(p2.y + 0.5), floor(p2.z + 0.5)
	local steps = math.abs(ex - ix) + math.abs(ey - iy) + math.abs(ez - iz)
	if steps == 0 then
		return 0
	end

	local huge = math.huge
	local function setup(i, o, d)
		if d > 0 then
			return 1, (i + 1 - o) / d, 1 / d
		elseif d < 0 then
			return -1, (o - i) / -d, 1 / -d
		end
		return 0, huge, huge
	end
	local sx, tx, ddx = setup(ix, x0, dx)
	local sy, ty, ddy = setup(iy, y0, dy)
	local sz, tz, ddz = setup(iz, z0, dz)

	local total = 0
	for step = 1, steps do
		if tx <= ty and tx <= tz then
			ix, tx = ix + sx, tx + ddx
		elseif ty <= tz then
			iy, ty = iy + sy, ty + ddy
		else
			iz, tz = iz + sz, tz + ddz
		end
		if step < steps then -- the last node is the listener's own
			total = total + weight_fn(ix, iy, iz)
			if total > limit then
				return total
			end
		end
	end
	return total
end

--------------------------------------------------------------------------------
-- Mouths and ears
--------------------------------------------------------------------------------

-- Where an object talks from and hears at: eye height for players, near the
-- top of the collision box for everything else.
function acoustics.head_pos(object)
	local pos = object:get_pos()
	if not pos then
		return nil
	end
	local props = object:get_properties()
	local height
	if object:is_player() then
		height = props.eye_height or 1.625
	else
		local box = props.collisionbox or props.selectionbox
		height = box and box[5] * 0.9 or 0.5
	end
	return {x = pos.x, y = pos.y + height, z = pos.z}
end

return acoustics
