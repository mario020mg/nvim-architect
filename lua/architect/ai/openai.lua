-- architect/ai/openai.lua
-- OpenAI API calls via curl with streaming.

local M = {}

local function get_config()
  return require("architect").config
end

local function parse_stream_chunk(chunk)
  local content = ""
  for line in chunk:gmatch("[^\n]+") do
    if line:sub(1, 6) == "data: " then
      local data = line:sub(7)
      if data == "[DONE]" then return content, true end
      local ok, parsed = pcall(vim.json.decode, data)
      if ok and parsed.choices and parsed.choices[1] then
        local delta = parsed.choices[1].delta
        if delta and delta.content then
          content = content .. delta.content
        end
      end
    end
  end
  return content, false
end

function M.has_ready_marker(text)
  return text and text:find("%[READY_TO_SAVE%]") ~= nil
end

-- Extract the data after [READY_TO_SAVE].
-- Returns: content string, is_json boolean
function M.extract_save_content(text)
  if not text then return nil, false end
  local after = text:match("%[READY_TO_SAVE%]%s*(.+)$")
  if not after then return nil, false end
  after = after:match("^%s*(.-)%s*$")

  -- Try to find a JSON block (```json ... ``` or bare {...})
  local json_str = after:match("```json%s*(.-)%s*```")
  if not json_str then
    json_str = after:match("```%s*(.-)%s*```")
  end
  if not json_str then
    -- Bare JSON starting with { or [
    json_str = after:match("^([%[{].+[%]}])$")
  end

  if json_str then
    return json_str, true
  end

  -- Plain text summary
  return after, false
end

-- Streaming chat via curl.
-- on_chunk(text)  called for each streamed piece
-- on_done(full_text, err)  called when finished
function M.chat(messages, system_prompt, on_chunk, on_done)
  local cfg = get_config()

  if cfg.openai_api_key == "" then
    on_done(nil, "OPENAI_API_KEY not configured.")
    return
  end

  local body = vim.json.encode({
    model    = cfg.model,
    stream   = true,
    messages = vim.list_extend(
      { { role = "system", content = system_prompt } },
      messages
    ),
  })

  local tmpfile = vim.fn.tempname()
  vim.fn.writefile({ body }, tmpfile)

  local full_response = ""
  local done_called   = false

  vim.system(
    {
      "curl", "-s", "-N",
      "https://api.openai.com/v1/chat/completions",
      "-H", "Authorization: Bearer " .. cfg.openai_api_key,
      "-H", "Content-Type: application/json",
      "-d", "@" .. tmpfile,
    },
    {
      stdout = function(err, chunk)
        if err or not chunk then return end
        local text, finished = parse_stream_chunk(chunk)
        if text ~= "" then
          full_response = full_response .. text
          vim.schedule(function() on_chunk(text) end)
        end
        if finished and not done_called then
          done_called = true
          vim.schedule(function()
            vim.fn.delete(tmpfile)
            on_done(full_response, nil)
          end)
        end
      end,
    },
    function(result)
      vim.schedule(function()
        vim.fn.delete(tmpfile)
        if not done_called then
          done_called = true
          if result.code ~= 0 and full_response == "" then
            on_done(nil, "curl error: " .. (result.stderr or "unknown"))
          else
            on_done(full_response, nil)
          end
        end
      end)
    end
  )
end

return M
