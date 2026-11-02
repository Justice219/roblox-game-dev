--!strict
--[[
	AttackRng — a tiny deterministic 32-bit PRNG for attack outcomes (intercept rolls, impact
	point choice).

	Why not Roblox `Random`: the attack outcome must be reproducible in the Lune tests exactly as
	it runs on the server (Lune has no `Random`, and the test loader's stand-in is a different
	generator). This module is pure Luau (`bit32` only), so the SAME code rolls in Studio, on the
	live server and in tests/attack-logic.luau.

	Algorithm: mulberry32 (Tommy Ettinger) — 32-bit state, passes basic statistical tests, more
	than enough for game rolls. Seeds are mixed with the murmur3 32-bit finaliser (`mix`) so
	neighbouring nuke ids give unrelated streams.

	Security: the server seeds every nuke from a per-server secret (Random.new():NextInteger at
	boot) mixed with the nuke id, so clients cannot predict a roll before it is published. Rolls
	are only ever made on the server; clients receive the decided timeline (NukeFlight).

	Example:
		local rng = AttackRng.new(AttackRng.mix(serverSeed, nukeId))
		if rng:next() < 0.3 then ... end           -- [0, 1)
		local index = rng:integer(1, 8)             -- 1..8 inclusive
]]

local AttackRng = {}
AttackRng.__index = AttackRng

export type Rng = typeof(setmetatable({} :: { state: number }, AttackRng))

local TWO32 = 4294967296

--[[
	32-bit multiply modulo 2^32 (C `imul`), exact in doubles: the 16-bit split keeps every partial
	product below 2^49, far inside the 2^53 integer range.
	@param a number — 0..2^32-1
	@param b number — 0..2^32-1
	@return number — (a * b) mod 2^32
]]
local function imul(a: number, b: number): number
	local aHigh = bit32.rshift(a, 16)
	local aLow = bit32.band(a, 0xFFFF)
	local high = (aHigh * b) % TWO32
	return (high * 65536 + aLow * b) % TWO32
end
AttackRng.imul = imul

-- Any finite number as an unsigned 32-bit integer (floor, then wrap). NaN / inf → 0.
local function u32(value: number): number
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.floor(value) % TWO32
end

--[[
	Mixes two numbers into one well-spread 32-bit seed (murmur3 fmix32 over a ^ b * golden ratio).
	@param a number — e.g. the per-server secret seed
	@param b number — e.g. the nuke id
	@return number — 0..2^32-1
	Example: AttackRng.mix(123456, 7) --> a 32-bit integer
]]
function AttackRng.mix(a: number, b: number): number
	local h = bit32.bxor(u32(a), imul(u32(b), 0x9E3779B1))
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = imul(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = imul(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

--[[
	Creates a generator.
	@param seed number — any finite number (wrapped to 32 bits)
	@return Rng
]]
function AttackRng.new(seed: number): Rng
	return setmetatable({ state = u32(seed) }, AttackRng)
end

--[[
	Next uniform number in [0, 1) (mulberry32 step).
	@return number
]]
function AttackRng.next(self: Rng): number
	self.state = (self.state + 0x6D2B79F5) % TWO32
	local t = self.state
	t = imul(bit32.bxor(t, bit32.rshift(t, 15)), bit32.bor(t, 1))
	t = bit32.bxor(t, (t + imul(bit32.bxor(t, bit32.rshift(t, 7)), bit32.bor(t, 61))) % TWO32)
	return bit32.bxor(t, bit32.rshift(t, 14)) / TWO32
end

--[[
	Next whole number in [min, max] (inclusive). max < min returns min.
	@param min number
	@param max number
	@return number
]]
function AttackRng.integer(self: Rng, min: number, max: number): number
	if max <= min then
		return min
	end
	return min + math.floor(self:next() * (max - min + 1))
end

return AttackRng
