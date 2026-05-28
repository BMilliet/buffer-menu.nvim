local M = {}

local defaults = {
    width = 0.86,
    height = 0.72,
    list_width = 0.38,
    min_list_width = 30,
    min_preview_width = 24,
    max_preview_lines = 1000,
    include_special_buffers = true,
}

local config = vim.deepcopy(defaults)
local active = nil
local namespace = vim.api.nvim_create_namespace("buffer_menu")

local function termcode(key)
    return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local keys = {
    esc = termcode("<Esc>"),
    cr = termcode("<CR>"),
    bs = termcode("<BS>"),
    del = termcode("<Del>"),
    c_u = termcode("<C-u>"),
    c_w = termcode("<C-w>"),
}

local function is_valid_win(win)
    return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
    return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function set_buf_option(buf, option, value)
    pcall(vim.api.nvim_set_option_value, option, value, { buf = buf })
end

local function get_buf_option(buf, option, fallback)
    local ok, value = pcall(vim.api.nvim_get_option_value, option, { buf = buf })
    if ok then
        return value
    end

    ok, value = pcall(function()
        return vim.bo[buf][option]
    end)

    if ok then
        return value
    end

    return fallback
end

local function set_win_option(win, option, value)
    pcall(vim.api.nvim_set_option_value, option, value, { win = win })
end

local function setup_highlights()
    local highlights = {
        BufferMenuPrompt = { link = "Question" },
        BufferMenuPromptActive = { link = "IncSearch" },
        BufferMenuCurrent = { link = "Identifier" },
        BufferMenuEmpty = { link = "Comment" },
        BufferMenuMatch = { link = "Search" },
    }

    for group, spec in pairs(highlights) do
        if vim.fn.hlexists(group) == 0 then
            vim.api.nvim_set_hl(0, group, spec)
        end
    end
end

local function truncate_display(text, max_width)
    text = text or ""

    if max_width <= 0 then
        return ""
    end

    if vim.fn.strdisplaywidth(text) <= max_width then
        return text
    end

    if max_width <= 3 then
        return vim.fn.strcharpart(text, 0, max_width)
    end

    local target = max_width - 3
    local truncated = vim.fn.strcharpart(text, 0, target)

    while vim.fn.strdisplaywidth(truncated) > target and vim.fn.strchars(truncated) > 0 do
        truncated = vim.fn.strcharpart(truncated, 0, vim.fn.strchars(truncated) - 1)
    end

    return truncated .. "..."
end

local function truncate_display_for_query(text, max_width, query)
    query = vim.trim((query or ""):lower())

    if query == "" or vim.fn.strdisplaywidth(text) <= max_width then
        return truncate_display(text, max_width)
    end

    local match_start = text:lower():find(query, 1, true)

    if not match_start or match_start == 1 or max_width <= 6 then
        return truncate_display(text, max_width)
    end

    return "..." .. truncate_display(text:sub(match_start), max_width - 3)
end

local function set_lines(buf, lines)
    if not is_valid_buf(buf) then
        return
    end

    set_buf_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    set_buf_option(buf, "modifiable", false)
end

local function relative_name(name)
    if not name or name == "" then
        return "[No Name]"
    end

    return vim.fn.fnamemodify(name, ":~:.")
end

local function close_state(state)
    if not state or state.closing then
        return
    end

    state.closing = true

    if state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    end

    if is_valid_win(state.preview_win) then
        pcall(vim.api.nvim_win_close, state.preview_win, true)
    end

    if is_valid_win(state.list_win) then
        pcall(vim.api.nvim_win_close, state.list_win, true)
    end

    if is_valid_buf(state.preview_buf) then
        pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
    end

    if is_valid_buf(state.list_buf) then
        pcall(vim.api.nvim_buf_delete, state.list_buf, { force = true })
    end

    if active == state then
        active = nil
    end
end

local function current_item(state)
    if not state or not state.filtered then
        return nil
    end

    return state.filtered[state.selected]
end

local function collect_buffers(state)
    local items = {}
    local infos = vim.fn.getbufinfo({ buflisted = 1 })

    for _, info in ipairs(infos) do
        local bufnr = info.bufnr

        if is_valid_buf(bufnr) and bufnr ~= state.list_buf and bufnr ~= state.preview_buf then
            local buftype = get_buf_option(bufnr, "buftype", "")

            if config.include_special_buffers or buftype == "" then
                local name = info.name or ""
                local display = relative_name(name)

                table.insert(items, {
                    bufnr = bufnr,
                    name = name,
                    display = display,
                    modified = info.changed == 1,
                    lastused = info.lastused or 0,
                    filetype = get_buf_option(bufnr, "filetype", ""),
                })
            end
        end
    end

    table.sort(items, function(a, b)
        if a.bufnr == state.origin_buf and b.bufnr ~= state.origin_buf then
            return true
        end

        if b.bufnr == state.origin_buf and a.bufnr ~= state.origin_buf then
            return false
        end

        if a.lastused == b.lastused then
            return a.bufnr < b.bufnr
        end

        return a.lastused > b.lastused
    end)

    return items
end

local function apply_filter(state, reset_selection)
    local query = vim.trim((state.query or ""):lower())
    state.filtered = {}

    for _, item in ipairs(state.items or {}) do
        local haystack = string.format("%d %s %s", item.bufnr, item.display, item.name):lower()

        if query == "" or haystack:find(query, 1, true) then
            table.insert(state.filtered, item)
        end
    end

    if reset_selection then
        state.selected = 1
    end

    if #state.filtered == 0 then
        state.selected = 1
    elseif state.selected > #state.filtered then
        state.selected = #state.filtered
    elseif state.selected < 1 then
        state.selected = 1
    end
end

local function refresh_buffers(state, reset_selection)
    state.items = collect_buffers(state)
    apply_filter(state, reset_selection)
end

local function layout()
    local columns = math.max(1, vim.o.columns)
    local lines = math.max(1, vim.o.lines - vim.o.cmdheight)
    local max_width = math.max(20, columns - 4)
    local max_height = math.max(6, lines - 4)

    local total_width = config.width
    if total_width <= 1 then
        total_width = math.floor(columns * total_width)
    end

    local total_height = config.height
    if total_height <= 1 then
        total_height = math.floor(lines * total_height)
    end

    total_width = math.min(max_width, math.max(20, total_width))
    total_height = math.min(max_height, math.max(6, total_height))

    local list_width = math.floor(total_width * config.list_width)
    list_width = math.max(config.min_list_width, list_width)
    list_width = math.min(list_width, total_width - config.min_preview_width - 1)

    if list_width < 12 then
        list_width = math.max(1, math.floor(total_width * 0.5))
    end

    local preview_width = total_width - list_width - 1
    if preview_width < 1 then
        preview_width = 1
    end

    local row = math.max(0, math.floor((lines - total_height) / 2) - 1)
    local col = math.max(0, math.floor((columns - total_width) / 2))

    return {
        row = row,
        col = col,
        height = total_height,
        list_width = list_width,
        preview_width = preview_width,
    }
end

local function configure_buffer(buf, filetype)
    set_buf_option(buf, "buftype", "nofile")
    set_buf_option(buf, "bufhidden", "wipe")
    set_buf_option(buf, "swapfile", false)
    set_buf_option(buf, "modifiable", false)
    set_buf_option(buf, "filetype", filetype)
end

local function configure_list_window(win)
    set_win_option(win, "cursorline", true)
    set_win_option(win, "number", false)
    set_win_option(win, "relativenumber", false)
    set_win_option(win, "signcolumn", "no")
    set_win_option(win, "wrap", false)
end

local function configure_preview_window(win)
    set_win_option(win, "cursorline", false)
    set_win_option(win, "number", true)
    set_win_option(win, "relativenumber", false)
    set_win_option(win, "signcolumn", "no")
    set_win_option(win, "wrap", false)
end

local function preview_lines(item)
    if not item then
        return { "No buffers" }, ""
    end

    if not is_valid_buf(item.bufnr) then
        return { "Buffer is no longer valid" }, ""
    end

    local max_lines = config.max_preview_lines
    local lines = {}
    local filetype = item.filetype or ""

    if vim.api.nvim_buf_is_loaded(item.bufnr) then
        local line_count = vim.api.nvim_buf_line_count(item.bufnr)
        local end_line = math.min(line_count, max_lines)
        lines = vim.api.nvim_buf_get_lines(item.bufnr, 0, end_line, false)

        if line_count > max_lines then
            table.insert(lines, string.format("... %d more lines", line_count - max_lines))
        end
    elseif item.name ~= "" and vim.fn.filereadable(item.name) == 1 then
        local ok, file_lines = pcall(vim.fn.readfile, item.name, "", max_lines)

        if ok then
            lines = file_lines
        else
            lines = { "Unable to read file" }
        end

        if filetype == "" and vim.filetype and vim.filetype.match then
            local matched = vim.filetype.match({ filename = item.name })
            filetype = matched or ""
        end
    else
        lines = { "Buffer is not loaded" }
    end

    if #lines == 0 then
        lines = { "" }
    end

    return lines, filetype
end

local function render_preview(state)
    if not is_valid_buf(state.preview_buf) then
        return
    end

    local item = current_item(state)
    local lines, filetype = preview_lines(item)

    set_buf_option(state.preview_buf, "filetype", filetype)
    set_lines(state.preview_buf, lines)

    if is_valid_win(state.preview_win) then
        pcall(vim.api.nvim_win_set_cursor, state.preview_win, { 1, 0 })

        local title = " Preview "
        if item then
            title = " " .. truncate_display(vim.fn.fnamemodify(item.display, ":t"), state.layout.preview_width - 4) .. " "
        end

        pcall(vim.api.nvim_win_set_config, state.preview_win, {
            title = title,
            title_pos = "center",
        })
    end
end

local function item_line(state, item)
    local current = item.bufnr == state.origin_buf and ">" or " "
    local modified = item.modified and "+" or " "
    local prefix = string.format("%s %3d %s ", current, item.bufnr, modified)
    local name_width = state.layout.list_width - vim.fn.strdisplaywidth(prefix) - 1

    return prefix .. truncate_display_for_query(item.display, name_width, state.query)
end

local function add_match_highlights(buf, line_index, line, query)
    query = vim.trim((query or ""):lower())

    if query == "" then
        return
    end

    local lower_line = line:lower()
    local start_col = 1

    while true do
        local match_start, match_end = lower_line:find(query, start_col, true)

        if not match_start then
            break
        end

        vim.api.nvim_buf_add_highlight(
            buf,
            namespace,
            "BufferMenuMatch",
            line_index,
            match_start - 1,
            match_end
        )

        start_col = match_end + 1
    end
end

local function render_list(state)
    if not is_valid_buf(state.list_buf) then
        return
    end

    local prompt = "Search: /" .. (state.query or "")
    if state.searching then
        prompt = prompt .. "_"
    end

    local list_height = math.max(1, state.layout.height - 1)
    local visible_items = {}
    local lines = {}

    if #state.filtered == 0 then
        table.insert(lines, "  No buffers")
    else
        state.list_offset = state.list_offset or 1

        if state.selected < state.list_offset then
            state.list_offset = state.selected
        elseif state.selected > state.list_offset + list_height - 1 then
            state.list_offset = state.selected - list_height + 1
        end

        local max_offset = math.max(1, #state.filtered - list_height + 1)
        state.list_offset = math.min(math.max(1, state.list_offset), max_offset)

        local last = math.min(#state.filtered, state.list_offset + list_height - 1)

        for index = state.list_offset, last do
            local item = state.filtered[index]
            local line = item_line(state, item)

            table.insert(lines, line)
            table.insert(visible_items, {
                index = index,
                item = item,
                line = line,
                line_index = #lines - 1,
            })
        end
    end

    while #lines < list_height do
        table.insert(lines, "")
    end

    table.insert(lines, prompt)

    set_lines(state.list_buf, lines)

    vim.api.nvim_buf_clear_namespace(state.list_buf, namespace, 0, -1)

    local prompt_line = #lines - 1

    vim.api.nvim_buf_add_highlight(
        state.list_buf,
        namespace,
        state.searching and "BufferMenuPromptActive" or "BufferMenuPrompt",
        prompt_line,
        0,
        -1
    )

    if #state.filtered == 0 then
        vim.api.nvim_buf_add_highlight(state.list_buf, namespace, "BufferMenuEmpty", 0, 0, -1)
    else
        for _, visible in ipairs(visible_items) do
            if visible.item.bufnr == state.origin_buf then
                vim.api.nvim_buf_add_highlight(
                    state.list_buf,
                    namespace,
                    "BufferMenuCurrent",
                    visible.line_index,
                    0,
                    -1
                )
            end

            add_match_highlights(state.list_buf, visible.line_index, visible.line, state.query)
        end
    end

    if is_valid_win(state.list_win) then
        local cursor_line = prompt_line + 1

        if not state.searching then
            cursor_line = #state.filtered == 0 and 1 or state.selected - state.list_offset + 1
        end

        cursor_line = math.min(cursor_line, #lines)
        pcall(vim.api.nvim_win_set_cursor, state.list_win, { cursor_line, 0 })
    end
end

local function render(state)
    render_list(state)
    render_preview(state)
end

local function move_selection(state, delta)
    if #state.filtered == 0 then
        return
    end

    state.selected = state.selected + delta

    if state.selected < 1 then
        state.selected = 1
    elseif state.selected > #state.filtered then
        state.selected = #state.filtered
    end

    render(state)
end

local function open_selected(state)
    local item = current_item(state)
    if not item or not is_valid_buf(item.bufnr) then
        return
    end

    local bufnr = item.bufnr
    local origin_win = state.origin_win
    close_state(state)

    if is_valid_win(origin_win) then
        vim.api.nvim_set_current_win(origin_win)
    end

    vim.cmd.buffer(bufnr)
end

local function delete_selected(state)
    local item = current_item(state)
    if not item then
        return
    end

    local ok, err = pcall(vim.api.nvim_buf_delete, item.bufnr, { force = false })

    if not ok then
        vim.notify(err, vim.log.levels.WARN, { title = "buffer-menu.nvim" })
        return
    end

    refresh_buffers(state, false)
    render(state)
end

local function redraw_search(state)
    apply_filter(state, true)
    render(state)
    vim.cmd.redraw()
end

local function remove_last_word(text)
    local trimmed = text:gsub("%s+$", "")
    return trimmed:gsub("%S+$", "")
end

local function enter_search(state)
    if state.searching then
        return
    end

    local previous_query = state.query
    state.searching = true
    render(state)
    vim.cmd.redraw()

    while active == state and state.searching do
        local char = vim.fn.getcharstr()

        if char == keys.cr or char == "\r" or char == "\n" then
            break
        elseif char == keys.esc or char == "\027" then
            state.query = previous_query
            break
        elseif char == keys.bs or char == keys.del or char == "\b" or char == "\127" then
            state.query = vim.fn.strcharpart(state.query, 0, math.max(0, vim.fn.strchars(state.query) - 1))
            redraw_search(state)
        elseif char == keys.c_u then
            state.query = ""
            redraw_search(state)
        elseif char == keys.c_w then
            state.query = remove_last_word(state.query)
            redraw_search(state)
        elseif char ~= "" and char:byte(1) ~= 128 then
            local byte = char:byte(1)
            if byte and (byte >= 32 or byte > 127) then
                state.query = state.query .. char
                redraw_search(state)
            end
        end
    end

    if active == state then
        state.searching = false
        apply_filter(state, true)
        render(state)
    end
end

local function set_keymaps(state)
    local opts = { buffer = state.list_buf, nowait = true, silent = true }

    vim.keymap.set("n", "q", function()
        close_state(state)
    end, opts)

    vim.keymap.set("n", "<Esc>", function()
        close_state(state)
    end, opts)

    vim.keymap.set("n", "<CR>", function()
        open_selected(state)
    end, opts)

    vim.keymap.set("n", "j", function()
        move_selection(state, 1)
    end, opts)

    vim.keymap.set("n", "<Down>", function()
        move_selection(state, 1)
    end, opts)

    vim.keymap.set("n", "k", function()
        move_selection(state, -1)
    end, opts)

    vim.keymap.set("n", "<Up>", function()
        move_selection(state, -1)
    end, opts)

    vim.keymap.set("n", "gg", function()
        state.selected = 1
        render(state)
    end, opts)

    vim.keymap.set("n", "G", function()
        state.selected = math.max(1, #state.filtered)
        render(state)
    end, opts)

    vim.keymap.set("n", "/", function()
        enter_search(state)
    end, opts)

    vim.keymap.set("n", "dd", function()
        delete_selected(state)
    end, opts)

    vim.keymap.set("n", "<C-r>", function()
        refresh_buffers(state, false)
        render(state)
    end, opts)
end

local function create_windows(state)
    state.layout = layout()
    state.list_buf = vim.api.nvim_create_buf(false, true)
    state.preview_buf = vim.api.nvim_create_buf(false, true)

    configure_buffer(state.list_buf, "buffer-menu")
    configure_buffer(state.preview_buf, "")

    state.list_win = vim.api.nvim_open_win(state.list_buf, true, {
        relative = "editor",
        row = state.layout.row,
        col = state.layout.col,
        width = state.layout.list_width,
        height = state.layout.height,
        style = "minimal",
        border = "rounded",
        title = " Buffers ",
        title_pos = "center",
    })

    state.preview_win = vim.api.nvim_open_win(state.preview_buf, false, {
        relative = "editor",
        row = state.layout.row,
        col = state.layout.col + state.layout.list_width + 1,
        width = state.layout.preview_width,
        height = state.layout.height,
        style = "minimal",
        border = "rounded",
        title = " Preview ",
        title_pos = "center",
    })

    configure_list_window(state.list_win)
    configure_preview_window(state.preview_win)

    state.augroup = vim.api.nvim_create_augroup("BufferMenu" .. state.list_buf, { clear = true })

    for _, win in ipairs({ state.list_win, state.preview_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group = state.augroup,
            pattern = tostring(win),
            callback = function()
                vim.schedule(function()
                    if active == state and not state.closing then
                        close_state(state)
                    end
                end)
            end,
        })
    end
end

function M.open()
    setup_highlights()

    if active then
        close_state(active)
    end

    local state = {
        origin_win = vim.api.nvim_get_current_win(),
        origin_buf = vim.api.nvim_get_current_buf(),
        query = "",
        searching = false,
        selected = 1,
        items = {},
        filtered = {},
    }

    active = state
    create_windows(state)
    set_keymaps(state)
    refresh_buffers(state, true)
    render(state)
end

function M.close()
    close_state(active)
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", defaults, opts or {})
    setup_highlights()

    if vim.fn.exists(":BufferMenu") == 2 then
        pcall(vim.api.nvim_del_user_command, "BufferMenu")
    end

    vim.api.nvim_create_user_command("BufferMenu", function()
        M.open()
    end, { desc = "Open buffer menu" })
end

return M
