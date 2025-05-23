local M = {}

local Path = require('plenary.path')
local config = require('possession.config')
local utils = require('possession.utils')
local plugins = require('possession.plugins')
local paths = require('possession.paths')

local state = {
    ---@type string?
    session_name = nil,
}

---@return string?
function M.get_session_name()
    return state.session_name
end

setmetatable(M, {
    __index = function(_, k)
        if k == 'session_name' then
            vim.deprecate('session.session_name', 'session.get_session_name()', '', 'possession')
            return M.get_session_name()
        end
    end,
})

---@class possession.SaveOpts
---@field vimscript? string mksession-generated commands, ignore hooks
---@field no_confirm? boolean do not ask when overwriting existing file
---@field callback? function called after saving (as vim.ui.input may be async)
---@field cwd? string force cwd, useful in combination with vimscript

--- Save current session
---@param name string
---@param opts? possession.SaveOpts
function M.save(name, opts)
    opts = vim.tbl_extend('force', {
        vimscript = nil,
        no_confirm = false,
        callback = nil,
        cwd = nil,
    }, opts or {})

    vim.validate {
        name = { name, 'string' },
        vimscript = { opts.vimscript, utils.is_type { 'nil', 'string' } },
        no_confirm = { opts.no_confirm, 'boolean' },
        callback = { opts.callback, utils.is_type { 'function', 'nil' } },
        cwd = { opts.cwd, utils.is_type { 'string', 'nil' } },
    }

    local vimscript
    local user_data
    local plugin_data

    if opts.vimscript then
        vimscript = opts.vimscript
        user_data = {}
        plugin_data = {}
    else
        -- Get user data to store, abort on false/nil
        user_data = config.hooks.before_save(name)
        if not user_data then
            return
        end

        -- Run plugins
        plugin_data = plugins.before_save(name)
        if not plugin_data then
            return
        end

        vim.api.nvim_exec_autocmds('User', { pattern = 'SessionSavePre' })
        vimscript = M.mksession()
    end

    -- Generate data for serialization
    local session_data = {
        name = name,
        vimscript = vimscript,
        cwd = opts.cwd or vim.fn.getcwd(),
        user_data = user_data,
        plugins = plugin_data,
    }

    -- Write to disk
    local path = paths.session(name)
    local short = paths.session_short(name)
    local commit = function(ok)
        utils.clear_prompt()
        if ok then
            vim.fn.mkdir(config.session_dir, 'p')
            path:write(vim.json.encode(session_data), 'w')

            state.session_name = name

            utils.info('Saved session as "%s"', short)
        else
            utils.info('Aborting session save')
        end

        if not opts.vimscript then
            plugins.after_save(name, plugin_data, not ok)
            config.hooks.after_save(name, user_data, not ok)
        end

        if opts.callback then
            opts.callback()
        end
    end

    -- ask for user confirmation if required
    if path:exists() and not opts.no_confirm then
        utils.prompt_yes_no(string.format('Overwrite session "%s"?', name), commit)
    else
        commit(true)
    end
end

--- Rename given session to a new name
---@param old_name string session to be renamed
---@param new_name string new name to use
function M.rename(old_name, new_name)
    vim.validate {
        new_name = { new_name, 'string' },
    }

    local old_path = paths.session(old_name)
    local new_path = paths.session(new_name)
    if not old_path:exists() then
        utils.error('Session "%s" does not exist, no file %s', old_name, paths.session_short(old_name))
        return
    end
    if new_path:exists() then
        utils.error('Session "%s" already exists, delete it first.', paths.session_short(new_name))
        return
    end

    local session_data = vim.json.decode(old_path:read())
    session_data.name = new_name
    new_path:write(vim.json.encode(session_data), 'w')
    vim.fn.delete(old_path:absolute())

    if state.session_name == old_name then
        state.session_name = new_name
    end

    utils.info('Renamed session "%s" to "%s"', old_name, new_name)
end

local function autosave_skip()
    -- Skip scratch buffer e.g. startscreen
    local unscratch_buffers = vim.tbl_filter(function(buf)
        return 'nofile' ~= vim.bo[buf].buftype
    end, vim.api.nvim_list_bufs())
    return not unscratch_buffers or not next(unscratch_buffers)
end

---@return { name: string, variant: 'current'|'cwd'|'tmp' }?
function M.autosave_info()
    if state.session_name then
        if not utils.as_function(config.autosave.current)(state.session_name) then
            return
        end
        return { name = state.session_name, variant = 'current' }
    elseif utils.as_function(config.autosave.cwd)() then
        if autosave_skip() then
            return
        end
        return { name = paths.cwd_session_name(), variant = 'cwd' }
    elseif utils.as_function(config.autosave.tmp)() then
        if autosave_skip() then
            return
        end
        return { name = utils.as_function(config.autosave.tmp_name)(), variant = 'tmp' }
    end
end

function M.autosave(autosave_info)
    local info = autosave_info or M.autosave_info()
    if info then
        utils.debug('Auto-saving %s session "%s"', info.variant, info.name)
        M.save(info.name, { no_confirm = true })
    end
end

--- Save some global options that are modified by mksession scripts to restore them in case of load error
---@return table
local function save_global_options()
    return {
        shortmess = vim.o.shortmess,
        splitbelow = vim.o.splitbelow,
        splitright = vim.o.splitright,
        winminheight = vim.o.winminheight,
        winheight = vim.o.winheight,
        winminwidth = vim.o.winminwidth,
        winwidth = vim.o.winwidth,
        hlsearch = vim.o.hlsearch,
    }
end

local function restore_global_options(options)
    -- luacheck thinks vim.o.? is read-only
    -- luacheck: push ignore 122
    local restore = function()
        for opt, value in pairs(options) do
            vim.o[opt] = value
        end
    end
    -- do not trigger OptionSet
    local eventignore = vim.o.eventignore
    vim.o.eventignore = 'all'
    utils.try(restore, nil, function()
        vim.o.eventignore = eventignore
    end)()
    -- luacheck: pop
end

--- Load session by name (or from raw data)
---@param name_or_data string|table name or raw data that will be saved as the session file in JSON format
---@param opts? { skip_autosave?: boolean }
function M.load(name_or_data, opts)
    opts = opts or { skip_autosave = false }
    vim.validate { name_or_data = { name_or_data, utils.is_type { 'string', 'table' } } }

    -- Load session data
    local session_data
    local path
    if type(name_or_data) == 'string' then
        path = paths.session(name_or_data)
        if not path:exists() then
            utils.error('Cannot load session "%s" - it does not exist', name_or_data)
            return
        end
        session_data = vim.json.decode(path:read())
    else
        session_data = name_or_data
    end

    -- Autosave if not loading the auto-saved session itself
    if not opts.skip_autosave then
        local autosave_info = M.autosave_info()
        if config.autosave.on_load and (autosave_info and session_data.name ~= autosave_info.name) then
            M.autosave(autosave_info)
        end
    end

    -- Run pre-load hook that can pre-process user data, abort if returns falsy value.
    local user_data = config.hooks.before_load(session_data.name, session_data.user_data)
    if not user_data then
        return
    end

    -- Run plugins
    local plugin_data = plugins.before_load(session_data.name, session_data.plugins or {})
    if not plugin_data then
        return
    end

    -- Source the Vimscript generated by mksession
    local restore = utils.bind(restore_global_options, save_global_options())

    local success, res = pcall(function()
        return vim.api.nvim_exec2(session_data.vimscript, { output = true })
    end)

    if not success then
        vim.notify(
            'Error executiong vimscript -- ignored:\n'
                .. res
                .. '\n\nCheck content of the vimscript in the next notification.\n\n',
            vim.log.levels.ERROR
        )
        vim.notify(session_data.vimscript, vim.log.levels.WARN)
    end
    restore()

    state.session_name = session_data.name

    if session_data.name == utils.as_function(config.autosave.tmp_name)() then
        state.session_name = nil
    else
        state.session_name = session_data.name
    end

    plugins.after_load(session_data.name, plugin_data)
    config.hooks.after_load(session_data.name, user_data)

    utils.info('Loaded session "%s"', session_data.name)

    -- update last session by updating modification time of session file (after any autosave)
    if path then
        utils.touch(path:absolute())
    end
end

--- Close currently open session
---@param force? boolean delete unsaved buffers
function M.close(force)
    if not state.session_name then
        return
    end

    utils.delete_all_buffers(force)
    utils.stop_lsp_clients()
    state.session_name = nil
end

---@class possession.DeleteOpts
---@field no_confirm? boolean do not ask when deleting
---@field callback? function called after saving (as vim.ui.input may be async)

--- Delete session by name
---@param name string
---@param opts? possession.DeleteOpts
function M.delete(name, opts)
    opts = vim.tbl_extend('force', {
        no_confirm = false,
        callback = nil,
    }, opts or {})

    vim.validate {
        name = { name, 'string' },
        no_confirm = { opts.no_confirm, 'boolean' },
        callback = { opts.callback, utils.is_type { 'function', 'nil' } },
    }

    local path = paths.session(name)
    local short = paths.session_short(name)

    if not path:exists() then
        utils.warn('Cannot delete session "%s" - it does not exist', path:absolute())
        return
    end

    local commit = function(ok)
        if ok then
            if vim.fn.delete(path:absolute()) ~= 0 then
                utils.error('Failed to delete session: "%s"', short)
            else
                if state.session_name == name then
                    state.session_name = nil
                end
                utils.info('Deleted session "%s"', short)
            end
        else
            utils.info('Aborting session delete')
        end

        if opts.callback then
            opts.callback()
        end
    end

    -- ask for user confirmation if required
    if not opts.no_confirm then
        utils.prompt_yes_no(string.format('Delete session "%s"?', name), commit)
    else
        commit(true)
    end
end

--- Check if given session exists
---@param name string session name
function M.exists(name)
    local path = paths.session(name)
    if not path:exists() then
        return false
    end
    local data_name = vim.F.npcall(function()
        return vim.json.decode(path:read()).name
    end)
    if not data_name then
        utils.warn('Could not read session file: %s', paths.session_short(name))
    elseif data_name ~= name then
        utils.error('Session corrupted: name vs filename mismatch: "%s" vs "%s"', data_name, paths.session_short(name))
        return false
    end
    return true
end

--- Get a list of sessions as map-like table
---@param opts? {}
---@return table<string, table> sessions {filename: session_data}
function M.list(opts)
    opts = opts or {}
    if opts.no_read then
        vim.deprecate('session.list().no_read', 'session files are now always read', '?', 'possession')
    end

    ---@type table<string, string[]>
    local files_by_name = {}

    local sessions = {}
    local glob = (Path:new(config.session_dir) / '*.json'):absolute()
    for _, file in ipairs(vim.fn.glob(glob, true, true)) do
        if vim.fn.filereadable(file) ~= 0 then
            local data = vim.json.decode(Path:new(file):read())
            sessions[file] = data

            files_by_name[data.name] = files_by_name[data.name] or {}
            table.insert(files_by_name[data.name], file)
        end
    end

    -- Check for name duplicates
    for name, files in pairs(files_by_name) do
        if #files > 1 then
            utils.warn(
                'Session name "%s" found in multiple session files, please remove one of them:\n%s',
                name,
                table.concat(files, '\n')
            )
        end
    end

    return sessions
end

--- Run :mksession! and return output as string by writing to a temporary file
function M.mksession()
    local tmp = vim.fn.tempname()
    vim.cmd('mksession! ' .. tmp)
    return Path:new(tmp):read()
end

return M
