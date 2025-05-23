local navic = require("nvim-navic.lib")

local nui_popup = require("nui.popup")
local nui_layout = require("nui.layout")
local nui_text = require("nui.text")

local ui = require("nvim-navbuddy.ui")

local ns = vim.api.nvim_create_namespace("nvim-navbuddy")

local function clear_buffer(buf)
  vim.api.nvim_win_set_buf(buf.winid, buf.bufnr)

  vim.api.nvim_win_set_option(buf.winid, "signcolumn", "no")
  vim.api.nvim_win_set_option(buf.winid, "foldlevel", 100)
  vim.api.nvim_win_set_option(buf.winid, "wrap", true)

  vim.api.nvim_buf_set_option(buf.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf.bufnr, 0, -1, false, {})
  vim.api.nvim_buf_set_option(buf.bufnr, "modifiable", false)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf.bufnr, ns, 0, -1, {})) do
    vim.api.nvim_buf_del_extmark(buf.bufnr, ns, extmark[1])
  end
end

local merge = function(...)
  return vim.tbl_deep_extend("force", ...)
end

local function fill_buffer(buf, node, config)
  local cursor_pos = vim.api.nvim_win_get_cursor(buf.winid)
  clear_buffer(buf)

  local parent = node.parent

  local lines = {}
  for _, child_node in ipairs(parent.children) do
    local text = " " .. config.icons[child_node.kind] .. child_node.name
    table.insert(lines, text)
  end

  vim.api.nvim_buf_set_option(buf.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf.bufnr, "modifiable", false)

  if cursor_pos[1] ~= node.index then
    cursor_pos[1] = node.index
  end

  for i, child_node in ipairs(parent.children) do
    local hl_group = "Navbuddy" .. navic.adapt_lsp_num_to_str(child_node.kind)
    vim.api.nvim_buf_add_highlight(buf.bufnr, ns, hl_group, i - 1, 0, -1)
    if config.node_markers.enabled then
      vim.api.nvim_buf_set_extmark(buf.bufnr, ns, i - 1, #lines[i], {
        virt_text = {
          {
            child_node.children ~= nil and config.node_markers.icons.branch
              or i == cursor_pos[1] and config.node_markers.icons.leaf_selected
              or config.node_markers.icons.leaf,
            i == cursor_pos[1] and { "NavbuddyCursorLine", hl_group } or hl_group,
          },
        },
        virt_text_pos = "right_align",
        virt_text_hide = false,
      })
    end
  end

  vim.api.nvim_buf_add_highlight(buf.bufnr, ns, "NavbuddyCursorLine", cursor_pos[1] - 1, 0, -1)
  vim.api.nvim_buf_set_extmark(buf.bufnr, ns, cursor_pos[1] - 1, #lines[cursor_pos[1]], {
    end_row = cursor_pos[1],
    hl_eol = true,
    hl_group = "NavbuddyCursorLine" .. navic.adapt_lsp_num_to_str(node.kind),
  })
  vim.api.nvim_win_set_cursor(buf.winid, cursor_pos)
end

---@private
---@class Navbuddy.display.opts
---@field config Navbuddy.config
---@field for_buf number
---@field for_win number
---@field start_cursor integer[] # (row, col) tuple
---@field focus_node Navbuddy.symbolNode
---@field lsp_name string

---@private
---@class Navbuddy.display.state
---@field leaving_window_for_action boolean
---@field leaving_window_for_reorientation boolean
---@field closed boolean
---@field source_buffer_scrolloff? number
---@field user_gui_cursor? string

---@private
---@class Navbuddy.display
---@field config Navbuddy.config
---@field lsp_name string
---@field for_buf number
---@field for_win number
---@field start_cursor integer[] # (row, col) tuple
---@field focus_node Navbuddy.symbolNode
---@field layout NuiLayout
---@field left NuiPopup
---@field mid NuiPopup
---@field right NuiPopup
---@field state Navbuddy.display.state
---@overload fun(opts:Navbuddy.display.opts): Navbuddy.display
local display = setmetatable({}, {
  __call = function(t, ...)
    return t.new(...)
  end,
})
display.__index = display

---@param opts Navbuddy.display.opts|Navbuddy.display
---@return any
function display.new(opts)
  local self = setmetatable({}, display)
  local config = opts.config

  -- NUI elements
  local left_popup = nui_popup(merge({
    focusable = false,
    border = config.window.sections.left.border or ui.get_border_chars(config.window.border, "left"),
    win_options = {
      winhighlight = "Normal:NavbuddyNormalFloat,FloatBorder:NavbuddyFloatBorder",
    },
    buf_options = {
      modifiable = false,
    },
  }, {
    win_options = config.window.sections.left.win_options,
    buf_options = config.window.sections.left.buf_options,
  }))

  local mid_popup = nui_popup(merge({
    enter = true,
    border = config.window.sections.mid.border or ui.get_border_chars(config.window.border, "mid"),
    win_options = {
      winhighlight = "Normal:NavbuddyNormalFloat,FloatBorder:NavbuddyFloatBorder",
      scrollofe = config.window.scrolloff,
    },
    buf_options = {
      modifiable = false,
    },
  }, {
    win_options = config.window.sections.mid.win_options,
    buf_options = config.window.sections.mid.buf_options,
  }))

  local lsp_name = {
    bottom = nui_text("[" .. opts.lsp_name .. "]", "NavbuddyFloatBorder"),
    bottom_align = "right",
  }

  if
    config.window.sections.right.border == "none"
    or config.window.border == "none"
    or config.window.sections.right.border == "shadow"
    or config.window.border == "shadow"
    or config.window.sections.right.border == "solid"
    or config.window.border == "solid"
  then
    lsp_name = nil
  end

  local right_border = config.window.sections.right.border
  local right_popup = nui_popup(merge({
    focusable = true,
    border = {
      style = right_border and right_border.style or right_border or ui.get_border_chars(config.window.border, "right"),
      text = lsp_name,
    },
    win_options = {
      winhighlight = "Normal:NavbuddyNormalFloat,FloatBorder:NavbuddyFloatBorder",
      scrolloff = 0,
    },
    buf_options = {
      modifiable = false,
    },
  }, {
    win_options = config.window.sections.right.win_options,
    buf_options = config.window.sections.right.buf_options,
  }))

  local layout = nui_layout(
    {
      relative = "editor",
      position = config.window.position,
      size = config.window.size,
    },
    nui_layout.Box({
      nui_layout.Box(left_popup, { size = config.window.sections.left.size }),
      nui_layout.Box(mid_popup, { size = config.window.sections.mid.size }),
      nui_layout.Box(right_popup, { grow = 1 }),
    }, { dir = "row" })
  )

  -- Prevent black splash on transparent terminals
  if vim.g.navbuddy_taransparent then
    layout._.float.win_options = { winblend = 0 }
  end

  self.config = opts.config
  self.lsp_name = opts.lsp_name
  self.for_buf = opts.for_buf
  self.for_win = opts.for_win
  self.start_cursor = opts.start_cursor
  self.focus_node = opts.focus_node
  -- self.lsp_name = lsp_name
  self.layout = layout
  self.left = left_popup
  self.mid = mid_popup
  self.right = right_popup
  self.state = {
    leaving_window_for_action = false,
    leaving_window_for_reorientation = false,
    closed = false,
    -- source_buffer_scrolloff = nil,
    -- user_gui_cursor = nil,
  }

  display.init(self)
  return self
end

function display:init()
  ui.highlight_setup(self.config)

  -- Set filetype
  vim.api.nvim_buf_set_option(self.mid.bufnr, "filetype", "Navbuddy")

  -- Hidden cursor
  if self.state.user_gui_cursor == nil then
    self.state.user_gui_cursor = vim.api.nvim_get_option("guicursor")
  end
  self.state.user_gui_cursor = vim.api.nvim_get_option("guicursor")
  if self.state.user_gui_cursor ~= "" then
    vim.api.nvim_set_option("guicursor", "a:NavbuddyCursor")
  end

  -- User Scrolloff
  if self.config.source_buffer.scrolloff then
    self.state.source_buffer_scrolloff = vim.api.nvim_get_option("scrolloff")
    vim.api.nvim_set_option("scrolloff", self.config.source_buffer.scrolloff)
  end

  -- Autocmds
  local augroup = vim.api.nvim_create_augroup("Navbuddy", { clear = false })
  vim.api.nvim_clear_autocmds({ buffer = self.mid.bufnr })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = self.mid.bufnr,
    callback = function()
      local cursor_pos = vim.api.nvim_win_get_cursor(self.mid.winid)
      if self.focus_node ~= self.focus_node.parent.children[cursor_pos[1]] then
        self.focus_node = self.focus_node.parent.children[cursor_pos[1]]
        self:redraw()
      end

      self.focus_node.parent.memory = self.focus_node.index

      self:clear_highlights()
      self:focus_range()
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = self.mid.bufnr,
    callback = function()
      if
        self.state.leaving_window_for_action == false
        and self.state.leaving_window_for_reorientation == false
        and self.state.closed == false
      then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = augroup,
    buffer = self.mid.bufnr,
    callback = function()
      vim.api.nvim_set_option("guicursor", self.state.user_gui_cursor)
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = augroup,
    buffer = self.mid.bufnr,
    callback = function()
      if self.state.user_gui_cursor ~= "" then
        vim.api.nvim_set_option("guicursor", "a:NavbuddyCursor")
      end
    end,
  })

  -- Mappings
  for i, v in pairs(self.config.mappings) do
    self.mid:map("n", i, function()
      v.callback(self)
    end, { nowait = true })
  end

  -- Display
  self.layout:mount()
  self:redraw()
  self:focus_range()
  return self
end

function display:focus_range()
  local ranges = nil

  if vim.deep_equal(self.focus_node.scope, self.focus_node.name_range) then
    ranges = { { "NavbuddyScope", self.focus_node.scope } }
  else
    ranges = { { "NavbuddyScope", self.focus_node.scope }, { "NavbuddyName", self.focus_node.name_range } }
  end

  if self.config.source_buffer.highlight then
    for _, v in ipairs(ranges) do
      local highlight, range = unpack(v)

      if range["start"].line == range["end"].line then
        vim.api.nvim_buf_add_highlight(
          self.for_buf,
          ns,
          highlight,
          range["start"].line - 1,
          range["start"].character,
          range["end"].character
        )
      else
        vim.api.nvim_buf_add_highlight(
          self.for_buf,
          ns,
          highlight,
          range["start"].line - 1,
          range["start"].character,
          -1
        )
        vim.api.nvim_buf_add_highlight(self.for_buf, ns, highlight, range["end"].line - 1, 0, range["end"].character)
        for i = range["start"].line, range["end"].line - 2, 1 do
          vim.api.nvim_buf_add_highlight(self.for_buf, ns, highlight, i, 0, -1)
        end
      end
    end
  end

  if self.config.source_buffer.follow_node then
    self:reorient(self.for_win, self.config.source_buffer.reorient)
  end
end

function display:reorient(ro_win, reorient_method)
  vim.api.nvim_win_set_cursor(
    ro_win,
    { self.focus_node.name_range["start"].line, self.focus_node.name_range["start"].character }
  )

  self.state.leaving_window_for_reorientation = true
  vim.api.nvim_set_current_win(ro_win)

  if reorient_method == "smart" then
    local total_lines = self.focus_node.scope["end"].line - self.focus_node.scope["start"].line + 1

    if total_lines >= vim.api.nvim_win_get_height(ro_win) then
      vim.api.nvim_command("normal! zt")
    else
      local mid_line = bit.rshift(self.focus_node.scope["start"].line + self.focus_node.scope["end"].line, 1)
      vim.api.nvim_win_set_cursor(ro_win, { mid_line, 0 })
      vim.api.nvim_command("normal! zz")
      vim.api.nvim_win_set_cursor(
        ro_win,
        { self.focus_node.name_range["start"].line, self.focus_node.name_range["start"].character }
      )
    end
  elseif reorient_method == "mid" then
    vim.api.nvim_command("normal! zz")
  elseif reorient_method == "top" then
    vim.api.nvim_command("normal! zt")
  end

  vim.api.nvim_set_current_win(self.mid.winid)
  self.state.leaving_window_for_reorientation = false
end

function display:show_preview()
  vim.api.nvim_win_set_buf(self.right.winid, self.for_buf)

  local win_options = merge({
    winhighlight = "Normal:NavbuddyNormalFloat,FloatBorder:NavbuddyFloatBorder",
    signcolumn = "no",
    foldlevel = 100,
    wrap = false,
  }, self.config.window.sections.right.win_options or {})

  for opt_name, opt_value in pairs(win_options) do
    vim.api.nvim_win_set_option(self.right.winid, opt_name, opt_value)
  end

  self:reorient(self.right.winid, "smart")
end

function display:hide_preview()
  vim.api.nvim_win_set_buf(self.right.winid, self.right.bufnr)
  local node = self.focus_node
  if node.children then
    if node.memory then
      fill_buffer(self.right, node.children[node.memory], self.config)
    else
      fill_buffer(self.right, node.children[1], self.config)
    end
  else
    clear_buffer(self.right)
  end
end

function display:clear_highlights()
  vim.api.nvim_buf_clear_highlight(self.for_buf, ns, 0, -1)
end

function display:redraw()
  local node = self.focus_node
  fill_buffer(self.mid, node, self.config)

  local preview_method = self.config.window.sections.right.preview

  if preview_method == "always" then
    self:show_preview()
  else
    if node.children then
      if node.memory then
        fill_buffer(self.right, node.children[node.memory], self.config)
      else
        fill_buffer(self.right, node.children[1], self.config)
      end

      -- Apply the window options for right_popup
      for opt_name, opt_value in pairs(self.config.window.sections.right.win_options or {}) do
        vim.api.nvim_win_set_option(self.right.winid, opt_name, opt_value)
      end
    else
      if preview_method == "leaf" then
        self:show_preview()
      else
        clear_buffer(self.right)
      end
    end
  end

  if node.parent.is_root then
    clear_buffer(self.left)
  else
    fill_buffer(self.left, node.parent, self.config)
  end
end

function display:close()
  self.state.closed = true
  vim.api.nvim_set_option("guicursor", self.state.user_gui_cursor)
  if self.state.source_buffer_scrolloff then
    vim.api.nvim_set_option("scrolloff", self.state.source_buffer_scrolloff)
  end
  self.layout:unmount()
  self:clear_highlights()
end

return display
