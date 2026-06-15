return {
    schema = 2,
    site = "command",
    role = "site_controller",
    modems = {
        site = "bottom",
        peripheral = "top",
        intersite = "right",
    },
    address_book = {
        mode = "client",
        cache_path = "/sgc/cache/address_book.lua",
        server_site = "command",
        server_path = "/sgc/data/address_book.json",
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
