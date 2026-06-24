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
---| "address_book"
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
---@alias SgcAvailability "available" | "degraded" | "unavailable" | "disabled"
---@alias SgcAddressKind "system" | "stellar" | "galactic"
---@alias SgcAlarmSignalName
---| "connection_established"
---| "connection_incoming"
---| "connection_outgoing"
---| "dialing"
---| "connection_disconnected"
---| "traveller_in"
---| "traveller_out"
---| "wormhole_incoming"
---| "wormhole_outgoing"
---| "chevron_engaged"
---| "message_received"
---| "reset"
---| "system_error"
---@alias SgcAlarmOutputBindingMode "direct" | "pulse"
---@alias SgcAlarmSpeakerPatternName "pattern_alpha" | "pattern_beta"
---@class SgcAlarmOutputBinding
---@field signal SgcAlarmSignalName
---@field mode SgcAlarmOutputBindingMode?
---@class SgcAlarmSpeakerBinding
---@field signal SgcAlarmSignalName
---@field pattern SgcAlarmSpeakerPatternName
---@alias SgcGateEventSignalName
---| "traveller_in"
---| "traveller_out"
---| "wormhole_incoming"
---| "wormhole_outgoing"
---| "chevron_engaged"
---| "message_received"
---| "reset"
---@alias SgcUpdateMode "disabled" | "notify" | "apply"
---@alias SgcDialMode "auto" | "fast" | "medium" | "slow"
---@alias SgcGateCommandAction "dial" | "disconnect" | "open_iris" | "close_iris" | "stop_iris" | "reset" | "status"
---@alias SgcGateConnectionDirection "incoming" | "outgoing"
---@alias SgcGateActivity
---| "idle"
---| "partial_dial"
---| "dialing_out"
---| "incoming_open"
---| "incoming_connected"
---| "outgoing_open"
---| "outgoing_connected"

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
---@field display_version string?
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
---@field display_version string?
---@field managed_paths string[]
---@field files table<string, SgcUpdateStateFile>

---@class SgcSiteCommandRequest
---@field action SgcGateCommandAction
---@field request_id string?
---@field destination_site string?
---@field dial_mode SgcDialMode?

---@class SgcGateCommand
---@field action SgcGateCommandAction
---@field request_id string?
---@field destination_site string?
---@field address integer[]?
---@field dial_mode SgcDialMode?

---@class SgcGateCommandResult
---@field action SgcGateCommandAction
---@field request_id string?
---@field destination_site string?
---@field dial_mode_used SgcDialMode?
---@field reset_performed boolean?
---@field state SgcGateState
---@field site_status SgcSiteStatus?

---@class SgcSiteCommandEnvelopePayload
---@field kind "site_request"
---@field target_role "site_controller"
---@field target_site string
---@field command SgcSiteCommandRequest

---@class SgcGateCommandEnvelopePayload
---@field kind "gate_request"
---@field target_role "gate_controller"
---@field target_site string
---@field command SgcGateCommand

---@class SgcCommandResultEnvelopePayload
---@field kind "command_result"
---@field request_id string
---@field ok boolean
---@field result SgcGateCommandResult?
---@field error string?
---@field details table?

---@class SgcSiteLifecycleEnvelopePayload
---@field kind "site_lifecycle_request"
---@field target_role "site_controller"
---@field target_site string
---@field command SgcSiteLifecycleCommand

---@class SgcHostLifecycleEnvelopePayload
---@field kind "host_lifecycle_request"
---@field target_role SgcRole
---@field target_site string
---@field command SgcHostLifecycleCommand

---@class SgcGateStateEnvelopePayload
---@field kind "gate_state"
---@field sequence integer
---@field emitted_at integer
---@field state SgcGateState

---@class SgcSiteStatusEnvelopePayload
---@field kind "site_status"
---@field sequence integer
---@field emitted_at integer
---@field status SgcSiteStatus

---@class SgcGateEventEnvelopePayload
---@field kind "gate_event"
---@field sequence integer
---@field emitted_at integer
---@field signal SgcGateEventSignalName
---@field details table?

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
---@field activity SgcGateActivity
---@field connection_direction SgcGateConnectionDirection?
---@field idle boolean
---@field partial_dial boolean
---@field local_address integer[]?
---@field dialed_address integer[]?
---@field connected_address integer[]?
---@field chevrons_engaged integer?
---@field stargate_generation integer?
---@field current_symbol integer?
---@field energy SgcEnergyState
---@field iris SgcIrisState

---@class SgcSiteStatus
---@field site string
---@field role SgcRole
---@field healthy boolean
---@field warnings_count integer
---@field address_book_available boolean
---@field address_book_error string?
---@field address_book_revision integer?
---@field last_internal_error string?
---@field started_at integer?
---@field maintenance_mode boolean?
---@field maintenance_reason string?
---@field maintenance_action string?

---@alias SgcLifecycleSiteAction "reboot_hosts"
---@alias SgcLifecycleHostAction "reboot_host"
---@alias SgcLifecycleScope "role" | "site"

---@class SgcSiteLifecycleCommand
---@field action SgcLifecycleSiteAction
---@field request_id string?
---@field scope SgcLifecycleScope
---@field target_role SgcRole?
---@field reason string?

---@class SgcHostLifecycleCommand
---@field action SgcLifecycleHostAction
---@field request_id string?
---@field reason string?
---@field requested_by_role SgcRole?
---@field requested_by_site string?

return {}
