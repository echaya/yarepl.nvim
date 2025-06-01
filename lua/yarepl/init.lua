--[[
This Lua module provides functionality for managing and interacting with
Read-Eval-Print Loops (REPLs) within Neovim. It allows users to start,
focus, hide, close, and send code to various REPLs, with configurable
behavior for different REPL types.
--]]

local M = {} -- Main module table that will be returned.
local api = vim.api -- Neovim API Lua bindings.
local fn = vim.fn -- Neovim built-in functions.
local is_win32 = vim.fn.has 'win32' == 1 and true or false -- Boolean flag indicating if the current OS is Windows.

--- @class YareplFormatter
--- @field factory fun(opts: table):fun(lines: string[]):string[] A function to create custom formatters.
--- @field trim_empty_lines fun(lines: string[]):string[] Formatter to remove empty lines.
--- @field bracketed_pasting fun(lines: string[]):string[] Formatter for bracketed paste mode.
--- @field bracketed_pasting_no_final_new_line fun(lines: string[]):string[] Formatter for bracketed paste mode without a final newline.

--- @type YareplFormatter
-- Public table to store formatter functions.
-- Users can add their own formatters here or use the predefined ones.
M.formatter = {}

--- Public table to store command implementations that can be exposed via `nvim_create_user_command`.
M.commands = {}

--- Namespace ID for virtual text used by this plugin.
-- This is initialized in the `M.setup` function.
M._virt_text_ns_id = nil

--- @class YareplVirtualTextConfig
--- @field enabled? boolean Enable virtual text for this REPL type.
--- @field hl_group? string Highlight group for the virtual text.

--- @class YareplMetaConfig
--- @field cmd string|fun():string The command or function to generate the command to start the REPL.
--- @field formatter string|fun(lines: string[]):string[] The formatter to use for this REPL. Can be a string name (from `M.formatter`) or a function.
--- @field source_syntax string|fun(content: string):string The syntax or function to source a file/content for this REPL.
--- @field wincmd? string|fun(bufnr: number, repl_name: string) Neovim command string (e.g., "belowright 15 split") or a function to open the REPL window.
--- @field virtual_text_when_source_content? YareplVirtualTextConfig Per-REPL override for virtual text settings when sourcing content.

--- @class YareplConfig
--- @field buflisted boolean Whether the REPL buffer should be listed.
--- @field scratch boolean Whether the REPL buffer should be a scratch buffer.
--- @field ft string The filetype to set for the REPL buffer.
--- @field wincmd string Default Neovim command string to open REPL windows.
--- @field metas table<string, YareplMetaConfig> Configuration for specific REPL types (e.g., python, bash).
--- @field close_on_exit boolean If true, closes the REPL window when the underlying process exits.
--- @field scroll_to_bottom_after_sending boolean If true, scrolls the REPL window to the bottom after sending input.
--- @field format_repl_buffers_names boolean If true, formats REPL buffer names like `#repl_name#n`.
--- @field os table OS-specific configurations.
--- @field virtual_text_when_source_content table Global virtual text settings.
--- @field virtual_text_when_source_content.enabled_default boolean Default for enabling virtual text on source.
--- @field virtual_text_when_source_content.hl_group_default string Default highlight group for virtual text.

--- Returns the default configuration for the plugin.
-- This function is called during setup to establish baseline settings,
-- which can then be overridden by user-provided options.
-- @return YareplConfig The default configuration table.
local default_config = function()
    return {
        buflisted = true, -- REPL buffers will appear in the buffer list.
        scratch = true, -- REPL buffers are scratch buffers (not associated with a file, not saved).
        ft = 'REPL', -- Default filetype for REPL buffers.
        wincmd = 'belowright 15 split', -- Default command to open REPL window.
        metas = {
            -- Configuration for 'aichat' REPL
            aichat = { cmd = 'aichat', formatter = 'bracketed_pasting', source_syntax = 'aichat' },
            -- Configuration for 'radian' (R console) REPL
            radian = { cmd = 'radian', formatter = 'bracketed_pasting_no_final_new_line', source_syntax = 'R' },
            -- Configuration for 'ipython' REPL
            ipython = { cmd = 'ipython', formatter = 'bracketed_pasting', source_syntax = 'ipython' },
            -- Configuration for standard 'python' REPL
            python = { cmd = 'python', formatter = 'trim_empty_lines', source_syntax = 'python' },
            -- Configuration for standard 'R' REPL
            R = { cmd = 'R', formatter = 'trim_empty_lines', source_syntax = 'R' },
            -- Configuration for 'bash' REPL.
            -- Uses bracketed paste mode on Linux, trims empty lines otherwise (e.g., macOS older bash).
            bash = {
                cmd = 'bash',
                formatter = vim.fn.has 'linux' == 1 and 'bracketed_pasting' or 'trim_empty_lines',
                source_syntax = 'bash',
            },
            -- Configuration for 'zsh' REPL
            zsh = { cmd = 'zsh', formatter = 'bracketed_pasting', source_syntax = 'bash' }, -- zsh typically supports bash-like sourcing
            -- Example of enabling virtual text for a specific REPL:
            -- mylua = {
            --     cmd = 'lua',
            --     formatter = 'trim_empty_lines',
            --     source_syntax = 'lua',
            --     virtual_text_when_source_content = { -- Per-REPL override for virtual text settings
            --         enabled = true,
            --         hl_group = 'MoreMsg',
            --     }
            -- },
        },
        close_on_exit = true, -- Automatically close REPL window when the REPL process terminates.
        scroll_to_bottom_after_sending = true, -- Scroll to the end of the REPL buffer after sending commands.
        -- Format REPL buffer names as #repl_name#n (e.g., #ipython#1) instead of using terminal defaults
        format_repl_buffers_names = true,
        os = {
            windows = {
                -- On Windows, send a delayed Carriage Return after sending input to help ensure execution.
                send_delayed_cr_after_sending = true,
            },
        },
        virtual_text_when_source_content = {
            enabled_default = false, -- Global default for enabling virtual text when sourcing content.
            hl_group_default = 'Comment', -- Default highlight group for YAREPL virtual text.
        },
    }
end

--- @class YareplInstance
--- @field bufnr number The buffer number of the REPL.
--- @field term number The job ID of the terminal process for the REPL.
--- @field name string The name (type) of the REPL (e.g., "python", "bash").
--- @field pending_virt_text_info? {command_to_match: string, comment_text: string, hl_group: string} Information for displaying virtual text.

--- @type table<number, YareplInstance>
-- Internal table to store active REPL instances, indexed by a sequential ID.
M._repls = {}

--- @type table<number, YareplInstance>
-- Internal table mapping buffer numbers to their corresponding REPL instances.
-- This allows finding the REPL associated with a given buffer (e.g., the current buffer).
M._bufnrs_to_repls = {}

--- Checks if a REPL instance is valid.
-- A REPL is valid if it's not nil and its associated buffer is loaded.
-- @param repl YareplInstance|nil The REPL instance to check.
-- @return boolean True if the REPL is valid, false otherwise.
local function repl_is_valid(repl)
    return repl ~= nil and api.nvim_buf_is_loaded(repl.bufnr)
end

--- Cleans up and reorganizes the internal REPL tracking tables.
-- This function removes invalid REPLs (e.g., whose buffers are no longer loaded),
-- re-indexes the `M._repls` table to ensure sequential IDs without gaps,
-- and updates REPL buffer names if `M._config.format_repl_buffers_names` is true.
local function repl_cleanup()
    local valid_repls = {} -- Stores valid REPL instances to rebuild M._repls.
    local valid_repls_id = {} -- Stores the IDs of valid REPLs.

    -- Collect IDs of all valid REPLs from M._repls.
    for id, repl in pairs(M._repls) do
        if repl_is_valid(repl) then
            table.insert(valid_repls_id, id)
        end
    end

    -- Clean up M._bufnrs_to_repls by removing entries for invalid REPLs or unloaded buffers.
    for bufnr, repl in pairs(M._bufnrs_to_repls) do
        if not repl_is_valid(repl) then
            M._bufnrs_to_repls[bufnr] = nil
        end

        if not api.nvim_buf_is_loaded(bufnr) then
            M._bufnrs_to_repls[bufnr] = nil
        end
    end

    table.sort(valid_repls_id) -- Sort IDs to maintain order.

    -- Rebuild M._repls with only valid REPLs, ensuring sequential indexing.
    for _, id in ipairs(valid_repls_id) do
        table.insert(valid_repls, M._repls[id])
    end
    M._repls = valid_repls

    -- Rename REPL buffers if configured to do so.
    -- This ensures names like #python#1, #python#2, etc., are consistent after cleanup.
    if M._config.format_repl_buffers_names then
        -- First pass: rename with a temporary suffix to avoid name collisions during renaming.
        for id, repl in pairs(M._repls) do
            api.nvim_buf_set_name(repl.bufnr, string.format('#%s#temp#%d', repl.name, id))
        end
        -- Second pass: set the final, correct names.
        for id, repl in pairs(M._repls) do
            api.nvim_buf_set_name(repl.bufnr, string.format('#%s#%d', repl.name, id))
        end
    end
end

--- Focuses on the window associated with the given REPL.
-- If the REPL buffer is already open in a window, it switches to that window.
-- Otherwise, it opens the REPL buffer in a new window according to the configured `wincmd`.
-- @param repl YareplInstance The REPL instance to focus.
local function focus_repl(repl)
    if not repl_is_valid(repl) then
        vim.notify [[REPL doesn't exist!]] -- User notification if REPL is invalid.
        return
    end
    local win = fn.bufwinid(repl.bufnr) -- Get window ID if buffer is already in a window.
    if win ~= -1 then
        api.nvim_set_current_win(win) -- Switch to existing window.
    else
        -- REPL buffer is not in any window, open it.
        local wincmd = M._config.metas[repl.name].wincmd or M._config.wincmd -- Get specific or default window command.

        if type(wincmd) == 'function' then
            wincmd(repl.bufnr, repl.name) -- Execute custom window command function.
        else
            vim.cmd(wincmd) -- Execute standard window command string.
            api.nvim_set_current_buf(repl.bufnr) -- Set the new window's buffer to the REPL buffer.
        end
    end
end

--- Creates a new REPL instance.
-- This involves:
-- 1. Checking if a REPL with the given ID already exists.
-- 2. Validating the REPL name against configured `metas`.
-- 3. Creating a new buffer for the REPL.
-- 4. Setting the filetype for the REPL buffer.
-- 5. Determining the command to start the REPL process.
-- 6. Opening a window for the REPL using the configured `wincmd`.
-- 7. Starting the terminal process using `termopen` (or `jobstart` for nvim-0.11+).
-- 8. Attaching to the REPL buffer to listen for new lines (for virtual text).
-- 9. Storing the new REPL instance in `M._repls`.
-- @param id number The ID to assign to the new REPL.
-- @param repl_name string The name (type) of the REPL to create (e.g., "python").
local function create_repl(id, repl_name)
    if repl_is_valid(M._repls[id]) then
        vim.notify(string.format('REPL %d already exists, no new REPL is created', id))
        return
    end

    if not M._config.metas[repl_name] then
        vim.notify 'No REPL palatte is found' -- "Palette" likely means configuration.
        return
    end

    -- Create a new buffer for the REPL.
    local bufnr = api.nvim_create_buf(M._config.buflisted, M._config.scratch)
    vim.bo[bufnr].filetype = M._config.ft -- Set filetype (e.g., "REPL").

    local cmd -- Command to start the REPL process.

    -- Determine the REPL command (can be a string or a function).
    if type(M._config.metas[repl_name].cmd) == 'function' then
        cmd = M._config.metas[repl_name].cmd()
    else
        cmd = M._config.metas[repl_name].cmd
    end

    -- Determine and execute the window command to display the REPL.
    local wincmd = M._config.metas[repl_name].wincmd or M._config.wincmd
    if type(wincmd) == 'function' then
        wincmd(bufnr, repl_name)
    else
        vim.cmd(wincmd)
        api.nvim_set_current_buf(bufnr)
    end

    local current_repl_obj_ref = {} -- Used to pass the REPL object to the on_lines callback by reference.
    local opts = {} -- Options for termopen/jobstart.
    opts.on_exit = function(_, _, _) -- Callback when the REPL process exits.
        -- Detach buffer if still loaded.
        if api.nvim_buf_is_loaded(bufnr) then
            pcall(api.nvim_buf_detach, bufnr) -- Safely attempt to detach.
        end
        if M._config.close_on_exit then
            -- Close all windows associated with this REPL buffer.
            local bufwinid = fn.bufwinid(bufnr)
            while bufwinid ~= -1 do
                api.nvim_win_close(bufwinid, true) -- Force close window.
                bufwinid = fn.bufwinid(bufnr)
            end
            -- Delete the REPL buffer if it still exists.
            if api.nvim_buf_is_loaded(bufnr) then
                api.nvim_buf_delete(bufnr, { force = true })
            end
        end
        repl_cleanup() -- Perform cleanup after REPL exits.
    end

    -- Shim for termopen/jobstart based on Neovim version.
    -- In Neovim 0.11+, jobstart with opts.term=true is preferred for terminal jobs.
    ---@diagnostic disable-next-line: redefined-local
    local function termopen(cmd_str, term_opts)
        if vim.fn.has 'nvim-0.11' == 1 then
            term_opts.term = true
            return vim.fn.jobstart(cmd_str, term_opts)
        else
            return vim.fn.termopen(cmd_str, term_opts)
        end
    end

    local term = termopen(cmd, opts) -- Start the terminal process.

    -- Attempt to attach an on_lines listener to the REPL buffer.
    -- This is used for features like displaying virtual text.
    local attach_success = pcall(api.nvim_buf_attach, bufnr, false, {
        on_lines = function(_, attached_bufnr, _, _, _, new_lastline, _)
            -- This callback is triggered when lines are added/changed in the REPL buffer.
            -- It's used here to find the echoed command and display virtual text above it.
            local current_repl = current_repl_obj_ref.value
            if not current_repl or not current_repl.pending_virt_text_info or not repl_is_valid(current_repl) then
                return -- No pending virtual text or invalid REPL.
            end
            if attached_bufnr ~= current_repl.bufnr then
                return -- Event is for a different buffer.
            end

            local pending_info = current_repl.pending_virt_text_info

            -- Scan recent lines in the REPL output to find where the command was echoed.
            local scan_start_line = math.max(0, new_lastline - 20) -- Scan last ~20 lines.
            local lines_in_repl_chunk = api.nvim_buf_get_lines(attached_bufnr, scan_start_line, new_lastline + 1, false)
            local found_cmd_line_0idx_absolute = -1

            -- Iterate backwards through the recent lines.
            for i = #lines_in_repl_chunk, 1, -1 do
                if lines_in_repl_chunk[i]:find(pending_info.command_to_match, 1, true) then -- Literal match.
                    found_cmd_line_0idx_absolute = scan_start_line + (i - 1) -- 0-indexed line number.
                    break
                end
            end

            if found_cmd_line_0idx_absolute ~= -1 then
                -- Command found, clear pending info and set virtual text.
                current_repl.pending_virt_text_info = nil

                local virt_lines_opts = {
                    virt_lines = { { { pending_info.comment_text, pending_info.hl_group } } }, -- Virtual text content and highlight.
                    virt_lines_above = false, -- Display virtual text on the same line (can be configured).
                }
                api.nvim_buf_set_extmark(
                    attached_bufnr,
                    M._virt_text_ns_id, -- Use the plugin's namespace for the extmark.
                    found_cmd_line_0idx_absolute,
                    0, -- Column (start of line).
                    virt_lines_opts
                )
            end
        end,
    })
    if not attach_success then
        vim.notify("YAREPL: Failed to attach 'on_lines' listener to REPL buffer " .. bufnr, vim.log.levels.ERROR)
    end

    -- Set formatted buffer name if configured.
    if M._config.format_repl_buffers_names then
        api.nvim_buf_set_name(bufnr, string.format('#%s#%d', repl_name, id))
    end

    -- Store the new REPL instance.
    M._repls[id] = { bufnr = bufnr, term = term, name = repl_name, pending_virt_text_info = nil }
    current_repl_obj_ref.value = M._repls[id] -- Make the REPL object available to the on_lines callback.
end

--- Finds the closest REPL instance with a given name, relative to a starting ID.
-- "Closest" means the REPL whose ID has the smallest absolute difference from the `id` parameter.
-- @param id number The starting ID for the search.
-- @param name string The name of the REPL type to find.
-- @return number|nil The ID of the closest REPL found, or nil if no REPL with that name exists.
local function find_closest_repl_from_id_with_name(id, name)
    local closest_id = nil
    local closest_distance = math.huge -- Initialize with a very large number.
    for repl_id, repl in ipairs(M._repls) do -- Iterate through sequentially indexed REPLs.
        if repl.name == name then
            local distance = math.abs(repl_id - id)
            if distance < closest_distance then
                closest_id = repl_id
                closest_distance = distance
            end
            if distance == 0 then -- Exact match at the starting ID.
                break
            end
        end
    end
    return closest_id
end

--- Swaps two REPL instances in the `M._repls` table by their IDs.
-- After swapping, `repl_cleanup` is called to re-index and rename buffers.
-- @param id_1 number The ID of the first REPL.
-- @param id_2 number The ID of the second REPL.
local function repl_swap(id_1, id_2)
    local repl_1 = M._repls[id_1]
    local repl_2 = M._repls[id_2]
    M._repls[id_1] = repl_2
    M._repls[id_2] = repl_1
    repl_cleanup() -- Re-organize REPLs after swapping.
end

--- Attaches a buffer to a specific REPL instance.
-- This means that commands sent from this buffer (without specifying a REPL ID)
-- will be directed to the attached REPL.
-- @param bufnr number The buffer number to attach.
-- @param repl YareplInstance The REPL instance to attach to.
local function attach_buffer_to_repl(bufnr, repl)
    if not repl_is_valid(repl) then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    if not api.nvim_buf_is_loaded(bufnr) then
        vim.notify [[Invalid buffer!]]
        return
    end
    M._bufnrs_to_repls[bufnr] = repl -- Store the mapping.
end

--- Checks if a given buffer number is currently attached to a valid REPL.
-- @param bufnr number The buffer number to check.
-- @return boolean True if the buffer is attached to a valid REPL, false otherwise.
M.bufnr_is_attached_to_repl = function(bufnr)
    if not repl_is_valid(M._bufnrs_to_repls[bufnr]) then
        return false
    else
        return true
    end
end

--- Retrieves a REPL instance based on ID, name, and current buffer.
-- This function has complex logic to determine the target REPL:
-- 1. If `id` is nil or 0:
--    a. Try to get the REPL attached to the `bufnr`.
--    b. If not attached, or attached REPL is invalid, default to `id = 1` and get `M._repls[1]`.
-- 2. If `id` is provided (and not 0):
--    a. Get `M._repls[id]`.
-- 3. If `name` is provided (and not empty):
--    a. Search for the closest REPL with that `name` relative to the `id` determined above.
--       The "base ID for search" is adjusted if the initially found REPL was from `_bufnrs_to_repls`.
-- @param id number|nil The ID of the REPL. If 0 or nil, infers from context.
-- @param name string|nil The name of the REPL type. If provided, searches for the closest match.
-- @param bufnr number|nil The buffer number, used for finding attached REPLs.
-- @return YareplInstance|nil The resolved REPL object, or nil if not found or invalid.
function M._get_repl(id, name, bufnr)
    local repl
    if id == nil or id == 0 then
        -- No ID or ID 0: try attached REPL for the buffer, or default to REPL #1.
        repl = M._bufnrs_to_repls[bufnr]
        id = 1 -- Default ID if no specific one is requested or found via attachment.
        if not repl_is_valid(repl) then
            repl = M._repls[id]
        end
    else
        -- Specific ID provided.
        repl = M._repls[id]
    end

    if name ~= nil and name ~= '' then
        -- A REPL name is specified; find the closest one of this type.
        local base_id_for_search = id
        -- If the current `repl` was the one attached to `bufnr`,
        -- find its actual index in `M._repls` to use as the search base.
        if M._bufnrs_to_repls[bufnr] == repl then
            for idx, r_obj in ipairs(M._repls) do
                if r_obj == repl then
                    base_id_for_search = idx
                    break
                end
            end
        end

        local found_idx_by_name = find_closest_repl_from_id_with_name(base_id_for_search, name)
        if found_idx_by_name then
            repl = M._repls[found_idx_by_name]
        else
            repl = nil -- No REPL of the given name found.
        end
    end

    if not repl_is_valid(repl) then
        return nil -- Return nil if the ultimately selected REPL is invalid.
    end

    return repl
end

--- Scrolls the window of a given REPL to the bottom.
-- This is typically called after sending input to the REPL.
-- @param repl YareplInstance The REPL instance whose window should be scrolled.
local function repl_win_scroll_to_bottom(repl)
    if not repl_is_valid(repl) then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    local repl_win = fn.bufwinid(repl.bufnr) -- Get the window ID of the REPL buffer.
    if repl_win ~= -1 then
        local lines = api.nvim_buf_line_count(repl.bufnr) -- Get total lines in buffer.
        api.nvim_win_set_cursor(repl_win, { lines, 0 }) -- Set cursor to the last line.
    end
end

--- Gets lines of code from the current buffer based on mode (visual or operator).
-- For visual mode, it uses '< and '> marks.
-- For operator mode, it uses '[ and '] marks.
-- @param mode string Either "operator" or "visual".
-- @return string[] An array of strings, where each string is a line of code.
local function get_lines(mode)
    local begin_mark = mode == 'operator' and "'[" or "'<" -- Start mark depends on mode.
    local end_mark = mode == 'operator' and "']" or "'>" -- End mark depends on mode.

    local begin_line = fn.getpos(begin_mark)[2] -- Get line number of the start mark.
    local end_line = fn.getpos(end_mark)[2] -- Get line number of the end mark.
    return api.nvim_buf_get_lines(0, begin_line - 1, end_line, false) -- Get lines (0-indexed).
end

--- Retrieves a formatter function.
-- The formatter can be specified as a string (name of a formatter in `M.formatter`)
-- or as a direct function.
-- @param formatter string|fun(lines: string[]):string[] The formatter name or function.
-- @return function The resolved formatter function.
-- @throws string Error if a formatter name is provided but not found in `M.formatter`.
local function get_formatter(formatter)
    if type(formatter) == 'string' then
        return M.formatter[formatter] or error('Unknown formatter: ' .. formatter)
    end
    return formatter -- It's already a function.
end

--- A factory function to create custom code formatters.
-- Formatters are functions that take an array of lines and return an array of processed lines
-- to be sent to the REPL.
-- @param opts table Configuration options for the formatter.
-- @param opts.replace_tab_by_space? boolean If true, replace tabs with spaces.
-- @param opts.number_of_spaces_to_replace_tab? number Number of spaces for each tab (default 8).
-- @param opts.when_multi_lines? table Options for multi-line input.
-- @param opts.when_multi_lines.open_code? string Code to prepend to the first line.
-- @param opts.when_multi_lines.end_code? string Code to append after the last line (typically a newline/CR).
-- @param opts.when_multi_lines.trim_empty_lines? boolean If true, remove empty lines.
-- @param opts.when_multi_lines.remove_leading_spaces? boolean If true, remove leading spaces from each line.
-- @param opts.when_multi_lines.gsub_pattern? string Lua pattern for `string.gsub`.
-- @param opts.when_multi_lines.gsub_repl? string Replacement string/function for `string.gsub`.
-- @param opts.when_single_line? table Options for single-line input.
-- @param opts.when_single_line.open_code? string Code to prepend.
-- @param opts.when_single_line.end_code? string Code to append.
-- @param opts.when_single_line.gsub_pattern? string Lua pattern for `string.gsub`.
-- @param opts.when_single_line.gsub_repl? string Replacement string/function for `string.gsub`.
-- @param opts.os? table OS-specific formatting options.
-- @param opts.os.windows? table Windows-specific options.
-- @param opts.os.windows.join_lines_with_cr? boolean If true, join lines with `\r` on Windows.
-- @return function A new formatter function based on the provided options.
function M.formatter.factory(opts)
    if type(opts) ~= 'table' then
        error 'opts must be a table' -- Ensure opts is a table.
    end

    -- Default configuration for a formatter.
    local config = {
        replace_tab_by_space = false,
        number_of_spaces_to_replace_tab = 8,
        when_multi_lines = {
            open_code = '', -- e.g., bracketed paste start sequence
            end_code = '\r', -- e.g., bracketed paste end sequence + carriage return
            trim_empty_lines = false,
            remove_leading_spaces = false,
            gsub_pattern = '', -- Lua pattern for string.gsub
            gsub_repl = '',   -- Replacement for string.gsub
        },
        when_single_line = {
            open_code = '',
            end_code = '\r',
            gsub_pattern = '',
            gsub_repl = '',
        },
        os = {
            windows = {
                join_lines_with_cr = true, -- Helps with some Windows REPLs.
            },
        },
    }

    -- Merge user options into the default config.
    config = vim.tbl_deep_extend('force', config, opts)

    -- Return the actual formatter function.
    return function(lines)
        if #lines == 1 then -- Single-line input processing.
            if config.replace_tab_by_space then
                lines[1] = lines[1]:gsub('\t', string.rep(' ', config.number_of_spaces_to_replace_tab))
            end

            if config.when_single_line.gsub_pattern ~= '' then
                lines[1] = lines[1]:gsub(config.when_single_line.gsub_pattern, config.when_single_line.gsub_repl)
            end

            lines[1] = config.when_single_line.open_code .. lines[1] .. config.when_single_line.end_code
            return lines
        end

        -- Multi-line input processing.
        local formatted_lines = {}
        local line = lines[1] -- First line.

        if config.when_multi_lines.gsub_pattern ~= '' then
           line = line:gsub(config.when_multi_lines.gsub_pattern, config.when_multi_lines.gsub_repl)
        end
        line = config.when_multi_lines.open_code .. line -- Prepend open_code.
        table.insert(formatted_lines, line)

        -- Process intermediate lines.
        for i = 2, #lines do
            line = lines[i]

            if config.when_multi_lines.trim_empty_lines and line == '' then
                goto continue -- Skip empty lines if configured.
            end

            if config.when_multi_lines.remove_leading_spaces then
                line = line:gsub('^%s+', '') -- Remove leading whitespace.
            end

            if config.replace_tab_by_space then
                line = line:gsub('\t', string.rep(' ', config.number_of_spaces_to_replace_tab))
            end

            if config.when_multi_lines.gsub_pattern ~= '' then
                line = line:gsub(config.when_multi_lines.gsub_pattern, config.when_multi_lines.gsub_repl)
            end

            table.insert(formatted_lines, line)

            ::continue:: -- Lua goto label.
        end

        -- Append end_code if it's defined for multi-lines.
        if config.when_multi_lines.end_code then
            table.insert(formatted_lines, config.when_multi_lines.end_code)
        end

        -- On Windows, join lines with `\r` instead of `\n` (which `chansend` uses by default for tables)
        -- to prevent extra blank lines in some REPLs.
        if is_win32 and config.os.windows.join_lines_with_cr then
            formatted_lines = { table.concat(formatted_lines, '\r') }
        end

        return formatted_lines
    end
end

-- Predefined formatter: trims empty lines from multi-line input.
M.formatter.trim_empty_lines = M.formatter.factory {
    when_multi_lines = {
        trim_empty_lines = true,
    },
}

-- Predefined formatter: wraps multi-line input with bracketed paste mode sequences.
-- \27[200~ (ESC[200~) starts bracketed paste, \27[201~ (ESC[201~) ends it.
-- Includes a final carriage return.
M.formatter.bracketed_pasting = M.formatter.factory {
    when_multi_lines = {
        open_code = '\27[200~', -- CSI 200 ~
        end_code = '\27[201~\r', -- CSI 201 ~ followed by CR
    },
}

-- Predefined formatter: bracketed paste mode without the final carriage return after the end sequence.
M.formatter.bracketed_pasting_no_final_new_line = M.formatter.factory {
    when_multi_lines = {
        open_code = '\27[200~', -- CSI 200 ~
        end_code = '\27[201~',   -- CSI 201 ~
    },
}

--- Displays a comment (derived from the source code) as virtual text in the REPL buffer.
-- This function prepares the information for virtual text display. The actual display
-- is handled by the `on_lines` callback in `create_repl` when the REPL output is received.
-- @param repl YareplInstance The REPL object.
-- @param original_strings string[] The original lines of code sent by the user.
-- @param command_to_match string The first line of the command actually sent to the REPL,
-- used to anchor the virtual text in the REPL output.
local function _display_source_comment_virtual_text(repl, original_strings, command_to_match)
    local meta = M._config.metas[repl.name]
    -- Check if virtual text is enabled for this REPL type.
    if meta.virtual_text_when_source_content and meta.virtual_text_when_source_content.enabled then
        local code_part_for_display = 'YAREPL' -- Default display text.
        -- Try to find the first non-empty trimmed line from original_strings for a more specific comment.
        if original_strings and #original_strings > 0 then
            for _, line_str in ipairs(original_strings) do
                local trimmed_line = vim.fn.trim(line_str)
                if #trimmed_line > 0 then
                    code_part_for_display = trimmed_line
                    break
                end
            end
        end
        -- Format the comment with a timestamp.
        local comment_text_for_virt = string.format('%s - %s', os.date '%H:%M:%S', code_part_for_display)

        -- Store information needed by the on_lines callback to display the virtual text.
        repl.pending_virt_text_info = {
            command_to_match = command_to_match, -- String to find in REPL output.
            comment_text = comment_text_for_virt, -- Text to display.
            hl_group = meta.virtual_text_when_source_content.hl_group, -- Highlight group.
        }
    end
end

--- Internal function to send an array of strings to a specified REPL.
-- @param id number|nil Target REPL ID. If nil or 0, determined by `_get_repl`.
-- @param name string|nil Target REPL name/type. Used by `_get_repl`.
-- @param bufnr number|nil Buffer number from which the send is initiated. Used by `_get_repl`.
-- @param strings string[] Array of strings to send to the REPL.
-- @param use_formatter? boolean Whether to apply the configured formatter (default true).
-- @param source_content? boolean If true, treat `strings` as content to be "sourced"
-- (e.g., written to a temp file and executed via a source command).
M._send_strings = function(id, name, bufnr, strings, use_formatter, source_content)
    use_formatter = use_formatter == nil and true or use_formatter -- Default to true.
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf() -- Default to current buffer if not specified.
    end

    local repl = M._get_repl(id, name, bufnr) -- Resolve the target REPL.

    if not repl then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    local meta = M._config.metas[repl.name] -- Get REPL-specific configuration.

    if source_content then
        -- Handle "sourcing" content: transform the input strings into a command that sources them.
        local source_syntax = M.source_syntaxes[meta.source_syntax] or meta.source_syntax

        if not source_syntax then
            vim.notify(
                'No source syntax or source function is available for '
                    .. repl.name
                    .. '. Fallback to send string directly.'
            )
            -- Fallback: do not treat as source content if no source_syntax is defined.
        else
            local content = table.concat(strings, '\n') -- Join lines into a single string.
            local source_command_sent_to_repl -- The actual command to execute the content.

            if type(source_syntax) == 'string' then
                -- `source_syntax` is a template string like "source {{file}}".
                source_command_sent_to_repl = M.source_file_with_source_syntax(content, source_syntax)
            elseif type(source_syntax) == 'function' then
                -- `source_syntax` is a function that generates the command.
                source_command_sent_to_repl = source_syntax(content)
            end

            if source_command_sent_to_repl and source_command_sent_to_repl ~= '' then
                -- If a source command was generated, prepare for virtual text display.
                local command_to_match_in_repl = vim.split(source_command_sent_to_repl, '\n')[1] -- Use first line of command for matching.
                _display_source_comment_virtual_text(repl, strings, command_to_match_in_repl)
                strings = vim.split(source_command_sent_to_repl, '\n') -- The new strings to send are the source command itself.
            end
        end
    end

    -- Apply formatter if enabled.
    if use_formatter then
        strings = meta.formatter(strings)
    end

    fn.chansend(repl.term, strings) -- Send the (possibly formatted) strings to the REPL's terminal channel.

    -- On Windows, a delayed carriage return might be needed for some REPLs to execute the command.
    -- See issues: https://github.com/milanglacier/yarepl.nvim/issues/12
    --             https://github.com/urbainvaes/vim-ripple/issues/12
    if is_win32 and M._config.os.windows.send_delayed_cr_after_sending then
        vim.defer_fn(function()
            if repl_is_valid(repl) then -- Check REPL validity again, as it might have closed.
                fn.chansend(repl.term, '\r') -- Send CR.
            end
        end, 100) -- Delay of 100ms.
    end

    -- Scroll REPL window to bottom if configured.
    if M._config.scroll_to_bottom_after_sending then
        repl_win_scroll_to_bottom(repl)
    end
end

--- Internal function for the "send" operator.
-- This function is set to `vim.go.operatorfunc` to handle operator-pending motions.
-- Implements dot-repeat by re-setting `operatorfunc` if `motion` is nil.
-- @param motion string|nil The motion command (e.g., "j", "ap"). Nil if called for dot-repeat setup.
M._send_operator_internal = function(motion)
    -- Hack to enable dot-repeat: if motion is nil, it means we are setting up for dot-repeat.
    -- The actual operation happens when Neovim calls this function again with the motion.
    if motion == nil then
        vim.go.operatorfunc = [[v:lua.require'yarepl'._send_operator_internal]] -- Set for next g@ invocation.
        api.nvim_feedkeys('g@', 'ni', false) -- Trigger operator pending mode.
        return
    end

    -- Retrieve REPL ID and name from buffer-local variables (set by the command).
    local id = vim.b[0].repl_id
    local name = vim.b[0].closest_repl_name
    local current_bufnr = api.nvim_get_current_buf()

    local lines = get_lines 'operator' -- Get lines based on the operator motion.

    if #lines == 0 then
        vim.notify 'No motion!' -- Or no text selected by motion.
        return
    end

    M._send_strings(id, name, current_bufnr, lines) -- Send the extracted lines.
end

--- Internal function for the "source" operator.
-- Similar to `_send_operator_internal` but sets `source_content = true` when calling `_send_strings`.
-- @param motion string|nil The motion command. Nil for dot-repeat setup.
M._source_operator_internal = function(motion)
    if motion == nil then
        vim.go.operatorfunc = [[v:lua.require'yarepl'._source_operator_internal]]
        api.nvim_feedkeys('g@', 'ni', false)
        return
    end

    local id = vim.b[0].repl_id
    local name = vim.b[0].closest_repl_name
    local current_bufnr = api.nvim_get_current_buf()

    local lines = get_lines 'operator'

    if #lines == 0 then
        vim.notify 'No motion!'
        return
    end

    M._send_strings(id, name, current_bufnr, lines, nil, true) -- `source_content` is true.
end

--- Helper function to run a command with the current `vim.v.count`.
-- @param cmd string The base command string (e.g., "REPLStart").
local function run_cmd_with_count(cmd)
    vim.cmd(string.format('%d%s', vim.v.count, cmd)) -- Prepends count to the command.
end

--- Helper function to create a command-line mode expression string that includes `vim.v.count`.
-- Used for keymaps that need to pass a count to an Ex command.
-- `<C-U>` (\21) clears any automatically inserted range like `:'<,'>`.
-- @param cmd string The base command string (e.g., "REPLExec ").
-- @return string The command string suitable for an `expr` mapping.
local function partial_cmd_with_count_expr(cmd)
    return ':\21' .. vim.v.count .. cmd
end

--- Adds keymaps for REPL commands.
-- Creates `<Plug>` mappings for various REPL operations.
-- If `meta_name` is provided, it creates specific mappings for that REPL type (e.g., `<Plug>(REPLStart-python)`).
-- Otherwise, it creates generic mappings (e.g., `<Plug>(REPLStart)`).
-- @param meta_name string|nil The name of the REPL meta configuration (e.g., "python").
local function add_keymap(meta_name)
    -- Sanitize meta_name for use in <Plug> mapping names.
    if meta_name then
        meta_name = meta_name:gsub('[^%w-_]', '-') -- Replace non-alphanumeric/hyphen/underscore with hyphen.
    end

    local suffix = meta_name and ('-' .. meta_name) or '' -- e.g., "-python" or ""

    -- List of commands and their default modes for <Plug> mappings.
    local mode_commands = {
        { 'n', 'REPLStart' },
        { 'n', 'REPLFocus' },
        { 'n', 'REPLHide' },
        { 'n', 'REPLHideOrFocus' },
        { 'n', 'REPLSendLine' },
        { 'n', 'REPLSendOperator' }, -- This will trigger operator pending mode
        { 'v', 'REPLSendVisual' },
        { 'n', 'REPLSourceOperator' }, -- This will trigger operator pending mode
        { 'v', 'REPLSourceVisual' },
        { 'n', 'REPLClose' },
    }

    for _, spec in ipairs(mode_commands) do
        api.nvim_set_keymap(spec[1], string.format('<Plug>(%s%s)', spec[2], suffix), '', {
            noremap = true,
            callback = function()
                -- The callback executes the corresponding Ex command, passing the meta_name if present.
                if meta_name then
                    run_cmd_with_count(spec[2] .. ' ' .. meta_name)
                else
                    run_cmd_with_count(spec[2])
                end
            end,
        })
    end

    -- Special handling for REPLExec keymap as it takes further input on the command line.
    api.nvim_set_keymap('n', string.format('<Plug>(%s%s)', 'REPLExec', suffix), '', {
        noremap = true,
        callback = function()
            -- This callback returns a string that is executed as a command-line command.
            if meta_name then
                return partial_cmd_with_count_expr('REPLExec $' .. meta_name .. ' ') -- Note the trailing space for user input.
            else
                return partial_cmd_with_count_expr 'REPLExec ' -- Note the trailing space.
            end
        end,
        expr = true, -- The callback returns an expression to be executed.
    })
end

--- Command implementation for starting a REPL.
-- `:REPLStart[!] [count] [repl_name]`
-- `[count]` specifies the REPL ID. If 0 or not given, uses next available ID.
-- `[repl_name]` specifies the type of REPL. If empty, prompts user to select.
-- `!` (bang) attaches the current buffer to the newly created REPL.
-- @param opts table Command arguments provided by `nvim_create_user_command`.
-- @param opts.args string The REPL name argument.
-- @param opts.count number The count provided to the command (REPL ID).
-- @param opts.bang boolean True if `!` was used.
M.commands.start = function(opts)
    local repl_name = opts.args
    -- If count is 0 (no explicit count given) or not provided, use it to mean "next available ID".
    -- Otherwise, `opts.count` is the desired REPL ID.
    local id = opts.count == 0 and (#M._repls + 1) or opts.count
    local repl = M._repls[id] -- Check if a REPL with this ID already exists.
    local current_bufnr = api.nvim_get_current_buf()

    if repl_is_valid(repl) then
        vim.notify(string.format('REPL %d already exists', id))
        focus_repl(repl) -- Focus existing REPL if it's already there.
        return
    end

    if repl_name == '' then -- No REPL name provided, prompt the user.
        local repls = {} -- Collect available REPL types from config.
        for name, _ in pairs(M._config.metas) do
            table.insert(repls, name)
        end

        vim.ui.select(repls, { -- Use Neovim's UI select for choice.
            prompt = 'Select REPL: ',
        }, function(choice)
            if not choice then return end -- User cancelled.

            repl_name = choice
            create_repl(id, repl_name) -- Create the selected REPL.

            if opts.bang then -- If `!` was used, attach current buffer.
                attach_buffer_to_repl(current_bufnr, M._repls[id])
            end

            if M._config.scroll_to_bottom_after_sending then
                repl_win_scroll_to_bottom(M._repls[id])
            end
        end)
    else
        -- REPL name was provided directly.
        create_repl(id, repl_name)

        if opts.bang then
            attach_buffer_to_repl(current_bufnr, M._repls[id])
        end

        if M._config.scroll_to_bottom_after_sending then
            repl_win_scroll_to_bottom(M._repls[id])
        end
    end
end

--- Command implementation for cleaning up REPLs.
-- Calls `repl_cleanup()`.
M.commands.cleanup = repl_cleanup

--- Command implementation for focusing a REPL.
-- `:[count]REPLFocus [repl_name]`
-- Uses `_get_repl` to determine the target REPL based on count, name, and current buffer's attached REPL.
-- @param opts table Command arguments.
M.commands.focus = function(opts)
    local id = opts.count
    local name = opts.args
    local current_buffer = api.nvim_get_current_buf()

    local repl = M._get_repl(id, name, current_buffer)

    if not repl then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    focus_repl(repl) -- Focus the resolved REPL.
end

--- Command implementation for hiding a REPL.
-- `:[count]REPLHide [repl_name]`
-- Closes all windows associated with the target REPL buffer.
-- @param opts table Command arguments.
M.commands.hide = function(opts)
    local id = opts.count
    local name = opts.args
    local current_buffer = api.nvim_get_current_buf()

    local repl = M._get_repl(id, name, current_buffer)

    if not repl then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    local bufnr = repl.bufnr
    local win = fn.bufwinid(bufnr)
    -- Loop as long as the buffer is found in any window.
    while win ~= -1 do
        api.nvim_win_close(win, true) -- Force close the window.
        win = fn.bufwinid(bufnr) -- Check again if other windows display this buffer.
    end
end

--- Command implementation for hiding or focusing a REPL.
-- `:[count]REPLHideOrFocus [repl_name]`
-- If the REPL is visible, it's hidden. If it's hidden, it's focused.
-- @param opts table Command arguments.
M.commands.hide_or_focus = function(opts)
    local id = opts.count
    local name = opts.args
    local current_buffer = api.nvim_get_current_buf()

    local repl = M._get_repl(id, name, current_buffer)

    if not repl then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    local bufnr = repl.bufnr
    local win = fn.bufwinid(bufnr)
    if win ~= -1 then -- REPL is currently visible in a window.
        -- Hide it by closing all associated windows.
        while win ~= -1 do
            api.nvim_win_close(win, true)
            win = fn.bufwinid(bufnr)
        end
    else
        -- REPL is not visible, so focus it.
        focus_repl(repl)
    end
end

--- Command implementation for closing a REPL.
-- `:[count]REPLClose [repl_name]`
-- Sends an EOF character (Ctrl-D, ASCII 4) to the REPL's terminal,
-- which usually causes the REPL process to exit.
-- The `on_exit` callback in `create_repl` handles buffer/window cleanup.
-- @param opts table Command arguments.
M.commands.close = function(opts)
    local id = opts.count
    local name = opts.args
    local current_buffer = api.nvim_get_current_buf()

    local repl = M._get_repl(id, name, current_buffer)

    if not repl then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    fn.chansend(repl.term, string.char(4)) -- Send EOT (End of Transmission).
end

--- Command implementation for swapping two REPLs.
-- `:REPLSwap [id1] [id2]`
-- If IDs are not provided, prompts the user to select them.
-- @param opts table Command arguments.
-- @param opts.fargs string[] Array of arguments passed to the command (id1, id2).
M.commands.swap = function(opts)
    local id_1 = tonumber(opts.fargs[1]) -- First argument as first REPL ID.
    local id_2 = tonumber(opts.fargs[2]) -- Second argument as second REPL ID.

    if id_1 ~= nil and id_2 ~= nil then
        repl_swap(id_1, id_2) -- Both IDs provided, perform swap.
        return
    end

    -- One or both IDs are missing, prompt user.
    local repl_ids = {} -- Collect IDs of all active REPLs.
    for id, _ in pairs(M._repls) do
        table.insert(repl_ids, id)
    end
    table.sort(repl_ids) -- Sort for consistent display.

    if #repl_ids < 2 and (id_1 == nil or id_2 == nil) then
        vim.notify 'Not enough REPLs to swap.'
        return
    end

    if id_1 == nil then -- First ID is missing.
        vim.ui.select(repl_ids, {
            prompt = 'select first REPL',
            format_item = function(item) return item .. ' ' .. M._repls[item].name end,
        }, function(selected_id1)
            if not selected_id1 then return end
            -- Now prompt for the second ID.
            vim.ui.select(repl_ids, {
                prompt = 'select second REPL',
                format_item = function(item) return item .. ' ' .. M._repls[item].name end,
            }, function(selected_id2)
                if not selected_id2 then return end
                repl_swap(selected_id1, selected_id2)
            end)
        end)
    elseif id_2 == nil then -- First ID provided, second is missing.
        vim.ui.select(repl_ids, {
            prompt = 'select second REPL',
            format_item = function(item) return item .. ' ' .. M._repls[item].name end,
        }, function(selected_id2)
            if not selected_id2 then return end
            repl_swap(id_1, selected_id2)
        end)
    end
end

--- Command implementation for attaching the current buffer to a REPL.
-- `:[count]REPLAttachBufferToREPL[!])`
-- `[count]` specifies the REPL ID to attach to. If 0 or not given, prompts user.
-- `!` (bang) detaches the current buffer from any REPL.
-- @param opts table Command arguments.
M.commands.attach_buffer = function(opts)
    local current_buffer = api.nvim_get_current_buf()

    if opts.bang then -- `!` means detach.
        M._bufnrs_to_repls[current_buffer] = nil
        vim.notify('Current buffer detached from REPL.')
        return
    end

    local repl_id = opts.count -- Target REPL ID from command count.

    local repl_ids = {} -- Collect IDs of active REPLs.
    for id, _ in pairs(M._repls) do
        table.insert(repl_ids, id)
    end
    table.sort(repl_ids)

    if #repl_ids == 0 then
        vim.notify 'No active REPLs to attach to.'
        return
    end

    if repl_id == 0 then -- No count given, prompt user.
        vim.ui.select(repl_ids, {
            prompt = 'select REPL that you want to attach to',
            format_item = function(item) return item .. ' ' .. M._repls[item].name end,
        }, function(id)
            if not id then return end
            attach_buffer_to_repl(current_buffer, M._repls[id])
            vim.notify(string.format('Buffer attached to REPL %d (%s).', id, M._repls[id].name))
        end)
    else
        -- Count provided, use it as REPL ID.
        if M._repls[repl_id] and repl_is_valid(M._repls[repl_id]) then
            attach_buffer_to_repl(current_buffer, M._repls[repl_id])
            vim.notify(string.format('Buffer attached to REPL %d (%s).', repl_id, M._repls[repl_id].name))
        else
            vim.notify(string.format('REPL %d does not exist or is invalid.', repl_id))
        end
    end
end

--- Command implementation for detaching the current buffer from its REPL.
-- `:REPLDetachBufferToREPL` (Note: command name seems to imply "to" but means "from")
M.commands.detach_buffer = function()
    local current_buffer = api.nvim_get_current_buf()
    if M._bufnrs_to_repls[current_buffer] then
        M._bufnrs_to_repls[current_buffer] = nil
        vim.notify('Current buffer detached from REPL.')
    else
        vim.notify('Current buffer was not attached to any REPL.')
    end
end

--- Command implementation for sending visually selected lines to a REPL.
-- `:[count]REPLSendVisual [repl_name]`
-- Uses `_get_repl` to determine target REPL.
-- `opts.source_content` is internally used by `REPLSourceVisual`.
-- @param opts table Command arguments.
-- @param opts.source_content? boolean Internal flag, true if sourcing.
M.commands.send_visual = function(opts)
    local id = opts.count
    local name = opts.args
    local current_buffer = api.nvim_get_current_buf()

    api.nvim_feedkeys('\27', 'nx', false) -- Send ESC to exit visual mode, so marks '< and '> are set.

    local lines = get_lines 'visual' -- Get lines from the visual selection.

    if #lines == 0 then
        vim.notify 'No visual range!'
        return
    end

    M._send_strings(id, name, current_buffer, lines, nil, opts.source_content)
end

--- Command implementation for sending the current line to a REPL.
-- `:[count]REPLSendLine [repl_name]`
-- @param opts table Command arguments.
M.commands.send_line = function(opts)
    local id = opts.count
    local name = opts.args
    local current_buffer = api.nvim_get_current_buf()

    local line = api.nvim_get_current_line() -- Get the content of the current line.

    M._send_strings(id, name, current_buffer, { line }) -- Send as an array containing one line.
end

--- Command implementation for setting up the "send" operator.
-- `:[count]REPLSendOperator [repl_name]`
-- This command configures `vim.go.operatorfunc` and then triggers operator pending mode (`g@`).
-- The actual sending happens in `_send_operator_internal` after a motion is provided.
-- Stores `repl_id` and `closest_repl_name` in buffer-local variables for the operator function.
-- `opts.source_content` is internally used by `REPLSourceOperator`.
-- @param opts table Command arguments.
-- @param opts.source_content? boolean Internal flag, true if sourcing.
M.commands.send_operator = function(opts)
    local repl_name = opts.args
    local id = opts.count

    -- Store REPL target info in buffer-local variables for the operator function.
    if repl_name ~= '' then
        vim.b[0].closest_repl_name = repl_name
    else
        vim.b[0].closest_repl_name = nil
    end

    if id ~= 0 then
        vim.b[0].repl_id = id
    else
        vim.b[0].repl_id = nil
    end

    -- Set the appropriate Lua function for `operatorfunc`.
    vim.go.operatorfunc = opts.source_content and [[v:lua.require'yarepl'._source_operator_internal]]
        or [[v:lua.require'yarepl'._send_operator_internal]]
    api.nvim_feedkeys('g@', 'ni', false) -- Enter operator pending mode. 'n' no remap, 'i' allow insert mode mappings.
end

--- Command implementation for sourcing visually selected lines to a REPL.
-- `:[count]REPLSourceVisual [repl_name]`
-- Essentially calls `M.commands.send_visual` with `source_content = true`.
-- @param opts table Command arguments.
M.commands.source_visual = function(opts)
    opts.source_content = true -- Mark for sourcing.
    M.commands.send_visual(opts)
end

--- Command implementation for setting up the "source" operator.
-- `:[count]REPLSourceOperator [repl_name]`
-- Calls `M.commands.send_operator` with `source_content = true`.
-- @param opts table Command arguments.
M.commands.source_operator = function(opts)
    opts.source_content = true -- Mark for sourcing.
    M.commands.send_operator(opts)
end

--- Command implementation for executing an arbitrary command string in a REPL.
-- `:[count]REPLExec [$repl_name] <command_string>`
-- If `$repl_name` is given (e.g., `$python`), it targets that specific REPL type.
-- The `<command_string>` can contain `\r` for multiple lines.
-- @param opts table Command arguments.
M.commands.exec = function(opts)
    local first_arg = opts.fargs[1] -- First word after command (could be $repl_name).
    local current_buffer = api.nvim_get_current_buf()
    local name = '' -- Target REPL name.
    local command = opts.args -- The full argument string.

    -- Check if the first argument specifies a REPL type like "$python".
    if first_arg then
        for repl_name_iter, _ in pairs(M._config.metas) do
            if '$' .. repl_name_iter == first_arg then
                name = first_arg:sub(2) -- Extract "python" from "$python".
                break
            end
        end
    end

    if name ~= '' then
        -- If $repl_name was found, remove it from the command string.
        command = command:gsub('^%$' .. name .. '%s+', '')
    end

    local id = opts.count -- Target REPL ID from command count.
    local command_list = vim.split(command, '\r') -- Split command by CR for multi-line exec.

    M._send_strings(id, name, current_buffer, command_list)
end

--- Creates a temporary file with the given content.
-- The file is scheduled for deletion after 5 seconds unless `keep_file` is true.
-- @param content string The content to write to the temporary file.
-- @param keep_file? boolean If true, the temporary file will not be automatically deleted.
-- @return string? The path to the created temporary file, or nil on failure.
function M.make_tmp_file(content, keep_file)
    local tmp_file = os.tmpname() .. '_yarepl' -- Generate a unique temporary filename.

    local f = io.open(tmp_file, 'w+') -- Open for writing (create if not exists, truncate).
    if f == nil then
        -- Error handling: could not open temp file.
        M.notify('Cannot open temporary message file: ' .. tmp_file, 'error', vim.log.levels.ERROR)
        return
    end

    f:write(content) -- Write content.
    f:close() -- Close file.

    if not keep_file then
        -- Schedule deletion of the temp file.
        vim.defer_fn(function()
            os.remove(tmp_file)
        end, 5000) -- 5-second delay.
    end

    return tmp_file
end

--- Creates a temporary file and formats a source command string to execute it.
-- Replaces `{{file}}` placeholder in `source_syntax` with the temp file path.
-- The file is scheduled for deletion after 5 seconds unless `keep_file` is true.
-- @param content string The content to write to the temporary file.
-- @param source_syntax string The command template for sourcing (e.g., "source {{file}}").
-- @param keep_file? boolean If true, the temporary file will not be automatically deleted.
-- @return string? The formatted source command string, or nil on failure to create temp file.
function M.source_file_with_source_syntax(content, source_syntax, keep_file)
    local tmp_file = os.tmpname() .. '_yarepl' -- Generate temp filename.

    local f = io.open(tmp_file, 'w+')
    if f == nil then
        M.notify('Cannot open temporary message file: ' .. tmp_file, 'error', vim.log.levels.ERROR)
        return
    end

    f:write(content)
    f:close()

    if not keep_file then
        vim.defer_fn(function()
            os.remove(tmp_file)
        end, 5000)
    end

    -- Replace the placeholder with the actual temporary file path.
    source_syntax = source_syntax:gsub('{{file}}', tmp_file)

    return source_syntax
end

--- @type table<string, string | fun(str: string): string?>
-- Table storing source syntaxes for different REPL types.
-- Keys are REPL `source_syntax` names (from `metas` config).
-- Values can be:
--   - A string template (e.g., "source {{file}}").
--   - A function that takes the content string and returns the command string.
M.source_syntaxes = {}

-- Specific source syntax for Python.
-- Uses `exec(compile(open(...)))` to execute code from a file.
-- Keeps the temporary file because tools like PDB might need it to show context.
M.source_syntaxes.python = function(str)
    return M.source_file_with_source_syntax(
        str,
        'exec(compile(open("{{file}}", "r").read(), "{{file}}", "exec"))',
        true -- Keep the temporary file.
    )
end

-- Specific source syntax for IPython.
-- Uses `%run -i` to execute a file, inheriting the current IPython environment.
-- Keeps the temporary file.
M.source_syntaxes.ipython = function(str)
    return M.source_file_with_source_syntax(str, '%run -i "{{file}}"', true) -- Keep file.
end

-- Standard source syntaxes for bash, R, and aichat.
M.source_syntaxes.bash = 'source "{{file}}"'
M.source_syntaxes.R = 'eval(parse(text = readr::read_file("{{file}}")))' -- Assumes 'readr' package.
M.source_syntaxes.aichat = '.file "{{file}}"' -- Command for aichat to load a file.

--- Setup function for the YAREPL plugin.
-- Merges user options with defaults, initializes namespaces, processes formatter configurations,
-- sets up virtual text defaults, and creates user commands and keymaps.
-- @param opts? table User-provided configuration options to override defaults.
M.setup = function(opts)
    -- Merge user options with default configuration. 'force' means user options take precedence.
    M._config = vim.tbl_deep_extend('force', default_config(), opts or {})
    M._virt_text_ns_id = api.nvim_create_namespace 'YAREPLVirtText' -- Create namespace for virtual text.

    -- Process `metas` configuration for each REPL type.
    for name, meta in pairs(M._config.metas) do
        if not meta then -- User explicitly disabled a built-in meta by setting it to nil/false.
            M._config.metas[name] = nil
        else
            -- Resolve string formatter names to actual formatter functions.
            if meta.formatter then
                meta.formatter = get_formatter(meta.formatter)
            end

            -- Initialize virtual text settings for this REPL meta, inheriting from global defaults.
            meta.virtual_text_when_source_content = meta.virtual_text_when_source_content or {}

            if meta.virtual_text_when_source_content.enabled == nil then
                meta.virtual_text_when_source_content.enabled =
                    M._config.virtual_text_when_source_content.enabled_default
            end
            if meta.virtual_text_when_source_content.hl_group == nil then
                meta.virtual_text_when_source_content.hl_group =
                    M._config.virtual_text_when_source_content.hl_group_default
            end
            -- Note: `delay_ms` for virtual text seems to be referenced but not defined in default_config or used elsewhere.
            -- if meta.virtual_text_when_source_content.delay_ms == nil then
            -- meta.virtual_text_when_source_content.delay_ms = M._config.virtual_text_when_source_content.delay_ms
            -- end
        end
    end

    add_keymap() -- Add generic <Plug> keymaps.

    -- Add specific <Plug> keymaps for each configured REPL type (e.g., <Plug>(REPLStart-python)).
    for meta_name, _ in pairs(M._config.metas) do
        if M._config.metas[meta_name] then -- Ensure meta wasn't disabled.
             add_keymap(meta_name)
        end
    end
end

-- User command definitions. These expose the plugin's functionality to the user via Ex commands.

--- `:REPLStart[!] [count] [name]` - Create/focus REPL `count` of type `name`. `!` attaches buffer.
api.nvim_create_user_command('REPLStart', M.commands.start, {
    count = true, -- Allows a count to be passed (e.g., `2REPLStart`).
    bang = true, -- Allows `!` (e.g., `REPLStart!`).
    nargs = '?', -- Zero or one argument (the REPL name).
    complete = function() -- Provides completion for the REPL name argument.
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Create REPL `i` from the list of available REPLs. `!` attaches current buffer.",
})

--- `:REPLCleanup` - Clean invalid REPLs and reorder.
api.nvim_create_user_command(
    'REPLCleanup',
    M.commands.cleanup,
    { desc = 'clean invalid repls, and rearrange the repls order.' }
)

--- `:[count]REPLFocus [name]` - Focus REPL `count` of type `name`, or attached REPL.
api.nvim_create_user_command('REPLFocus', M.commands.focus, {
    count = true,
    nargs = '?',
    complete = function() -- Provides completion for the REPL name argument.
        local metas = {}
        for name, _ in pairs(M._config.metas) do
             if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Focus on REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLHide [name]` - Hide REPL `count` of type `name`, or attached REPL.
api.nvim_create_user_command('REPLHide', M.commands.hide, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Hide REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLHideOrFocus [name]` - Toggle hide/focus for REPL `count` of type `name`, or attached REPL.
api.nvim_create_user_command('REPLHideOrFocus', M.commands.hide_or_focus, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Hide or focus REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLClose [name]` - Close REPL `count` of type `name`, or attached REPL.
api.nvim_create_user_command('REPLClose', M.commands.close, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Close REPL `i` or the REPL that current buffer is attached to.",
})

--- `:REPLSwap [id1] [id2]` - Swap two REPLs by their IDs.
api.nvim_create_user_command('REPLSwap', M.commands.swap, {
    desc = "Swap two REPLs",
    nargs = '*', -- Accepts zero, one, or two arguments (the REPL IDs).
    -- TODO: Add completion for REPL IDs if possible.
})

--- `:[count]REPLAttachBufferToREPL[!])` - Attach current buffer to REPL `count`. `!` detaches.
api.nvim_create_user_command('REPLAttachBufferToREPL', M.commands.attach_buffer, {
    count = true,
    bang = true,
    desc = "Attach current buffer to REPL `i`. With `!`, detach from any REPL.",
})

--- `:REPLDetachBufferToREPL` - Detach current buffer from any REPL. (Command name is a bit misleading)
api.nvim_create_user_command('REPLDetachBufferToREPL', M.commands.detach_buffer, {
    -- count = true, -- Original code had count, but M.commands.detach_buffer doesn't use it.
    desc = "Detach current buffer from any REPL.",
})

--- `:[count]REPLSendVisual [name]` - Send visual selection to REPL `count` of type `name`.
api.nvim_create_user_command('REPLSendVisual', M.commands.send_visual, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Send visual range to REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLSendLine [name]` - Send current line to REPL `count` of type `name`.
api.nvim_create_user_command('REPLSendLine', M.commands.send_line, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Send current line to REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLSendOperator [name]` - Operator to send motion text to REPL `count` of type `name`.
api.nvim_create_user_command('REPLSendOperator', M.commands.send_operator, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Operator to send text to REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLSourceVisual [name]` - Source visual selection to REPL `count` of type `name`.
api.nvim_create_user_command('REPLSourceVisual', M.commands.source_visual, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Source visual range to REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLSourceOperator [name]` - Operator to source motion text to REPL `count` of type `name`.
api.nvim_create_user_command('REPLSourceOperator', M.commands.source_operator, {
    count = true,
    nargs = '?',
    complete = function()
        local metas = {}
        for name, _ in pairs(M._config.metas) do
            if M._config.metas[name] then table.insert(metas, name) end
        end
        return metas
    end,
    desc = "Operator to source text to REPL `i` or the REPL that current buffer is attached to.",
})

--- `:[count]REPLExec [$name] <command>` - Execute `<command>` in REPL `count` (optionally of type `name`).
api.nvim_create_user_command('REPLExec', M.commands.exec, {
    count = true,
    nargs = '*', -- Accepts multiple arguments for the command string.
    complete = function(arglead, cmdline, cursorPos) -- Advanced completion.
        -- If arglead starts with '$', complete REPL names.
        if arglead:match '^%$' then
            local metas = {}
            for name, _ in pairs(M._config.metas) do
                if M._config.metas[name] then table.insert(metas, '$' .. name) end
            end
            return vim.tbl_filter(function(meta) return meta:sub(1, #arglead) == arglead end, metas)
        end
        -- Otherwise, no specific completion for arbitrary commands.
        return {}
    end,
    desc = "Execute a command in REPL `i` or the REPL that current buffer is attached to. Prefix with `$name` for specific REPL type.",
})

return M -- Return the main module table.
