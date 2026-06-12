return {
    schema = 2,
    site = "outpost_alpha",
    role = "gate_controller",
    modems = {
        site = "bottom",
        peripheral = "top",
        intersite = nil,
    },
    address_book = {
        mode = "disabled",
        cache_path = "/sgc/cache/address_book.lua",
        server_site = "command",
        server_path = "/sgc/data/address_book.lua",
    },
    security = {
        allowlist_enabled = false,
        allowed_computer_ids = {},
        shared_secret = nil,
    },
    logging = {
        level = "info",
    },
}

