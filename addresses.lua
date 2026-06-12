return {
    schema = 2, -- data format version
    revision = 17, -- incremented for every address book edit
    sites = {
        command = {
            enabled = true, -- master toggle for if this site is visible. If false then it acts as if this site is not in the book
            allow_outbound = true, -- toggle allowing dialing out
            name = "SGCommand", -- friendly name to be displayed
            galaxy = "milkyway", -- galaxy this site belongs to
            universe = "minecraft", -- universe this site belongs to
            addresses = {
                system = { 27, 25, 4, 35, 10, 28 }, -- local system address
                stellar = { 1, 2, 3, 4, 5, 6, 7 }, -- interstellar address
                galactic = { 1, 2, 3, 4, 5, 6, 7, 8 }, -- galactic/unique address
            },
            visibility = {
                listed = true, -- whether this site is listed at other sites
                hidden_at = {}, -- sites which this site is not visble. supports '*'
                intergalactic = { "*" }, -- by default intergalactic sites are hidden from selection. This controls which sites this site will show. supports '*'
            },
        },
        nether = {
            enabled = true,
            allow_outbound = true,
            name = "Nether",
            galaxy = "milkyway",
            universe = "minecraft",
            addresses = {
                system = { 27, 23, 4, 34, 12, 28 },
                stellar = { 1, 2, 3, 4, 5, 6, 7 },
                galactic = { 1, 2, 3, 4, 5, 6, 7, 8 },
            },
            visibility = {
                listed = true,
                hidden_from = {},
                intergalactic = { "*" },
            },
        },
        theend_mw = {
            enabled = true,
            allow_outbound = true,
            name = "The End",
            galaxy = "milkyway",
            universe = "minecraft",
            addresses = {
                system = { 13, 24, 2, 19, 3, 30 },
                stellar = { 1, 2, 3, 4, 5, 6, 7 },
                galactic = { 1, 2, 3, 4, 5, 6, 7, 8 },
            },
            visibility = {
                listed = true,
                hidden_from = { "theend_p" },
                intergalactic = { "*" },
            },
        },
        theend_p = {
            enabled = true,
            allow_outbound = true,
            name = "The End",
            galaxy = "pegasus",
            universe = "minecraft",
            addresses = {
                system = { 14, 30, 6, 13, 17, 23 },
                stellar = { 1, 2, 3, 4, 5, 6, 7 },
                galactic = { 1, 2, 3, 4, 5, 6, 7, 8 },
            },
            visibility = {
                listed = true,
                hidden_from = { "*" },
                intergalactic = { "*" },
            },
        },
        lantea = {
            enabled = true,
            allow_outbound = true,
            name = "Lantea",
            galaxy = "pegasus",
            universe = "minecraft",
            addresses = {
                system = { 29, 5, 17, 34, 6, 12 },
                stellar = { 1, 2, 3, 4, 5, 6, 7 },
                galactic = { 1, 2, 3, 4, 5, 6, 7, 8 },
            },
            visibility = {
                listed = true,
                hidden_from = {},
                intergalactic = { "*" },
            },
        },
    },
}
