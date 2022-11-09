require 'script.bootstrap'

local config = require 'config'
local cc_control = require 'script.cc'
local rc_control = require 'script.rc'
local signals = require 'script.signals'
local util = require 'script.util'
local gui = require 'script.gui'
local blueprint = require 'script.blueprint'
local migration_helper = require 'script.migration-helper'
local clone_helper = require 'script.clone-helper'
local housekeeping = require 'script.housekeeping'
commands.add_command("crafting_combinator_xeraph", nil, housekeeping.cc_command)

local function enable_recipes()
	for _, force in pairs(game.forces) do
		if force.technologies['circuit-network'].researched then
			force.recipes[config.CC_NAME].enabled = true
			force.recipes[config.RC_NAME].enabled = true
		end
	end
end

local function on_load(forced)
	if not forced and next(late_migrations.__migrations) ~= nil then return; end
	cc_control.on_load()
	rc_control.on_load()
	signals.on_load()
	clone_helper.on_load()
	
	if remote.interfaces['PickerDollies'] then
		script.on_event(remote.call('PickerDollies', 'dolly_moved_entity_id'), function(event)
			local entity = event.moved_entity
			local combinator
			if entity.name == config.CC_NAME then combinator = global.cc.data[entity.unit_number]
			elseif entity.name == config.RC_NAME then combinator = global.rc.data[entity.unit_number]; end
			if combinator then combinator:update_inner_positions(); end
		end)
	end
end

local function init_global()
	global.delayed_blueprint_tag_state = {}
	global.clone_placeholder = {combinator = {count = 0}, cache = {count = 0}, timestamp = {}}
	global.main_uid_by_part_uid = {}
end

script.on_init(function()
	init_global()
	cc_control.init_global()
	rc_control.init_global()
	signals.init_global()
	on_load(true)
end)
script.on_load(on_load)

script.on_configuration_changed(function(changes)
	migration_helper.migrate(changes)
	late_migrations(changes)
	on_load(true)
	enable_recipes()
end)

local function on_built(event)
	local entity = event.created_entity or event.entity
	if not (entity and entity.valid) then return end

	local entity_name = entity.name
	if entity_name == config.CC_NAME then
		local tags = event.tags
		cc_control.create(entity, tags);
	elseif entity_name == config.RC_NAME then
		local tags = event.tags
		rc_control.create(entity, tags);
	else
		local entity_type = entity.type
		if entity_type == 'assembling-machine' then
			cc_control.update_assemblers(entity.surface, entity);
		else -- util.CONTAINER_TYPES[entity.type]
			cc_control.update_chests(entity.surface, entity);
		end
	end

	-- blueprint events
	blueprint.handle_event(event)
end

--- Lookup table for cc entities.
--- @type { [string]: boolean } Value is always true
local is_cc_entities = {
	[config.CC_NAME] = true,
	[config.RC_NAME] = true,
	[config.MODULE_CHEST_NAME] = true,
	[config.RC_PROXY_NAME] = true,
	[config.SIGNAL_CACHE_NAME] = true
}

local function on_cloned(event)
	local entity = event.destination
	if not (entity and entity.valid) then return end

	-- cc entities - cc, rc, module chest, output proxy, lamp
	if is_cc_entities[entity.name] then
		clone_helper.on_entity_cloned(event)
		if not (entity.valid) then return end
		-- destination entity will be destroyed during clone_helper handling if it is a redundant component
		-- only one old state can exist as a partially cloned state at a time
	end

	-- assembler and containers
	local entity_type = entity.type
	if entity_type == 'assembling-machine' then
		cc_control.update_assemblers(entity.surface, entity);
	elseif util.CONTAINER_TYPES[entity.type] then
		cc_control.update_chests(entity.surface, entity);
	end
end
-- Note: 2022-11-08
-- Currently clone events are handled under the assumption that no existing cc entities are replaced by area/brush clone (clear_destination_entities = false)
-- At the time of writing, there is no API that notifies the clearing of entities due to area/brush clone
-- on_entity_cloned event, despite being the first event received for cloning, is only fired after cleared entity has become invalid

local function on_destroyed(event) -- on_entity_died, on_player_mined_entity, on_robot_mined_entity, script_raised_destroy
	local entity = event.entity
	if not (entity and entity.valid) then return end

	-- cached properties
	local entity_name = entity.name
	local entity_type = entity.type
	local entity_surface = entity.surface
	local event_name = event.name

	-- Notify nearby combinators that a container was destroyed
	if util.CONTAINER_TYPES[entity_type] then
		cc_control.update_chests(entity_surface, entity, true)
	end

	if entity_name == config.CC_NAME then
		local uid = entity.unit_number
		local module_chest = global.cc.data[uid].module_chest
		local module_chest_uid = module_chest.unit_number
		if event_name == defines.events.on_player_mined_entity then
			-- Need to mine module chest first, success == true
			if not cc_control.mine_module_chest(uid, event.player_index) then
				-- Unable to mine module chest, cc cloned and replaced - remove cc from buffer, then return
				event.buffer.remove({name=config.CC_NAME, count=1})
				return
			end
		end
		if event_name == defines.events.on_entity_died
		or event_name == defines.events.script_raised_destroy then
			cc_control.update_chests(entity_surface, module_chest, true)
			module_chest.destroy()
		end
		if event_name ~= defines.events.on_entity_died then -- need state data until post_entity_died
			cc_control.destroy(entity)
		end
		global.main_uid_by_part_uid[module_chest_uid] = nil
	elseif entity_name == config.MODULE_CHEST_NAME then
		local uid = entity.unit_number
		if event_name == defines.events.on_player_mined_entity then
			-- This should only be called from cc's mine_module_chest() method after mine_entity() is successful
			-- Remove one cc from buffer because cc is the mine product
			event.buffer.remove({name=config.CC_NAME, count=1})
		elseif event_name == defines.events.on_robot_mined_entity
		or event_name == defines.events.script_raised_destroy then
			local cc_entity = global.cc.data[global.main_uid_by_part_uid[uid]].entity
			if cc_entity and cc_entity.valid then
				cc_control.destroy(cc_entity.unit_number)
				cc_entity.destroy()
			end
		end
		global.main_uid_by_part_uid[uid] = nil
	elseif entity_name == config.RC_NAME then
		local output_proxy = global.rc.data[entity.unit_number].output_proxy
		local output_proxy_uid = output_proxy.unit_number
		if event_name == defines.events.on_entity_died
		or event_name == defines.events.script_raised_destroy
		or event_name == defines.events.on_robot_mined_entity
		or event_name == defines.events.on_player_mined_entity then			
			output_proxy.destroy()
		end
		if event_name ~= defines.events.on_entity_died then -- need state data until post_entity_died
			rc_control.destroy(entity)
		end
		global.main_uid_by_part_uid[output_proxy_uid] = nil
	elseif entity_name == config.RC_PROXY_NAME then
		local uid = entity.unit_number
		if event_name == defines.events.script_raised_destroy then
			local rc_entity = global.rc.data[global.main_uid_by_part_uid[uid]].entity
			rc_control.destroy(rc_entity.unit_number)
			rc_entity.destroy()
		end
		global.main_uid_by_part_uid[uid] = nil
	elseif entity_name == config.SIGNAL_CACHE_NAME then
		global.main_uid_by_part_uid[entity.unit_number] = nil
	else
		if entity_type == 'assembling-machine' then
			cc_control.update_assemblers(entity_surface, entity, true)
		end
	end
end

-- load values from settings on script load
local cc_rate = settings.global[config.REFRESH_RATE_CC_NAME].value
local rc_rate = settings.global[config.REFRESH_RATE_RC_NAME].value
config:load_values(settings)
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting == config.REFRESH_RATE_CC_NAME then
		cc_rate = settings.global[config.REFRESH_RATE_CC_NAME].value
	elseif event.setting == config.REFRESH_RATE_RC_NAME then
		rc_rate = settings.global[config.REFRESH_RATE_RC_NAME].value
	end
	config:on_mod_settings_changed(event)
end)

local function run_update(tab, tick, rate)
	for i = tick % (rate + 1) + 1, #tab, (rate + 1) do tab[i]:update(nil, tick); end
end
script.on_event(defines.events.on_tick, function(event)
	if global.cc.inserter_empty_queue[event.tick] then
		for _, e in pairs(global.cc.inserter_empty_queue[event.tick]) do
			if e.entity.valid and e.assembler and e.assembler.valid then e:empty_inserters(); end
		end
		global.cc.inserter_empty_queue[event.tick] = nil
	end
	
	run_update(global.cc.ordered, event.tick, cc_rate)
	run_update(global.rc.ordered, event.tick, rc_rate)
end)

script.on_nth_tick(600, function(event)
	-- clean up partially cloned entities
	clone_helper.on_nth_tick(event)
end)

script.on_event(defines.events.on_player_rotated_entity, function(event)
	if event.entity.name == config.CC_NAME then
		local combinator = global.cc.data[event.entity.unit_number]
		combinator:find_assembler()
		combinator:find_chest()
	end
end)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
	local source, destination
	if event.source.name == config.CC_NAME and event.destination.name == config.CC_NAME then
		source, destination = global.cc.data[event.source.unit_number], global.cc.data[event.destination.unit_number]
	elseif event.source.name == config.RC_NAME and event.destination.name == config.RC_NAME then
		source, destination = global.rc.data[event.source.unit_number], global.rc.data[event.destination.unit_number]
	else return; end
	
	destination.settings = util.deepcopy(source.settings)
	if destination.entity.name == config.RC_NAME then destination:update(true)
	elseif destination.entity.name == config.CC_NAME then destination:copy(source); end
end)

-- filter for built and destroyed events
local filter_built_destroyed = {
	{filter = "name", name = config.CC_NAME},
	{filter = "name", name = config.RC_NAME},
	{filter = "name", name = config.MODULE_CHEST_NAME},
	{filter = "name", name = config.RC_PROXY_NAME},
	{filter = "name", name = config.SIGNAL_CACHE_NAME},
	{filter = "type", type = 'assembling-machine'}
}

-- filter: containers
for container in pairs(util.CONTAINER_TYPES) do
	table.insert(filter_built_destroyed, {filter = "type", type = container})
end

-- entity built events
script.on_event(defines.events.on_built_entity, on_built, filter_built_destroyed)
script.on_event(defines.events.on_robot_built_entity, on_built, filter_built_destroyed)
script.on_event(defines.events.script_raised_built, on_built, filter_built_destroyed)
script.on_event(defines.events.script_raised_revive, on_built, filter_built_destroyed)
script.on_event(defines.events.on_entity_cloned, on_cloned, filter_built_destroyed)

-- entity destroyed events
script.on_event(defines.events.on_entity_died, on_destroyed, filter_built_destroyed)
script.on_event(defines.events.on_player_mined_entity, on_destroyed, filter_built_destroyed)
script.on_event(defines.events.on_robot_mined_entity , on_destroyed, filter_built_destroyed)
script.on_event(defines.events.script_raised_destroy, on_destroyed, filter_built_destroyed)

-- additional blueprint events
script.on_event(defines.events.on_player_setup_blueprint, blueprint.handle_event)
script.on_event(defines.events.on_post_entity_died, blueprint.handle_event, {{filter = "type", type = "constant-combinator"}, {filter = "type", type = "arithmetic-combinator"}})

-- decontruction events
script.on_event(
	defines.events.on_marked_for_deconstruction,
	function(event) cc_control.on_module_chest_marked_for_decon(event.entity) end,
	{{filter = "name", name = config.MODULE_CHEST_NAME}}
)
script.on_event(
	defines.events.on_cancelled_deconstruction,
	function(event) cc_control.on_module_chest_cancel_decon(event.entity) end,
	{{filter = "name", name = config.MODULE_CHEST_NAME}}
)

-- GUI events
script.on_event(defines.events.on_gui_opened, function(event)
	local entity = event.entity
	if entity then
		if entity.name == config.CC_NAME then global.cc.data[entity.unit_number]:open(event.player_index); end
		if entity.name == config.RC_NAME then global.rc.data[entity.unit_number]:open(event.player_index); end
	end
end)
script.on_event(defines.events.on_gui_closed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		element.destroy()
	end

	-- blueprint gui
	blueprint.handle_event(event)
end)
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		
		if gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_checked_changed(element_name, element.state, element)
		end
		if gui_name == 'recipe-combinator' then
			global.rc.data[unit_number]:on_checked_changed(element_name, element.state, element)
		end
	end
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		if gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_selection_changed(element_name, element.selected_index)
		end
	end
end)
script.on_event(defines.events.on_gui_text_changed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		if gui_name == 'recipe-combinator' then
			global.rc.data[unit_number]:on_text_changed(element_name, element.text)
		elseif gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_text_changed(element_name, element.text)
		end
	end
end)
script.on_event(defines.events.on_gui_click, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		if gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_click(element_name, element)
		end
	end
end)