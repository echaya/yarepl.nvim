local M = {}
local api = vim.api
local fn = vim.fn
local is_win32 = vim.fn.has 'win32' == 1 and true or false

M.formatter = {}
M.commands = {}
M._virt_text_ns_id = nil -- Namespace for virtual text

local default_config = function()
    return {
        buflisted = true,
        scratch = true,
        ft = 'REPL',
        wincmd = 'belowright 15 split',
        metas = {
            aichat = { cmd = 'aichat', formatter = 'bracketed_pasting', source_syntax = 'aichat' },
            radian = { cmd = 'radian', formatter = 'bracketed_pasting_no_final_new_line', source_syntax = 'R' },
            ipython = { cmd = 'ipython', formatter = 'bracketed_pasting', source_syntax = 'ipython' },
            python = { cmd = 'python', formatter = 'trim_empty_lines', source_syntax = 'python' },
            R = { cmd = 'R', formatter = 'trim_empty_lines', source_syntax = 'R' },
            bash = {
                cmd = 'bash',
                formatter = vim.fn.has 'linux' == 1 and 'bracketed_pasting' or 'trim_empty_lines',
                source_syntax = 'bash',
            },
            zsh = { cmd = 'zsh', formatter = 'bracketed_pasting', source_syntax = 'bash' },
        },
        close_on_exit = true,
        scroll_to_bottom_after_sending = true,
        format_repl_buffers_names = true,
        os = {
            windows = {
                send_delayed_cr_after_sending = true,
            },
        },
        virtual_text_when_source_content = {
            enabled_default = false,
            hl_group_default = 'Comment',
        },
    }
end

M._repls = {}
M._bufnrs_to_repls = {}

local function repl_is_valid(repl)
    return repl ~= nil and api.nvim_buf_is_loaded(repl.bufnr)
end

local function repl_cleanup()
    local valid_repl_objects = {}
    local ids_to_remove = {}
    for id, repl_obj in pairs(M._repls) do
        if not repl_is_valid(repl_obj) then
            if repl_obj and repl_obj.bufnr and api.nvim_buf_is_loaded(repl_obj.bufnr) then
                pcall(api.nvim_buf_detach, repl_obj.bufnr)
            end
            table.insert(ids_to_remove, id)
        end
    end
    for _, id in ipairs(ids_to_remove) do
        M._repls[id] = nil
    end

    local temp_valid_repls_seq = {}
    local sorted_valid_ids = {}
    for id, _ in pairs(M._repls) do
        if type(id) == "number" then
            table.insert(sorted_valid_ids, id)
        end
    end
    table.sort(sorted_valid_ids)

    for _, id in ipairs(sorted_valid_ids) do
        table.insert(temp_valid_repls_seq, M._repls[id])
    end
    M._repls = temp_valid_repls_seq


    for bufnr, repl_obj in pairs(M._bufnrs_to_repls) do
        local still_valid = false
        for _, valid_repl in ipairs(M._repls) do
            if valid_repl == repl_obj then
                still_valid = true
                break
            end
        end
        if not still_valid then
            M._bufnrs_to_repls[bufnr] = nil
        end
        if not api.nvim_buf_is_loaded(bufnr) then
            M._bufnrs_to_repls[bufnr] = nil
        end
    end

    if M._config.format_repl_buffers_names then
        for id, repl_obj in ipairs(M._repls) do
            api.nvim_buf_set_name(repl_obj.bufnr, string.format('#%s#temp#%d', repl_obj.name, id))
        end
        for id, repl_obj in ipairs(M._repls) do
            api.nvim_buf_set_name(repl_obj.bufnr, string.format('#%s#%d', repl_obj.name, id))
        end
    end
end


local function focus_repl(repl)
    if not repl_is_valid(repl) then
        vim.notify [[REPL doesn't exist!]]
        return
    end
    local win = fn.bufwinid(repl.bufnr)
    if win ~= -1 then
        api.nvim_set_current_win(win)
    else
        local wincmd = M._config.metas[repl.name].wincmd or M._config.wincmd

        if type(wincmd) == 'function' then
            wincmd(repl.bufnr, repl.name)
        else
            vim.cmd(wincmd)
            api.nvim_set_current_buf(repl.bufnr)
        end
    end
end

local function create_repl(id, repl_name)
    if M._repls[id] and repl_is_valid(M._repls[id]) then
        vim.notify(string.format('REPL %d already exists, no new REPL is created', id))
        return
    end

    if not M._config.metas[repl_name] then
        vim.notify 'No REPL palatte is found'
        return
    end

    local bufnr = api.nvim_create_buf(M._config.buflisted, M._config.scratch)
    vim.bo[bufnr].filetype = M._config.ft

    local cmd
    if type(M._config.metas[repl_name].cmd) == 'function' then
        cmd = M._config.metas[repl_name].cmd()
    else
        cmd = M._config.metas[repl_name].cmd
    end

    local wincmd = M._config.metas[repl_name].wincmd or M._config.wincmd
    if type(wincmd) == 'function' then
        wincmd(bufnr, repl_name)
    else
        vim.cmd(wincmd)
        api.nvim_set_current_buf(bufnr)
    end

    local current_repl_obj_ref = {}

    local opts_for_termopen = {}
    opts_for_termopen.on_exit = function(_, _, _)
        if api.nvim_buf_is_loaded(bufnr) then
            pcall(api.nvim_buf_detach, bufnr)
        end
        if M._config.close_on_exit then
            local bufwinid = fn.bufwinid(bufnr)
            while bufwinid ~= -1 do
                api.nvim_win_close(bufwinid, true)
                bufwinid = fn.bufwinid(bufnr)
            end
            if api.nvim_buf_is_loaded(bufnr) then
                api.nvim_buf_delete(bufnr, { force = true })
            end
        end
        repl_cleanup()
    end

    ---@diagnostic disable-next-line: redefined-local
    local function termopen(cmd_str, term_opts)
        if vim.fn.has 'nvim-0.11' == 1 then
            term_opts.term = true
            return vim.fn.jobstart(cmd_str, term_opts)
        else
            return vim.fn.termopen(cmd_str, term_opts)
        end
    end
    local term_job_id = termopen(cmd, opts_for_termopen)

    M._repls[id] = {
        bufnr = bufnr,
        term = term_job_id,
        name = repl_name,
        pending_virt_text_info = nil
    }
    current_repl_obj_ref.value = M._repls[id]

    local attach_success = pcall(api.nvim_buf_attach, bufnr, false, {
        on_lines = function(_, attached_bufnr, _, _, _, new_lastline, _)
            local current_repl = current_repl_obj_ref.value
            if not current_repl or not current_repl.pending_virt_text_info or not repl_is_valid(current_repl) then
                return
            end
            if attached_bufnr ~= current_repl.bufnr then return end

            local pending_info = current_repl.pending_virt_text_info

            local scan_start_line = math.max(0, new_lastline - 20)
            local lines_in_repl_chunk = api.nvim_buf_get_lines(attached_bufnr, scan_start_line, new_lastline + 1, false)
            local found_cmd_line_0idx_absolute = -1

            for i = #lines_in_repl_chunk, 1, -1 do
                if lines_in_repl_chunk[i]:find(pending_info.command_to_match, 1, true) then
                    found_cmd_line_0idx_absolute = scan_start_line + (i - 1)
                    break
                end
            end

            if found_cmd_line_0idx_absolute ~= -1 then
                current_repl.pending_virt_text_info = nil

                local virt_lines_opts = {
                    virt_lines = {{{pending_info.comment_text, pending_info.hl_group}}},
                    virt_lines_above = false,
                }
                api.nvim_buf_set_extmark(attached_bufnr, M._virt_text_ns_id, found_cmd_line_0idx_absolute, 0, virt_lines_opts)
            end
        end
    })
    if not attach_success then
        vim.notify("YAREPL: Failed to attach 'on_lines' listener to REPL buffer " .. bufnr, vim.log.levels.ERROR)
    end

    if M._config.format_repl_buffers_names then
        api.nvim_buf_set_name(bufnr, string.format('#%s#%d', repl_name, id))
    end
end


local function find_closest_repl_from_id_with_name(id, name)
    local closest_id = nil
    local closest_distance = math.huge
    for repl_idx, repl in ipairs(M._repls) do
        if repl.name == name then
            local distance = math.abs(repl_idx - id)
            if distance < closest_distance then
                closest_id = repl_idx
                closest_distance = distance
            end
            if distance == 0 then
                break
            end
        end
    end
    return closest_id
end

local function repl_swap(id_1, id_2)
    local repl_1 = M._repls[id_1]
    local repl_2 = M._repls[id_2]
    M._repls[id_1] = repl_2
    M._repls[id_2] = repl_1
    repl_cleanup()
end

local function attach_buffer_to_repl(bufnr, repl)
    if not repl_is_valid(repl) then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    if not api.nvim_buf_is_loaded(bufnr) then
        vim.notify [[Invalid buffer!]]
        return
    end
    M._bufnrs_to_repls[bufnr] = repl
end

M.bufnr_is_attached_to_repl = function(bufnr)
    if not repl_is_valid(M._bufnrs_to_repls[bufnr]) then
        return false
    else
        return true
    end
end

function M._get_repl(id, name, bufnr)
    local repl
    if id == nil or id == 0 then
        repl = M._bufnrs_to_repls[bufnr]
        id = 1
        if not repl_is_valid(repl) then
            repl = M._repls[id]
        end
    else
        repl = M._repls[id]
    end

    if name ~= nil and name ~= '' then
        local base_id_for_search = id
        if M._bufnrs_to_repls[bufnr] == repl then
             for idx, r_obj in ipairs(M._repls) do if r_obj == repl then base_id_for_search = idx break end end
        end

        local found_idx_by_name = find_closest_repl_from_id_with_name(base_id_for_search, name)
        if found_idx_by_name then
             repl = M._repls[found_idx_by_name]
        else
             repl = nil
        end
    end

    if not repl_is_valid(repl) then
        return nil
    end

    return repl
end

local function repl_win_scroll_to_bottom(repl) -- Defined as local function
    if not repl_is_valid(repl) then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    local repl_win = fn.bufwinid(repl.bufnr)
    if repl_win ~= -1 then
        local lines = api.nvim_buf_line_count(repl.bufnr)
        api.nvim_win_set_cursor(repl_win, { lines, 0 })
    end
end

local function get_lines(mode)
    local begin_mark = mode == 'operator' and "'[" or "'<"
    local end_mark = mode == 'operator' and "']" or "'>"

    local begin_line = fn.getpos(begin_mark)[2]
    local end_line = fn.getpos(end_mark)[2]
    return api.nvim_buf_get_lines(0, begin_line - 1, end_line, false)
end

local function get_formatter(formatter)
    if type(formatter) == 'string' then
        return M.formatter[formatter] or error('Unknown formatter: ' .. formatter)
    end
    return formatter
end

M.formatter.factory = function(opts)
    if type(opts) ~= 'table' then
        error 'opts must be a table'
    end

    local config = {
        replace_tab_by_space = false,
        number_of_spaces_to_replace_tab = 8,
        when_multi_lines = {
            open_code = '',
            end_code = '\r',
            trim_empty_lines = false,
            remove_leading_spaces = false,
            gsub_pattern = '',
            gsub_repl = '',
        },
        when_single_line = {
            open_code = '',
            end_code = '\r',
            gsub_pattern = '',
            gsub_repl = '',
        },
        os = {
            windows = {
                join_lines_with_cr = true,
            },
        },
    }

    config = vim.tbl_deep_extend('force', config, opts)

    return function(lines)
        if #lines == 1 then
            if config.replace_tab_by_space then
                lines[1] = lines[1]:gsub('\t', string.rep(' ', config.number_of_spaces_to_replace_tab))
            end

            lines[1] = lines[1]:gsub(config.when_single_line.gsub_pattern, config.when_single_line.gsub_repl)
            lines[1] = config.when_single_line.open_code .. lines[1] .. config.when_single_line.end_code
            return lines
        end

        local formatted_lines = {}
        local line = lines[1]

        line = line:gsub(config.when_multi_lines.gsub_pattern, config.when_multi_lines.gsub_repl)
        line = config.when_multi_lines.open_code .. line
        table.insert(formatted_lines, line)

        for i = 2, #lines do
            line = lines[i]
            if config.when_multi_lines.trim_empty_lines and line == '' then
                goto continue
            end
            if config.when_multi_lines.remove_leading_spaces then
                line = line:gsub('^%s+', '')
            end
            if config.replace_tab_by_space then
                line = line:gsub('\t', string.rep(' ', config.number_of_spaces_to_replace_tab))
            end
            line = line:gsub(config.when_multi_lines.gsub_pattern, config.when_multi_lines.gsub_repl)
            table.insert(formatted_lines, line)
            ::continue::
        end

        if config.when_multi_lines.end_code then
            table.insert(formatted_lines, config.when_multi_lines.end_code)
        end

        if is_win32 and config.os.windows.join_lines_with_cr then
            formatted_lines = { table.concat(formatted_lines, '\r') }
        end

        return formatted_lines
    end
end

M.formatter.trim_empty_lines = M.formatter.factory {
    when_multi_lines = {
        trim_empty_lines = true,
    },
}

M.formatter.bracketed_pasting = M.formatter.factory {
    when_multi_lines = {
        open_code = '\27[200~',
        end_code = '\27[201~\r',
    },
}

M.formatter.bracketed_pasting_no_final_new_line = M.formatter.factory {
    when_multi_lines = {
        open_code = '\27[200~',
        end_code = '\27[201~',
    },
}

M._send_strings = function(id, name, bufnr, strings, use_formatter, source_content)
    use_formatter = use_formatter == nil and true or use_formatter
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end

    local repl = M._get_repl(id, name, bufnr)

    if not repl then
        vim.notify [[REPL doesn't exist!]]
        return
    end

    local meta = M._config.metas[repl.name]
    local strings_to_send_to_repl_process = strings

    if source_content then
        local source_syntax_config = meta.source_syntax
        local source_syntax_processor = M.source_syntaxes[source_syntax_config] or source_syntax_config
        local constructed_source_command

        if not source_syntax_processor then
            vim.notify(
                'No source syntax or source function is available for '
                .. repl.name
                .. '. Fallback to send string directly.'
            )
            constructed_source_command = table.concat(strings, '\n')
        else
            local content = table.concat(strings, '\n')
            if type(source_syntax_processor) == 'string' then
                constructed_source_command = M.source_file_with_source_syntax(content, source_syntax_processor)
            elseif type(source_syntax_processor) == 'function' then
                constructed_source_command = source_syntax_processor(content)
            end
        end

        if constructed_source_command and constructed_source_command ~= '' then
            if meta.virtual_text_when_source_content and meta.virtual_text_when_source_content.enabled then
                local command_to_match_in_repl = vim.split(constructed_source_command, '\n')[1]

                local code_part_for_display = "YAREPL"
                if strings and #strings > 0 then
                    for _, line_str in ipairs(strings) do
                        local trimmed_line = vim.fn.trim(line_str)
                        if #trimmed_line > 0 then
                            code_part_for_display = trimmed_line
                            break
                        end
                    end
                end
                local comment_text_for_virt = string.format('%s - %s', os.date '%H:%M:%S', code_part_for_display)

                repl.pending_virt_text_info = {
                    command_to_match = command_to_match_in_repl,
                    comment_text = comment_text_for_virt,
                    hl_group = meta.virtual_text_when_source_content.hl_group
                }
            end
            strings_to_send_to_repl_process = vim.split(constructed_source_command, '\n')
        else
            -- strings_to_send_to_repl_process remains original strings
        end
    end

    if use_formatter then
        strings_to_send_to_repl_process = meta.formatter(strings_to_send_to_repl_process)
    end

    fn.chansend(repl.term, strings_to_send_to_repl_process)

    if is_win32 and M._config.os.windows.send_delayed_cr_after_sending then
        vim.defer_fn(function()
            if repl_is_valid(repl) then
                 fn.chansend(repl.term, '\r')
            end
        end, 100)
    end

    if M._config.scroll_to_bottom_after_sending then
        repl_win_scroll_to_bottom(repl) -- Changed to call local function
    end
end

M._send_operator_internal = function(motion)
    if motion == nil then
        vim.go.operatorfunc = [[v:lua.require'yarepl'._send_operator_internal]]
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

    M._send_strings(id, name, current_bufnr, lines)
end

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

    M._send_strings(id, name, current_bufnr, lines, nil, true)
end

local function run_cmd_with_count(cmd)
    vim.cmd(string.format('%d%s', vim.v.count, cmd))
end

local function partial_cmd_with_count_expr(cmd)
    return ':\21' .. vim.v.count .. cmd
end

local function add_keymap(meta_name)
    if meta_name then
        meta_name = meta_name:gsub('[^%w-_]', '-')
    end
    local suffix = meta_name and ('-' .. meta_name) or ''

    local mode_commands = {
        { 'n', 'REPLStart' }, { 'n', 'REPLFocus' }, { 'n', 'REPLHide' },
        { 'n', 'REPLHideOrFocus' }, { 'n', 'REPLSendLine' }, { 'n', 'REPLSendOperator' },
        { 'v', 'REPLSendVisual' }, { 'n', 'REPLSourceOperator' }, { 'v', 'REPLSourceVisual' },
        { 'n', 'REPLClose' },
    }

    for _, spec in ipairs(mode_commands) do
        api.nvim_set_keymap(spec[1], string.format('<Plug>(%s%s)', spec[2], suffix), '', {
            noremap = true,
            callback = function()
                if meta_name then
                    run_cmd_with_count(spec[2] .. ' ' .. meta_name)
                else
                    run_cmd_with_count(spec[2])
                end
            end,
        })
    end

    api.nvim_set_keymap('n', string.format('<Plug>(%s%s)', 'REPLExec', suffix), '', {
        noremap = true,
        callback = function()
            if meta_name then
                return partial_cmd_with_count_expr('REPLExec $' .. meta_name)
            else
                return partial_cmd_with_count_expr 'REPLExec '
            end
        end,
        expr = true,
    })
end

M.commands.start = function(opts)
    local repl_name = opts.args
    local id_to_use = opts.count == 0 and (#M._repls + 1) or opts.count

    if M._repls[id_to_use] and repl_is_valid(M._repls[id_to_use]) then
         vim.notify(string.format('REPL %d already exists', id_to_use))
         focus_repl(M._repls[id_to_use])
         return
    end

    local current_bufnr = api.nvim_get_current_buf()

    if repl_name == '' then
        local repls_available = {}
        for name_key, _ in pairs(M._config.metas) do table.insert(repls_available, name_key) end
        vim.ui.select(repls_available, { prompt = 'Select REPL: ' }, function(choice)
            if not choice then return end
            repl_name = choice
            create_repl(id_to_use, repl_name)
            if opts.bang and M._repls[id_to_use] then attach_buffer_to_repl(current_bufnr, M._repls[id_to_use]) end
            if M._config.scroll_to_bottom_after_sending and M._repls[id_to_use] then repl_win_scroll_to_bottom(M._repls[id_to_use]) end -- Changed to call local function
        end)
    else
        create_repl(id_to_use, repl_name)
        if opts.bang and M._repls[id_to_use] then attach_buffer_to_repl(current_bufnr, M._repls[id_to_use]) end
        if M._config.scroll_to_bottom_after_sending and M._repls[id_to_use] then repl_win_scroll_to_bottom(M._repls[id_to_use]) end -- Changed to call local function
    end
end

M.commands.cleanup = repl_cleanup

M.commands.focus = function(opts)
    local repl = M._get_repl(opts.count, opts.args, api.nvim_get_current_buf())
    if not repl then vim.notify [[REPL doesn't exist!]]; return end
    focus_repl(repl)
end

M.commands.hide = function(opts)
    local repl = M._get_repl(opts.count, opts.args, api.nvim_get_current_buf())
    if not repl then vim.notify [[REPL doesn't exist!]]; return end
    local bufnr = repl.bufnr
    local win = fn.bufwinid(bufnr)
    while win ~= -1 do
        api.nvim_win_close(win, true)
        win = fn.bufwinid(bufnr)
    end
end

M.commands.hide_or_focus = function(opts)
    local repl = M._get_repl(opts.count, opts.args, api.nvim_get_current_buf())
    if not repl then vim.notify [[REPL doesn't exist!]]; return end
    local win = fn.bufwinid(repl.bufnr)
    if win ~= -1 then
        while win ~= -1 do
            api.nvim_win_close(win, true)
            win = fn.bufwinid(repl.bufnr)
        end
    else
        focus_repl(repl)
    end
end

M.commands.close = function(opts)
    local repl = M._get_repl(opts.count, opts.args, api.nvim_get_current_buf())
    if not repl then vim.notify [[REPL doesn't exist!]]; return end
    if repl_is_valid(repl) then fn.chansend(repl.term, string.char(4)) end
end

M.commands.swap = function(opts)
    local id_1 = tonumber(opts.fargs[1])
    local id_2 = tonumber(opts.fargs[2])
    if id_1 and id_2 then
        if M._repls[id_1] and M._repls[id_2] then
            repl_swap(id_1, id_2)
        else
            vim.notify("One or both REPL IDs are invalid.", vim.log.levels.ERROR)
        end
        return
    end

    local repl_ids_available = {}
    for id_key, _ in ipairs(M._repls) do table.insert(repl_ids_available, id_key) end

    if #repl_ids_available < 2 then
        vim.notify("Not enough REPLs to swap.", vim.log.levels.WARN)
        return
    end

    local format_item = function(item_id) return item_id .. ' ' .. M._repls[item_id].name end
    if not id_1 then
        vim.ui.select(repl_ids_available, { prompt = 'select first REPL', format_item = format_item }, function(id1_choice)
            if not id1_choice then return end
            local remaining_ids = vim.tbl_filter(function(id_val) return id_val ~= id1_choice end, repl_ids_available)
            if #remaining_ids == 0 then vim.notify("No other REPL to swap with.", vim.log.levels.WARN); return end
            vim.ui.select(remaining_ids, { prompt = 'select second REPL', format_item = format_item }, function(id2_choice)
                if not id2_choice then return end
                repl_swap(id1_choice, id2_choice)
            end)
        end)
    elseif not id_2 then
         local remaining_ids = vim.tbl_filter(function(id_val) return id_val ~= id_1 end, repl_ids_available)
         if #remaining_ids == 0 then vim.notify("No other REPL to swap with ID " .. id_1, vim.log.levels.WARN); return end
        vim.ui.select(remaining_ids, { prompt = 'select second REPL', format_item = format_item }, function(id2_choice)
            if not id2_choice then return end
            repl_swap(id_1, id2_choice)
        end)
    end
end

M.commands.attach_buffer = function(opts)
    local current_bufnr = api.nvim_get_current_buf()
    if opts.bang then M._bufnrs_to_repls[current_bufnr] = nil; return end
    local repl_id_arg = opts.count

    local repl_ids_available = {}
    for id_key, repl_obj in ipairs(M._repls) do if repl_is_valid(repl_obj) then table.insert(repl_ids_available, id_key) end end

    if #repl_ids_available == 0 then
        vim.notify("No valid REPLs available to attach.", vim.log.levels.WARN)
        return
    end

    if repl_id_arg == 0 then
        vim.ui.select(repl_ids_available, { prompt = 'Select REPL to attach', format_item = function(item_id) return item_id .. ' ' .. M._repls[item_id].name end }, function(id_choice)
            if not id_choice then return end
            attach_buffer_to_repl(current_bufnr, M._repls[id_choice])
        end)
    else
        if M._repls[repl_id_arg] and repl_is_valid(M._repls[repl_id_arg]) then
            attach_buffer_to_repl(current_bufnr, M._repls[repl_id_arg])
        else
            vim.notify("REPL with ID " .. repl_id_arg .. " not found or is invalid.", vim.log.levels.ERROR)
        end
    end
end

M.commands.detach_buffer = function()
    M._bufnrs_to_repls[api.nvim_get_current_buf()] = nil
end

M.commands.send_visual = function(opts)
    local id = opts.count
    local name = opts.args
    local current_bufnr = api.nvim_get_current_buf()

    api.nvim_feedkeys('\27', 'nx', false)

    local lines = get_lines 'visual'

    if #lines == 0 then
        vim.notify 'No visual range!'
        return
    end

    M._send_strings(id, name, current_bufnr, lines, nil, opts.source_content)
end

M.commands.send_line = function(opts)
    local id = opts.count
    local name = opts.args
    local current_bufnr = api.nvim_get_current_buf()

    local line = api.nvim_get_current_line()

    M._send_strings(id, name, current_bufnr, { line })
end

M.commands.send_operator = function(opts)
    vim.b[0].closest_repl_name = opts.args ~= '' and opts.args or nil
    vim.b[0].repl_id = opts.count ~= 0 and opts.count or nil
    vim.go.operatorfunc = opts.source_content and [[v:lua.require'yarepl'._source_operator_internal]]
        or [[v:lua.require'yarepl'._send_operator_internal]]
    api.nvim_feedkeys('g@', 'ni', false)
end

M.commands.source_visual = function(opts)
    opts.source_content = true
    M.commands.send_visual(opts)
end

M.commands.source_operator = function(opts)
    opts.source_content = true
    M.commands.send_operator(opts)
end

M.commands.exec = function(opts)
    local first_arg = opts.fargs[1]
    local current_bufnr = api.nvim_get_current_buf()
    local name_match = ''
    local command_to_exec = opts.args

    for repl_name_key, _ in pairs(M._config.metas) do
        if '$' .. repl_name_key == first_arg then
            name_match = repl_name_key
            break
        end
    end

    if name_match ~= '' then
        command_to_exec = command_to_exec:gsub('^%$' .. name_match .. '%s+', '')
    end

    local id_arg = opts.count
    local command_list = vim.split(command_to_exec, '\r')
    M._send_strings(id_arg, name_match, current_bufnr, command_list)
end

function M.make_tmp_file(content, keep_file)
    local tmp_file = fn.tempname() .. '_yarepl'
    local f = io.open(tmp_file, 'w+')
    if f == nil then
        vim.notify('Cannot open temporary message file: ' .. tmp_file, vim.log.levels.ERROR)
        return
    end
    f:write(content)
    f:close()
    if not keep_file then
        vim.defer_fn(function() os.remove(tmp_file) end, 5000)
    end
    return tmp_file
end

function M.source_file_with_source_syntax(content, source_syntax, keep_file)
    local tmp_file = M.make_tmp_file(content, keep_file)
    if not tmp_file then return end

    source_syntax = source_syntax:gsub('{{file}}', tmp_file)
    return source_syntax
end

M.source_syntaxes = {}
M.source_syntaxes.python = function(str)
    return M.source_file_with_source_syntax(
        str,
        'exec(compile(open("{{file}}", "r").read(), "{{file}}", "exec"))',
        true
    )
end
M.source_syntaxes.ipython = function(str)
    return M.source_file_with_source_syntax(str, '%run -i "{{file}}"', true)
end
M.source_syntaxes.bash = 'source "{{file}}"'
M.source_syntaxes.R = 'eval(parse(text = readr::read_file("{{file}}")))'
M.source_syntaxes.aichat = '.file "{{file}}"'

M.setup = function(opts)
    M._config = vim.tbl_deep_extend('force', default_config(), opts or {})
    M._virt_text_ns_id = api.nvim_create_namespace('YAREPLVirtText')

    for name_key, meta in pairs(M._config.metas) do
        if not meta then
            M._config.metas[name_key] = nil
        else
            if meta.formatter then
                meta.formatter = get_formatter(meta.formatter)
            end

            meta.virtual_text_when_source_content = meta.virtual_text_when_source_content or {}

            if meta.virtual_text_when_source_content.enabled == nil then
                meta.virtual_text_when_source_content.enabled = M._config.virtual_text_when_source_content.enabled_default
            end
            if meta.virtual_text_when_source_content.hl_group == nil then
                meta.virtual_text_when_source_content.hl_group = M._config.virtual_text_when_source_content.hl_group_default
            end
        end
    end

    add_keymap()
    for meta_name_key, _ in pairs(M._config.metas) do
        add_keymap(meta_name_key)
    end
end

api.nvim_create_user_command('REPLStart', M.commands.start, {
    count = true, bang = true, nargs = '?',
    complete = function() local m = {}; for n, _ in pairs(M._config.metas) do table.insert(m, n) end return m end,
    desc = "Create REPL `i` from the list of available REPLs.",
})
api.nvim_create_user_command('REPLCleanup', M.commands.cleanup, { desc = 'Clean invalid repls, and rearrange the repls order.' })
api.nvim_create_user_command('REPLFocus', M.commands.focus, { count = true, nargs = '?', desc = "Focus on REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLHide', M.commands.hide, { count = true, nargs = '?', desc = "Hide REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLHideOrFocus', M.commands.hide_or_focus, { count = true, nargs = '?', desc = "Hide or focus REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLClose', M.commands.close, { count = true, nargs = '?', desc = "Close REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLSwap', M.commands.swap, { desc = "Swap two REPLs", nargs = '*' })
api.nvim_create_user_command('REPLAttachBufferToREPL', M.commands.attach_buffer, { count = true, bang = true, desc = "Attach current buffer to REPL `i`" })
api.nvim_create_user_command('REPLDetachBufferToREPL', M.commands.detach_buffer, { count = true, desc = "Detach current buffer to any REPL." })
api.nvim_create_user_command('REPLSendVisual', M.commands.send_visual, { count = true, nargs = '?', desc = "Send visual range to REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLSendLine', M.commands.send_line, { count = true, nargs = '?', desc = "Send current line to REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLSendOperator', M.commands.send_operator, { count = true, nargs = '?', desc = "The operator of send text to REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLSourceVisual', M.commands.source_visual, { count = true, nargs = '?', desc = "Source visual range to REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLSourceOperator', M.commands.source_operator, { count = true, nargs = '?', desc = "Source operator range to REPL `i` or the REPL that current buffer is attached to." })
api.nvim_create_user_command('REPLExec', M.commands.exec, { count = true, nargs = '*', desc = "Execute a command in REPL `i` or the REPL that current buffer is attached to." })

return M

