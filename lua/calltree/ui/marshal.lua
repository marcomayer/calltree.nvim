local ct = require('calltree')
local config = require('calltree').config
local lsp_util = require('calltree.lsp.util')

local M = {}

M.glyphs = {
    expanded = (function() if ct.active_icon_set ~= nil then return ct.active_icon_set.Expanded else return "▼" end end)(),
    collapsed = (function() if ct.active_icon_set ~= nil then return ct.active_icon_set.Collapsed else return "▶" end end)(),
    separator = "•",
    guide = "⎸",
    space = " "
}

-- buf_line_map keeps a mapping between marshaled
-- buffer lines and the node objects for a given tree.
--
-- the structure of this table is as follows:
-- {
--   tree_handle = {
--      line_number = node,
--      ...
--   },
--   ...
-- }
M.buf_line_map = {}

-- maps source code lines to buffer lines
-- for a given tree.
--
-- currently only useful for symboltree.
--
-- the struture of this table is as follows:
-- {
--   tree_handle = {
--      source_file_line_number = {
--          uri = relative_path_to_file,
--          line = calltree_buffer_line_number
--      }
--      ...
--   }
--   ...
-- }
M.source_line_map = {}

-- marshal_node takes a node and marshals
-- it into a UI buffer line.
--
-- node : tree.Node - the node to marshal into
-- a buffer line.
--
-- returns:
--    string - a string for the collapsed or expanded symbol name
--    table  - a virt_text chunk that can be passed directly to
-- vim.api.nvim_buf_set_extmark() via the virt_text option.
function M.marshal_node(node, final)
    local expand_guide = ""
    if node.expanded then
        expand_guide = M.glyphs["expanded"]
    else
        expand_guide = M.glyphs["collapsed"]
    end

    -- prefer using workspace symbol details if available.
    -- fallback to callhierarchy object details.
    local name, kind, detail, str = "", "", "", ""
    if node.symbol ~= nil then
        name = node.symbol.name
        kind = vim.lsp.protocol.SymbolKind[node.symbol.kind]

        local file, relative = lsp_util.relative_path_from_uri(node.symbol.location.uri)
        if relative then
            detail = file
        elseif node.symbol.detail ~= nil then
            detail = node.symbol.detail
        end
        if
            #node.children == 0
            and node.expanded == true
        then
        -- we are at a leaf, no guide necessary.
            expand_guide = M.glyphs["space"]
         end
    elseif node.document_symbol ~= nil then
        name = node.document_symbol.name
        kind = vim.lsp.protocol.SymbolKind[node.document_symbol.kind]

        if node.document_symbol.detail ~= nil then
            detail = node.document_symbol.detail
        end
        if #node.children == 0 then
            expand_guide = M.glyphs.space
        end
    elseif node.call_hierarchy_item ~= nil then
        name = node.name
        kind = vim.lsp.protocol.SymbolKind[node.call_hierarchy_item.kind]

        local file, relative = lsp_util.relative_path_from_uri(node.call_hierarchy_item.uri)
        if relative then
            detail = file
        elseif node.call_hierarchy_item.detail ~= nil then
            detail = node.call_hierarchy_item.detail
        end
    end

    local icon = ""
    if kind ~= "" then
        if ct.active_icon_set ~= nil then
            icon = ct.active_icon_set[kind]
        end
    end

    -- compute guides or spaces dependent on configs.
    if config.indent_guides then
        for i=1, node.depth do
            if i == 1 then
                str = str .. M.glyphs.space
            else
                str = str .. M.glyphs.guide .. M.glyphs.space
            end
        end
    else
        for _=1, node.depth do
            str = str .. M.glyphs.space
        end
    end

    -- ▶ Func1
    str = str .. expand_guide .. M.glyphs.space

    if ct.config.icons ~= "none" then
        -- ▶   Func1
        str = str .. icon .. M.glyphs.space  .. M.glyphs.space .. name
    else
        -- ▶ [Function] Func1
        str = str .. M.glyphs.space .. "[" .. kind .. "]" .. M.glyphs.space .. M.glyphs.separator .. M.glyphs.space .. name
    end

    -- return detail as virtual text chunk.
    return str, {{detail, ct.hls.SymbolDetailHL}}
end

-- marshal_line takes a UI buffer line and
-- marshals it into a tree.Node.
--
-- linenr : {row,col} - the UI buffer line typically returned by
-- vim.api.nvim_win_get_cursor(calltree_win_handle)
--
-- tree: the handle of the tree we are marshaling the
-- line from.
--
-- returns:
--   tree.Node - the marshaled tree.Node table.
function M.marshal_line(linenr, tree)
    if M.buf_line_map == nil then
        return nil
    end
    if M.buf_line_map[tree] == nil then
        return nil
    end
    local node = M.buf_line_map[tree][linenr[1]]
    return node
end

-- marshal_tree recursively marshals all nodes from the provided root
-- down into UI lines.
--
-- buf_handle : buffer_handle - the buffer to write the marshalled tree
-- to
--
-- lines : array of strings - recursive accumlator of marshaled lines.
-- call this function with an empty array.
--
-- node : tree.tree.Node - the root node of the tree where marshaling will
-- begin.
--
-- tree : tree_handle - a handle to a the tree we are marshaling.
function M.marshal_tree(buf_handle, lines, node, tree, virtual_text_lines, final)
    if node.depth == 0 then
        virtual_text_lines = {}
        -- create a new line mapping
        M.buf_line_map[tree] = {}
        M.source_line_map[tree] = {}
    end

    local line, virtual_text = M.marshal_node(node, final)
    table.insert(lines, line)
    table.insert(virtual_text_lines, virtual_text)
    M.buf_line_map[tree][#lines] = node

    -- track the source code line that maps to
    -- this is really only used for symboltree at
    -- the moment.
    local loc = lsp_util.resolve_location(node)
    if loc ~= nil then
        local start_line = loc["range"]["start"].line
        M.source_line_map[tree][start_line+1] = {
            uri = lsp_util.resolve_absolute_file_path(node),
            line = #lines
        }
    end

    -- if we are an expanded node or we are the root (always expand)
    -- recurse
    if node.expanded  or node.depth == 0 then
        for i, child in ipairs(node.children) do
            if i == #node.children then
                final = true
            else
                final = false
            end
            M.marshal_tree(buf_handle, lines, child, tree, virtual_text_lines, final)
        end
    end

    -- we are back at the root, all lines are inserted, lets write it out
    -- to the buffer
    if node.depth == 0 then
        vim.api.nvim_buf_set_option(buf_handle, 'modifiable', true)
        vim.api.nvim_buf_set_lines(buf_handle, 0, -1, true, {})
        vim.api.nvim_buf_set_lines(buf_handle, 0, #lines, false, lines)
        vim.api.nvim_buf_set_option(buf_handle, 'modifiable', false)
        for i, vt in ipairs(virtual_text_lines) do
            if vt[1][1] == "" then
                goto continue
            end
            local opts = {
                virt_text = vt,
                virt_text_pos = 'eol',
                hl_mode = 'combine'
            }
            vim.api.nvim_buf_set_extmark(buf_handle, 1, i-1, 0, opts)
            ::continue::
        end
    end
end

return M
