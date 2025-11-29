---@diagnostic disable: cast-local-type
local format = require("__flib__.format")
local math = require("__flib__.math")
local flib_technology = require("__flib__.technology")

local constants = require("constants")
local util = require("util")

--- @class ResearchQueueNode
--- @field technology LuaTechnology
--- @field level uint
--- @field duration string
--- @field key string
--- @field next ResearchQueueNode?
--- @field prev ResearchQueueNode?

--- @class TechnologyAndLevel
--- @field technology LuaTechnology
--- @field level uint

--- @class ResearchQueue
--- @field force LuaForce
--- @field force_table ForceTable
--- @field head ResearchQueueNode?
--- @field len uint
--- @field lookup table<string, ResearchQueueNode>
--- @field paused boolean
--- @field requeue_multilevel boolean
--- @field updating_active_research boolean

--- @class ResearchQueueMod
local research_queue = {}

--- @param self ResearchQueue
function research_queue.clear(self)
  self.head = nil
  self.len = 0
  self.lookup = {}
  -- Single GUI update
  util.schedule_force_update(self.force)
end

--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level boolean|uint?
--- @return boolean
function research_queue.contains(self, technology, level)
  if not flib_technology.is_multilevel(technology) then
    return not not self.lookup[technology.name]
  end

  local base_name = flib_technology.get_base_name(technology)
  if level and type(level) == "number" then
    -- This level
    return not not self.lookup[base_name .. "-" .. level]
  elseif level and technology.prototype.max_level ~= math.max_uint then
    -- All levels
    local base_key = base_name .. "-"
    for i = technology.level, technology.prototype.max_level do
      if not self.lookup[base_key .. i] then
        return false
      end
    end
    return true
  else
    -- Any level
    for key in pairs(self.lookup) do
      if string.find(key, base_name, nil, true) then
        return true
      end
    end
    return false
  end
end

--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @return uint
function research_queue.get_highest_level(self, technology)
  if not flib_technology.is_multilevel(technology) then
    return self.lookup[technology.name] and technology.level or 0
  end
  
  local base_name = flib_technology.get_base_name(technology)
  local highest = 0
  for key in pairs(self.lookup) do
    if string.find(key, base_name .. "-", 1, true) == 1 then
      local level = tonumber(string.match(key, base_name .. "%-(%d+)"))
      if level then
        highest = math.max(level, highest)
      end
    end
  end
  return highest
end

--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @return ResearchState | nil
function get_satisfaction_state(self, technology)
  -- Check prerequisites once and determine state based on results
  local all_satisfied = true
  local all_satisfied_or_queued = true
  
  for _, prerequisite in pairs(technology.prerequisites) do
    if not prerequisite.researched then
      all_satisfied = false
      if not research_queue.contains(self, prerequisite, true) then
        all_satisfied_or_queued = false
        break -- No need to check further if we already know it's not available
      end
    end
  end
  
  if all_satisfied_or_queued then
    return constants.research_state.conditionally_available
  end
  if all_satisfied then
    return constants.research_state.available
  end
end

--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @return ResearchState
function research_queue.get_research_state(self, technology)
  if technology.researched then
    return constants.research_state.researched
  end
  if technology.prototype.hidden or not technology.enabled then
    return constants.research_state.disabled
  end
  local state = get_satisfaction_state(self, technology)
  return state or constants.research_state.not_available
end


--- Append a node to the front of the linked list.
--- @param self ResearchQueue
--- @param node ResearchQueueNode
local function append_to_front(self, node)
  node.prev = nil
  node.next = self.head
  if self.head then
    self.head.prev = node
  end
  self.head = node
end

--- @param self ResearchQueue
--- @param new_node ResearchQueueNode
--- @param index integer
local function insert_at_index(self, new_node, index)
    -- Insert at index
    local node = self.head
    while node and node.next and index > 2 do
      index = index - 1
      node = node.next
    end
    -- This shouldn't ever fail...
    if node then
      new_node.next = node.next
      new_node.prev = node
      node.next = new_node
    end
end

--- @param self ResearchQueue
--- @param new_node ResearchQueueNode
local function append_to_end(self, new_node)

  local node = self.head
  while node and node.next do
    node = node.next
  end
  -- This shouldn't ever fail...
  node.next = new_node
  new_node.prev = node
end

--- Add a technology and its prerequisites to the queue.
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
--- @param index integer?
--- @return LocalisedString?
local function push(self, technology, level, index)
  -- Update flag and length
  self.len = self.len + 1
  local key = flib_technology.get_leveled_name(technology, level)

  --- @type ResearchQueueNode
  local new_node = {
    technology = technology,
    level = level,
    duration = "[img=infinity]",
    key = key
  }
  self.lookup[key] = new_node

  -- Add to linked list
  if not self.head or index == 1 then
    append_to_front(self, new_node)
  elseif index then
    insert_at_index(self, new_node, index)
  else
    append_to_end(self, new_node)
  end
end

--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @return LocalisedString?
function research_queue.instant_research(self, technology)
  local research_state = self.force_table.research_states[technology.name]
  if research_state == constants.research_state.researched then return { "message.urq-already-researched" } end
  if research_state == constants.research_state.available then technology.researched = true; return end

  -- Research prerequisites and then this technology
  local prerequisites = storage.technology_prerequisites[technology.name] or {}
  local technologies = self.force.technologies
  for i = 1, #prerequisites do
    local prerequisite = technologies[prerequisites[i]]
    if not prerequisite.researched then
      prerequisite.researched = true
    end
  end
  technology.researched = true
end

--- Remove a node from the linked list.
--- @param self ResearchQueue
--- @param node ResearchQueueNode
local function remove_node(self, node)
  if node.prev then
    node.prev.next = node.next
  else
    -- This is the head node, update the head pointer
    self.head = node.next
  end
  if node.next then
    node.next.prev = node.prev
  end
  self.lookup[node.key] = nil
  self.len = self.len - 1
  return node
end

--- Find a node in the linked list.
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
--- @return ResearchQueueNode?
local function find_node(self, technology, level)
  -- Find node from linked list
  local node = self.head
  while node and (node.technology ~= technology or node.level ~= level) do
    node = node.next
  end
  return node
end

--- Move a node to the front of the linked list.
--- This does not account for prerequisites
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
function research_queue.move_to_front(self, technology, level)
  local key = flib_technology.get_leveled_name(technology, level)
  local node = self.lookup[key]
  
  if not node or node == self.head then
    return -- Node doesn't exist or is already at front
  end

  node = remove_node(self, node)
  append_to_front(self, node)
end

--- Move a node to the back of the linked list.
--- This does not account for descendants
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
function move_to_back(self, technology, level)
  local key = flib_technology.get_leveled_name(technology, level)
  local node = self.lookup[key]
  
  if not node then
    return -- Node doesn't exist
  end

  node = remove_node(self, node)
  append_to_end(self, node)
end

--- @param force LuaForce
--- @param force_table ForceTable
--- @return ResearchQueue
function research_queue.new(force, force_table)
  --- @type ResearchQueue
  return {
    force = force,
    force_table = force_table,
    --- @type ResearchQueueNode?
    head = nil,
    len = 0,
    --- @type table<string, ResearchQueueNode>
    lookup = {},
    paused = false,
    requeue_multilevel = false,
    updating_active_research = true,
  }
end

--- Add a technology to the queue. Adds all levels from current to `level` or max level.
--- @param to_research TechnologyAndLevel[]
--- @param technology LuaTechnology
--- @param level uint?
--- @param queue ResearchQueue?
local function add_technology(to_research, technology, level, queue)
  local lower = technology.level
  if queue then
    lower = math.clamp(research_queue.get_highest_level(queue, technology) + 1, lower, technology.prototype.max_level) --[[@as uint]]
  end
  for i = lower, level or technology.prototype.max_level do
    --- @cast i uint
    to_research[#to_research + 1] = { technology = technology, level = i }
  end
end

-- Mark all prerequisites to to_research using depth-first traversal (original approach), marking already queued techs to to_move
--- @param self ResearchQueue
--- @param to_research TechnologyAndLevel[]
--- @param technology LuaTechnology
--- @param to_move TechnologyAndLevel[]
--- @return LocalisedString?
local function add_prerequisites_depth_first(self, to_research, technology, to_move)
  local technologies = self.force.technologies
  local technology_prerequisites = storage.technology_prerequisites[technology.name] or {}
  for i = 1, #technology_prerequisites do
    local prerequisite_name = technology_prerequisites[i]
    local prerequisite = technologies[prerequisite_name]
    local prerequisite_research_state = self.force_table.research_states[prerequisite_name]
    if prerequisite_research_state == constants.research_state.disabled then
      return { "message.urq-has-disabled-prerequisites" }
    end
    if prerequisite.researched then
      -- Already researched, skip
      -- Might happen in modded runs
      -- Where scripts control the research state.
      goto continue
    end

    if
        not research_queue.contains(self, prerequisite, true)
        and prerequisite_research_state ~= constants.research_state.researched
    then
      add_technology(to_research, prerequisite)
    else
      add_technology(to_move, prerequisite)
    end
    ::continue::
  end
end

-- Mark all prerequisites to to_research using breadth-first traversal, marking already queued techs to to_move
--- @param self ResearchQueue
--- @param to_research TechnologyAndLevel[]
--- @param technology LuaTechnology
--- @param to_move TechnologyAndLevel[]
--- @return LocalisedString?
local function add_prerequisites_breadth_first(self, to_research, technology, to_move)
  local technologies = self.force.technologies
  local visited = {}
  local queue = {technology}
  local levels = {} -- Track the depth level of each technology for breadth-first ordering
  levels[technology.name] = 0
  local max_level = 0
  
  -- Breadth-first traversal of prerequisite tree
  while #queue > 0 do
    local current = table.remove(queue, 1) -- Remove from front (queue behavior)
    local current_level = levels[current.name]
    
    -- Process immediate prerequisites of current technology
    for _, prerequisite in pairs(current.prerequisites) do
      if not visited[prerequisite.name] then
        visited[prerequisite.name] = true
        local prerequisite_level = current_level + 1
        levels[prerequisite.name] = prerequisite_level
        max_level = math.max(max_level, prerequisite_level)
        
        local prerequisite_research_state = self.force_table.research_states[prerequisite.name]
        if prerequisite_research_state == constants.research_state.disabled then
          return { "message.urq-has-disabled-prerequisites" }
        end
        
        -- Add to queue for further processing if not researched
        if prerequisite_research_state ~= constants.research_state.researched then
          table.insert(queue, prerequisite)
        end
      end
    end
  end
  
  -- Sort prerequisites by level (breadth-first order) and add them
  local prerequisites_by_level = {}
  for tech_name, level in pairs(levels) do
    if tech_name ~= technology.name then -- Exclude the original technology
      if not prerequisites_by_level[level] then
        prerequisites_by_level[level] = {}
      end
      table.insert(prerequisites_by_level[level], tech_name)
    end
  end
  
  -- Add prerequisites level by level, starting from the deepest (highest level) and working backwards
  -- This ensures dependencies are added in the correct order for the queue
  for level = max_level, 1, -1 do
    local tech_names = prerequisites_by_level[level]
    if tech_names then
      for _, prerequisite_name in pairs(tech_names) do
        local prerequisite = technologies[prerequisite_name]
        local prerequisite_research_state = self.force_table.research_states[prerequisite_name]
        
        if prerequisite_research_state ~= constants.research_state.researched then
          if not research_queue.contains(self, prerequisite, true) then
            add_technology(to_research, prerequisite)
          else
            add_technology(to_move, prerequisite)
          end
        end
      end
    end
  end
end

-- Mark all prerequisites to to_research, choosing strategy based on player setting
--- @param self ResearchQueue
--- @param to_research TechnologyAndLevel[]
--- @param technology LuaTechnology
--- @param to_move TechnologyAndLevel[]
--- @param player_index uint?
--- @return LocalisedString?
local function add_prerequisites(self, to_research, technology, to_move, player_index)
  -- Default to depth-first if no player specified or setting not found
  local use_breadth_first = false
  
  if player_index then
    local player = game.get_player(player_index)
    if player and player.valid then
      --- @cast use_breadth_first boolean
      use_breadth_first = player.mod_settings["urq-breadth-first-prerequisites"].value
    end
  end
  
  if use_breadth_first then
    return add_prerequisites_breadth_first(self, to_research, technology, to_move)
  else
    return add_prerequisites_depth_first(self, to_research, technology, to_move)
  end
end

--- @param self ResearchQueue
--- @param to_research TechnologyAndLevel[]
local function check_for_errors(self, to_research)
  local num_to_research = #to_research
  if num_to_research > constants.queue_limit then
    return { "message.urq-too-many-unresearched-prerequisites" }
  else
    local len = self.len
    -- It shouldn't ever be greater... right?
    if len >= constants.queue_limit then
      return { "message.urq-queue-is-full" }
    elseif len + num_to_research > constants.queue_limit then
      return { "message.urq-too-many-prerequisites-queue-full" }
    end
  end
end

--- Preprocess adding a technology and its prerequisites to the queue.
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
--- @param to_research TechnologyAndLevel[]
--- @param player_index uint?
--- @return LocalisedString?
local function preprocess_push(self, technology, level, to_research, player_index)
  local research_state = self.force_table.research_states[technology.name]
  if research_state == constants.research_state.researched then
    return { "message.urq-already-researched" }
  elseif research_state == constants.research_state.disabled then
    return { "message.urq-tech-is-disabled" }
  elseif research_queue.contains(self, technology, level) then
    local node = find_node(self, technology, level)
    if not node then return { "message.urq-already-in-queue" } end
    remove_node(self, node)
    append_to_front(self, node)
  end

  if research_state == constants.research_state.not_available then
    -- Store result, and return only if there was an error
    local result = add_prerequisites(self, to_research, technology, {}, player_index) -- don't care about moving techs.
    if result then return result end
  end
  add_technology(to_research, technology, level, self)

  check_for_errors(self, to_research)
end

--- Push a technology and its prerequisites to the queue.
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
--- @param player_index uint?
--- @return LocalisedString?
function research_queue.push(self, technology, level, player_index)
  --- @type TechnologyAndLevel[]
  local to_research = {}

  local result = preprocess_push(self, technology, level, to_research, player_index)
  if result then return result end

  -- Actually push to queue
  for i = 1, #to_research do
    local to_research = to_research[i]
    push(self, to_research.technology, to_research.level)
  end
  util.schedule_force_update(self.force)
end

--- Add a technology and its prerequisites to the front of the queue, moving prerequisites if required.
--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
--- @param player_index uint?
function research_queue.push_front(self, technology, level, player_index)
  -- pre-processing
  local research_state = self.force_table.research_states[technology.name]
  if research_state == constants.research_state.researched then
    return { "message.urq-already-researched" }
  elseif is_trigger_research(technology) then
    return { "message.urq-unable-to-queue" }
  elseif research_queue.contains(self, technology, level) then
    research_queue.move_to_front(self, technology, level)
  end

  --- @type TechnologyAndLevel[]
  local to_research = {}
  --- @type TechnologyAndLevel[]
  local to_move = {}

  local result = add_prerequisites(self, to_research, technology, to_move, player_index)
  if result then return result end

  -- Move higher levels of this tech forward
  if flib_technology.is_multilevel(technology) and research_queue.contains(self, technology, true) then
    local highest = research_queue.get_highest_level(self, technology)
    add_technology(to_move, technology, highest)
  end
  add_technology(to_research, technology, level, self)

  check_for_errors(self, to_research)

  -- Actually move techs to the front of the queue
  local num_to_move = #to_move
  for i = num_to_move, 1, -1 do
    local to_move = to_move[i]
    research_queue.move_to_front(self, to_move.technology, to_move.level)
  end

  -- Actually add techs to the front of the queue
  for i = 1, #to_research do
    local to_research = to_research[i]
    push(self, to_research.technology, to_research.level, num_to_move + i)
  end
  util.schedule_force_update(self.force)
end

--- Validate the queue after a removal.
--- This removes descendants and higher levels of the same technology.
--- @param self ResearchQueue
--- @param technology LuaTechnology
local function validate_queue(self, technology, level)
  -- Remove descendants
  local technologies = self.force.technologies
  local descendants = storage.technology_descendants[technology.name]
  local is_multilevel = flib_technology.is_multilevel(technology)
  if descendants then
    for _, descendant_name in pairs(descendants) do
      local descendant = technologies[descendant_name]
      local level = descendant.level
      if is_multilevel then
        level = level + 1
      end
      if research_queue.contains(self, descendant, level) then
        research_queue.remove(self, descendant, level)
      end
    end
  end
  -- Remove all levels above this one
  if is_multilevel and technology.level <= level then
    local node = self.head
    while node do
      if node.technology == technology and node.level > level then
        research_queue.remove(self, technology, node.level)
      end
      node = node.next
    end
  end
end

--- @param self ResearchQueue
--- @param technology LuaTechnology
--- @param level uint
--- @param skip_validation boolean?
--- @return boolean?
function research_queue.remove(self, technology, level, skip_validation)
  local key = flib_technology.get_leveled_name(technology, level)
  if not self.lookup[key] then return end

  local node = find_node(self, technology, level)
  if not node then return end

  remove_node(self, node)

  if skip_validation then return end
  validate_queue(self, technology, level)
  
  -- Schedule GUI update after removal (only when not skipping validation)
  util.schedule_force_update(self.force)
end

--- @param self ResearchQueue
function research_queue.requeue_multilevel(self)
  if not self.requeue_multilevel then return end
  local head = self.head
  if not head then return end
  local technology = head.technology
  if not flib_technology.is_multilevel(technology) then return end

  -- Find next level, and push it if it exists
  local next_level = research_queue.get_highest_level(self, technology) + 1
  if next_level > technology.prototype.max_level then
    return
  end
  -- Note: No player_index here since this is automatic requeuing, use default depth-first
  research_queue.push(self, technology, next_level)
end

--- @param self ResearchQueue
function research_queue.toggle_paused(self)
  self.paused = not self.paused
  research_queue.update_active_research(self)
end

--- @param self ResearchQueue
function research_queue.toggle_requeue_multilevel(self)
  self.requeue_multilevel = not self.requeue_multilevel
end

--- Unresearch a technology and all its descendants.
--- @param self ResearchQueue
--- @param technology LuaTechnology
function research_queue.unresearch(self, technology)
  local technologies = self.force.technologies
  local research_states = self.force_table.research_states

  --- @param technology LuaTechnology
  local function propagate(technology)
    local descendants = storage.technology_descendants[technology.name] or {}
    for i = 1, #descendants do
      local descendant_name = descendants[i]
      if research_states[descendant_name] == constants.research_state.researched then
        local descendant_data = technologies[descendant_name]
        propagate(descendant_data)
      end
    end
    technology.researched = false
  end

  propagate(technology)
end

local function assign_next_research(self)
  head = self.head
  if head then
    local node = head.next
    while node do
      local state = self.force_table.research_states[node.technology.name]
      if state == constants.research_state.available then
        research_queue.move_to_front(self, node.technology, node.level)
        break
      end
      node = node.next
    end
  end
end

--- @param self ResearchQueue
function research_queue.update_active_research(self)
  local head = self.head
  local should_research = not self.paused and head
  
  if should_research then
    --- @cast head -nil
    local current_research = self.force.current_research
    local needs_new_research = not current_research or head.technology.name ~= current_research.name
    
    if needs_new_research then
      self.updating_active_research = true
      self.force.add_research(head.technology)
      self.updating_active_research = false
      
      -- Update progress tracking
      self.force_table.last_research_progress = flib_technology.get_research_progress(head.technology, head.level)
      
      -- Notify players if research requires manual action
      if #head.technology.research_unit_ingredients == 0 then
        -- TODO: Use localization
        local message = { "", "Next Research requires player action: ", head.technology.prototype.localised_name }
        head.technology.force.print(message)
        -- skip validation, so we don't remove descendants
        research_queue.remove(self, head.technology, head.level, true)
        -- Try again with the next item in the queue. It might be another trigger tech.
        research_queue.update_active_research(self)
        -- Now that all trigger techs are removed, head should be a normal tech or nil
        -- If there's a normal tech, bubble it behind the next valid and researchable tech.
        assign_next_research(self)
      end
    end
  else
    -- Cancel research when paused or queue is empty
    self.updating_active_research = true
    self.force.cancel_current_research()
    self.updating_active_research = false
    self.force_table.last_research_progress = 0
  end
  
  self.force_table.last_research_progress_tick = game.tick
end

--- @param self ResearchQueue
function research_queue.update_durations(self)
  local speed = self.force_table.research_speed
  local duration = 0
  local node = self.head
  while node do
    if speed == 0 then
      node.duration = "[img=infinity]"
    else
      local technology, level = node.technology, node.level
      local progress = flib_technology.get_research_progress(technology, level)
      duration = duration
          + (1 - progress)
          * flib_technology.get_research_unit_count(technology, node.level)
          * technology.research_unit_energy
          / speed
      node.duration = format.time(duration --[[@as uint]])
    end
    node = node.next
  end
end

--- @param self ResearchQueue
function research_queue.update_all_research_states(self)
  for _, technology in pairs(self.force.technologies) do
    local order = storage.technology_order[technology.name]
    local groups = self.force_table.technology_groups
    local research_states = self.force_table.research_states
    local previous_state = research_states[technology.name]
    local new_state = research_queue.get_research_state(self, technology)
    if new_state ~= previous_state then
      groups[previous_state][order] = nil
      groups[new_state][order] = technology
      research_states[technology.name] = new_state
    end
  end
end

--- @param self ResearchQueue
function research_queue.verify_integrity(self)
  local old_head = self.head
  self.head, self.lookup, self.len = nil, {}, 0
  local node = old_head
  local technologies = self.force.technologies
  while node do
    local old_technology, old_level = node.technology, node.level
    if old_technology.valid then
      local technology = technologies[old_technology.name]
      if old_level >= technology.prototype.level and old_level <= technology.prototype.max_level then
        research_queue.push(self, technology, technology.prototype.level)
      end
    end
    node = node.next
  end
end

return research_queue
