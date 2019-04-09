local config = require 'config'


local item_types = {}
for type, prototypes in pairs(data.raw) do
	-- Anything that's an item has to have the stack_size property, so that's how we find item types
	if next(prototypes) and next(prototypes).stack_size ~= nil then table.insert(item_types, type); end
end


local function _is_result(item, result, results)
	if item == result then return true; end
	for _, result in pairs(results or {}) do
		if result.name == item then return true; end
	end
	return false
end
local function is_result(recipe, item)
	if _is_result(item, recipe.result, recipe.results) then return true; end
	if recipe.normal and _is_result(item, recipe.normal.result, recipe.normal.results) then return true; end
	if recipe.expensive and _is_result(item, recipe.expensive.result, recipe.expensive.results) then return true; end
	return false
end

local function is_ignored(name)
	for _, ignore_name in pairs(config.RECIPES_TO_IGNORE) do
		if name:find(ignore_name) then return true; end
	end
	return false
end

local function needs_signal(recipe)
	if type(recipe) == 'string' then recipe = data.raw['recipe'][recipe]; end
	local name = recipe.name
	return not (
			recipe.hidden
			or is_ignored(name)
			or is_result(recipe, name)
			or data.raw['virtual-signal'][name]
		)
end

local function get_result_name(result) return result.name or result[1]; end

local function try_get_icons(item)
	if not item then return nil; end
	if item.icon then return {{icon = item.icon}}; end
	if item.icons then return item.icons; end
	return nil
end

local function get_possible_results(recipe)
	local res = {}
	local function _get_results(tab)
		if tab.result then table.insert(res, tab.result); end
		if tab.results then
			for _, result in pairs(tab.results) do table.insert(res, get_result_name(result)); end
		end
	end
	
	_get_results(recipe)
	if recipe.expensive then _get_results(recipe.expensive); end
	if recipe.normal then _get_results(recipe.normal); end
	
	return res
end

local function get_icons(recipe)
	if recipe.icon then return {{icon = recipe.icon}}; end
	if recipe.icons then return recipe.icons; end
	
	for _, type in pairs(item_types) do
		local first_icons
		for _, result in pairs(get_possible_results(recipe)) do
			local icons = try_get_icons(data.raw[type][result])
			if result == recipe.name and icons then return icons; end
			first_icons = first_icons or icons
		end
		if first_icons then return first_icons; end
	end
	
	log("Icon not found for: "..recipe.name)
	return {{icon = '__core__/graphics/clear.png'}}
end

local function get_locale(recipe)
	local item, result_item
	local results = get_possible_results(recipe)
	for _, type in pairs(item_types) do
		item = data.raw[type][recipe.name]
		result_item = data.raw[type][results[1]]
		if item or result_item then break; end
	end
	
	local key = {'recipe-name.'..recipe.name}
	if recipe.localised_name then key = recipe.localised_name
	elseif item and item.localised_name then key = item.localised_name
	elseif result_item and result_item.type == 'fluid' then key = {'fluid-name.'..result_item.name}
	elseif result_item then key = {'item-name.'..result_item.name}
	elseif item and item.place_result then key = {'entity-name.'..result_item.place_result}
	elseif item and item.placed_as_equipment_result then key = {'equipment-name.'..item.placed_as_equipment_result}
	end
	return {'crafting_combinator.recipe-locale', key}
end

local function get_order(recipe)
	local subgroup_order = (data.raw['item-subgroup'][recipe.subgroup] or {}).order or 'zzz'
	local recipe_order = recipe.order or 'zzz'
	return subgroup_order..'-'..recipe_order..'['..recipe.name..']'
end


for name, recipe in pairs(data.raw['recipe']) do
	if needs_signal(recipe) then
		local subgroup = config.UNSORTED_RECIPE_SUBGROUP
		if recipe.subgroup then
			local group = data.raw['item-group'][data.raw['item-subgroup'][recipe.subgroup].group]
			subgroup = config.RECIPE_SUBGROUP_PREFIX..group.name
			if not data.raw['item-subgroup'][subgroup] then
				data:extend{{
					type = 'item-subgroup',
					name = subgroup,
					group = config.GROUP_NAME,
					order = group.order..'['..group.name..']',
				}}
			end
		end
		
		data:extend{{
			type = 'virtual-signal',
			name = name,
			localised_name = get_locale(recipe),
			icons = get_icons(recipe),
			subgroup = subgroup,
			icon_size = 32, --TODO: This can't possibly work correctly...
			order = get_order(recipe),
		}}
	end
end