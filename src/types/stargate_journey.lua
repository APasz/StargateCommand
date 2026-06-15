---@meta

---@alias SgJourneyInterfaceType
---| "advanced_crystal_interface"
---| "crystal_interface"
---| "basic_interface"

---@class StargateJourneyInterface
---@field addressToString fun(address: integer[]): string
---@field getEnergy fun(): number
---@field getEnergyCapacity fun(): number
---@field disconnectStargate fun(): boolean
---@field getChevronsEngaged fun(): integer
---@field getStargateGeneration fun(): integer
---@field engageSymbol fun(symbol: integer): integer, string?
---@field getCurrentSymbol fun(): integer
---@field rotateAntiClockwise fun(symbol: integer): integer, string?
---@field rotateClockwise fun(symbol: integer): integer, string?
---@field isCurrentSymbol fun(symbol: integer): boolean
---@field encodeChevron fun(): integer, string?
---@field openChevron fun(): integer, string?
---@field closeChevron fun(): integer, string?
---@field isStargateConnected fun(): boolean
---@field isStargateDialingOut fun(): boolean
---@field isWormholeOpen fun(): boolean
---@field getIris fun(): string?
---@field closeIris fun(): boolean
---@field openIris fun(): boolean
---@field stopIris fun(): boolean
---@field getIrisProgress fun(): number
---@field getIrisProgressPercentage fun(): number
---@field getDialedAddress fun(): integer[]
---@field getConnectedAddress fun(): integer[]
---@field getLocalAddress fun(): integer[]

return {}
