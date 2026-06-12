return {
    schema = 2,
    site = "command",
    role = "dial_console",
    modems = {
        site = "bottom",
        peripheral = "top",
        intersite = nil,
    },
    address_book = {
        mode = "client",
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

