local sample = {}

---@return SgcAddressBook
function sample.create()
    return {
        schema = 2,
        revision = 1,
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
            outpost_alpha = {
                enabled = true,
                allow_outbound = true,
                id = "outpost_alpha",
                name = "Outpost Alpha",
                location = {
                    universe = "minecraft",
                    galaxy = "milkyway",
                    dimension = "nether",
                },
                addresses = {
                    system = { 9, 11, 14, 21, 22, 29 },
                    stellar = { 9, 11, 14, 21, 22, 29, 0 },
                    galactic = nil,
                },
                visibility = {
                    listed = true,
                    hidden_at = nil,
                    visible_from = nil,
                    intergalactic = nil,
                },
                tags = { "outpost" },
                notes = "Small test outpost.",
            },
        },
    }
end

return sample

