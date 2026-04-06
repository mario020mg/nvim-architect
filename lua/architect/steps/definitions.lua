-- architect/steps/definitions.lua

local M = {}

local RULES = [[
RULES (always follow):
- Be extremely concise. No long explanations.
- Read the PROJECT CONTEXT carefully before responding.
- Always propose immediately. Never ask for confirmation.
- If the user says "no", "none", "no preference", or anything similar: propose a sensible default immediately.
- If the user types a correction, adjust and propose again.
- Always end your response with [READY_TO_SAVE] followed by the data. Every single response must end with this.
- Never ask "do you accept?", "does this work?", or any confirmation question. Ever.
]]

M.steps = {
  {
    id       = 1,
    title    = "Business Problem",
    icon     = "󰭾",
    question = "What problem does this app solve, and for whom?",
    state_key = "business_problem",
    type     = "text",
    system_prompt = RULES .. [[
Step 1: Business problem.
The user has just described the problem. Write a 2-3 sentence summary they can accept immediately.
If unclear, make a reasonable assumption and note it in one line.
End with:
[READY_TO_SAVE]
<the summary>]],
    save_action = function(state, content)
      state.business_problem = content
    end,
  },
  {
    id       = 2,
    title    = "Requirements",
    icon     = "󰄬",
    question = "Any specific requirements to add? (or just press Enter to get a proposal)",
    state_key = "requirements",
    type     = "structured",
    system_prompt = RULES .. [[
Step 2: Requirements.
Based on the PROJECT CONTEXT, immediately propose a minimal list of functional and non-functional requirements.
User can say "add X", "remove Y", or just agree.
When agreed:
[READY_TO_SAVE]
{"functional":["..."],"non_functional":["..."]}]],
    save_action = function(state, content)
      local ok, parsed = pcall(vim.json.decode, content)
      if ok and parsed then
        state.functional_requirements   = parsed.functional or {}
        state.non_functional_requirements = parsed.non_functional or {}
      end
    end,
  },
  {
    id       = 3,
    title    = "High-Level Design",
    icon     = "󰋊",
    question = "Any architecture preference? (or just press Enter to get a proposal)",
    state_key = "high_level_description",
    type     = "text",
    system_prompt = RULES .. [[
Step 3: High-level design.
Based on the PROJECT CONTEXT, propose the simplest fitting architecture in max 3 lines.
When agreed:
[READY_TO_SAVE]
<summary>]],
    save_action = function(state, content)
      state.high_level_description = content
      for _, t in ipairs({ "monolith", "microservices", "event-driven", "REST", "GraphQL" }) do
        if content:lower():find(t:lower()) then
          state.system_type = t
          break
        end
      end
    end,
  },
  {
    id       = 4,
    title    = "Tech Stack",
    icon     = "󰏗",
    question = "Any tech preferences? (or just press Enter to get a proposal)",
    state_key = "language",
    type     = "structured",
    system_prompt = RULES .. [[
Step 4: Tech stack.
Based on the PROJECT CONTEXT, propose the best fitting stack. No justification unless asked.
When agreed:
[READY_TO_SAVE]
{"language":"","framework":"","database":"","infrastructure":"","other_services":[]}]],
    save_action = function(state, content)
      local ok, parsed = pcall(vim.json.decode, content)
      if ok and parsed then
        state.language       = parsed.language or ""
        state.framework      = parsed.framework or ""
        state.database       = parsed.database or ""
        state.infrastructure = parsed.infrastructure or ""
        state.other_services = parsed.other_services or {}
      end
    end,
  },
  {
    id       = 5,
    title    = "Domain Model",
    icon     = "󰆧",
    question = "Any specific entities you need? (or just press Enter to get a proposal)",
    state_key = "entities",
    type     = "structured",
    system_prompt = RULES .. [[
Step 5: Domain model.
Based on the PROJECT CONTEXT, list the core entities with their key fields. Be minimal.
When agreed:
[READY_TO_SAVE]
{"entities":[{"name":"","description":"","fields":["field: type"]}]}]],
    save_action = function(state, content)
      local ok, parsed = pcall(vim.json.decode, content)
      if ok and parsed then
        state.entities = parsed.entities or {}
      end
    end,
  },
  {
    id       = 6,
    title    = "Contracts",
    icon     = "󰘓",
    question = "Any specific functions or endpoints? (or just press Enter to get a proposal)",
    state_key = "contracts",
    type     = "structured",
    system_prompt = RULES .. [[
Step 6: Contracts.
Based on the PROJECT CONTEXT, define input/output for each key function or endpoint. No implementation details.
When agreed:
[READY_TO_SAVE]
{"contracts":[{"name":"","input":"","output":"","description":""}]}]],
    save_action = function(state, content)
      local ok, parsed = pcall(vim.json.decode, content)
      if ok and parsed then
        state.contracts = parsed.contracts or {}
      end
    end,
  },
  {
    id       = 7,
    title    = "File Structure",
    icon     = "󰉋",
    question = "Any folder structure preferences? (or just press Enter to get a proposal)",
    state_key = "file_structure",
    type     = "structured",
    system_prompt = RULES .. [[
Step 7: File structure.
Based on the PROJECT CONTEXT, propose a folder tree for the project root.

CRITICAL: Every single response — including the very first one — must end with BOTH:
1. A human-readable ASCII tree for display
2. The [READY_TO_SAVE] block with the JSON immediately after

Do NOT wait for the user to agree before outputting [READY_TO_SAVE]. Output it every time.
Do NOT put the tree inside the JSON. The tree is for display only.

Format your response exactly like this:
<ASCII tree here>

[READY_TO_SAVE]
{"tree":"<same folder tree as a single string with \n for newlines>","descriptions":{"relative/path/to/file.js":"one line description"}}

The "descriptions" object must use relative paths (no leading slash, no absolute paths).
Every file in the tree must have an entry in "descriptions".
]],
    save_action = function(state, content)
      local ok, parsed = pcall(vim.json.decode, content)
      if ok and parsed and type(parsed) == "table" then
        state.file_structure    = parsed.tree or ""
        state.file_descriptions = parsed.descriptions or {}
        return
      end

      -- Fallback: JSON failed, try to extract file paths from the raw tree text
      -- Matches lines ending in .ext optionally followed by // comment
      local descriptions = {}
      for line in content:gmatch("[^\n]+") do
        -- Extract relative paths like src/models/User.js
        local filepath = line:match("([%w_%-]+/[%w_%.%-/]+%.[%w]+)")
        if filepath then
          -- Grab inline comment if present
          local desc = line:match("//%s*(.+)$") or "no description"
          descriptions[filepath] = desc:match("^%s*(.-)%s*$")
        end
      end

      state.file_structure    = content
      state.file_descriptions = descriptions
    end,
  },
  {
    id       = 8,
    title    = "Implementation",
    icon     = "󰅱",
    question = "Type 'start' to begin implementation file by file.",
    state_key = "implementation_notes",
    type     = "code",
    system_prompt = RULES .. [[
Step 8: Implementation.
Work file by file inside the PROJECT DIRECTORY from the context.
For each file:
1. Show filename and full code
2. Ask: "Apply? [yes/no]"
Only write the next file after the user confirms.
When all files are done:
[READY_TO_SAVE]
<one-line summary of what was created>]],
    save_action = function(state, content)
      state.implementation_notes = content
    end,
  },
  {
    id       = 9,
    title    = "Tests",
    icon     = "󰙨",
    question = "Type 'start' to generate tests based on the contracts.",
    state_key = "test_strategy",
    type     = "code",
    system_prompt = RULES .. [[
Step 9: Tests.
Based on the contracts in PROJECT CONTEXT, generate test files in the project directory.
Show each file and ask: "Apply? [yes/no]"
When done:
[READY_TO_SAVE]
<one-line test strategy summary>]],
    save_action = function(state, content)
      state.test_strategy = content
    end,
  },
  {
    id       = 10,
    title    = "CI/CD",
    icon     = "󰉦",
    question = "Type 'start' to generate the CI/CD pipeline config.",
    state_key = "cicd_config",
    type     = "code",
    system_prompt = RULES .. [[
Step 10: CI/CD.
Based on the PROJECT CONTEXT, propose a minimal pipeline config file.
Show the file and ask: "Apply? [yes/no]"
When done:
[READY_TO_SAVE]
<one-line summary>]],
    save_action = function(state, content)
      state.cicd_config = content
    end,
  },
}

function M.get(id)
  return M.steps[id]
end

-- Always reads context.md from project root first, then supplements with live state.
function M.get_context(state)
  local parts = {}

  local ctx_file = vim.fn.getcwd() .. "/context.md"
  if vim.fn.filereadable(ctx_file) == 1 then
    local lines = vim.fn.readfile(ctx_file)
    if #lines > 0 then
      table.insert(parts, "CONTEXT FILE (context.md):\n" .. table.concat(lines, "\n"))
    end
  end

  -- Supplement with live state fields not yet flushed to context.md
  if state.language and state.language ~= "" then
    table.insert(parts, "TECH STACK: " .. state.language
      .. " / " .. (state.framework or "")
      .. " / " .. (state.database or ""))
  end
  if state.file_structure and state.file_structure ~= "" then
    table.insert(parts, "FILE STRUCTURE:\n" .. state.file_structure)
  end
  if #(state.contracts or {}) > 0 then
    local c = {}
    for _, contract in ipairs(state.contracts) do
      table.insert(c, contract.name .. ": "
        .. (contract.input or "") .. " -> " .. (contract.output or ""))
    end
    table.insert(parts, "CONTRACTS:\n" .. table.concat(c, "\n"))
  end

  table.insert(parts, "PROJECT DIRECTORY: " .. vim.fn.getcwd())

  return table.concat(parts, "\n\n")
end

return M
