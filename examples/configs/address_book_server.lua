return {
    schema = 2,
    site = "command",
    role = "address_book_server",
    modems = {
        site = "bottom",
        peripheral = "top",
        intersite = "right",
    },
    address_book = {
        mode = "server",
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
