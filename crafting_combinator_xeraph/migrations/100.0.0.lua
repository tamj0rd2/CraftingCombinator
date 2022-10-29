if not late_migrations then return end

late_migrations['100.0.0'] = function(changes)
    local change = changes.mod_changes['crafting_combinator']
	if not change or not change.old_version then return end

    -- initialise global
    global.delayed_blueprint_tag_state = {}
	global.dead_combinator_settings = {}

    -- update cc data
    for _, combinator in pairs(global.cc.data) do
        combinator.last_combinator_mode = nil

        combinator.entityUID = combinator.entity.unit_number
        combinator.last_assembler_recipe = false
        combinator.read_mode_cb = false

        combinator.sticky = false
        combinator.allow_sticky = true
        combinator.craft_n_before_switch = {
            unstick_at_tick = 0
        }

        combinator.settings.craft_n_before_switch = 1
    end
    
    -- update rc data
    for _, combinator in pairs(global.rc.data) do
        combinator.entityUID = combinator.entity.unit_number
    end
end