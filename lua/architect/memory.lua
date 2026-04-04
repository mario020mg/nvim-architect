-- architect/memory.lua
-- Persists project state to .nvim/architect/ and exports context.md to CWD.

local M = {}
local json = vim.json

local function get_root()
  return vim.fn.getcwd()
end

local function memory_dir()
  local cfg = require("architect").config
  return get_root() .. "/" .. cfg.memory_dir
end

local function ensure_dir()
  local dir = memory_dir()
  vim.fn.mkdir(dir, "p")
  -- Add .nvim/architect to .gitignore if not already there
  local gitignore = get_root() .. "/.gitignore"
  if vim.fn.filereadable(gitignore) == 1 then
    local content = table.concat(vim.fn.readfile(gitignore), "\n")
    if not content:find(".nvim/architect") then
      local f = io.open(gitignore, "a")
      if f then
        f:write("\n# Architect AI plugin memory\n.nvim/architect/\n")
        f:close()
      end
    end
  end
  return dir
end

local function default_state()
  return {
    current_step             = 1,
    completed_steps          = {},
    business_problem         = "",
    functional_requirements  = {},
    non_functional_requirements = {},
    system_type              = "",
    high_level_description   = "",
    language                 = "",
    framework                = "",
    database                 = "",
    infrastructure           = "",
    other_services           = {},
    entities                 = {},
    contracts                = {},
    file_structure           = "",
    file_descriptions        = {},
    implementation_notes     = "",
    test_strategy            = "",
    cicd_config              = "",
    conversations            = {},
  }
end

function M.load()
  local state_file = memory_dir() .. "/state.json"
  if vim.fn.filereadable(state_file) == 1 then
    local ok, content = pcall(table.concat, vim.fn.readfile(state_file), "\n")
    if ok and content ~= "" then
      local decoded = json.decode(content)
      if decoded then
        return vim.tbl_deep_extend("keep", decoded, default_state())
      end
    end
  end
  return default_state()
end

function M.save(state)
  local dir = ensure_dir()
  local ok, encoded = pcall(json.encode, state)
  if ok then
    vim.fn.writefile(vim.split(encoded, "\n"), dir .. "/state.json")
  end
end

function M.add_conversation(state, step, role, content)
  if not state.conversations then state.conversations = {} end
  local key = tostring(step)
  if not state.conversations[key] then state.conversations[key] = {} end
  table.insert(state.conversations[key], { role = role, content = content })
end

function M.get_conversation(state, step)
  if not state.conversations then return {} end
  return state.conversations[tostring(step)] or {}
end

-- Export context.md to project root + individual txt files to .nvim/architect/
-- Called after every step save so the AI always has fresh context.
function M.export_summary(state)
  local dir  = ensure_dir()
  local root = get_root()

  local function write(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(content, "\n"), path)
  end

  -- Individual files in .nvim/architect/
  if state.business_problem and state.business_problem ~= "" then
    write(dir .. "/business_problem.txt", state.business_problem)
  end

  local req_lines = { "# Functional Requirements" }
  for i, r in ipairs(state.functional_requirements or {}) do
    table.insert(req_lines, i .. ". " .. r)
  end
  table.insert(req_lines, "\n# Non-Functional Requirements")
  for i, r in ipairs(state.non_functional_requirements or {}) do
    table.insert(req_lines, i .. ". " .. r)
  end
  write(dir .. "/requirements.txt", table.concat(req_lines, "\n"))

  local tech_lines = {
    "# Tech Stack",
    "Language: "       .. (state.language or ""),
    "Framework: "      .. (state.framework or ""),
    "Database: "       .. (state.database or ""),
    "Infrastructure: " .. (state.infrastructure or ""),
    "Other: "          .. table.concat(state.other_services or {}, ", "),
  }
  write(dir .. "/tech_stack.txt", table.concat(tech_lines, "\n"))

  if state.file_structure and state.file_structure ~= "" then
    local struct_lines = { "# File Structure\n", state.file_structure, "\n# File Descriptions" }
    for path, desc in pairs(state.file_descriptions or {}) do
      table.insert(struct_lines, "\n## " .. path)
      table.insert(struct_lines, desc)
    end
    write(dir .. "/structure.txt", table.concat(struct_lines, "\n"))

    -- Create actual directories in the project root based on file_descriptions keys
    for filepath, _ in pairs(state.file_descriptions or {}) do
      local folder = (root .. "/" .. filepath):match("^(.*)/[^/]*$")
      if folder then vim.fn.mkdir(folder, "p") end
    end
  end

  -- Build context.md — written to project root so AI always reads it
  local ctx = { "# Project Context", "" }

  if state.business_problem and state.business_problem ~= "" then
    table.insert(ctx, "## Business Problem")
    table.insert(ctx, state.business_problem)
    table.insert(ctx, "")
  end

  if #(state.functional_requirements or {}) > 0 then
    table.insert(ctx, "## Functional Requirements")
    for _, r in ipairs(state.functional_requirements) do
      table.insert(ctx, "- " .. r)
    end
    table.insert(ctx, "")
  end

  if #(state.non_functional_requirements or {}) > 0 then
    table.insert(ctx, "## Non-Functional Requirements")
    for _, r in ipairs(state.non_functional_requirements) do
      table.insert(ctx, "- " .. r)
    end
    table.insert(ctx, "")
  end

  if state.high_level_description and state.high_level_description ~= "" then
    table.insert(ctx, "## Architecture")
    table.insert(ctx, state.high_level_description)
    table.insert(ctx, "")
  end

  if state.language and state.language ~= "" then
    table.insert(ctx, "## Tech Stack")
    table.insert(ctx, "- Language: "       .. state.language)
    table.insert(ctx, "- Framework: "      .. (state.framework or ""))
    table.insert(ctx, "- Database: "       .. (state.database or ""))
    table.insert(ctx, "- Infrastructure: " .. (state.infrastructure or ""))
    if #(state.other_services or {}) > 0 then
      table.insert(ctx, "- Other: " .. table.concat(state.other_services, ", "))
    end
    table.insert(ctx, "")
  end

  if #(state.entities or {}) > 0 then
    table.insert(ctx, "## Domain Entities")
    for _, e in ipairs(state.entities) do
      table.insert(ctx, "### " .. e.name)
      if e.description and e.description ~= "" then
        table.insert(ctx, e.description)
      end
      for _, f in ipairs(e.fields or {}) do
        table.insert(ctx, "- " .. f)
      end
    end
    table.insert(ctx, "")
  end

  if #(state.contracts or {}) > 0 then
    table.insert(ctx, "## Contracts")
    for _, c in ipairs(state.contracts) do
      table.insert(ctx, "### " .. c.name)
      table.insert(ctx, "- Input: "       .. (c.input or ""))
      table.insert(ctx, "- Output: "      .. (c.output or ""))
      table.insert(ctx, "- Description: " .. (c.description or ""))
    end
    table.insert(ctx, "")
  end

  if state.file_structure and state.file_structure ~= "" then
    table.insert(ctx, "## File Structure")
    table.insert(ctx, "```")
    table.insert(ctx, state.file_structure)
    table.insert(ctx, "```")
    table.insert(ctx, "")
  end

  if state.implementation_notes and state.implementation_notes ~= "" then
    table.insert(ctx, "## Implementation Notes")
    table.insert(ctx, state.implementation_notes)
    table.insert(ctx, "")
  end

  if state.test_strategy and state.test_strategy ~= "" then
    table.insert(ctx, "## Test Strategy")
    table.insert(ctx, state.test_strategy)
    table.insert(ctx, "")
  end

  -- Write context.md to project root
  write(root .. "/context.md", table.concat(ctx, "\n"))

  return dir
end

function M.reset()
  local state = default_state()
  M.save(state)
  -- Remove context.md from project root on reset
  local ctx_file = get_root() .. "/context.md"
  if vim.fn.filereadable(ctx_file) == 1 then
    vim.fn.delete(ctx_file)
  end
  return state
end

return M
