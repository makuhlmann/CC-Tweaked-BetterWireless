-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Find where a computer is from how far it is from places whose positions it knows (GPS hosts, or cells), and how
far off that may be. The [`gps`] API and phones share it.

Distances from modem messages are exact, so a computer which stays put is found exactly. One which moves heard each
place at another time, from somewhere else. Given enough fixes, heard over a few seconds, we work out how it's moving
as well as where it is, which is exact again for a computer going steadily in a straight line, and close for one which
turns slowly. Otherwise each distance may be off by as far as we've moved since (our speed times the fix's age, the
speed from how fast the distance to a place heard twice changed), and we may be wherever the distances, each off by no
more than that, could put us. How far that is depends on where the places are: seen from far away, places close
together (or at much the same height) say little about one direction, and we may be far off along it.

This is loaded with `dofile` by the `gps` API, and with `require` by phones, so it uses neither.

@local
]]

local sqrt = math.sqrt

-- How far from a line or a plane places may be and still count as on it, in blocks. Positions are block coordinates.
local TOLERANCE = 0.5
-- How far back fixes may go to work out how we're moving, in seconds: further, and we'll likely have turned.
local MOVING_WINDOW = 10
-- How many fixes it takes to work out how we're moving: six unknowns, and some to spare to tell how well they fit.
local MOVING_FIXES = 8
-- How old fixes count for half as much in working out how we're moving, in seconds.
local RECENT = 2.5
-- How much worse than the best fit, in units of how far the fixes disagree (squared, on average), where we are may still
-- fit: 8 is where we'd be about 95% of the time, if they disagreed at random.
local DISAGREEMENT = 8

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function scale(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
local function length(a) return sqrt(dot(a, a)) end
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

--[[ Where a point would be on the far side of the plane which fits some points best: through their middle, across the
way they spread least (found by inverse iteration on how they spread, a little more each way so points which are in a
plane still have an answer). ]]
local function far_side(p, points)
    local middle, spread = { 0, 0, 0 }, zero()
    for _, point in ipairs(points) do middle = add(middle, scale(point, 1 / #points)) end
    for _, point in ipairs(points) do add_outer(spread, sub(point, middle), 1) end
    local extra = 1e-6 * (spread[1] + spread[5] + spread[9])
    spread[1], spread[5], spread[9] = spread[1] + extra, spread[5] + extra, spread[9] + extra
    local inv = inverse(spread)
    if not inv then return nil end
    local normal = { 0.3, 0.9, 0.3 }
    for _ = 1, 16 do
        normal = times(inv, normal)
        normal = scale(normal, 1 / length(normal))
    end
    return sub(p, scale(normal, 2 * dot(sub(p, middle), normal)))
end

--[[ How well a position fits: the distances' misfits, squared and weighted. Each fix has a weight (`weights`): fresher
ones count for more, as we've moved less since. ]]
local function cost(p, places, weights)
    local px, py, pz, total = p[1], p[2], p[3], 0
    for i = 1, #places do
        local place = places[i]
        local at = place.at
        local dx, dy, dz = px - at[1], py - at[2], pz - at[3]
        local r = sqrt(dx * dx + dy * dy + dz * dz) - place.distance
        total = total + weights[i] * r * r
    end
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
        -- The normal equations, written out: m = Σ w u uᵀ, v = Σ w u (misfit).
        local m11, m12, m13, m22, m23, m33, v1, v2, v3 = 0, 0, 0, 0, 0, 0, 0, 0, 0
        local px, py, pz = p[1], p[2], p[3]
        for i = 1, #places do
            local place = places[i]
            local at = place.at
            local dx, dy, dz = px - at[1], py - at[2], pz - at[3]
            local d = sqrt(dx * dx + dy * dy + dz * dz)
            if d > 0 then
                local w = weights[i]
                dx, dy, dz = dx / d, dy / d, dz / d
                m11, m12, m13 = m11 + w * dx * dx, m12 + w * dx * dy, m13 + w * dx * dz
                m22, m23, m33 = m22 + w * dy * dy, m23 + w * dy * dz, m33 + w * dz * dz
                local r = (d - place.distance) * w
                v1, v2, v3 = v1 + dx * r, v2 + dy * r, v3 + dz * r
            end
        end
        local m, v = { m11, m12, m13, m12, m22, m23, m13, m23, m33 }, { v1, v2, v3 }
        if fixed then add_outer(m, fixed, 1000 * (m[1] + m[5] + m[9])) end
        local inv = inverse(m)
        if not inv then return p end
        local step, moved = times(inv, v), nil
        -- Only across the fixed direction: the weight above keeps the system solvable, but leaves a little of a step
        -- along it, which would creep along it for ever.
        if fixed then step = sub(step, scale(fixed, dot(step, fixed))) end
        for _ = 1, 30 do
            local candidate = sub(p, step)
            local candidate_fit = cost(candidate, places, weights)
            if candidate_fit <= fit then
                p, fit, moved = candidate, candidate_fit, step
                break
            end
            step = scale(step, 0.5)
        end
        -- A micrometre is close enough: positions are given to a hundredth of a block.
        if not moved or length(moved) < 1e-6 then break end
    end
    return p
end

--[[ Find where we are, taking it we stood still, from each place's newest fix: exact if we did. If we moved, each
distance may be off by how far we went since (speed times age). Returns x, y, z and the error, or nil, why and (if we
might be either side of a plane) the two places we might be. `quick` gives the error to first order, which is never
more than the full one, without the work of finding the rest. ]]
local function still(fixes, speed, quick)

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
        h = sqrt(math.max(0, total / #places))
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
    than Σ w e². Distances which disagree beyond what three need to agree on may be off for other reasons, by about as
    much as they disagree (`DISAGREEMENT`). So we're within `slack` of how well the best fit does. ]]
    local slack = 0
    for i, place in ipairs(places) do slack = slack + weights[i] * (speed * place.age) ^ 2 end
    if #places > 3 then slack = slack + DISAGREEMENT * here / (#places - 3) end
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
            for _ = 1, 6 do
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
        least = (m11 + m22) / 2 - sqrt(((m11 - m22) / 2) ^ 2 + m12 ^ 2)
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
    local off = sqrt(slack / least)
    if quick then return round(p[1]), round(p[2]), round(p[3]), round(sqrt(off * off + h * h)) end
    -- That's as good as going there unless we may be far off compared to how far the places are: then the directions
    -- to them change along the way.
    local nearest = math.huge
    for _, place in ipairs(places) do nearest = math.min(nearest, length(sub(p, place.at))) end
    if flat or off > 0.02 * nearest then
        off = math.max(off, reach(weakest, math.max(0.01, flat and sqrt(slack) or off / 2)))
    end

    -- Places nearly in a plane leave somewhere each side of it which fits nearly as well. If the far side fits within
    -- slack too, we may be there.
    if not flat and off ~= math.huge then
        local points = {}
        for i, place in ipairs(places) do points[i] = place.at end
        local seed = far_side(p, points)
        if seed then
            local other = refine(seed, places, weights)
            local apart = length(sub(other, p))
            if apart > off and cost(other, places, weights) <= limit then off = apart + off end
        end
    end

    if off == math.huge then return round(p[1]), round(p[2]), round(p[3]), off end
    return round(p[1]), round(p[2]), round(p[3]), round(sqrt(off * off + h * h))
end

-- Solve a 6x6 system (rows of six numbers) for b, by Gaussian elimination, or nil if it has no answer worth the name.
local function solve6(m, b)
    local a, largest = {}, 0
    for r = 1, 6 do
        a[r] = { m[r][1], m[r][2], m[r][3], m[r][4], m[r][5], m[r][6], b[r] }
        for c = 1, 6 do largest = math.max(largest, math.abs(m[r][c])) end
    end
    if largest == 0 then return nil end
    for c = 1, 6 do
        local pivot = c
        for r = c + 1, 6 do
            if math.abs(a[r][c]) > math.abs(a[pivot][c]) then pivot = r end
        end
        if math.abs(a[pivot][c]) <= 1e-12 * largest then return nil end
        a[c], a[pivot] = a[pivot], a[c]
        for r = c + 1, 6 do
            local f = a[r][c] / a[c][c]
            for k = c, 7 do a[r][k] = a[r][k] - f * a[c][k] end
        end
    end
    local x = {}
    for r = 6, 1, -1 do
        local s = a[r][7]
        for k = r + 1, 6 do s = s - a[r][k] * x[k] end
        x[r] = s / a[r][r]
    end
    return x
end

--[[ Find where we are and how we're moving (x, y, z now, and our velocity), taking it we went steadily in a straight
line, from every fix of the last few seconds, starting from a guess at where we are. Each fix was heard from where we
were `age` seconds ago: here, less velocity times age. Fresher fixes count for more (`RECENT`), so the fit follows a
turn sooner. Returns x, y, z, how far off that may be, and how well the fixes fit; or nil.

How far off we may be has two parts. How well the fixes fit: a computer which went steadily in a straight line fits
them exactly, and one which turned long enough ago, less well; as for standing still, we may be wherever fits within
that much more (`DISAGREEMENT` times what each fix is off by, squared, on average beyond what the six unknowns soak
up). And a turn the newest fixes can't show yet: it takes three places' distances to pin down where we are, so since
the third newest of those, we may have gone another way, by up to twice our speed for that long. ]]
local function moving(fixes, from, speed)
    for _, fix in ipairs(fixes) do fix.weight = 1 / (1 + (fix.age / RECENT) ^ 2) end
    local function misfit(state)
        local total = 0
        for i = 1, #fixes do
            local fix = fixes[i]
            local age, place = fix.age, fix.at
            local dx = state[1] - state[4] * age - place[1]
            local dy = state[2] - state[5] * age - place[2]
            local dz = state[3] - state[6] * age - place[3]
            local r = sqrt(dx * dx + dy * dy + dz * dz) - fix.distance
            total = total + fix.weight * r * r
        end
        return total
    end
    -- The normal equations at a state: JtWJ, and JtW times the misfits, J being how each distance changes with each
    -- unknown, and W the weights.
    local function normal(state)
        -- Each fix's row is (u, -age u), so the matrix is made of Σ w u uᵀ, times 1, -age and age² for its blocks.
        local p11, p12, p13, p22, p23, p33 = 0, 0, 0, 0, 0, 0
        local q11, q12, q13, q22, q23, q33 = 0, 0, 0, 0, 0, 0
        local s11, s12, s13, s22, s23, s33 = 0, 0, 0, 0, 0, 0
        local g1, g2, g3, h1, h2, h3 = 0, 0, 0, 0, 0, 0
        local x, y, z, vx, vy, vz = state[1], state[2], state[3], state[4], state[5], state[6]
        for i = 1, #fixes do
            local fix = fixes[i]
            local age, place, w = fix.age, fix.at, fix.weight
            local dx, dy, dz = x - vx * age - place[1], y - vy * age - place[2], z - vz * age - place[3]
            local d = sqrt(dx * dx + dy * dy + dz * dz)
            if d > 0 then
                dx, dy, dz = dx / d, dy / d, dz / d
                local xx, xy, xz, yy, yz, zz = w * dx * dx, w * dx * dy, w * dx * dz, w * dy * dy, w * dy * dz, w * dz * dz
                p11, p12, p13, p22, p23, p33 = p11 + xx, p12 + xy, p13 + xz, p22 + yy, p23 + yz, p33 + zz
                local a, a2 = -age, age * age
                q11, q12, q13, q22, q23, q33 = q11 + a * xx, q12 + a * xy, q13 + a * xz, q22 + a * yy, q23 + a * yz, q33 + a * zz
                s11, s12, s13, s22, s23, s33 = s11 + a2 * xx, s12 + a2 * xy, s13 + a2 * xz, s22 + a2 * yy, s23 + a2 * yz, s33 + a2 * zz
                local e = (d - fix.distance) * w
                g1, g2, g3 = g1 + dx * e, g2 + dy * e, g3 + dz * e
                h1, h2, h3 = h1 + a * dx * e, h2 + a * dy * e, h3 + a * dz * e
            end
        end
        return {
            { p11, p12, p13, q11, q12, q13 },
            { p12, p22, p23, q12, q22, q23 },
            { p13, p23, p33, q13, q23, q33 },
            { q11, q12, q13, s11, s12, s13 },
            { q12, q22, q23, s12, s22, s23 },
            { q13, q23, q33, s13, s23, s33 },
        }, { g1, g2, g3, h1, h2, h3 }
    end

    local state = { from[1], from[2], from[3], 0, 0, 0 }
    local fit = misfit(state)
    for _ = 1, 20 do
        local before = fit
        local step = solve6(normal(state))
        if not step then return nil end
        local moved
        for _ = 1, 30 do
            local candidate = {}
            for k = 1, 6 do candidate[k] = state[k] - step[k] end
            local candidate_fit = misfit(candidate)
            if candidate_fit <= fit then
                state, fit, moved = candidate, candidate_fit, step
                break
            end
            for k = 1, 6 do step[k] = step[k] * 0.5 end
        end
        -- Done once a step hardly helps: a micrometre's misfit, or a millionth of it.
        if not moved or before - fit <= 1e-12 + 1e-6 * before then break end
    end

    -- How well the fixes fit: along the direction where our position is least certain, given the velocity can make up
    -- for some of it (the inverse's corner for our position).
    local off = 0
    local slack = DISAGREEMENT * fit / (#fixes - 6)
    if slack > 1e-12 then
        local m = normal(state)
        local corner = zero()
        for c = 1, 3 do
            local unit = { 0, 0, 0, 0, 0, 0 }
            unit[c] = 1
            local column = solve6(m, unit)
            if not column then return nil end
            for r = 1, 3 do corner[(r - 1) * 3 + c] = column[r] end
        end
        local direction, largest = { 1, 1, 1 }, 0
        for _ = 1, 32 do
            direction = times(corner, direction)
            largest = length(direction)
            if largest == 0 then break end
            direction = scale(direction, 1 / largest)
        end
        off = sqrt(slack * largest)
    end

    -- A turn since the third newest place's fix.
    local newest = {}
    for _, fix in ipairs(fixes) do
        local known
        for _, place in ipairs(newest) do
            if length(sub(place.at, fix.at)) < TOLERANCE then known = place end
        end
        if known then known.age = math.min(known.age, fix.age) else newest[#newest + 1] = { at = fix.at, age = fix.age } end
    end
    table.sort(newest, function(a, b) return a.age < b.age end)
    local velocity = sqrt(state[4] ^ 2 + state[5] ^ 2 + state[6] ^ 2)
    local unseen = newest[3] and newest[3].age or 0
    return state[1], state[2], state[3], off + 2 * math.max(speed, velocity) * unseen, fit
end

--[[- Find where we are.

Each fix of a place counts, even several of one place: from how the distance to it changed, we know how fast we're
moving towards or away from it, at least, and from enough fixes over a few seconds, how we're moving.

@tparam { { x = number, y = number, z = number, distance = number, age? = number }... } fixes Each place heard: its
position, how far away it was, and how many seconds ago that was (0 if just now).
@tparam[opt=0] number speed How fast we may be moving, in blocks a second, if we know better than the fixes say.
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

    -- How fast we've lately been moving towards or away from each place heard more than once: between its two newest
    -- fixes.
    local list, groups = {}, {}
    for i, fix in ipairs(fixes) do
        local entry = { at = { fix.x, fix.y, fix.z }, distance = fix.distance, age = math.max(0, fix.age or 0) }
        list[i] = entry
        local group
        for _, other in ipairs(groups) do
            if length(sub(other[1].at, entry.at)) < TOLERANCE then group = other end
        end
        if group then group[#group + 1] = entry else groups[#groups + 1] = { entry } end
    end
    for _, group in ipairs(groups) do
        table.sort(group, function(a, b) return a.age < b.age end)
        local newest, before = group[1], group[2]
        if before and before.age - newest.age > 0.05 then
            speed = math.max(speed, math.abs(newest.distance - before.distance) / (before.age - newest.age))
        end
    end

    local x, y, z, off = still(fixes, speed, true)
    if not x or off == 0 then return x, y, z, off end

    -- We moved: if we've enough fixes of the last few seconds, of enough places, work out how, which may say better
    -- where we are. Start from where standing still put us, and from the far side of the places' plane, where we may
    -- be instead, and keep whichever fits better.
    local recent, places = {}, {}
    for _, fix in ipairs(list) do
        if fix.age <= MOVING_WINDOW then
            recent[#recent + 1] = fix
            local known = false
            for _, place in ipairs(places) do
                if length(sub(place, fix.at)) < TOLERANCE then known = true end
            end
            if not known then places[#places + 1] = fix.at end
        end
    end
    local best
    if #recent >= MOVING_FIXES and #places >= 4 then
        local fits = {}
        for _, start in ipairs { { x, y, z }, far_side({ x, y, z }, places) } do
            local mx, my, mz, moving_off, fit = moving(recent, start, speed)
            if mx then fits[#fits + 1] = { mx, my, mz, moving_off, fit } end
            -- A fit with no misfit to speak of is where we are: the far side can't fit as well, unless the places
            -- are all in a plane, as for standing still.
            if mx and fit <= 1e-9 then break end
        end
        table.sort(fits, function(a, b) return a[5] < b[5] end)
        best = fits[1]
        -- If the other fits nearly as well (within what the fixes disagree by), we may be there instead.
        local other = fits[2]
        if other then
            local apart = length(sub(other, best))
            if apart >= TOLERANCE and other[5] - best[5] <= DISAGREEMENT * best[5] / (#recent - 6) then
                best[4] = best[4] + apart
            end
        end
        -- The quick error is never more than the full one: if this beats it, it beats that.
        if best and best[4] < off then return round(best[1]), round(best[2]), round(best[3]), round(best[4]) end
    end
    x, y, z, off = still(fixes, speed)
    if best and best[4] < off then return round(best[1]), round(best[2]), round(best[3]), round(best[4]) end
    return x, y, z, off
end

return { locate = locate }
