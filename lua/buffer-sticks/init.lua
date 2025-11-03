-- luacheck: globals vim

---@class BufferSticks
---@field setup function Setup the buffer sticks plugin
---@field toggle function Toggle the visibility of buffer sticks
---@field show function Show the buffer sticks
---@field hide function Hide the buffer sticks
local M = {}

-- Fuzzy matching helpers (extracted from mini.fuzzy)
local function string_to_letters(s)
	return vim.tbl_map(vim.pesc, vim.split(s, ""))
end

local function score_positions(positions, cutoff)
	if positions == nil or #positions == 0 then
		return -1
	end
	local first, last = positions[1], positions[#positions]
	return cutoff * math.min(last - first + 1, cutoff) + math.min(first, cutoff)
end

local function find_best_positions(letters, candidate, cutoff)
	local n_candidate, n_letters = #candidate, #letters
	if n_letters == 0 then
		return {}
	end
	if n_candidate < n_letters then
		return nil
	end

	-- Search forward to find matching positions with left-most last letter match
	local pos_last = 0
	for let_i = 1, #letters do
		pos_last = candidate:find(letters[let_i], pos_last + 1)
		if not pos_last then
			break
		end
	end

	-- Candidate is matched only if word's last letter is found
	if not pos_last then
		return nil
	end

	-- If there is only one letter, it is already the best match
	if n_letters == 1 then
		return { pos_last }
	end

	-- Compute best match positions by iteratively checking all possible last
	-- letter matches. At end of each iteration best_pos_last holds best match
	-- for last letter among all previously checked such matches.
	local best_pos_last, best_width = pos_last, math.huge
	local rev_candidate = candidate:reverse()

	while pos_last do
		-- Simulate computing best match positions ending exactly at pos_last by
		-- going backwards from current last letter match.
		local rev_first = n_candidate - pos_last + 1
		for i = #letters - 1, 1, -1 do
			rev_first = rev_candidate:find(letters[i], rev_first + 1)
		end
		local first = n_candidate - rev_first + 1
		local width = math.min(pos_last - first + 1, cutoff)

		if width < best_width then
			best_pos_last, best_width = pos_last, width
		end

		-- Advance iteration
		pos_last = candidate:find(letters[n_letters], pos_last + 1)
	end

	-- Actually compute best matched positions from best last letter match
	local best_positions = { best_pos_last }
	local rev_pos = n_candidate - best_pos_last + 1
	for i = #letters - 1, 1, -1 do
		rev_pos = rev_candidate:find(letters[i], rev_pos + 1)
		table.insert(best_positions, 1, n_candidate - rev_pos + 1)
	end

	return best_positions
end

local function make_filter_indexes(word, candidate_array, cutoff)
	local res, letters = {}, string_to_letters(word)
	for i, cand in ipairs(candidate_array) do
		local positions = find_best_positions(letters, cand, cutoff)
		if positions ~= nil then
			table.insert(res, { index = i, score = score_positions(positions, cutoff) })
		end
	end
	return res
end

local function compare_filter_indexes(a, b)
	return a.score < b.score or (a.score == b.score and a.index < b.index)
end

local function filter_by_indexes(candidate_array, ids)
	local res, res_ids = {}, {}
	for _, id in pairs(ids) do
		table.insert(res, candidate_array[id.index])
		table.insert(res_ids, id.index)
	end
	return res, res_ids
end

local function fuzzy_filtersort(word, candidate_array, cutoff)
	cutoff = cutoff or 100
	-- Use 'smart case': case insensitive if word is lowercase
	local cand_array = word == word:lower() and vim.tbl_map(string.lower, candidate_array) or candidate_array
	local filter_ids = make_filter_indexes(word, cand_array, cutoff)
	table.sort(filter_ids, compare_filter_indexes)
	return filter_by_indexes(candidate_array, filter_ids)
end

-- End fuzzy matching helpers

---@class BufferSticksState
---@field wins table<integer, integer> Map of tabpage to window handle
---@field buf integer Buffer handle for the display buffer
---@field visible boolean Whether the buffer sticks are currently visible
---@field cached_buffer_ids integer[] Cached list of buffer IDs for label generation
---@field cached_labels table<integer, string> Map of buffer ID to generated label
---@field list_mode boolean Whether list mode is active
---@field list_input string Current input in list mode
---@field list_action string Current action in list mode ("open" or "close")
---@field list_mode_selected_index integer|nil Currently selected buffer index in list mode (non-filter)
---@field last_selected_buffer_id integer|nil Last selected buffer ID (persists across sessions)
---@field filter_mode boolean Whether filter mode is active
---@field filter_input string Current filter input string
---@field filter_selected_index integer Currently selected buffer index in filtered results
local state = {
	wins = {},
	buf = -1,
	visible = false,
	list_mode = false,
	list_input = "",
	list_action = "open",
	list_mode_selected_index = nil,
	last_selected_buffer_id = nil,
	filter_mode = false,
	filter_input = "",
	filter_selected_index = 1,
	cached_buffer_ids = {},
	cached_labels = {},
	auto_hidden = false,
	win_pos = { col = 0, row = 0, width = 0, height = 0 },
	preview_origin_win = nil,
	preview_origin_buf = nil,
	preview_float_win = nil,
	preview_float_buf = nil,
}

---@alias BufferSticksHighlights vim.api.keyset.highlight

---@class BufferSticksOffset
---@field x integer Horizontal offset from default position
---@field y integer Vertical offset from default position

---@class BufferSticksPadding
---@field top integer Top padding inside the window
---@field right integer Right padding inside the window
---@field bottom integer Bottom padding inside the window
---@field left integer Left padding inside the window

---@class BufferSticksListKeys
---@field close_buffer string Key combination to close buffer in list mode
---@field move_up string Key to move selection up in list mode
---@field move_down string Key to move selection down in list mode

---@class BufferSticksFilterKeys
---@field enter string Key to enter filter mode
---@field confirm string Key to confirm selection in filter mode
---@field exit string Key to exit filter mode
---@field move_up string Key to move selection up in filter mode
---@field move_down string Key to move selection down in filter mode

---@class BufferSticksListFilter
---@field title string Title for filter prompt when filter input is not empty
---@field title_empty string Title for filter prompt when filter input is empty
---@field active_indicator string Symbol to show for the selected item in filter mode
---@field fuzzy_cutoff number Cutoff value for fuzzy matching algorithm (default: 100)
---@field keys BufferSticksFilterKeys Key mappings for filter mode

---@class BufferSticksList
---@field show string[] What to show in list mode: "filename", "space", "label", "stick"
---@field active_indicator string Symbol to show for the selected item when using arrow navigation
---@field keys BufferSticksListKeys Key mappings for list mode
---@field filter BufferSticksListFilter Filter configuration

---@class BufferSticksLabel
---@field show "always"|"list"|"never" When to show buffer name characters

---@class BufferSticksFilter
---@field filetypes? string[] List of filetypes to exclude from buffer sticks
---@field buftypes? string[] List of buftypes to exclude from buffer sticks (e.g., "terminal", "help", "quickfix")
---@field names? string[] List of buffer name patterns to exclude (supports lua patterns)

---@class BufferSticksConfig
---@field offset BufferSticksOffset Position offset for fine-tuning
---@field padding BufferSticksPadding Padding inside the window
---@field active_char string Character to display for the active buffer
---@field inactive_char string Character to display for inactive buffers
---@field alternate_char string Character to display for the alternate buffer
---@field alternate_modified_char string Character to display for the alternate modified buffer
---@field active_modified_char string Character to display for the active modified buffer
---@field inactive_modified_char string Character to display for inactive modified buffers
---@field transparent boolean Whether the background should be transparent
---@field winblend? number Window blend level (0-100)
---@field auto_hide boolean Auto-hide when cursor is over float
---@field label? BufferSticksLabel Label display configuration
---@field list? BufferSticksList List mode configuration
---@field filter? BufferSticksFilter Filter configuration for excluding buffers
---@field highlights table<string, BufferSticksHighlights> Highlight groups for active/inactive/label states
local config = {
	offset = { x = 0, y = 0 },
	padding = { top = 0, right = 1, bottom = 0, left = 1 },
	active_char = "──",
	inactive_char = " ─",
	alternate_char = " ─",
	active_modified_char = "──",
	inactive_modified_char = " ─",
	alternate_modified_char = " ─",
	transparent = true,
	auto_hide = true,
	label = { show = "list" },
	list = {
		show = { "filename", "space", "label" },
		active_indicator = "•",
		keys = {
			close_buffer = "<C-q>",
			move_up = "<Up>",
			move_down = "<Down>",
		},
		filter = {
			title = "➜ ",
			title_empty = "Filter",
			active_indicator = "•",
			fuzzy_cutoff = 100,
			keys = {
				enter = "/",
				confirm = "<CR>",
				exit = "<Esc>",
				move_up = "<Up>",
				move_down = "<Down>",
			},
		},
	},
	preview = {
		enabled = true,
		mode = "float",
		float = {
			position = "right",
			width = 0.5,
			height = 0.8,
			border = "single",
			title = nil,
			title_pos = "center",
			footer = nil,
			footer_pos = "center",
		},
	},
	highlights = {
		active = { fg = "#bbbbbb" },
		alternate = { fg = "#888888" },
		inactive = { fg = "#333333" },
		active_modified = { fg = "#ffffff" },
		alternate_modified = { fg = "#dddddd" },
		inactive_modified = { fg = "#999999" },
		label = { fg = "#aaaaaa", italic = true },
		filter_selected = { fg = "#bbbbbb", italic = true },
		filter_title = { fg = "#aaaaaa", italic = true },
		list_selected = { fg = "#bbbbbb", italic = true },
	},
}

---@class BufferInfo
---@field id integer Buffer ID
---@field name string Buffer name/path
---@field is_current boolean Whether this is the currently active buffer
---@field is_alternate boolean Whether this is the alternate buffer
---@field is_modified boolean Whether this buffer has unsaved changes
---@field label string Generated unique label for this buffer

---Check if buffer list has changed compared to cached version
---@param current_buffer_ids integer[] Current list of buffer IDs
---@return boolean changed Whether the buffer list has changed
local function has_buffer_list_changed(current_buffer_ids)
	if #current_buffer_ids ~= #state.cached_buffer_ids then
		return true
	end

	for i, buffer_id in ipairs(current_buffer_ids) do
		if buffer_id ~= state.cached_buffer_ids[i] then
			return true
		end
	end

	return false
end

---Generate unique labels for buffers using collision avoidance algorithm
---@param buffers BufferInfo[] List of buffers to generate labels for
---@return BufferInfo[] buffers List of buffers with unique labels assigned
local function generate_unique_labels(buffers)
	local labels = {}
	local used_labels = {}
	local filename_map = {}
	local collision_groups = {}

	-- Phase 1: Extract filenames and group by first word character (skip leading symbols)
	for _, buffer in ipairs(buffers) do
		local filename = vim.fn.fnamemodify(buffer.name, ":t")
		if filename == "" then
			filename = "?"
		end
		filename_map[buffer.id] = filename:lower()

		-- Find first word character (skip leading symbols like . _ -)
		local first_word_char = filename:match("%w")
		if first_word_char then
			first_word_char = first_word_char:lower()
			if not collision_groups[first_word_char] then
				collision_groups[first_word_char] = {}
			end
			table.insert(collision_groups[first_word_char], buffer)
		end
		-- Buffers with no word characters will be handled in Phase 3
	end

	-- Phase 2: Assign labels based on collision detection
	for first_char, group in pairs(collision_groups) do
		if #group == 1 then
			-- No collision: use single character
			local buffer = group[1]
			labels[buffer.id] = first_char
			used_labels[first_char] = true
		else
			-- Collision detected: ALL buffers in this group get two-character labels
			for _, buffer in ipairs(group) do
				local filename = filename_map[buffer.id]
				local found_label = false

				-- Try first two characters
				if #filename >= 2 then
					local two_char = filename:sub(1, 2)
					if two_char:match("^%w%w$") and not used_labels[two_char] then
						labels[buffer.id] = two_char
						used_labels[two_char] = true
						found_label = true
					end
				end

				-- If first two chars didn't work, try first char + other chars
				if not found_label and first_char:match("%w") then
					for i = 2, math.min(#filename, 5) do
						local second_char = filename:sub(i, i)
						if second_char:match("%w") then
							local alt_label = first_char .. second_char
							if not used_labels[alt_label] then
								labels[buffer.id] = alt_label
								used_labels[alt_label] = true
								found_label = true
								break
							end
						end
					end
				end

				-- Fallback: use sequential two-character combinations
				if not found_label then
					local base_char = string.byte("a")
					for i = 0, 25 do
						for j = 0, 25 do
							local fallback_label = string.char(base_char + i) .. string.char(base_char + j)
							if not used_labels[fallback_label] then
								labels[buffer.id] = fallback_label
								used_labels[fallback_label] = true
								found_label = true
								break
							end
						end
						if found_label then
							break
						end
					end
				end
			end
		end
	end

	-- Phase 3: Handle buffers with no word characters (use numeric labels)
	for _, buffer in ipairs(buffers) do
		if not labels[buffer.id] then
			-- Use numeric labels for files with no word characters
			-- This prevents collision with letter-based labels
			for i = 0, 9 do
				local numeric_label = tostring(i)
				if not used_labels[numeric_label] then
					labels[buffer.id] = numeric_label
					used_labels[numeric_label] = true
					break
				end
			end
		end
	end

	return labels
end

---Get a list of all loaded and listed buffers with filtering applied
---@return BufferInfo[] buffers List of buffer information
local function get_buffer_list()
	local buffers = {}
	local current_buf = vim.api.nvim_get_current_buf()
	local alternate_buf = vim.fn.bufnr("#")
	local buffer_ids = {}

	-- Collect filtered buffers
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
			local buf_name = vim.api.nvim_buf_get_name(buf)
			local buf_filetype = vim.bo[buf].filetype
			local should_include = true

			-- Filter by filetype
			if config.filter and config.filter.filetypes then
				for _, ft in ipairs(config.filter.filetypes) do
					if buf_filetype == ft then
						should_include = false
						break
					end
				end
			end

			-- Filter by buftype
			if should_include and config.filter and config.filter.buftypes then
				local buf_buftype = vim.bo[buf].buftype
				for _, bt in ipairs(config.filter.buftypes) do
					if buf_buftype == bt then
						should_include = false
						break
					end
				end
			end

			-- Filter by buffer name patterns
			if should_include and config.filter and config.filter.names then
				for _, pattern in ipairs(config.filter.names) do
					if buf_name:match(pattern) then
						should_include = false
						break
					end
				end
			end

			if should_include then
				table.insert(buffers, {
					id = buf,
					name = buf_name,
					is_current = buf == current_buf,
					is_modified = vim.bo[buf].modified,
					is_alternate = buf == alternate_buf,
				})
				table.insert(buffer_ids, buf)
			end
		end
	end

	-- Check if we need to regenerate labels
	if has_buffer_list_changed(buffer_ids) then
		-- Generate new labels and cache them
		state.cached_labels = generate_unique_labels(buffers)
		state.cached_buffer_ids = buffer_ids
	end

	-- Assign cached labels to buffers
	for _, buffer in ipairs(buffers) do
		buffer.label = state.cached_labels[buffer.id] or "?"
	end

	return buffers
end

---Right-align lines within a given width by padding with spaces
---@param lines string[] Lines to align
---@param width number Target width for alignment
---@return string[] aligned_lines Right-aligned lines
local function right_align_lines(lines, width)
	local aligned_lines = {}
	for _, line in ipairs(lines) do
		local content_width = vim.fn.strwidth(line)
		local padding = width - content_width
		local aligned_line = string.rep(" ", math.max(0, config.padding.left + padding))
			.. line
			.. string.rep(" ", math.max(0, config.padding.right))
		table.insert(aligned_lines, aligned_line)
	end
	return aligned_lines
end

---Apply vertical padding (top and bottom) to lines
---@param lines string[] Lines to add vertical padding to
---@return string[] padded_lines Lines with top and bottom padding applied
local function vertical_align_lines(lines)
	local padded_lines = {}

	-- Add top padding (empty lines)
	for _ = 1, config.padding.top do
		table.insert(padded_lines, lines[1] and string.rep(" ", vim.fn.strwidth(lines[1])) or "")
	end

	-- Add original content lines
	for _, line in ipairs(lines) do
		table.insert(padded_lines, line)
	end

	-- Add bottom padding (empty lines)
	for _ = 1, config.padding.bottom do
		table.insert(padded_lines, lines[1] and string.rep(" ", vim.fn.strwidth(lines[1])) or "")
	end

	return padded_lines
end

---Get display paths for buffers with recursive expansion for duplicates
---@param buffers BufferInfo[] List of buffers
---@return table<integer, string> Map of buffer.id to display path
local function get_display_paths(buffers)
	local display_paths = {}
	local path_components = {}

	-- Initialize with full paths split into components
	for _, buffer in ipairs(buffers) do
		local full_path = buffer.name
		local components = {}

		-- Split path into components (reverse order, filename first)
		local filename = vim.fn.fnamemodify(full_path, ":t")
		if filename ~= "" then
			table.insert(components, filename)

			-- Get parent directories - Cross-platform root detection
			local parent = vim.fn.fnamemodify(full_path, ":h")
			while parent ~= "" and parent ~= "." do
				local new_parent = vim.fn.fnamemodify(parent, ":h")
				-- Stop if parent doesn't change (reached filesystem root)
				if new_parent == parent then
					break
				end

				local dir = vim.fn.fnamemodify(parent, ":t")
				if dir ~= "" then
					table.insert(components, dir)
				end
				parent = new_parent
			end
		end

		path_components[buffer.id] = components
		-- Start with just the filename
		display_paths[buffer.id] = components[1] or "?"
	end

	-- Recursively expand duplicates
	local max_iterations = 10 -- Safety limit
	for _ = 1, max_iterations do
		-- Group by current display path
		local path_groups = {}
		for buffer_id, display_path in pairs(display_paths) do
			if not path_groups[display_path] then
				path_groups[display_path] = {}
			end
			table.insert(path_groups[display_path], buffer_id)
		end

		-- Check if we still have duplicates
		local has_duplicates = false
		for _, group in pairs(path_groups) do
			if #group > 1 then
				has_duplicates = true
				break
			end
		end

		if not has_duplicates then
			break
		end

		-- Expand duplicates by one level
		for display_path, buffer_ids in pairs(path_groups) do
			if #buffer_ids > 1 then
				-- This path is duplicated, expand all buffers in this group
				for _, buffer_id in ipairs(buffer_ids) do
					local components = path_components[buffer_id]
					local current_depth = 0

					-- Count current depth
					for i = 1, #components do
						if display_paths[buffer_id]:find(components[i], 1, true) then
							current_depth = math.max(current_depth, i)
						end
					end

					-- Add one more parent level if available
					if current_depth < #components then
						local new_depth = current_depth + 1
						local path_parts = {}
						for i = new_depth, 1, -1 do
							table.insert(path_parts, components[i])
						end
						display_paths[buffer_id] = table.concat(path_parts, "/")
					end
				end
			end
		end
	end

	return display_paths
end

---Check if any buffer has a two-character label
---@param buffers BufferInfo[] List of buffers to check
---@return boolean has_two_char_label True if any buffer has a two-character label
local function has_two_char_label(buffers)
	for _, buffer in ipairs(buffers) do
		if #buffer.label == 2 then
			return true
		end
	end
	return false
end

---Calculate the required width based on current display mode and content
---@return number width The calculated width needed for the floating window
local function calculate_required_width()
	local buffers = get_buffer_list()
	local max_width = 1

	-- Calculate based on current display mode
	if state.list_mode and config.list and config.list.show then
		-- List mode: calculate based on list.show config
		local show_filename = vim.list_contains(config.list.show, "filename")
		local show_space = vim.list_contains(config.list.show, "space")
		local show_label = vim.list_contains(config.list.show, "label")
		local show_stick = vim.list_contains(config.list.show, "stick")

		local total_width = 0

		if show_stick then
			total_width = total_width
				+ math.max(
					vim.fn.strwidth(config.active_char),
					vim.fn.strwidth(config.inactive_char),
					vim.fn.strwidth(config.alternate_char),
					vim.fn.strwidth(config.alternate_modified_char),
					vim.fn.strwidth(config.active_modified_char),
					vim.fn.strwidth(config.inactive_modified_char)
				)
		end

		if show_filename then
			-- Get recursively-expanded display paths
			local display_paths = get_display_paths(buffers)

			-- Find the longest display path among all buffers
			local max_filename_width = 0
			for _, buffer in ipairs(buffers) do
				local display_path = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
				max_filename_width = math.max(max_filename_width, vim.fn.strwidth(display_path))
			end
			total_width = total_width + max_filename_width
		end

		if show_space and (show_stick or show_filename or show_label) then
			-- Count spaces needed between elements
			local element_count = 0
			if show_stick then
				element_count = element_count + 1
			end
			if show_filename then
				element_count = element_count + 1
			end
			if show_label then
				element_count = element_count + 1
			end
			if element_count > 1 then
				total_width = total_width + (element_count - 1) -- spaces between elements
			end
		end

		if show_label then
			-- Find the longest label among all buffers
			local max_label_width = 0
			for _, buffer in ipairs(buffers) do
				max_label_width = math.max(max_label_width, vim.fn.strwidth(buffer.label))
			end
			total_width = total_width + max_label_width
		end

		max_width = total_width

		-- If in filter mode, also consider the filter prompt width
		if state.filter_mode then
			local filter_config = config.list and config.list.filter or {}
			local filter_title = #state.filter_input > 0 and (filter_config.title or "Filter: ")
				or (filter_config.title_empty or "Filter:   ")
			-- Add padding: 3 spaces if we have two-char labels, 2 spaces otherwise
			local padding = has_two_char_label(buffers) and "   " or "  "
			local filter_prompt_width = vim.fn.strwidth(filter_title .. state.filter_input .. padding)
			max_width = math.max(max_width, filter_prompt_width)
		end
	else
		-- Normal mode: check if labels should be shown
		local should_show_labels = (config.label and config.label.show == "always")

		-- Use the longest of all character options (display width)
		max_width = math.max(
			vim.fn.strwidth(config.active_char),
			vim.fn.strwidth(config.inactive_char),
			vim.fn.strwidth(config.alternate_char),
			vim.fn.strwidth(config.alternate_modified_char),
			vim.fn.strwidth(config.active_modified_char),
			vim.fn.strwidth(config.inactive_modified_char)
		)

		if should_show_labels then
			-- Find the longest label among all buffers
			local max_label_width = 0
			for _, buffer in ipairs(buffers) do
				max_label_width = math.max(max_label_width, vim.fn.strwidth(buffer.label))
			end
			max_width = max_width + 1 + max_label_width -- space + label
		end
	end

	return max_width
end

---@class WindowInfo
---@field buf number Buffer handle
---@field win number Window handle

---Check if cursor position is within the floating window bounds
---@return boolean collision True if cursor is within the window area
local function check_cursor_collision()
	-- If auto_hide is disabled, no collision detection needed
	if not config.auto_hide then
		return false
	end

	-- If we don't have valid window position data, no collision
	if state.win_pos.width == 0 or state.win_pos.height == 0 then
		return false
	end

	-- Get screen cursor position
	-- Convert to 0-based like window coordinates
	local cursor_row = vim.fn.screenrow() - 1
	local cursor_col = vim.fn.screencol() - 1

	-- Use a small consistent offset for collision detection
	local offset = 1

	-- Check if cursor is within floating window bounds (regardless of window validity)
	return cursor_col >= state.win_pos.col - offset
		and cursor_col < state.win_pos.col + state.win_pos.width + offset
		and cursor_row >= state.win_pos.row - offset
		and cursor_row < state.win_pos.row + state.win_pos.height + offset
end

---Handle cursor movement for auto-hide behavior
local function handle_cursor_move()
	-- Only handle auto-hide if auto_hide is enabled and we're visible (or auto-hidden)
	if not config.auto_hide or state.list_mode then
		return
	end

	-- If we're not visible and not auto-hidden, nothing to do
	if not state.visible and not state.auto_hidden then
		return
	end

	local collision = check_cursor_collision()
	local cursor_row = vim.fn.screenrow() - 1
	local cursor_col = vim.fn.screencol() - 1

	if collision and state.visible and not state.auto_hidden then
		-- Cursor entered float area, hide it immediately
		state.auto_hidden = true
		local current_tab = vim.api.nvim_get_current_tabpage()
		local win = state.wins[current_tab]
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_hide(win)
		end
	elseif not collision and state.auto_hidden then
		-- Cursor left float area, show it immediately
		state.auto_hidden = false
		M.show()
	end
end

---Create or update the floating window for buffer sticks
---@return WindowInfo window_info Information about the window and buffer
local function create_or_update_floating_window()
	local buffers = get_buffer_list()
	local content_height = math.max(#buffers, 1)
	local content_width = calculate_required_width()

	-- Add extra line for filter prompt if in filter mode
	if state.filter_mode then
		content_height = content_height + 1
	end

	-- Add padding to window dimensions
	local height = content_height + config.padding.top + config.padding.bottom
	local width = content_width + config.padding.left + config.padding.right

	-- Position on the right side of the screen
	local col = vim.o.columns - width - config.offset.x
	local row = math.floor((vim.o.lines - height) / 2) + config.offset.y

	-- Create buffer if needed
	if not vim.api.nvim_buf_is_valid(state.buf) then
		state.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[state.buf].bufhidden = "wipe"
		vim.bo[state.buf].filetype = "buffersticks"
	end

	-- Create window
	local win_config = {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "none",
		focusable = false,
		zindex = 10,
	}

	-- Set background based on transparency setting
	if not config.transparent then
		win_config.style = "minimal"
		-- Add a background highlight group if not transparent
	end

	-- Get current tabpage and its window handle
	local current_tab = vim.api.nvim_get_current_tabpage()
	local win = state.wins[current_tab]

	-- Check if window is valid in current tabpage
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, win_config)
	else
		win = vim.api.nvim_open_win(state.buf, false, win_config)
		state.wins[current_tab] = win
	end

	-- Store window position for collision detection
	state.win_pos = { col = col, row = row, width = width, height = height }

	---@type vim.api.keyset.option
	local win_opts = { win = win }

	-- Set winblend if specified
	if config.winblend then
		vim.api.nvim_set_option_value("winblend", config.winblend, win_opts)
	end

	-- Set window background based on transparency
	if not config.winblend and not config.transparent then
		vim.api.nvim_set_option_value("winhl", "Normal:BufferSticksBackground", win_opts)
	else
		vim.api.nvim_set_option_value("winhl", "Normal:NONE", win_opts)
	end

	return { buf = state.buf, win = win }
end

---Apply fuzzy filter to buffers based on current filter input
---@param buffers BufferInfo[] List of buffers to filter
---@param display_paths table<integer, string> Map of buffer.id to display path
---@return integer[] filtered_indices Indices of matched buffers
local function apply_fuzzy_filter(buffers, display_paths)
	-- Build candidate array for filtering
	local candidates = {}
	for _, buffer in ipairs(buffers) do
		local display_name = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
		table.insert(candidates, display_name)
	end

	-- Apply fuzzy filter
	local filter_config = config.list and config.list.filter or {}
	local cutoff = filter_config.fuzzy_cutoff or 100
	local _, filtered_indices = fuzzy_filtersort(state.filter_input, candidates, cutoff)
	return filtered_indices
end

---Render buffer indicators in the floating window
---Updates the buffer content and applies appropriate highlighting
local function render_buffers()
	local current_tab = vim.api.nvim_get_current_tabpage()
	local win = state.wins[current_tab]

	if not vim.api.nvim_buf_is_valid(state.buf) or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local buffers = get_buffer_list()
	local lines = {}
	local window_width = vim.api.nvim_win_get_width(win)

	-- Get display paths with recursive expansion for duplicates
	local display_paths = get_display_paths(buffers)

	-- Filter buffers if in filter mode
	local filtered_buffers = buffers
	local filtered_indices = {}
	if state.filter_mode and state.filter_input ~= "" then
		filtered_indices = apply_fuzzy_filter(buffers, display_paths)
		filtered_buffers = {}
		for _, idx in ipairs(filtered_indices) do
			table.insert(filtered_buffers, buffers[idx])
		end
	else
		-- No filter, use all buffers with sequential indices
		for i = 1, #buffers do
			table.insert(filtered_indices, i)
		end
	end

	-- Check if we have any two-character labels (to determine if we should pad single-char labels)
	local has_two_char = has_two_char_label(filtered_buffers)

	-- Add filter prompt line if in filter mode
	if state.filter_mode then
		local filter_config = config.list and config.list.filter or {}
		local filter_title = #state.filter_input > 0 and (filter_config.title or "Filter: ")
			or (filter_config.title_empty or "Filter:   ")
		-- Add padding: 3 spaces if we have two-char labels, 2 spaces otherwise
		local padding = has_two_char and "   " or "  "
		local filter_prompt = filter_title .. state.filter_input .. padding
		table.insert(lines, filter_prompt)
	end

	for buffer_idx, buffer in ipairs(filtered_buffers) do
		local line_content
		local should_show_char = false

		-- Check if this buffer is selected in filter mode
		local is_filter_selected = state.filter_mode and buffer_idx == state.filter_selected_index
		-- Check if this buffer is selected in list mode (non-filter)
		local is_list_selected = state.list_mode
			and not state.filter_mode
			and buffer_idx == state.list_mode_selected_index

		-- Determine if we should show characters based on config and state
		if config.label and config.label.show == "always" then
			should_show_char = true
		elseif config.label and config.label.show == "list" and state.list_mode then
			should_show_char = true
		end

		-- In list mode, use list.show configuration
		if state.list_mode and config.list and config.list.show then
			local show_filename = vim.list_contains(config.list.show, "filename")
			local show_space = vim.list_contains(config.list.show, "space")
			local show_label = vim.list_contains(config.list.show, "label")
			local show_stick = vim.list_contains(config.list.show, "stick")

			local parts = {}

			if show_stick then
				if buffer.is_modified then
					if buffer.is_current then
						table.insert(parts, config.active_modified_char)
					elseif buffer.is_alternate then
						table.insert(parts, config.alternate_modified_char)
					else
						table.insert(parts, config.inactive_modified_char)
					end
				else
					if buffer.is_current then
						table.insert(parts, config.active_char)
					elseif buffer.is_alternate then
						table.insert(parts, config.alternate_char)
					else
						table.insert(parts, config.inactive_char)
					end
				end
			end

			if show_filename then
				-- Use the recursively-expanded display path
				local filename = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
				table.insert(parts, filename)
			end

			if show_label then
				-- Pad single-character labels with a space only if there are two-character labels
				local label_display = (#buffer.label == 1 and has_two_char) and " " .. buffer.label or buffer.label
				-- In filter mode, show active indicator for selected item or spaces for others
				if state.filter_mode then
					if is_filter_selected then
						-- Use configurable active indicator with padding to match label width
						local filter_config = config.list and config.list.filter or {}
						local indicator = filter_config.active_indicator or "•"
						local padding_needed = #label_display - vim.fn.strwidth(indicator)
						table.insert(parts, indicator .. string.rep(" ", math.max(0, padding_needed)))
					else
						table.insert(parts, string.rep(" ", #label_display))
					end
				elseif is_list_selected then
					-- In list mode with selection, show active indicator with leading space if two-char labels exist
					local list_config = config.list or {}
					local indicator = list_config.active_indicator or "•"
					local indicator_display = has_two_char and " " .. indicator or indicator
					table.insert(parts, indicator_display)
				else
					table.insert(parts, label_display)
				end
			end

			if show_space and #parts > 1 then
				line_content = table.concat(parts, " ")
			else
				line_content = table.concat(parts, "")
			end
		elseif should_show_char then
			-- Use generated unique label
			if buffer.is_modified then
				if buffer.is_current then
					line_content = config.active_modified_char .. " " .. buffer.label
				elseif buffer.is_alternate then
					line_content = config.alternate_modified_char .. " " .. buffer.label
				else
					line_content = config.inactive_modified_char .. " " .. buffer.label
				end
			else
				if buffer.is_current then
					line_content = config.active_char .. " " .. buffer.label
				elseif buffer.is_alternate then
					line_content = config.alternate_char .. " " .. buffer.label
				else
					line_content = config.inactive_char .. " " .. buffer.label
				end
			end
		else
			if buffer.is_modified then
				if buffer.is_current then
					line_content = config.active_modified_char
				elseif buffer.is_alternate then
					line_content = config.alternate_modified_char
				else
					line_content = config.inactive_modified_char
				end
			else
				if buffer.is_current then
					line_content = config.active_char
				elseif buffer.is_alternate then
					line_content = config.alternate_char
				else
					line_content = config.inactive_char
				end
			end
		end
		table.insert(lines, line_content)
	end

	-- Right-align content within the window
	window_width = calculate_required_width()
	local aligned_lines = right_align_lines(lines, window_width)

	-- Apply vertical padding
	local final_lines = vertical_align_lines(aligned_lines)

	local ns_id = vim.api.nvim_create_namespace("BufferSticks")
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, final_lines)

	-- Highlight filter prompt if in filter mode
	if state.filter_mode then
		local filter_line_idx = config.padding.top
		vim.hl.range(state.buf, ns_id, "BufferSticksFilterTitle", { filter_line_idx, 0 }, { filter_line_idx, -1 })
	end

	-- Set highlights
	local line_offset = state.filter_mode and 1 or 0 -- Offset for filter prompt line
	for i, buffer in ipairs(filtered_buffers) do
		local line_idx = i - 1 + config.padding.top + line_offset -- Account for top padding and filter prompt
		local line_content = final_lines[i + config.padding.top + line_offset] -- Access content from final padded lines

		-- Check if this buffer is selected in filter mode
		local is_filter_selected = state.filter_mode and i == state.filter_selected_index
		-- Check if this buffer is selected in list mode (non-filter)
		local is_list_selected = state.list_mode and not state.filter_mode and i == state.list_mode_selected_index

		-- In list mode, apply specific highlighting for different parts
		if state.list_mode and config.list and config.list.show then
			local show_filename = vim.list_contains(config.list.show, "filename")
			local show_space = vim.list_contains(config.list.show, "space")
			local show_label = vim.list_contains(config.list.show, "label")
			local show_stick = vim.list_contains(config.list.show, "stick")

			local col_offset = 0
			-- Find where content starts (after right-alignment padding)
			local padding_match = line_content:match("^( *)")
			if padding_match then
				col_offset = #padding_match
			end

			-- Highlight stick part
			if show_stick then
				local stick_char
				local hl_group

				-- Determine stick character based on buffer state
				if buffer.is_modified then
					if buffer.is_current then
						stick_char = config.active_modified_char
						hl_group = "BufferSticksActiveModified"
					elseif buffer.is_alternate then
						stick_char = config.alternate_modified_char
						hl_group = "BufferSticksAlternateModified"
					else
						stick_char = config.inactive_modified_char
						hl_group = "BufferSticksInactiveModified"
					end
				else
					if buffer.is_current then
						stick_char = config.active_char
						hl_group = "BufferSticksActive"
					elseif buffer.is_alternate then
						stick_char = config.alternate_char
						hl_group = "BufferSticksAlternate"
					else
						stick_char = config.inactive_char
						hl_group = "BufferSticksInactive"
					end
				end

				-- Override highlight if selected
				if is_filter_selected then
					hl_group = "BufferSticksFilterSelected"
				elseif is_list_selected then
					hl_group = "BufferSticksListSelected"
				end
				local stick_width = vim.fn.strwidth(stick_char)
				vim.hl.range(
					state.buf,
					ns_id,
					hl_group,
					{ line_idx, col_offset },
					{ line_idx, col_offset + stick_width }
				)
				col_offset = col_offset + stick_width
			end

			-- Highlight filename part (use same color as stick for now)
			if show_filename then
				-- Use the recursively-expanded display path
				local filename = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
				local filename_width = vim.fn.strwidth(filename)
				local hl_group
				if is_filter_selected then
					-- Use filter selected highlight
					hl_group = "BufferSticksFilterSelected"
				elseif is_list_selected then
					-- Use list mode selected highlight
					hl_group = "BufferSticksListSelected"
				elseif buffer.is_modified then
					if buffer.is_current then
						hl_group = "BufferSticksActiveModified"
					elseif buffer.is_alternate then
						hl_group = "BufferSticksAlternateModified"
					else
						hl_group = "BufferSticksInactiveModified"
					end
				else
					if buffer.is_current then
						hl_group = "BufferSticksActive"
					elseif buffer.is_alternate then
						hl_group = "BufferSticksAlternate"
					else
						hl_group = "BufferSticksInactive"
					end
				end
				vim.hl.range(
					state.buf,
					ns_id,
					hl_group,
					{ line_idx, col_offset },
					{ line_idx, col_offset + filename_width }
				)
				col_offset = col_offset + filename_width

				-- Add space after filename if needed
				if show_space and show_label then
					col_offset = col_offset + 1
				end
			elseif show_stick and show_space and show_label then
				-- Add space after stick if needed
				col_offset = col_offset + 1
			end

			-- Highlight label part
			if show_label then
				if state.filter_mode then
					-- In filter mode, highlight the indicator for selected item
					if is_filter_selected then
						local filter_config = config.list and config.list.filter or {}
						local indicator = filter_config.active_indicator or "•"
						-- Find the indicator in the line content
						local content_start = line_content:sub(col_offset + 1)
						local indicator_start_pos = content_start:find(vim.pesc(indicator))
						if indicator_start_pos then
							local byte_start = col_offset + indicator_start_pos - 1
							local byte_end = byte_start + #indicator
							vim.hl.range(
								state.buf,
								ns_id,
								"BufferSticksFilterSelected",
								{ line_idx, byte_start },
								{ line_idx, byte_end }
							)
						end
					end
				elseif is_list_selected then
					-- In list mode with selection, highlight the indicator
					local list_config = config.list or {}
					local indicator = list_config.active_indicator or "•"
					local content_start = line_content:sub(col_offset + 1)
					local indicator_start_pos = content_start:find(vim.pesc(indicator))
					if indicator_start_pos then
						local byte_start = col_offset + indicator_start_pos - 1
						local byte_end = byte_start + #indicator
						vim.hl.range(
							state.buf,
							ns_id,
							"BufferSticksListSelected",
							{ line_idx, byte_start },
							{ line_idx, byte_end }
						)
					end
				else
					-- Not in filter or selection mode, use normal label highlight
					local content_start = line_content:sub(col_offset + 1)
					local label_start_pos = content_start:find(vim.pesc(buffer.label))

					if label_start_pos then
						local byte_start = col_offset + label_start_pos - 1
						local byte_end = byte_start + #buffer.label
						vim.hl.range(
							state.buf,
							ns_id,
							"BufferSticksLabel",
							{ line_idx, byte_start },
							{ line_idx, byte_end }
						)
					end
				end
			end
		else
			-- Normal mode: highlight entire line
			local hl_group
			if is_filter_selected then
				-- Use filter selected highlight
				hl_group = "BufferSticksFilterSelected"
			elseif is_list_selected then
				-- Use list mode selected highlight
				hl_group = "BufferSticksListSelected"
			elseif buffer.is_modified then
				if buffer.is_current then
					hl_group = "BufferSticksActiveModified"
				elseif buffer.is_alternate then
					hl_group = "BufferSticksAlternateModified"
				else
					hl_group = "BufferSticksInactiveModified"
				end
			else
				if buffer.is_current then
					hl_group = "BufferSticksActive"
				elseif buffer.is_alternate then
					hl_group = "BufferSticksAlternate"
				else
					hl_group = "BufferSticksInactive"
				end
			end
			vim.hl.range(state.buf, ns_id, hl_group, { line_idx, 0 }, { line_idx, -1 })
		end
	end
end

---Create or update the preview floating window
---@param buffer_id integer Buffer ID to preview
local function create_preview_float(buffer_id)
	if not vim.api.nvim_buf_is_valid(buffer_id) then
		return
	end

	local preview_config = config.preview and config.preview.float or {}
	local position = preview_config.position or "right"
	local width_frac = preview_config.width or 0.5
	local height_frac = preview_config.height or 0.8

	local editor_width = vim.o.columns
	local editor_height = vim.o.lines

	local width = math.floor(editor_width * width_frac)
	local height = math.floor(editor_height * height_frac)

	local col, row
	if position == "left" then
		col = 0
		row = math.floor((editor_height - height) / 2)
	elseif position == "below" then
		col = math.floor((editor_width - width) / 2)
		row = editor_height - height
	else
		col = editor_width - width - (state.win_pos.width or 0) - 2
		row = math.floor((editor_height - height) / 2)
	end

	local win_config = {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = preview_config.border or "single",
		focusable = false,
		zindex = 9,
	}

	if preview_config.title then
		win_config.title = preview_config.title
		win_config.title_pos = preview_config.title_pos or "center"
	end

	if preview_config.footer then
		win_config.footer = preview_config.footer
		win_config.footer_pos = preview_config.footer_pos or "center"
	end

	if state.preview_float_win and vim.api.nvim_win_is_valid(state.preview_float_win) then
		vim.api.nvim_win_set_config(state.preview_float_win, win_config)
		pcall(vim.api.nvim_win_set_buf, state.preview_float_win, buffer_id)
	else
		state.preview_float_win = vim.api.nvim_open_win(buffer_id, false, win_config)
	end
end

---Clean up preview resources
---@param restore_original? boolean Whether to restore original buffer in "current" mode
local function cleanup_preview(restore_original)
	if restore_original and config.preview and config.preview.mode == "current" then
		if state.preview_origin_buf and vim.api.nvim_buf_is_valid(state.preview_origin_buf) then
			pcall(vim.api.nvim_set_current_buf, state.preview_origin_buf)
		end
	end

	if state.preview_float_win and vim.api.nvim_win_is_valid(state.preview_float_win) then
		pcall(vim.api.nvim_win_close, state.preview_float_win, true)
	end
	state.preview_float_win = nil
	state.preview_float_buf = nil
	state.preview_origin_win = nil
	state.preview_origin_buf = nil
end

---Update preview based on selected buffer
---@param buffer_id integer Buffer ID to preview
local function update_preview(buffer_id)
	if not config.preview or not config.preview.enabled then
		return
	end

	if not buffer_id or not vim.api.nvim_buf_is_valid(buffer_id) then
		return
	end

	local mode = config.preview.mode

	if mode == "float" then
		create_preview_float(buffer_id)
	elseif mode == "current" then
		pcall(vim.api.nvim_set_current_buf, buffer_id)
	elseif mode == "last_window" then
		if state.preview_origin_win and vim.api.nvim_win_is_valid(state.preview_origin_win) then
			local current_win = vim.api.nvim_get_current_win()
			pcall(vim.api.nvim_win_set_buf, state.preview_origin_win, buffer_id)
			if current_win ~= state.preview_origin_win then
				pcall(vim.api.nvim_set_current_win, current_win)
			end
		end
	end
end

---Show the buffer sticks floating window
---Creates the window and renders the current buffer state
function M.show()
	vim.schedule(function()
		if not state.visible then
			return
		end
		create_or_update_floating_window()
		render_buffers()
		state.auto_hidden = false -- Reset auto-hide state when manually shown
	end)
	state.visible = true
end

---Hide the buffer sticks floating window
---Closes the window in all tabs and updates the visibility state
function M.hide()
	-- Set state first to prevent autocmds from re-showing
	state.visible = false
	state.auto_hidden = false -- Reset auto-hide state when manually hidden

	-- Close windows in all tabs
	for tab, win in pairs(state.wins) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	state.wins = {}
end

---Enter list mode to navigate or close buffers by typing characters
---@param opts? {action?: "open"|"close"|fun(buffer: BufferInfo, leave: function)} Options for list mode
function M.list(opts)
	opts = opts or {}
	local action = opts.action or "open"

	if not state.visible then
		M.show()
	end

	state.list_mode = true
	state.list_input = ""
	state.list_action = action
	state.list_mode_selected_index = nil
	state.preview_origin_win = vim.api.nvim_get_current_win()
	state.preview_origin_buf = vim.api.nvim_get_current_buf()

	-- Always start at the currently active buffer
	local current_buf = vim.api.nvim_get_current_buf()
	local buffers = get_buffer_list()
	for idx, buffer in ipairs(buffers) do
		if buffer.id == current_buf then
			state.list_mode_selected_index = idx
			state.last_selected_buffer_id = current_buf
			break
		end
	end

	-- Refresh display to show characters (resize window for list mode content)
	create_or_update_floating_window()
	render_buffers()

	if state.list_mode_selected_index then
		update_preview(buffers[state.list_mode_selected_index].id)
	end

	-- Helper to update display with window resize and redraw
	local function update_display()
		create_or_update_floating_window()
		render_buffers()
		vim.cmd("redraw")
	end

	-- Helper to exit list mode
	---@param restore_original? boolean Whether to restore original buffer (true when canceling, false when confirming)
	local function leave(restore_original)
		state.list_mode = false
		state.list_input = ""
		state.list_mode_selected_index = nil
		state.filter_mode = false
		state.filter_input = ""
		state.filter_selected_index = 1
		cleanup_preview(restore_original)
		create_or_update_floating_window() -- Resize back to normal mode
		render_buffers()
	end

	-- Start input loop
	local function handle_input()
		local char = vim.fn.getchar()
		local char_str

		if type(char) == "number" then
			char_str = vim.fn.nr2char(char)
		elseif type(char) == "string" then
			char_str = char
		else
			char_str = ""
		end

		-- Handle escape or ctrl-c to exit list mode (or filter mode)
		if char == 27 or (type(char_str) == "string" and (char_str == "\x03" or char_str == "\27")) then
			if state.filter_mode then
				-- Exit filter mode back to list mode (preserve list mode selection)
				state.filter_mode = false
				state.filter_input = ""
				state.filter_selected_index = 1
				update_display()
				vim.schedule(handle_input)
			elseif state.list_mode_selected_index ~= nil then
				-- Clear list mode selection (first ESC) - cleanup preview
				if config.preview and config.preview.enabled then
					if config.preview.mode == "current" then
						if state.preview_origin_buf and vim.api.nvim_buf_is_valid(state.preview_origin_buf) then
							pcall(vim.api.nvim_set_current_buf, state.preview_origin_buf)
						end
					elseif config.preview.mode == "float" then
						if state.preview_float_win and vim.api.nvim_win_is_valid(state.preview_float_win) then
							pcall(vim.api.nvim_win_close, state.preview_float_win, true)
						end
						state.preview_float_win = nil
					elseif config.preview.mode == "last_window" then
						if state.preview_origin_win and vim.api.nvim_win_is_valid(state.preview_origin_win) then
							if state.preview_origin_buf and vim.api.nvim_buf_is_valid(state.preview_origin_buf) then
								pcall(vim.api.nvim_win_set_buf, state.preview_origin_win, state.preview_origin_buf)
							end
						end
					end
				end
				state.list_mode_selected_index = nil
				state.last_selected_buffer_id = nil
				update_display()
				vim.schedule(handle_input)
			else
				-- Exit list mode entirely (second ESC)
				leave(true)
			end
			return
		end

		-- If in filter mode, handle filter-specific input
		if state.filter_mode then
			local filter_keys = config.list and config.list.filter and config.list.filter.keys or {}

			-- Handle up arrow (check for both escape sequence and Vim's key notation)
			if filter_keys.move_up then
				local should_move_up = false

				if filter_keys.move_up == "<Up>" then
					should_move_up = type(char_str) == "string"
						and (char_str == "\x1b[A" or char_str == "<80>ku" or char_str:match("ku$"))
				else
					should_move_up = char_str == filter_keys.move_up
				end
				if should_move_up then
					local buffers = get_buffer_list()
					local display_paths = get_display_paths(buffers)
					local filtered_indices = apply_fuzzy_filter(buffers, display_paths)
					local num_results = #filtered_indices

					if num_results > 0 then
						state.filter_selected_index = state.filter_selected_index - 1
						if state.filter_selected_index < 1 then
							state.filter_selected_index = num_results
						end
						local selected_buffer = buffers[filtered_indices[state.filter_selected_index]]
						if selected_buffer then
							update_preview(selected_buffer.id)
						end
						update_display()
					end
					vim.schedule(handle_input)
					return
				end
			end

			-- Handle down arrow (check for both escape sequence and Vim's key notation)

			if filter_keys.move_down then
				local should_move_down = false

				if filter_keys.move_down == "<Down>" then
					should_move_down = type(char_str) == "string"
						and (char_str == "\x1b[B" or char_str == "<80>kd" or char_str:match("kd$"))
				else
					should_move_down = char_str == filter_keys.move_down
				end

				if should_move_down then
					local buffers = get_buffer_list()
					local display_paths = get_display_paths(buffers)
					local filtered_indices = apply_fuzzy_filter(buffers, display_paths)
					local num_results = #filtered_indices

					if num_results > 0 then
						state.filter_selected_index = state.filter_selected_index + 1
						if state.filter_selected_index > num_results then
							state.filter_selected_index = 1
						end
						local selected_buffer = buffers[filtered_indices[state.filter_selected_index]]
						if selected_buffer then
							update_preview(selected_buffer.id)
						end
						update_display()
					end
					vim.schedule(handle_input)
					return
				end
			end

			-- Handle enter/confirm
			if filter_keys.confirm == "<CR>" and (char == 13 or char == 10) then
				local buffers = get_buffer_list()
				local display_paths = get_display_paths(buffers)
				local filtered_indices = apply_fuzzy_filter(buffers, display_paths)

				if #filtered_indices > 0 then
					local selected_buffer = buffers[filtered_indices[state.filter_selected_index]]
					if selected_buffer then
						if type(state.list_action) == "function" then
							state.list_action(selected_buffer, function()
								leave(false)
							end)
						elseif state.list_action == "open" then
							vim.api.nvim_set_current_buf(selected_buffer.id)
							leave(false)
						elseif state.list_action == "close" then
							vim.api.nvim_buf_delete(selected_buffer.id, { force = false })
							leave(false)
						end
					end
				end
				return
			end

			-- Handle backspace (127, 8 for numeric, "<80>kb" or "�kb" for string representation)
			if char == 127 or char == 8 or char_str == "<80>kb" or char_str:match("kb$") then
				if #state.filter_input > 0 then
					state.filter_input = state.filter_input:sub(1, -2)
					state.filter_selected_index = 1
					local buffers = get_buffer_list()
					local display_paths = get_display_paths(buffers)
					local filtered_indices = apply_fuzzy_filter(buffers, display_paths)
					if #filtered_indices > 0 then
						local selected_buffer = buffers[filtered_indices[state.filter_selected_index]]
						if selected_buffer then
							update_preview(selected_buffer.id)
						end
					end
					update_display()
				end
				vim.schedule(handle_input)
				return
			end

			-- Handle regular character input in filter mode
			if
				type(char_str) == "string"
				and #char_str > 0
				and type(char) == "number"
				and char >= 32
				and char < 127
			then
				if char_str:match("[%w%s%p]") then
					state.filter_input = state.filter_input .. char_str
					state.filter_selected_index = 1
					local buffers = get_buffer_list()
					local display_paths = get_display_paths(buffers)
					local filtered_indices = apply_fuzzy_filter(buffers, display_paths)
					if #filtered_indices > 0 then
						local selected_buffer = buffers[filtered_indices[state.filter_selected_index]]
						if selected_buffer then
							update_preview(selected_buffer.id)
						end
					end
					update_display()
					vim.schedule(handle_input)
					return
				end
			end

			-- Invalid character in filter mode, ignore and continue
			vim.schedule(handle_input)
			return
		end

		-- Handle arrow keys in list mode (non-filter) - check configured keys
		local list_keys = config.list and config.list.keys or {}

		if list_keys.move_up then
			local should_move_up = false

			if list_keys.move_up == "<Up>" then
				-- Special key: check for arrow escape sequences
				should_move_up = type(char_str) == "string"
					and (char_str == "\x1b[A" or char_str == "<80>ku" or char_str:match("ku$"))
			else
				should_move_up = char_str == list_keys.move_up
			end

			if should_move_up then
				local buffers = get_buffer_list()
				if #buffers > 0 then
					if state.list_mode_selected_index == nil then
						-- Find current buffer index
						local current_buf = vim.api.nvim_get_current_buf()
						for idx, buffer in ipairs(buffers) do
							if buffer.id == current_buf then
								state.list_mode_selected_index = idx
								break
							end
						end
						if state.list_mode_selected_index == nil then
							state.list_mode_selected_index = #buffers
						end
					end
					-- Move selection up
					state.list_mode_selected_index = state.list_mode_selected_index == 1 and #buffers
						or state.list_mode_selected_index - 1
					-- Store selected buffer ID for persistence
					state.last_selected_buffer_id = buffers[state.list_mode_selected_index].id
					update_preview(buffers[state.list_mode_selected_index].id)
					update_display()
				end
			end
			vim.schedule(handle_input)
			return
		end

		if list_keys.move_down and char_str == list_keys.move_down then
			local should_move_down = false

			if list_keys.move_up == "Downp>" then
				-- Special key: check for arrow escape sequences
				should_move_down = type(char_str) == "string"
					and (char_str == "\x1b[B" or char_str == "<80>kd" or char_str:match("kd$"))
			else
				should_move_down = char_str == list_keys.move_down
			end

			if should_move_down then
				local buffers = get_buffer_list()
				if #buffers > 0 then
					if state.list_mode_selected_index == nil then
						-- Find current buffer index
						local current_buf = vim.api.nvim_get_current_buf()
						for idx, buffer in ipairs(buffers) do
							if buffer.id == current_buf then
								state.list_mode_selected_index = idx
								break
							end
						end
						if state.list_mode_selected_index == nil then
							state.list_mode_selected_index = 1
						end
					end
					-- Move selection down
					state.list_mode_selected_index = (state.list_mode_selected_index % #buffers) + 1
					-- Store selected buffer ID for persistence
					state.last_selected_buffer_id = buffers[state.list_mode_selected_index].id
					update_preview(buffers[state.list_mode_selected_index].id)
					update_display()
				end
			end
			vim.schedule(handle_input)
			return
		end

		-- Enter key to confirm selection - only when selection is active
		if (char == 13 or char == 10) and state.list_mode_selected_index ~= nil then
			local buffers = get_buffer_list()
			if state.list_mode_selected_index > 0 and state.list_mode_selected_index <= #buffers then
				local selected_buffer = buffers[state.list_mode_selected_index]
				if selected_buffer then
					if type(state.list_action) == "function" then
						state.list_action(selected_buffer, function()
							leave(false)
						end)
					elseif state.list_action == "open" then
						vim.api.nvim_set_current_buf(selected_buffer.id)
						leave(false)
					elseif state.list_action == "close" then
						vim.api.nvim_buf_delete(selected_buffer.id, { force = false })
						leave(false)
					end
				end
			end
			return
		end

		-- Check if user wants to enter filter mode (must come before word character check)
		local filter_keys = config.list and config.list.filter and config.list.filter.keys or {}
		if filter_keys.enter == "/" and type(char_str) == "string" and char_str == "/" then
			state.filter_mode = true
			state.filter_input = ""
			state.filter_selected_index = 1
			-- Preserve list_mode_selected_index so it can be restored when exiting filter mode
			update_display()
			vim.schedule(handle_input)
			return
		end

		-- Handle configured close buffer key (default ctrl-q)
		local list_keys = config.list and config.list.keys or {}

		if list_keys.close_buffer then
			local should_close = false

			if list_keys.close_buffer == "<C-q>" then
				should_close = char == 17
			else
				should_close = char_str == list_keys.close_buffer
			end

			if should_close then
				local current_buf = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_delete(current_buf, { force = false })
				leave(false)
				return
			else
				-- Handle regular character input (original list mode behavior)
				if type(char_str) == "string" and #char_str > 0 and char_str:match("%w") then
					-- Clear selection when typing label characters
					state.list_mode_selected_index = nil
					state.list_input = state.list_input .. char_str:lower()

					-- Find matching buffers
					local buffers = get_buffer_list()
					local matches = {}
					for _, buffer in ipairs(buffers) do
						-- Match against the beginning of the generated label
						local label_prefix = buffer.label:sub(1, #state.list_input)
						if label_prefix == state.list_input then
							table.insert(matches, buffer)
						end
					end

					-- If exactly one match, perform the action
					if #matches == 1 then
						if type(state.list_action) == "function" then
							-- Custom function action
							state.list_action(matches[1], function()
								leave(false)
							end)
						elseif state.list_action == "open" then
							vim.api.nvim_set_current_buf(matches[1].id)
							leave(false)
						elseif state.list_action == "close" then
							vim.api.nvim_buf_delete(matches[1].id, { force = false })
							leave(false)
						end
						return
					elseif #matches == 0 then
						-- No matches, exit list mode
						leave(true)
						return
					end

					-- Multiple matches, continue immediately
					render_buffers()
					vim.schedule(handle_input)
				else
					-- Invalid character, exit list mode
					leave(true)
				end
			end
		end
	end

	-- Start input handling with a small delay
	vim.defer_fn(handle_input, 10)
end

---Alias for list mode with "open" action
function M.jump()
	M.list({ action = "open" })
end

---Alias for list mode with "close" action
function M.close()
	M.list({ action = "close" })
end

---Toggle the visibility of buffer sticks
---Shows if hidden, hides if visible
function M.toggle()
	if state.visible then
		M.hide()
	else
		M.show()
	end
end

---Check if the buffer list is visible
---@return boolean Whether the buffer list is visible
function M.is_visible()
	return state.visible
end

---Setup the buffer sticks plugin with user configuration
---@param opts? BufferSticksConfig User configuration options to override defaults
function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_deep_extend("force", config, opts)

	-- Helper function to set up highlights
	local function setup_highlights()
		-- Check if we should remove background colors (transparent mode only)
		local is_transparent = config.transparent

		if config.highlights.active.link then
			vim.api.nvim_set_hl(0, "BufferSticksActive", { link = config.highlights.active.link })
		else
			local active_hl = vim.deepcopy(config.highlights.active)
			if is_transparent then
				active_hl.bg = nil -- Remove background for transparency
			end
			vim.api.nvim_set_hl(0, "BufferSticksActive", active_hl)
		end

		if config.highlights.alternate.link then
			vim.api.nvim_set_hl(0, "BufferSticksAlternate", { link = config.highlights.alternate.link })
		else
			local alternate_hl = vim.deepcopy(config.highlights.alternate)
			if is_transparent then
				alternate_hl.bg = nil -- Remove background for transparency
			end
			vim.api.nvim_set_hl(0, "BufferSticksAlternate", alternate_hl)
		end

		if config.highlights.inactive.link then
			vim.api.nvim_set_hl(0, "BufferSticksInactive", { link = config.highlights.inactive.link })
		else
			local inactive_hl = vim.deepcopy(config.highlights.inactive)
			if is_transparent then
				inactive_hl.bg = nil -- Remove background for transparency
			end
			vim.api.nvim_set_hl(0, "BufferSticksInactive", inactive_hl)
		end

		if config.highlights.active_modified then
			if config.highlights.active_modified.link then
				vim.api.nvim_set_hl(0, "BufferSticksActiveModified", { link = config.highlights.active_modified.link })
			else
				local active_modified_hl = vim.deepcopy(config.highlights.active_modified)
				if is_transparent then
					active_modified_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksActiveModified", active_modified_hl)
			end
		end

		if config.highlights.alternate_modified then
			if config.highlights.alternate_modified.link then
				vim.api.nvim_set_hl(
					0,
					"BufferSticksAlternateModified",
					{ link = config.highlights.alternate_modified.link }
				)
			else
				local alternate_modified_hl = vim.deepcopy(config.highlights.alternate_modified)
				if is_transparent then
					alternate_modified_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksAlternateModified", alternate_modified_hl)
			end
		end

		if config.highlights.inactive_modified then
			if config.highlights.inactive_modified.link then
				vim.api.nvim_set_hl(
					0,
					"BufferSticksInactiveModified",
					{ link = config.highlights.inactive_modified.link }
				)
			else
				local inactive_modified_hl = vim.deepcopy(config.highlights.inactive_modified)
				if is_transparent then
					inactive_modified_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksInactiveModified", inactive_modified_hl)
			end
		end

		if config.highlights.label then
			if config.highlights.label.link then
				vim.api.nvim_set_hl(0, "BufferSticksLabel", { link = config.highlights.label.link })
			else
				local label_hl = vim.deepcopy(config.highlights.label)
				if is_transparent then
					label_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksLabel", label_hl)
			end
		end

		-- Set up filter_selected highlight
		if config.highlights.filter_selected then
			if config.highlights.filter_selected.link then
				vim.api.nvim_set_hl(0, "BufferSticksFilterSelected", { link = config.highlights.filter_selected.link })
			else
				local filter_selected_hl = vim.deepcopy(config.highlights.filter_selected)
				if is_transparent then
					filter_selected_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksFilterSelected", filter_selected_hl)
			end
		end

		-- Set up filter_title highlight
		if config.highlights.filter_title then
			if config.highlights.filter_title.link then
				vim.api.nvim_set_hl(0, "BufferSticksFilterTitle", { link = config.highlights.filter_title.link })
			else
				local filter_title_hl = vim.deepcopy(config.highlights.filter_title)
				if is_transparent then
					filter_title_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksFilterTitle", filter_title_hl)
			end
		end

		-- Set up list_selected highlight
		if config.highlights.list_selected then
			if config.highlights.list_selected.link then
				vim.api.nvim_set_hl(0, "BufferSticksListSelected", { link = config.highlights.list_selected.link })
			else
				local list_selected_hl = vim.deepcopy(config.highlights.list_selected)
				if is_transparent then
					list_selected_hl.bg = nil -- Remove background for transparency
				end
				vim.api.nvim_set_hl(0, "BufferSticksListSelected", list_selected_hl)
			end
		end

		-- Set up background highlight for non-transparent mode
		if not is_transparent then
			vim.api.nvim_set_hl(0, "BufferSticksBackground", { bg = "#1e1e1e" })
		end
	end

	-- Set up highlights initially
	setup_highlights()

	-- Auto-update on buffer changes and colorscheme changes
	local augroup = vim.api.nvim_create_augroup("BufferSticks", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufDelete", "BufWipeout" }, {
		group = augroup,
		callback = function(args)
			-- Invalidate label cache when buffer list changes
			state.cached_buffer_ids = {}
			state.cached_labels = {}

			-- Clear last selected buffer if it was deleted
			if
				(args.event == "BufDelete" or args.event == "BufWipeout")
				and state.last_selected_buffer_id == args.buf
			then
				state.last_selected_buffer_id = nil
			end

			if state.visible then
				M.show() -- Refresh the display
			end
		end,
	})

	-- Update display when buffer modified status changes
	vim.api.nvim_create_autocmd({ "BufModifiedSet", "TextChanged", "TextChangedI", "BufWritePost" }, {
		group = augroup,
		callback = function()
			vim.schedule(function()
				if state.visible then
					-- Just re-render, don't need to recreate window
					render_buffers()
				end
			end)
		end,
	})

	-- Reapply highlights when colorscheme changes
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = augroup,
		callback = function()
			vim.schedule(setup_highlights)
		end,
	})

	-- Reposition window when terminal is resized
	vim.api.nvim_create_autocmd("VimResized", {
		group = augroup,
		callback = function()
			if state.visible then
				M.show() -- Refresh the display and position
			end
		end,
	})

	-- Show in new tab when entering it
	vim.api.nvim_create_autocmd("TabEnter", {
		group = augroup,
		callback = function()
			if state.visible then
				M.show() -- Recreate window in new tab
			end
		end,
	})

	-- Handle cursor movement for auto-hide behavior
	vim.api.nvim_create_autocmd({
		"CursorMoved",
		"CursorMovedI",
		"CursorHold",
		"CursorHoldI",
		"WinScrolled",
		"ModeChanged",
		"SafeState",
	}, {
		group = augroup,
		callback = function()
			if config.auto_hide then
				handle_cursor_move()
			end
		end,
	})

	-- Store globally for access
	_G.BufferSticks = {
		toggle = M.toggle,
		show = M.show,
		hide = M.hide,
		is_visible = M.is_visible,
		list = M.list,
		jump = M.jump,
		close = M.close,
	}
end

return M
-- vim:noet:ts=4:sts=4:sw=4:
