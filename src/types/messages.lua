---@meta

---@alias SgcRole
---| "site_controller"
---| "gate_controller"
---| "dial_console"
---| "veto_console"
---| "display"
---| "iris_controller"
---| "alarm_controller"
---| "energy_controller"
---| "address_book_server"
---| "update_client"
---| "bridge"

---@alias SgcProtocol
---| "sgc.hello"
---| "sgc.command"
---| "sgc.event"
---| "sgc.state"
---| "sgc.addressbook"
---| "sgc.update"

---@alias SgcEnvelopeType
---| "hello"
---| "command"
---| "event"
---| "state"
---| "result"
---| "addressbook"

---@alias SgcAddressBookMode "client" | "server" | "disabled"
---@alias SgcAddressKind "system" | "stellar" | "galactic"
---@alias SgcUpdateMode "disabled" | "notify" | "apply"

---@class SgcResult
---@field ok boolean
---@field value any?
---@field error string?
---@field details table?

---@class SgcEnvelope
---@field schema integer
---@field type SgcEnvelopeType
---@field msg_id string
---@field site string
---@field role SgcRole
---@field sent_at integer
---@field reply_to string?
---@field payload table

---@class SgcAddressSet
---@field system integer[]?
---@field stellar integer[]?
---@field galactic integer[]?

---@class SgcSiteLocation
---@field universe string
---@field galaxy string
---@field dimension string

---@class SgcSiteVisibility
---@field listed boolean
---@field hidden_at string[]?
---@field visible_from string[]?
---@field intergalactic string[]?
---@field hidden_from string[]? Deprecated legacy alias

---@class SgcSiteEntry
---@field enabled boolean
---@field allow_outbound boolean
---@field id string
---@field name string
---@field location SgcSiteLocation
---@field addresses SgcAddressSet
---@field visibility SgcSiteVisibility
---@field tags string[]?
---@field notes string?

---@class SgcAddressBook
---@field schema integer
---@field revision integer
---@field updated_at integer
---@field updated_by string
---@field sites table<string, SgcSiteEntry>

---@class SgcUpdateConfig
---@field mode SgcUpdateMode
---@field base_url string
---@field channel string
---@field state_path string
---@field temp_dir string
---@field auto_reboot boolean

---@class SgcUpdateManifestFile
---@field path string
---@field size integer
---@field sha256 string

---@class SgcUpdateManifest
---@field schema integer
---@field channel string
---@field source_kind string
---@field revision string
---@field generated_at string
---@field managed_paths string[]
---@field files SgcUpdateManifestFile[]
---@field source_ref string?

---@class SgcUpdateStateFile
---@field size integer
---@field sha256 string

---@class SgcUpdateState
---@field schema integer
---@field channel string
---@field revision string
---@field managed_paths string[]
---@field files table<string, SgcUpdateStateFile>

---@class SgcEnergyState
---@field stored number?
---@field capacity number?
---@field available boolean

---@class SgcIrisState
---@field supported boolean
---@field identifier string?
---@field installed boolean?
---@field progress number?
---@field progress_percent number?

---@class SgcGateState
---@field side string
---@field interface_type string
---@field connected boolean
---@field open boolean
---@field dialing_out boolean
---@field local_address integer[]?
---@field dialed_address integer[]?
---@field connected_address integer[]?
---@field energy SgcEnergyState
---@field iris SgcIrisState

return {}
