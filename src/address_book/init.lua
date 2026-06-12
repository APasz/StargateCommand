local resolver = require("address_book.resolver")
local schema = require("address_book.schema")
local store = require("address_book.store")
local visibility = require("address_book.visibility")

local address_book = {}

address_book.load = store.load
address_book.save = store.save
address_book.validate = schema.validate
address_book.can_see = visibility.can_see
address_book.get_best_address = resolver.get_best_address
address_book.list_visible_destinations = resolver.list_visible_destinations

return address_book
