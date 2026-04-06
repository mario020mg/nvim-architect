-- architect/ui/init.lua
-- Floating panel: sidebar (steps) + chat + input.
--
-- Workflow per step:
--   1. Fixed question shown immediately (no AI call yet)
--   2. User types answer → <CR> → AI reads context.md → proposes MVP
--   3. User corrects if needed → AI adjusts
--   4. User presses <C-s> → saves → context.md updated → next step

local M = {}
local api = vim.api
local memory    = require("architect.memory")
local steps_def = require("architect.steps.definitions")
local openai    = require("architect.ai.openai")

local state       = nil
local wins        = {}
local bufs        = {}
local is_open     = false
local is_streaming = false

---------------------------------------------------------------------------
-- Highlights
---------------------------------------------------------------------------

local function setup_highlights()
  local function hl(g, o) api.nvim_set_hl(0, g, o) end
  hl("ArchitectBorder",      { fg = "#4a9eff",                bold = false })
  hl("ArchitectStepActive",  { fg = "#4a9eff", bg = "#1a1f2e", bold = true  })
  hl("ArchitectStepDone",    { fg = "#3ddc84",                bold = false })
  hl("ArchitectStepPending", { fg = "#4a5568",                bold = false })
  hl("ArchitectNormal",      { fg = "#e2e8f0", bg = "#0f1117"              })
  hl("ArchitectSidebarBg",   { fg = "#cbd5e0", bg = "#0a0d14"              })
end

---------------------------------------------------------------------------
-- Buffer helpers
---------------------------------------------------------------------------

local function buf_set(buf, lines, keep_mod)
  api.nvim_buf_set_option(buf, "modifiable", true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if not keep_mod then
    api.nvim_buf_set_option(buf, "modifiable", false)
  end
end

local function buf_append(buf, lines)
  api.nvim_buf_set_option(buf, "modifiable", true)
  local n = api.nvim_buf_line_count(buf)
  api.nvim_buf_set_lines(buf, n, n, false, lines)
  api.nvim_buf_set_option(buf, "modifiable", false)
end

local function scroll_bottom(win)
  if not win or not api.nvim_win_is_valid(win) then return end
  local n = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  api.nvim_win_set_cursor(win, { n, 0 })
end

local function focus_input()
  if bufs.input and api.nvim_buf_is_valid(bufs.input) then
    api.nvim_buf_set_option(bufs.input, "modifiable", true)
  end
  if wins.input and api.nvim_win_is_valid(wins.input) then
    api.nvim_set_current_win(wins.input)
    vim.cmd("startinsert")
  end
end

---------------------------------------------------------------------------
-- Sidebar
---------------------------------------------------------------------------

local function render_sidebar()
  if not bufs.sidebar or not api.nvim_buf_is_valid(bufs.sidebar) then return end

  local lines = { "", "  ARCHITECT", "  AI Dev Workflow", "" }

  for i, step in ipairs(steps_def.steps) do
    local is_current = (state.current_step == i)
    local is_done    = vim.tbl_contains(state.completed_steps or {}, i)
    local prefix     = is_done and "  v " or (is_current and "  > " or "    ")
    table.insert(lines, prefix .. step.icon .. "  " .. step.title)
    if is_current then table.insert(lines, "") end
  end

  table.insert(lines, "")
  table.insert(lines, "  -----------------")
  table.insert(lines, "")
  local mem_ok = vim.fn.isdirectory(vim.fn.getcwd() .. "/.nvim/architect") == 1
  table.insert(lines, mem_ok and "  Memory: saved" or "  Memory: not saved")
  table.insert(lines, "")
  table.insert(lines, "  <CR>   send")
  table.insert(lines, "  <C-s>  save + next")
  table.insert(lines, "  <C-q>  close")

  buf_set(bufs.sidebar, lines, false)

  -- Highlights
  local ns = api.nvim_create_namespace("architect_sidebar")
  api.nvim_buf_clear_namespace(bufs.sidebar, ns, 0, -1)
  local offset = 4
  for i in ipairs(steps_def.steps) do
    local line_idx = offset + (i - 1)
    for j = 1, i - 1 do
      if state.current_step == j then line_idx = line_idx + 1 end
    end
    local grp = vim.tbl_contains(state.completed_steps or {}, i) and "ArchitectStepDone"
      or (state.current_step == i and "ArchitectStepActive" or "ArchitectStepPending")
    api.nvim_buf_add_highlight(bufs.sidebar, ns, grp, line_idx, 0, -1)
  end
end

---------------------------------------------------------------------------
-- Chat: render current step
---------------------------------------------------------------------------

local function render_step()
  if not bufs.chat or not api.nvim_buf_is_valid(bufs.chat) then return end

  local step        = steps_def.get(state.current_step)
  local history     = memory.get_conversation(state, state.current_step)
  local has_history = #history > 0

  local lines = {
    "",
    "  Step " .. state.current_step .. " / 10   " .. step.icon .. "  " .. step.title,
    "  ──────────────────────────────────────────",
    "",
  }

  -- Show the fixed question only when the step is fresh (no messages yet)
  if not has_history then
    table.insert(lines, "  " .. step.question)
    table.insert(lines, "")
  end

  buf_set(bufs.chat, lines, false)

  -- Replay conversation history
  for _, msg in ipairs(history) do
    if msg.role == "user" then
      M.append_user(msg.content, true)
    else
      M.append_ai(msg.content, true)
    end
  end
end

---------------------------------------------------------------------------
-- Append messages to chat buffer
---------------------------------------------------------------------------

function M.append_user(text, no_save)
  if not bufs.chat or not api.nvim_buf_is_valid(bufs.chat) then return end
  local lines = { "  You ▸", "" }
  for _, l in ipairs(vim.split(text, "\n")) do
    table.insert(lines, "  " .. l)
  end
  table.insert(lines, "")
  table.insert(lines, "  ──────────────────────────────────────────")
  table.insert(lines, "")
  buf_append(bufs.chat, lines)
  scroll_bottom(wins.chat)
  if not no_save then
    memory.add_conversation(state, state.current_step, "user", text)
    memory.save(state)
  end
end

function M.append_ai(text, no_save)
  if not bufs.chat or not api.nvim_buf_is_valid(bufs.chat) then return end
  local lines = { "  AI ◆", "" }
  for _, l in ipairs(vim.split(text, "\n")) do
    table.insert(lines, "  " .. l)
  end
  table.insert(lines, "")
  if openai.has_ready_marker(text) then
    table.insert(lines, "  ✓  Ready — press <C-s> to save and continue")
  end
  table.insert(lines, "  ──────────────────────────────────────────")
  table.insert(lines, "")
  buf_append(bufs.chat, lines)
  scroll_bottom(wins.chat)
  if not no_save then
    memory.add_conversation(state, state.current_step, "assistant", text)
    memory.save(state)
  end
end

---------------------------------------------------------------------------
-- Streaming
---------------------------------------------------------------------------

local function start_streaming()
  is_streaming = true
  buf_append(bufs.chat, { "  AI ◆", "", "  " })
end

local function stream_chunk(chunk)
  if not bufs.chat or not api.nvim_buf_is_valid(bufs.chat) then return end
  api.nvim_buf_set_option(bufs.chat, "modifiable", true)
  local count = api.nvim_buf_line_count(bufs.chat)
  local last  = api.nvim_buf_get_lines(bufs.chat, count - 1, count, false)[1] or ""
  local parts = vim.split(chunk, "\n")
  for i, part in ipairs(parts) do
    if i == 1 then
      api.nvim_buf_set_lines(bufs.chat, count - 1, count, false, { last .. part })
    else
      count = api.nvim_buf_line_count(bufs.chat)
      api.nvim_buf_set_lines(bufs.chat, count, count, false, { "  " .. part })
    end
  end
  api.nvim_buf_set_option(bufs.chat, "modifiable", false)
  scroll_bottom(wins.chat)
end

local function finish_streaming(full_text)
  is_streaming = false
  if not bufs.chat or not api.nvim_buf_is_valid(bufs.chat) then return end
  local extra = { "" }
  if openai.has_ready_marker(full_text) then
    table.insert(extra, "  ✓  Ready — press <C-s> to save and continue")
  end
  table.insert(extra, "  ──────────────────────────────────────────")
  table.insert(extra, "")
  buf_append(bufs.chat, extra)
  scroll_bottom(wins.chat)
  memory.add_conversation(state, state.current_step, "assistant", full_text)
  memory.save(state)
end

---------------------------------------------------------------------------
-- Send message → AI reads context.md → streams proposal
---------------------------------------------------------------------------

local function send_message()
  if is_streaming then
    vim.notify("[architect] AI is responding...", vim.log.levels.WARN)
    return
  end
  if not bufs.input or not api.nvim_buf_is_valid(bufs.input) then return end

  local lines = api.nvim_buf_get_lines(bufs.input, 0, -1, false)
  local text  = table.concat(lines, "\n"):match("^%s*(.-)%s*$")
  if text == "" then return end

  -- Clear input
  api.nvim_buf_set_option(bufs.input, "modifiable", true)
  api.nvim_buf_set_lines(bufs.input, 0, -1, false, { "" })

  M.append_user(text)

  local step = steps_def.get(state.current_step)

  -- Always inject context.md before calling AI
  local context = steps_def.get_context(state)
  local system  = step.system_prompt
  if context ~= "" then
    system = system .. "\n\n--- PROJECT CONTEXT ---\n" .. context
  end

  -- Build conversation history for this step (excluding the message just appended,
  -- which was already added by append_user)
  local history  = memory.get_conversation(state, state.current_step)
  local messages = {}
  for _, msg in ipairs(history) do
    table.insert(messages, { role = msg.role, content = msg.content })
  end

  start_streaming()

  openai.chat(messages, system, function(chunk)
    stream_chunk(chunk)
  end, function(full_text, err)
    if err then
      finish_streaming("")
      M.append_ai("⚠ Error: " .. err)
      vim.schedule(function() focus_input() end)
      return
    end
    finish_streaming(full_text)
    vim.schedule(function() focus_input() end)
  end)
end

---------------------------------------------------------------------------
-- Step 8: implement files one by one from state.file_descriptions
---------------------------------------------------------------------------

local function implement_files(file_list, index, context, on_all_done)
  if index > #file_list then
    on_all_done()
    return
  end

  local filepath = file_list[index]
  local description = (state.file_descriptions or {})[filepath] or "no description"
  local root = vim.fn.getcwd()
  local full_path = root .. "/" .. filepath

  -- Show which file we're working on
  buf_append(bufs.chat, {
    "",
    "  ── File " .. index .. " / " .. #file_list .. ": " .. filepath,
    "  " .. description,
    "",
  })
  scroll_bottom(wins.chat)

  -- Create parent directories and an empty file immediately
  local dir = full_path:match("^(.*)/[^/]*$")
  if dir then vim.fn.mkdir(dir, "p") end
  vim.fn.writefile({}, full_path)

  local system = [[
You are implementing a single source file. Return ONLY the raw file contents.
No markdown fences, no explanation, no commentary before or after.
Just the code that goes in the file.
]] .. "\n\n--- PROJECT CONTEXT ---\n" .. context

  local prompt = "Implement this file: " .. filepath .. "\nPurpose: " .. description

  is_streaming = true
  buf_append(bufs.chat, { "  AI ◆", "", "  " })

  local full_response = ""

  openai.chat(
    { { role = "user", content = prompt } },
    system,
    function(chunk)
      -- Stream to chat
      stream_chunk(chunk)
      -- Accumulate for disk write
      full_response = full_response .. chunk
    end,
    function(full_text, err)
      is_streaming = false

      if err then
        buf_append(bufs.chat, {
          "",
          "  ⚠ Error writing " .. filepath .. ": " .. err,
          "  ──────────────────────────────────────────",
          "",
        })
        scroll_bottom(wins.chat)
      else
        -- Write full response to disk
        local content = full_text or full_response
        vim.fn.writefile(vim.split(content, "\n"), full_path)

        buf_append(bufs.chat, {
          "",
          "  ✓ Written: " .. filepath,
          "  ──────────────────────────────────────────",
          "",
        })
        scroll_bottom(wins.chat)
      end

      -- Next file
      vim.schedule(function()
        implement_files(file_list, index + 1, context, on_all_done)
      end)
    end
  )
end

---------------------------------------------------------------------------
-- Save & advance
---------------------------------------------------------------------------

local function save_and_next()
  local history = memory.get_conversation(state, state.current_step)
  local last_ai = nil
  for i = #history, 1, -1 do
    if history[i].role == "assistant" then
      last_ai = history[i].content
      break
    end
  end

  if not last_ai then
    vim.notify("[architect] No AI response to save yet.", vim.log.levels.WARN)
    return
  end

  if not openai.has_ready_marker(last_ai) then
    vim.ui.input({ prompt = "Not marked ready. Save anyway? [y/N] " }, function(input)
      if input and input:lower() == "y" then
        do_save(last_ai)
      end
    end)
    return
  end
  do_save(last_ai)
end

function do_save(ai_text)
  local step = steps_def.get(state.current_step)

  -- Step 8: automated file-by-file implementation from state.file_descriptions
  if step.id == 8 then
    local file_descriptions = state.file_descriptions or {}
    local file_list = {}
    for path, _ in pairs(file_descriptions) do
      table.insert(file_list, path)
    end
    table.sort(file_list)

    if #file_list == 0 then
      vim.notify("[architect] No files found from step 7. Complete step 7 first.", vim.log.levels.WARN)
      return
    end

    local context = steps_def.get_context(state)

    buf_append(bufs.chat, {
      "",
      "  ── Starting implementation: " .. #file_list .. " files ──",
      "",
    })
    scroll_bottom(wins.chat)

    implement_files(file_list, 1, context, function()
      -- All files done — save summary and advance
      local summary = "Implemented " .. #file_list .. " files from step 7 file structure."
      pcall(step.save_action, state, summary)

      if not vim.tbl_contains(state.completed_steps, state.current_step) then
        table.insert(state.completed_steps, state.current_step)
      end

      memory.save(state)
      memory.export_summary(state)

      buf_append(bufs.chat, {
        "",
        "  ✓ All files implemented. Advancing to next step.",
        "  ──────────────────────────────────────────",
        "",
      })
      scroll_bottom(wins.chat)

      local next_step = state.current_step + 1
      if next_step <= #steps_def.steps then
        state.current_step = next_step
        memory.save(state)
        render_sidebar()
        render_step()
      else
        render_sidebar()
      end

      vim.schedule(function() focus_input() end)
    end)

    return -- early return: advancement handled inside implement_files chain
  end

  -- Steps 9, 10 (code type): manual filename prompt as before
  if step.type == "code" then
    local root = vim.fn.getcwd()
    local history = memory.get_conversation(state, state.current_step)
    local last_ai = nil
    for i = #history, 1, -1 do
      if history[i].role == "assistant" then
        last_ai = history[i].content
        break
      end
    end

    vim.ui.input({ prompt = "Filename (e.g. src/index.js): " }, function(filepath)
      if not filepath or filepath == "" then return end
      local full = root .. "/" .. filepath
      local dir = full:match("^(.*)/[^/]*$")
      if dir then vim.fn.mkdir(dir, "p") end

      local code = last_ai and last_ai:match("```[%w]*\n(.-)\n```") or last_ai
      if not code then code = last_ai or "" end

      vim.fn.writefile(vim.split(code, "\n"), full)
      vim.notify("Created: " .. filepath, vim.log.levels.INFO)
    end)
  end

  -- Save state data for all steps
  local content = openai.extract_save_content(ai_text)
  if content then
    pcall(step.save_action, state, content)
  end

  if not vim.tbl_contains(state.completed_steps, state.current_step) then
    table.insert(state.completed_steps, state.current_step)
  end

  memory.save(state)
  memory.export_summary(state)

  local next_step = state.current_step + 1
  if next_step > #steps_def.steps then
    render_sidebar()
    return
  end

  state.current_step = next_step
  memory.save(state)

  render_sidebar()
  render_step()

  vim.schedule(function() focus_input() end)
end

---------------------------------------------------------------------------
-- Window layout
---------------------------------------------------------------------------

local function layout()
  local W  = vim.o.columns
  local H  = vim.o.lines
  local tw = math.floor(W * 0.92)
  local th = math.floor(H * 0.88)
  local sc = math.floor((W - tw) / 2)
  local sr = math.floor((H - th) / 2)
  local sw = 24
  local cw = math.floor(tw - sw - 3)
  local ih = 4
  local ch = math.floor(th - ih - 3)
  return {
    sidebar = { row = sr,       col = sc,       width = sw, height = th },
    chat    = { row = sr,       col = sc+sw+1,  width = cw, height = ch },
    input   = { row = sr+ch+2,  col = sc+sw+1,  width = cw, height = ih },
  }
end

local function create_buf()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  return buf
end

local function open_win(buf, opts)
  return api.nvim_open_win(buf, false, vim.tbl_extend("force", {
    relative = "editor",
    style    = "minimal",
    border   = "rounded",
  }, opts))
end

---------------------------------------------------------------------------
-- Open / Close
---------------------------------------------------------------------------

function M.open()
  if is_open then M.close(); return end

  state = memory.load()
  setup_highlights()

  local l = layout()

  -- Sidebar
  bufs.sidebar = create_buf()
  wins.sidebar = open_win(bufs.sidebar, {
    row = l.sidebar.row, col = l.sidebar.col,
    width = l.sidebar.width, height = l.sidebar.height,
    title = " Architect ", title_pos = "center",
  })
  api.nvim_win_set_option(wins.sidebar, "winhighlight",
    "Normal:ArchitectSidebarBg,FloatBorder:ArchitectBorder")

  -- Chat
  bufs.chat = create_buf()
  wins.chat = open_win(bufs.chat, {
    row = l.chat.row, col = l.chat.col,
    width = l.chat.width, height = l.chat.height,
    title = " Chat ", title_pos = "center",
  })
  api.nvim_win_set_option(wins.chat, "winhighlight",
    "Normal:ArchitectNormal,FloatBorder:ArchitectBorder")
  api.nvim_win_set_option(wins.chat, "wrap", true)

  -- Input
  bufs.input = create_buf()
  api.nvim_buf_set_option(bufs.input, "modifiable", true)
  wins.input = open_win(bufs.input, {
    row = l.input.row, col = l.input.col,
    width = l.input.width, height = l.input.height,
    title = " Message ", title_pos = "center",
  })
  api.nvim_win_set_option(wins.input, "winhighlight",
    "Normal:ArchitectNormal,FloatBorder:ArchitectBorder")

  is_open = true

  render_sidebar()
  render_step()

  -- Keymaps (only on input buffer)
  local function map(mode, key, fn, desc)
    vim.keymap.set(mode, key, fn, { buffer = bufs.input, silent = true, desc = desc })
  end

  map("n", "<CR>", send_message, "Send")
  map("i", "<CR>", function()
    vim.cmd("stopinsert")
    send_message()
  end, "Send")
  map({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    save_and_next()
  end, "Save and advance")
  map({ "n", "i" }, "<C-q>", M.close, "Close")
  map({ "n", "i" }, "<Esc>", M.close, "Close")

  focus_input()
end

function M.close()
  is_open      = false
  is_streaming = false
  memory.reset()
  for _, win in pairs(wins) do
    if type(win) == "number" and api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  wins = {}
  bufs = {}
end

function M.show_status()
  if not state then state = memory.load() end
  local step = steps_def.get(state.current_step)
  vim.notify(string.format(
    "[architect] Step %d/10: %s | Completed: %d",
    state.current_step, step.title, #(state.completed_steps or {})
  ), vim.log.levels.INFO)
end

return M
