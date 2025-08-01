local require = require("noice.util.lazy")

local Config = require("noice.config")
local Format = require("noice.text.format")
local Manager = require("noice.message.manager")
local builtin = require("fzf-lua.previewer.builtin")
local fzf = require("fzf-lua")

local M = {}

---@alias NoiceEntry {message: NoiceMessage, ordinal: string, display: string}

---@param message NoiceMessage
---@return NoiceEntry
function M.entry(message)
  message = Format.format(message, "fzf")
  local line = message._lines[1]
  local hl = { message.id .. " " } ---@type string[]
  for _, text in ipairs(line._texts) do
    ---@type string?
    local hl_group = text.extmark and text.extmark.hl_group
    if type(hl_group) == "number" then
      hl_group = vim.fn.synIDattr(hl_group, "name")
    end
    hl[#hl + 1] = hl_group and fzf.utils.ansi_from_hl(hl_group, text:content()) or text:content()
  end
  return {
    message = message,
    ordinal = message:content(),
    display = table.concat(hl, ""),
  }
end

function M.find()
  local messages = Manager.get(Config.options.commands.all.filter, {
    history = true,
    sort = true,
    reverse = true,
  })
  ---@type table<number, NoiceEntry>
  local ret = {}
  ---@type NoiceEntry[]
  local ordered = {}

  for _, message in ipairs(messages) do
    local entry = M.entry(message)
    ret[message.id] = entry
    table.insert(ordered, entry)
  end

  return ret, ordered
end

---@param messages table<number, NoiceEntry>
function M.previewer(messages)
  local previewer = builtin.buffer_or_file:extend()

  function previewer:new(o, opts, fzf_win)
    previewer.super.new(self, o, opts, fzf_win)
    self.title = "Noice"
    setmetatable(self, previewer)
    return self
  end

  function previewer:parse_entry(entry_str)
    local id = tonumber(entry_str:match("^%d+"))
    local entry = messages[id]
    assert(entry, "No message found for entry: " .. entry_str)
    return entry
  end

  function previewer:populate_preview_buf(entry_str)
    local buf = self:get_tmp_buffer()
    local entry = self:parse_entry(entry_str)
    assert(entry, "No message found for entry: " .. entry_str)

    ---@type NoiceMessage
    local m = Format.format(entry.message, "fzf_preview")
    m:render(buf, Config.ns)

    self:set_preview_buf(buf)
    self.win:update_preview_title(" Noice ")
    self.win:update_preview_scrollbar()
  end

  return previewer
end

---@param opts? table<string, any>
function M.open(opts)
  local messages, ordered = M.find()
  opts = vim.tbl_deep_extend("force", opts or {}, {
    prompt = false,
    winopts = {
      title = " Noice ",
      title_pos = "center",
      preview = {
        title = " Noice ",
        title_pos = "center",
      },
    },
    previewer = M.previewer(messages),
    fzf_opts = {
      ["--no-multi"] = "",
      ["--with-nth"] = "2..",
    },
    actions = {
      default = function(selected, opts)
        if not selected or #selected == 0 then
          return
        end
        
        local entry_str = selected[1]
        local id = tonumber(entry_str:match("^%d+"))
        local entry = messages[id]
        if not entry then
          return
        end

        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_keymap(buf, "n", "q", ":q<CR>", { silent = true })
        vim.api.nvim_buf_set_keymap(buf, "n", "<esc>", ":q<CR>", { silent = true })

        -- Custom rendering: title (if set) + newline + message
        local lines = {}
        local message = entry.message
        
        -- Add title if it exists
        if message.opts and message.opts.title and message.opts.title ~= "" then
          table.insert(lines, message.opts.title)
          table.insert(lines, "") -- empty line separator
        end
        
        -- Get the raw content and trim away level/timestamp prefix
        local content = message:content()
        if content and content ~= "" then
          -- Remove level and timestamp prefix (e.g., "Info  21:57:32 ")
          local clean_content = content:gsub("^%s*%w+%s+%d+:%d+:%d+%s+", "")
          
          -- If that didn't work, try a more flexible pattern
          if clean_content == content then
            clean_content = content:gsub("^.-(%d+:%d+:%d+)%s+", "")
          end
          
          -- Split content by newlines and add each line
          for line in clean_content:gmatch("[^\r\n]*") do
            if line ~= "" then -- skip empty lines
              table.insert(lines, line)
            end
          end
        end
        
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

        local lines = vim.opt.lines:get()
        local cols = vim.opt.columns:get()
        local width = math.ceil(cols * 0.8)
        local height = math.ceil(lines * 0.8 - 4)
        local left = math.ceil((cols - width) * 0.5)
        local top = math.ceil((lines - height) * 0.5)

        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          style = "minimal",
          width = width,
          height = height,
          col = left,
          row = top,
          border = "rounded",
        })

        vim.api.nvim_win_set_option(win, "wrap", true)
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
      end,
    },
  })
  local lines = vim.tbl_map(function(entry)
    return entry.display
  end, ordered)
  return fzf.fzf_exec(lines, opts)
end

return M
