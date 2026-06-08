-- Citum LuaLaTeX adapter.
--
-- This file intentionally has no FFI backend. LuaLaTeX talks to the Rust
-- engine by spawning citum-server once per LaTeX pass and sending one
-- format_document JSON-RPC request over stdin/stdout.

local CITUM = {}

CITUM.document_citations = {}
CITUM.document_bibliography_blocks = {}
CITUM.cached_results = {
    citations = {},
    bibliography = "",
    bibliography_blocks = {},
}
CITUM.citation_index = 0
CITUM.bibliography_block_index = 0
CITUM.config = { server_path = nil, jobname = "texput", backend = "pipe" }

local json
do
    local ok, res = pcall(require, "citum_json")
    if ok and res then
        json = res
    else
        ok, res = pcall(require, "citum.citum_json")
        if ok and res then
            json = res
        else
            ok, res = pcall(require, "utilities.json")
            if ok and res then
                json = res
            end
        end
    end
end

if not json then
    error("citum: cannot load a JSON module")
end

local function json_encode(value)
    local encode = json.tostring or json.encode
    local ok, encoded = pcall(encode, value)
    if not ok then error("citum: failed to encode JSON: " .. tostring(encoded)) end
    return encoded
end

local function json_decode(value)
    local decode = json.tolua or json.decode
    local ok, decoded = pcall(decode, value)
    if not ok then error("citum: failed to decode JSON: " .. tostring(decoded)) end
    return decoded
end

local function shell_quote(path)
    return '"' .. tostring(path):gsub('"', '\\"') .. '"'
end

local function find_server_binary()
    local explicit = CITUM.config.server_path or os.getenv("CITUM_SERVER_PATH")
    if explicit and explicit ~= "" then return explicit end
    local ok = os.execute("citum-server --version >/dev/null 2>&1")
    if ok == true or ok == 0 then return "citum-server" end
    return nil
end

local function pipe_request(server_path, payload)
    local tmpfile = CITUM.config.jobname .. ".citum_rpc_in.json"
    local f, err = io.open(tmpfile, "w")
    if not f then
        return nil, "cannot create RPC input file: " .. tostring(err)
    end
    f:write(payload)
    f:write("\n")
    f:close()

    local cmd = shell_quote(server_path) .. " < " .. shell_quote(tmpfile) .. " 2>/dev/null"
    local pipe = io.popen(cmd, "r")
    if not pipe then
        os.remove(tmpfile)
        return nil, "failed to spawn citum-server"
    end

    local response = pipe:read("*l")
    pipe:close()
    os.remove(tmpfile)

    if not response or response == "" then
        return nil, "citum-server returned no output"
    end
    return response
end

function CITUM.load_cache(jobname)
    CITUM.config.jobname = jobname
    CITUM.citation_index = 0
    CITUM.bibliography_block_index = 0
    CITUM.document_citations = {}
    CITUM.document_bibliography_blocks = {}
    local f = io.open(jobname .. ".citum.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        local data = json_decode(content)
        if data then CITUM.cached_results = data end
    end
end

function CITUM.save_cache(data)
    local f = io.open(CITUM.config.jobname .. ".citum.json", "w")
    if f then
        f:write(json_encode(data))
        f:close()
    end
end

local function cache_from_result(result)
    local cached = { citations = {}, bibliography = "", bibliography_blocks = {} }
    for _, citation in ipairs(result.formatted_citations or {}) do
        table.insert(cached.citations, citation.text or "")
    end
    local bibliography = result.bibliography
    cached.bibliography = (type(bibliography) == "table" and bibliography.content) or bibliography or ""
    cached.bibliography_blocks = result.bibliography_blocks or {}
    return cached
end

local function consume_response_file(jobname)
    local response_path = jobname .. ".citum_response.json"
    local f = io.open(response_path, "r")
    if not f then return false end
    local response = f:read("*a")
    f:close()
    if not response or response == "" then return false end

    local data = json_decode(response)
    if data and data.error then
        error("citum: citum-server error: " .. tostring(data.error))
    end
    if not data or not data.result then
        error("citum: malformed citum-server response in " .. response_path)
    end
    CITUM.cached_results = cache_from_result(data.result)
    CITUM.save_cache(CITUM.cached_results)
    return true
end

function CITUM.parse_locator(s)
    if not s or s == "" then return nil, nil end
    local labels = {
        ["p."] = "page",
        ["pp."] = "page",
        ["f."] = "page",
        ["ff."] = "page",
        ["ch."] = "chapter",
        ["vol."] = "volume",
        ["sect."] = "section",
        ["§"] = "section",
    }
    for prefix, label in pairs(labels) do
        if s:sub(1, #prefix) == prefix then
            return label, s:sub(#prefix + 1):gsub("^[%s~]+", "")
        end
    end
    if s:match("^%d") then return "page", s end
    return nil, s
end

function CITUM.record_cite(cite_opts)
    table.insert(CITUM.document_citations, cite_opts)
    CITUM.citation_index = CITUM.citation_index + 1
    local rendered = (CITUM.cached_results.citations or {})[CITUM.citation_index]
    if rendered then
        tex.sprint(rendered)
    else
        tex.sprint("\\textbf{[?]}")
    end
end

function CITUM.split_keys(s)
    local keys = {}
    for key in s:gmatch("([^,%s]+)") do
        table.insert(keys, key)
    end
    return keys
end

CITUM.cites_items = {}

local function make_citation_item(raw_loc, key)
    local label, locator = CITUM.parse_locator(raw_loc)
    local item = { id = key }
    if label and locator then
        item.locator = { label = label, value = locator }
    elseif locator then
        item.prefix = locator
    end
    return item
end

function CITUM.cites_start()
    CITUM.cites_items = {}
end

function CITUM.cites_add(raw_loc, key)
    table.insert(CITUM.cites_items, make_citation_item(raw_loc, key))
end

function CITUM.cites_flush(_proc)
    CITUM.record_cite({ items = CITUM.cites_items })
end

function CITUM.cites_flush_integral(_proc)
    CITUM.record_cite({ mode = "integral", items = CITUM.cites_items })
end

function CITUM.cites_flush_sentence_start(_proc)
    CITUM.record_cite({ sentence_start = true, items = CITUM.cites_items })
end

function CITUM.cites_flush_integral_sentence_start(_proc)
    CITUM.record_cite({ mode = "integral", sentence_start = true, items = CITUM.cites_items })
end

function CITUM.cite_single(_proc, raw_loc, key)
    CITUM.record_cite({ items = { make_citation_item(raw_loc, key) } })
end

function CITUM.textcite_single(_proc, raw_loc, key)
    CITUM.record_cite({ mode = "integral", items = { make_citation_item(raw_loc, key) } })
end

function CITUM.Cite_single(proc, raw_loc, key)
    CITUM.cite_single(proc, raw_loc, key)
    local c = CITUM.document_citations[#CITUM.document_citations]
    c.sentence_start = true
end

function CITUM.Textcite_single(proc, raw_loc, key)
    CITUM.textcite_single(proc, raw_loc, key)
    local c = CITUM.document_citations[#CITUM.document_citations]
    c.sentence_start = true
end

function CITUM.cite_keys(_proc, keys_str)
    local items = {}
    for _, key in ipairs(CITUM.split_keys(keys_str)) do
        table.insert(items, { id = key })
    end
    CITUM.record_cite({ items = items })
end

function CITUM.textcite_keys(_proc, keys_str)
    local items = {}
    for _, key in ipairs(CITUM.split_keys(keys_str)) do
        table.insert(items, { id = key })
    end
    CITUM.record_cite({ mode = "integral", items = items })
end

function CITUM.Cite_keys(proc, keys_str)
    CITUM.cite_keys(proc, keys_str)
    local c = CITUM.document_citations[#CITUM.document_citations]
    c.sentence_start = true
end

function CITUM.Textcite_keys(proc, keys_str)
    CITUM.textcite_keys(proc, keys_str)
    local c = CITUM.document_citations[#CITUM.document_citations]
    c.sentence_start = true
end

local function parse_bibliography_filter(opts)
    if not opts or opts == "" then return nil end
    local ref_type = opts:match("^type=([%w%-%_]+)$")
    if ref_type then
        return { ["type"] = ref_type }
    end
    local not_type = opts:match("^not%-type=([%w%-%_]+)$")
    if not_type then
        return { ["not"] = { ["type"] = not_type } }
    end
    error("citum: unsupported bibliography filter '" .. opts .. "'")
end

function CITUM.print_bibliography(_proc, opts_str)
    if not opts_str or opts_str == "" then
        local bib = CITUM.cached_results.bibliography
        if bib and bib ~= "" then
            tex.sprint(bib)
        else
            tex.sprint("\\PackageWarning{citum}{Bibliography not yet rendered. Rerun LaTeX.}")
        end
        return
    end

    CITUM.bibliography_block_index = CITUM.bibliography_block_index + 1
    local block_id = "bib-" .. CITUM.bibliography_block_index
    table.insert(CITUM.document_bibliography_blocks, {
        id = block_id,
        group = {
            id = block_id,
            selector = parse_bibliography_filter(opts_str),
        },
    })

    local block = (CITUM.cached_results.bibliography_blocks or {})[CITUM.bibliography_block_index]
    if block and block.content and block.content ~= "" then
        tex.sprint(block.content)
    else
        tex.sprint("\\PackageWarning{citum}{Bibliography block not yet rendered. Rerun LaTeX.}")
    end
end

local function citation_occurrences()
    local out = {}
    for i, citation in ipairs(CITUM.document_citations) do
        citation.id = citation.id or ("cite-" .. i)
        table.insert(out, citation)
    end
    return out
end

function CITUM.process_document(_proc, style_path, bib_path, locale)
    if not bib_path or bib_path == "" then
        error("citum: no bibliography file specified. Use bibfile=... or \\addbibresource{...}.")
    end
    local params = {
        style = { kind = "path", value = style_path },
        refs = { kind = "path", value = bib_path },
        output_format = "latex",
        citations = citation_occurrences(),
        bibliography_blocks = CITUM.document_bibliography_blocks,
    }
    if locale and locale ~= "" then params.locale = locale end

    local request = { jsonrpc = "2.0", id = 1, method = "format_document", params = params }
    local payload = json_encode(request)
    local request_path = CITUM.config.jobname .. ".citum_request.json"
    local rf = io.open(request_path, "w")
    if rf then
        rf:write(payload)
        rf:write("\n")
        rf:close()
    end
    if CITUM.config.backend == "external" then
        texio.write_nl("Package citum Info: wrote " .. request_path .. " for external citum-server run.")
        return
    end
    if os.getenv("CITUM_DEBUG_RPC") then
        local sf = io.open(CITUM.config.jobname .. ".citum_server.txt", "w")
        if sf then
            sf:write(tostring(CITUM.config.server_path))
            sf:write("\n")
            sf:close()
        end
        local f = io.open(request_path, "w")
        if f then
            f:write(payload)
            f:write("\n")
            f:close()
        end
    end
    local response, err = pipe_request(CITUM.config.server_path, payload)
    if not response then
        texio.write_nl("Package citum Warning: pipe error: " .. tostring(err))
        return
    end
    if os.getenv("CITUM_DEBUG_RPC") then
        local f = io.open(CITUM.config.jobname .. ".citum_response.json", "w")
        if f then
            f:write(response)
            f:write("\n")
            f:close()
        end
    end

    local data = json_decode(response)
    if data and data.error then
        error("citum: citum-server error: " .. tostring(data.error))
    end
    if not data or not data.result then
        error("citum: malformed citum-server response")
    end
    local cached = cache_from_result(data.result)
    CITUM.save_cache(cached)

    local changed = false
    if #cached.citations ~= #(CITUM.cached_results.citations or {}) then
        changed = true
    else
        for i, text in ipairs(cached.citations) do
            if text ~= CITUM.cached_results.citations[i] then changed = true end
        end
    end
    if cached.bibliography ~= CITUM.cached_results.bibliography then changed = true end
    if changed then
        tex.print("\\PackageWarningNoLine{citum}{Citation(s) may have changed. Rerun to get cross-references right}")
    end
end

function CITUM.init_processor(_style_opt, _bibfile, _locale_opt, jobname, server_path_opt, backend_opt)
    CITUM.load_cache(jobname)
    local env_backend = os.getenv("CITUM_BACKEND")
    if backend_opt and backend_opt ~= "" then
        CITUM.config.backend = backend_opt
    elseif env_backend and env_backend ~= "" then
        CITUM.config.backend = env_backend
    else
        CITUM.config.backend = "pipe"
    end
    if CITUM.config.backend ~= "pipe" and CITUM.config.backend ~= "external" then
        error("citum: unsupported backend '" .. tostring(CITUM.config.backend) .. "'")
    end
    local env_server = os.getenv("CITUM_SERVER_PATH")
    if server_path_opt and server_path_opt ~= "" and server_path_opt ~= "citum-server" then
        CITUM.config.server_path = server_path_opt
    elseif env_server and env_server ~= "" then
        CITUM.config.server_path = env_server
    else
        CITUM.config.server_path = find_server_binary()
    end
    if not CITUM.config.server_path then
        error("citum: citum-server not found. Install citum-server, set CITUM_SERVER_PATH, or pass server=/path/to/citum-server.")
    end
    if CITUM.config.backend == "external" then
        consume_response_file(jobname)
    end
    return { server = CITUM.config.server_path, backend = CITUM.config.backend }
end

return CITUM
