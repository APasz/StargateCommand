local sample = {}

---@return SgcAddressBook
function sample.create()
    return {
        schema = 2,
        revision = 2,
        updated_at = 0,
        updated_by = "system",
        sites = {
            command = {
                enabled = true,
                allow_outbound = true,
                id = "command",
                name = "SGCommand",
                location = {
                    universe = "minecraft",
                    galaxy = "milkyway",
                    dimension = "overworld",
                },
                addresses = {
                    system = { 27, 25, 4, 35, 10, 28 },
                    stellar = nil,
                    galactic = nil,
                },
                visibility = {
                    listed = true,
                    hidden_at = nil,
                    visible_from = nil,
                    intergalactic = { "*" },
                },
                tags = { "primary", "sgc" },
                notes = "Stargate Command site.",
            },
            nether = {
                enabled = true,
                allow_outbound = true,
                id = "nether",
                name = "Nether",
                location = {
                    universe = "minecraft",
                    galaxy = "milkyway",
                    dimension = "the_nether",
                },
                addresses = {
                    system = { 27, 23, 4, 34, 12, 28 },
                    stellar = nil,
                    galactic = nil,
                },
                visibility = {
                    listed = true,
                    hidden_at = nil,
                    visible_from = nil,
                    intergalactic = {},
                },
            }
        },
    }
end

return sample

