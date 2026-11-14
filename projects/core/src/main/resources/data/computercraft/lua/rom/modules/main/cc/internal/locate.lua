-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Find where a computer is from how far it is from places whose positions it knows (GPS hosts, or cells), and how
far off that may be. The [`gps`] API and phones share it.

Distances from modem messages are exact, so a computer which stays put is found exactly. One which moves is found less
well: it heard each place at another time, from somewhere else, so each distance may be off by as far as it has moved
since (its speed times the fix's age). Where we may be is then wherever the distances, each off by no more than that,
could put us. Its size depends on where the places are: seen from far away, places close together (or at much the same
height) say little about one direction, and we may be far off along it.

This is loaded with `dofile` by the `gps` API, and with `require` by phones, so it uses neither.

@local
]]

-- How far from a line or a plane places may be and still count as on it, in blocks. Positions are block coordinates.
local TOLERANCE = 0.5

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function scale(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
local function length(a) return math.sqrt(dot(a, a)) end
local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

-- Round to hundredths, as GPS always has.
local function round(v) return math.floor(v * 100 + 0.5) / 100 end

-- 3x3 matrices are nine numbers, row by row.
local function zero() return { 0, 0, 0, 0, 0, 0, 0, 0, 0 } end

-- Add w v vᵀ to a matrix.
local function add_outer(m, v, w)
    for r = 1, 3 do
        for c = 1, 3 do m[(r - 1) * 3 + c] = m[(r - 1) * 3 + c] + w * v[r] * v[c] end
    end
end

local function times(m, v)
    return {
        m[1] * v[1] + m[2] * v[2] + m[3] * v[3],
        m[4] * v[1] + m[5] * v[2] + m[6] * v[3],
        m[7] * v[1] + m[8] * v[2] + m[9] * v[3],
    }
end

-- A matrix's inverse, or nil if it has none worth the name.
local function inverse(m)
    local a, b, c, d, e, f, g, h, i = m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]
    local A, B, C = e * i - f * h, f * g - d * i, d * h - e * g
    local det = a * A + b * B + c * C
    local largest = 0
    for k = 1, 9 do largest = math.max(largest, math.abs(m[k])) end
    if largest == 0 or math.abs(det) <= 1e-14 * largest ^ 3 then return nil end
    local D, E, F = c * h - b * i, a * i - c * g, b * g - a * h
    local G, H, I = b * f - c * e, c * d - a * f, a * e - b * d
    return { A / det, D / det, G / det, B / det, E / det, H / det, C / det, F / det, I / det }
end

--[[ How well a position fits: the distances' misfits, squared and weighted. Each fix has a weight (`weights`): fresher
ones count for more, as we've moved less since. ]]
local function cost(p, places, weights)
    local total = 0
    for i, place in ipairs(places) do total = total + weights[i] * (length(sub(p, place.at)) - place.distance) ^ 2 end
    return total
end

--[[ How a position's fit changes as it moves (to first order): A = Σ w u uᵀ, u being the direction from each place. A
direction A makes little of is one the distances say little about. ]]
local function curvature(p, places, weights)
    local m = zero()
    for i, place in ipairs(places) do
        local offset = sub(p, place.at)
        local d = length(offset)
        if d > 0 then add_outer(m, scale(offset, 1 / d), weights[i]) end
    end
    return m
end

--[[ Move to the position which fits best, by least squares (Gauss-Newton), from one nearby. Given a direction
(`fixed`), only across it. A step which fits worse is shortened until it doesn't, as far from the places as they're
apart, the fit can be so flat that a whole step would go far past the best place. ]]
local function refine(p, places, weights, fixed)
    local fit = cost(p, places, weights)
    for _ = 1, 30 do
        local m, v = zero(), { 0, 0, 0 }
        for i, place in ipairs(places) do
            local offset = sub(p, place.at)
            local d = length(offset)
            if d > 0 then
                local u = scale(offset, 1 / d)
                add_outer(m, u, weights[i])
                v = add(v, scale(u, (d - place.distance) * weights[i]))
            end
        end
        if fixed then add_outer(m, fixed, 1000 * (m[1] + m[5] + m[9])) end
        local inv = inverse(m)
        if not inv then return p end
        local step, moved = times(inv, v), nil
        for _ = 1, 30 do
            local candidate = sub(p, step)
            local candidate_fit = cost(candidate, places, weights)
            if candidate_fit <= fit then
                p, fit, moved = candidate, candidate_fit, step
                break
            end
            step = scale(step, 0.5)
        end
        if not moved or length(moved) < 1e-9 then break end
    end
    return p
end

--[[- Find where we are.

@tparam { { x = number, y = number, z = number, distance = number, age? = number }... } fixes Each place heard: its
position, how far away it was, and how many seconds ago that was (0 if just now).
@tparam[opt=0] number speed How fast we may be moving, in blocks a second.
@treturn[1] number Our `x` position.
@treturn[1] number Our `y` position.
@treturn[1] number Our `z` position.
@treturn[1] number How far off that may be, in blocks: 0 if it's exact.
@treturn[2] nil If we can't tell.
@treturn[2] string Why not: `"too few"` (fewer than three places, or all on a line) or `"ambiguous"` (the places
are all in a plane, as hosts at one height are, and we're off it, so we might be on either side).
@treturn[2] table|nil One place we might be, if ambiguous, as `{ x, y, z }`: the one above the plane.
@treturn[2] table|nil The other.
]]
local function locate(fixes, speed)
    speed = speed or 0

    -- One fix for each place: the newest.
    local places = {}
    for index, fix in ipairs(fixes) do
        local place = { at = { fix.x, fix.y, fix.z }, distance = fix.distance, age = math.max(0, fix.age or 0), index = index }
        local same
        for i, other in ipairs(places) do
            if length(sub(place.at, other.at)) < TOLERANCE then
                same = i
                break
            end
        end
        if not same then
            places[#places + 1] = place
        elseif place.age < places[same].age then
            places[same] = place
        end
    end

    -- Right at one of them: no geometry needed.
    for _, place in ipairs(places) do
        if place.distance == 0 then return place.at[1], place.at[2], place.at[3], round(speed * place.age) end
    end
    if #places < 3 then return nil, "too few" end

    -- Work from the newest fix, the place furthest from it, and the place furthest from the line between those two.
    table.sort(places, function(a, b)
        if a.age ~= b.age then return a.age < b.age end
        return a.index < b.index
    end)
    local first = places[1]
    local far, far_d = nil, 0
    for _, place in ipairs(places) do
        local d = length(sub(place.at, first.at))
        if d > far_d then far, far_d = place, d end
    end
    if far_d < TOLERANCE then return nil, "too few" end
    local ex = scale(sub(far.at, first.at), 1 / far_d)
    local side, side_d = nil, 0
    for _, place in ipairs(places) do
        local v = sub(place.at, first.at)
        local d = length(sub(v, scale(ex, dot(v, ex))))
        if d > side_d then side, side_d = place, d end
    end
    if side_d < TOLERANCE then return nil, "too few" end
    local towards = sub(side.at, first.at)
    local ey = sub(towards, scale(ex, dot(towards, ex)))
    ey = scale(ey, 1 / length(ey))
    -- Their plane's normal, pointing up (or else south, or east), so the place above it comes first when we can't tell.
    local ez = cross(ex, ey)
    if ez[2] < -1e-9 or (math.abs(ez[2]) <= 1e-9 and (ez[3] < -1e-9 or (math.abs(ez[3]) <= 1e-9 and ez[1] < 0))) then
        ez = scale(ez, -1)
    end
    local flat = true
    for _, place in ipairs(places) do
        if math.abs(dot(sub(place.at, first.at), ez)) >= TOLERANCE then flat = false end
    end

    --[[ Taking the first place's sphere from each other's gives a plane each: (place - first) . q = b, where q is our
    position from the first place. ]]
    local rows = {}
    for i = 2, #places do
        local offset = sub(places[i].at, first.at)
        rows[#rows + 1] = { offset, (dot(offset, offset) + first.distance ^ 2 - places[i].distance ^ 2) / 2 }
    end

    local p, h = nil, 0
    if flat then
        -- In the places' plane: solve there, then how far off it we are says where, up to which side.
        local m11, m12, m22, r1, r2 = 0, 0, 0, 0, 0
        for _, row in ipairs(rows) do
            local a, b = dot(row[1], ex), dot(row[1], ey)
            m11, m12, m22 = m11 + a * a, m12 + a * b, m22 + b * b
            r1, r2 = r1 + a * row[2], r2 + b * row[2]
        end
        local det = m11 * m22 - m12 * m12
        if math.abs(det) < 1e-12 then return nil, "too few" end
        local q = add(scale(ex, (m22 * r1 - m12 * r2) / det), scale(ey, (m11 * r2 - m12 * r1) / det))
        local total = 0
        for _, place in ipairs(places) do
            local in_plane = sub(q, sub(place.at, first.at))
            total = total + place.distance ^ 2 - dot(in_plane, in_plane)
        end
        h = math.sqrt(math.max(0, total / #places))
        p = add(first.at, q)
        if h >= TOLERANCE then
            local one, other = add(p, scale(ez, h)), add(p, scale(ez, -h))
            return nil, "ambiguous", { round(one[1]), round(one[2]), round(one[3]) },
                { round(other[1]), round(other[2]), round(other[3]) }
        end
    else
        local m, r = zero(), { 0, 0, 0 }
        for _, row in ipairs(rows) do
            add_outer(m, row[1], 1)
            r = add(r, scale(row[1], row[2]))
        end
        local inv = inverse(m)
        if not inv then return nil, "ambiguous" end
        p = add(first.at, times(inv, r))
    end

    -- Fit the distances as well as we can, the fresher ones counting for more (but not so much more that the others
    -- count for nothing). In a plane, only within it.
    local weights = {}
    for i, place in ipairs(places) do weights[i] = 1 / (1 + (speed * place.age) ^ 2) end
    p = refine(p, places, weights, flat and ez or nil)
    local here = cost(p, places, weights)

    --[[ Where we may be. At most, each distance is off by how far we've moved since (e), so where we are fits no worse
    than Σ w e². Distances which disagree beyond what three need to agree on may be off for other reasons: by as much
    again as they disagree. So we're within `slack` of how well the best fit does. ]]
    local slack = 0
    for i, place in ipairs(places) do slack = slack + weights[i] * (speed * place.age) ^ 2 end
    if #places > 3 then slack = slack + 3 * here / (#places - 3) end
    if slack <= 1e-12 then return round(p[1]), round(p[2]), round(p[3]), round(h) end

    -- How far we may be along a direction: as far as the fit stays within slack, fitting again across it as we go.
    local limit = here + slack
    local function reach(along, start)
        local furthest = 0
        for _, sign in ipairs { 1, -1 } do
            local inside, outside, t = 0, nil, start
            local function fits(at)
                local q = refine(add(p, scale(along, sign * at)), places, weights, along)
                if cost(q, places, weights) > limit then return false end
                furthest = math.max(furthest, length(sub(q, p)))
                return true
            end
            for _ = 1, 40 do
                if not fits(t) then
                    outside = t
                    break
                end
                inside, t = t, t * 2
            end
            if not outside then return math.huge end
            for _ = 1, 12 do
                local middle = (inside + outside) / 2
                if fits(middle) then inside = middle else outside = middle end
            end
        end
        return furthest
    end

    --[[ To first order, the fit worsens by dᵀ A d moving by d, so we may be as far as sqrt(slack / λ) along each of A's
    directions (λ how much A makes of it). Further along the one it makes least of, which is where that's least
    true, find how far by going there. In a plane, that's off it (the distances hardly change as we leave it), and
    the rest is in it. ]]
    local a = curvature(p, places, weights)
    local weakest, least
    if flat then
        weakest = ez
        local ax, ay = times(a, ex), times(a, ey)
        local m11, m12, m22 = dot(ex, ax), dot(ex, ay), dot(ey, ay)
        least = (m11 + m22) / 2 - math.sqrt(((m11 - m22) / 2) ^ 2 + m12 ^ 2)
    else
        local inv = inverse(a)
        if not inv then return round(p[1]), round(p[2]), round(p[3]), math.huge end
        weakest = ez
        for _ = 1, 16 do
            weakest = times(inv, weakest)
            weakest = scale(weakest, 1 / length(weakest))
        end
        least = dot(weakest, times(a, weakest))
    end
    if least <= 0 then return round(p[1]), round(p[2]), round(p[3]), math.huge end
    local off = math.sqrt(slack / least)
    off = math.max(off, reach(weakest, math.max(0.01, flat and math.sqrt(slack) or off / 4)))

    -- Places nearly in a plane leave somewhere each side of it which fits nearly as well. If the far side fits within
    -- slack too, we may be there.
    if not flat and off ~= math.huge then
        local middle, spread = { 0, 0, 0 }, zero()
        for _, place in ipairs(places) do middle = add(middle, scale(place.at, 1 / #places)) end
        for _, place in ipairs(places) do add_outer(spread, sub(place.at, middle), 1) end
        local normal, inv = ez, inverse(spread)
        for _ = 1, inv and 16 or 0 do
            normal = times(inv, normal)
            normal = scale(normal, 1 / length(normal))
        end
        local other = refine(sub(p, scale(normal, 2 * dot(sub(p, middle), normal))), places, weights)
        local apart = length(sub(other, p))
        if apart > off and cost(other, places, weights) <= limit then off = apart + off end
    end

    if off == math.huge then return round(p[1]), round(p[2]), round(p[3]), off end
    return round(p[1]), round(p[2]), round(p[3]), round(math.sqrt(off * off + h * h))
end

return { locate = locate }
