--[[
    ScriptFinder v2 — Studio-style script browser, global search & editor
    Run in an executor with decompile()/getscriptbytecode() support.
    Made in collaboration with Claude

    Features
      • Explorer panel (grouped by service) / Find Results with per-line hits
      • Name filter (Explorer) + "find in this script" filter (editor)
      • Server-side scripts are excluded (ServerScriptService, ServerStorage,
        and Script objects whose RunContext isn't Client)
      • Script tabs, syntax highlighting (Studio dark palette), search-term highlighting
      • Full scrollable + editable editor with line numbers, caret and Ln/Col
      • Drag, resize (bottom-right grip), maximize (button or double-click title),
        minimize, and a draggable splitter between Explorer and editor

    Hotkeys
      Ctrl+Shift+F  show / hide window       F5        re-index
      F3 / Enter    next match               Shift+F3  previous match
      Ctrl+S        save active tab
]]

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextService      = game:GetService("TextService")
local RunService       = game:GetService("RunService")

local player = Players.LocalPlayer

-- ================= CONFIG =================
local INCLUDE_PLAYER_SCRIPTS = false   -- true = also index PlayerScripts
local CHUNK_LINES     = 120            -- lines per highlighted text label
local MAX_EDIT_CHARS  = 190000         -- bigger scripts open read-only
local MAX_RESULT_ROWS = 400            -- cap on rows in the left panel
local CODE_FONT, CODE_SIZE = Enum.Font.RobotoMono, 14
local UI_FONT, UI_BOLD     = Enum.Font.SourceSans, Enum.Font.SourceSansSemibold
local PAD    = 6
local TOP, RIBBON, STATUS = 28, 34, 22
local GUT_W  = 56
local MINW, MINH = 560, 320

-- ================= THEME (Studio dark) =================
local C = {
    window   = Color3.fromRGB(46, 46, 46),
    titlebar = Color3.fromRGB(37, 37, 37),
    ribbon   = Color3.fromRGB(53, 53, 53),
    header   = Color3.fromRGB(53, 53, 53),
    panel    = Color3.fromRGB(46, 46, 46),
    editor   = Color3.fromRGB(37, 37, 37),
    border   = Color3.fromRGB(26, 26, 26),
    input    = Color3.fromRGB(37, 37, 37),
    button   = Color3.fromRGB(60, 60, 60),
    buttonHi = Color3.fromRGB(75, 75, 75),
    hover    = Color3.fromRGB(66, 66, 66),
    select   = Color3.fromRGB(11, 90, 175),
    accent   = Color3.fromRGB(0, 162, 255),
    text     = Color3.fromRGB(204, 204, 204),
    dim      = Color3.fromRGB(140, 140, 140),
    lineNum  = Color3.fromRGB(110, 110, 110),
    match    = Color3.fromRGB(255, 153, 0),
}
local SYN = {
    keyword  = "#F86D7C", self    = "#F86D7C",
    bool     = "#FFC600", number  = "#FFC600",
    string   = "#ADF195", comment = "#666666",
    builtin  = "#84D6F7", func    = "#FDFBAC",
    property = "#61A1F1",
}
local MARK_OPEN, MARK_CLOSE = '<mark color="#8A7000" transparency="0.2">', '</mark>'

-- ================= HELPERS =================
local conns = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    conns[#conns + 1] = c
    return c
end

local function new(class, props)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then o[k] = v end
    end
    if props and props.Parent then o.Parent = props.Parent end
    return o
end

local function stroke(o, color)
    return new("UIStroke", {
        Color = color, Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = o,
    })
end

local function label(props)
    local p = {
        BackgroundTransparency = 1, BorderSizePixel = 0, Font = UI_FONT, TextSize = 14,
        TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left,
    }
    for k, v in pairs(props) do p[k] = v end
    return new("TextLabel", p)
end

local function toolButton(text, size, pos, parent)
    local b = new("TextButton", {
        Text = text, Size = size, Position = pos, BackgroundColor3 = C.button,
        BorderSizePixel = 0, AutoButtonColor = false, Font = UI_FONT, TextSize = 14,
        TextColor3 = C.text, Parent = parent,
    })
    stroke(b, C.border)
    b.MouseEnter:Connect(function() b.BackgroundColor3 = C.buttonHi end)
    b.MouseLeave:Connect(function()
        b.BackgroundColor3 = b:GetAttribute("on") and C.select or C.button
    end)
    return b
end

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }
local function esc(s)
    return (string.gsub(s, "[&<>\"']", ESC))
end

-- icons are drawn from plain Frames, so they never depend on a sprite sheet
local ICONS = {
    LocalScript  = { color = Color3.fromRGB(0, 162, 255),   letter = "L" },
    ModuleScript = { color = Color3.fromRGB(170, 110, 230), letter = "M" },
    Script       = { color = Color3.fromRGB(80, 190, 110),  letter = "S" },
}
local function classIcon(class, parent, x, y)
    local holder = new("Frame", {
        Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(x, y),
        BackgroundTransparency = 1, Parent = parent,
    })
    if class == "Folder" then
        local tab = new("Frame", {
            Position = UDim2.fromOffset(1, 2), Size = UDim2.fromOffset(7, 4),
            BackgroundColor3 = Color3.fromRGB(196, 158, 70), BorderSizePixel = 0, Parent = holder,
        })
        new("UICorner", { CornerRadius = UDim.new(0, 1), Parent = tab })
        local bodyF = new("Frame", {
            Position = UDim2.fromOffset(1, 4), Size = UDim2.fromOffset(14, 10),
            BackgroundColor3 = Color3.fromRGB(230, 190, 95), BorderSizePixel = 0, Parent = holder,
        })
        new("UICorner", { CornerRadius = UDim.new(0, 2), Parent = bodyF })
        return holder
    end
    local spec = ICONS[class] or ICONS.Script
    local page = new("Frame", {
        Position = UDim2.fromOffset(2, 1), Size = UDim2.fromOffset(12, 14),
        BackgroundColor3 = spec.color, BorderSizePixel = 0, Parent = holder,
    })
    new("UICorner", { CornerRadius = UDim.new(0, 2), Parent = page })
    new("TextLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = spec.letter,
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = Color3.new(1, 1, 1), Parent = page,
    })
    return holder
end

-- ================= ROOT GUI =================
local parentGui = (gethui and gethui()) or player:WaitForChild("PlayerGui")
local old = parentGui:FindFirstChild("ScriptFinder")
if old then old:Destroy() end

local gui = new("ScreenGui", {
    Name = "ScriptFinder", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 50, Parent = parentGui,
})

-- measure the monospace font so the editable box and the highlight layer line up
local charW, lineH
do
    local probe = label({
        TextTransparency = 1, Font = CODE_FONT, TextSize = CODE_SIZE,
        Size = UDim2.fromOffset(1, 1), TextYAlignment = Enum.TextYAlignment.Top,
        Text = string.rep("M", 200), Parent = gui,
    })
    task.wait(); task.wait()
    charW = probe.TextBounds.X / 200
    probe.Text = string.rep("M\n", 199) .. "M"
    task.wait(); task.wait()
    lineH = probe.TextBounds.Y / 200
    probe:Destroy()
    if not charW or charW <= 0 then
        charW = TextService:GetTextSize(string.rep("M", 200), CODE_SIZE, CODE_FONT, Vector2.new(1e6, 1e6)).X / 200
    end
    if not lineH or lineH <= 0 then lineH = CODE_SIZE end
end

-- ================= LEXER / HIGHLIGHTER =================
local KEYWORDS, BUILTINS = {}, {}
for w in ("and break do else elseif end for function if in local not or repeat return then until while continue"):gmatch("%S+") do
    KEYWORDS[w] = true
end
for w in ([[game workspace script plugin shared _G _VERSION print warn error assert pcall xpcall require
    typeof type tostring tonumber pairs ipairs next select unpack rawget rawset rawequal rawlen
    setmetatable getmetatable tick time wait delay spawn elapsedTime math string table task coroutine
    os debug utf8 bit32 buffer Instance Vector2 Vector3 Vector2int16 Vector3int16 CFrame Color3 UDim
    UDim2 Enum Ray Rect BrickColor TweenInfo NumberSequence NumberSequenceKeypoint NumberRange
    ColorSequence ColorSequenceKeypoint Random Region3 DateTime Axes Faces PhysicalProperties
    OverlapParams RaycastParams Font]]):gmatch("%S+") do
    BUILTINS[w] = true
end

-- returns { {startIndex, endIndex, kind|nil}, ... } covering the whole source
local function tokenize(src)
    local toks, n, i = {}, #src, 1
    local prevSig = ""
    local function add(s, e, kind) toks[#toks + 1] = { s, e, kind } end

    while i <= n do
        local c = string.byte(src, i)

        -- whitespace
        local _, we = string.find(src, "^%s+", i)
        if we then add(i, we, nil); i = we + 1; continue end

        -- comments
        if c == 45 and string.byte(src, i + 1) == 45 then
            local e
            local eqs = string.match(src, "^%[(=*)%[", i + 2)
            if eqs then
                local _, ce = string.find(src, "]" .. eqs .. "]", i + 4 + #eqs, true)
                e = ce or n
            else
                e = (string.find(src, "\n", i, true) or n + 1) - 1
            end
            add(i, e, "comment"); i = e + 1; continue
        end

        -- long strings [[ ]] / [=[ ]=]
        if c == 91 then
            local eqs = string.match(src, "^%[(=*)%[", i)
            if eqs then
                local _, ce = string.find(src, "]" .. eqs .. "]", i + 2 + #eqs, true)
                local e = ce or n
                add(i, e, "string"); i = e + 1; prevSig = "str"; continue
            end
        end

        -- quoted strings " ' `
        if c == 34 or c == 39 or c == 96 then
            local j = i + 1
            while j <= n do
                local d = string.byte(src, j)
                if d == 92 then j += 2
                elseif d == c then break
                elseif d == 10 then j -= 1; break
                else j += 1 end
            end
            local e = math.min(j, n)
            add(i, e, "string"); i = e + 1; prevSig = "str"; continue
        end

        -- numbers
        if (c >= 48 and c <= 57) or (c == 46 and string.find(src, "^%.%d", i)) then
            local _, e = string.find(src, "^0[xXbB][%x_]*", i)
            if not e then
                _, e = string.find(src, "^[%d_]*%.?[%d_]*", i)
                local _, ee = string.find(src, "^[eE][%+%-]?%d+", e + 1)
                if ee then e = ee end
            end
            add(i, e, "number"); i = e + 1; prevSig = "num"; continue
        end

        -- identifiers / keywords
        local s, e = string.find(src, "^[%a_][%w_]*", i)
        if s then
            local word = string.sub(src, s, e)
            local kind
            if word == "true" or word == "false" or word == "nil" then
                kind = "bool"
            elseif KEYWORDS[word] then
                kind = "keyword"
            elseif word == "self" then
                kind = "self"
            else
                local nextc = string.match(src, "^%s*(.)", e + 1)
                if prevSig == "." or prevSig == ":" then
                    kind = (nextc == "(") and "func" or "property"
                elseif BUILTINS[word] then
                    kind = "builtin"
                elseif prevSig == "function" or nextc == "(" then
                    kind = "func"
                end
            end
            add(s, e, kind); i = e + 1; prevSig = word; continue
        end

        -- multi-byte UTF-8 runs stay together
        if c >= 128 then
            local _, ue = string.find(src, "^[\128-\255]+", i)
            add(i, ue, nil); i = ue + 1; continue
        end

        -- operators / punctuation (default text colour)
        add(i, i, nil); prevSig = string.sub(src, i, i); i += 1
    end
    return toks
end

-- case-(in)sensitive plain search; returns sorted { {s, e}, ... }
local matchCase = false
local function findAll(src, term)
    local list = {}
    if term == "" then return list end
    local hay    = matchCase and src or string.lower(src)
    local needle = matchCase and term or string.lower(term)
    local pos = 1
    while #list < 5000 do
        local s, e = string.find(hay, needle, pos, true)
        if not s then break end
        list[#list + 1] = { s, e }
        pos = e + 1
    end
    return list
end

-- turns source into an array of RichText lines (syntax colours + <mark> on matches)
local function buildLines(src, matches)
    local toks = tokenize(src)
    local nls = {}
    do
        local p = 0
        while true do
            p = string.find(src, "\n", p + 1, true)
            if not p then break end
            nls[#nls + 1] = p
        end
    end

    local lines, buf = {}, {}
    local mi, ni = 1, 1
    local function push(a, b, kind, marked)
        if b < a then return end
        local t = esc(string.sub(src, a, b))
        local col = kind and SYN[kind]
        if col then t = '<font color="' .. col .. '">' .. t .. "</font>" end
        if marked then t = MARK_OPEN .. t .. MARK_CLOSE end
        buf[#buf + 1] = t
    end

    for _, tk in ipairs(toks) do
        local pos, tEnd, kind = tk[1], tk[2], tk[3]
        while pos <= tEnd do
            while matches[mi] and matches[mi][2] < pos do mi += 1 end
            while nls[ni] and nls[ni] < pos do ni += 1 end
            local m = matches[mi]
            local inMatch = m ~= nil and m[1] <= pos
            local stop = tEnd
            if inMatch then
                stop = math.min(stop, m[2])
            elseif m and m[1] <= tEnd then
                stop = m[1] - 1
            end
            local nl = nls[ni]
            if nl and nl <= stop then
                push(pos, nl - 1, kind, inMatch)
                lines[#lines + 1] = table.concat(buf)
                table.clear(buf)
                pos = nl + 1
            else
                push(pos, stop, kind, inMatch)
                pos = stop + 1
            end
        end
    end
    lines[#lines + 1] = table.concat(buf)
    return lines
end

-- 0-based line and column of a 1-based character index
local function lineCol(text, index)
    local prefix = string.sub(text, 1, index - 1)
    local _, line = string.gsub(prefix, "\n", "")
    local lastNl = string.match(prefix, "^.*()\n") or 0
    local colStr = string.sub(prefix, lastNl + 1)
    return line, (utf8.len(colStr) or #colStr)
end

-- ================= WINDOW =================
local vp = workspace.CurrentCamera.ViewportSize
local main = new("Frame", {
    Size = UDim2.fromOffset(920, 580),
    Position = UDim2.fromOffset(math.floor(vp.X / 2 - 460), math.floor(vp.Y / 2 - 290)),
    BackgroundColor3 = C.window, BorderSizePixel = 0, Active = true,
    ClipsDescendants = true, Parent = gui,
})
stroke(main, C.border)

-- title bar
local titleBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, TOP), BackgroundColor3 = C.titlebar,
    BorderSizePixel = 0, Active = true, Parent = main,
})
local titleText = label({
    RichText = true, Font = UI_BOLD, TextSize = 15, Position = UDim2.fromOffset(10, 0),
    Size = UDim2.new(1, -140, 1, 0), Parent = titleBar,
})
local function setTitleCount(n)
    titleText.Text = ('Script Finder  <font color="#8C8C8C">·  %d scripts indexed</font>'):format(n)
end
setTitleCount(0)

local function winButton(xOff, hoverColor)
    local b = new("TextButton", {
        Size = UDim2.new(0, 42, 1, 0), Position = UDim2.new(1, xOff, 0, 0),
        BackgroundColor3 = hoverColor, BackgroundTransparency = 1, BorderSizePixel = 0,
        AutoButtonColor = false, Text = "", Parent = titleBar,
    })
    b.MouseEnter:Connect(function() b.BackgroundTransparency = 0 end)
    b.MouseLeave:Connect(function() b.BackgroundTransparency = 1 end)
    return b
end
local closeBtn = winButton(-42, Color3.fromRGB(196, 43, 28))
label({ Text = "×", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = closeBtn })
local maxBtn = winButton(-84, C.hover)
local maxIcon = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, Parent = maxBtn,
})
stroke(maxIcon, C.text)
local minBtn = winButton(-126, C.hover)
new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(10, 1), BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = minBtn,
})

-- ribbon (search toolbar)
local ribbon = new("Frame", {
    Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 0, RIBBON),
    BackgroundColor3 = C.ribbon, BorderSizePixel = 0, Parent = main,
})
new("Frame", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.border, BorderSizePixel = 0, Parent = ribbon })

local function inputBox(placeholder, pos, size, parent, textSize)
    local box = new("TextBox", {
        Position = pos, Size = size,
        BackgroundColor3 = C.input, BorderSizePixel = 0, ClearTextOnFocus = false, Text = "",
        PlaceholderText = placeholder, PlaceholderColor3 = Color3.fromRGB(110, 110, 110),
        Font = UI_FONT, TextSize = textSize or 15, TextColor3 = C.text,
        TextXAlignment = Enum.TextXAlignment.Left, ClipsDescendants = true, Parent = parent,
    })
    local st = stroke(box, C.border)
    new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = box })
    box.Focused:Connect(function() st.Color = C.accent end)
    box.FocusLost:Connect(function() st.Color = C.border end)
    return box
end

local searchBox  = inputBox("Find in all scripts…", UDim2.fromOffset(8, 5), UDim2.fromOffset(280, 24), ribbon)
local caseBtn    = toolButton("Aa", UDim2.fromOffset(30, 24), UDim2.fromOffset(294, 5), ribbon)
local nameBox    = inputBox("Filter by script name…", UDim2.fromOffset(334, 5), UDim2.fromOffset(190, 24), ribbon)
local reindexBtn = toolButton("Re-index  (F5)", UDim2.fromOffset(104, 24), UDim2.fromOffset(530, 5), ribbon)
local hint = label({
    Text = "Ctrl+Shift+F toggle  ·  F3 next match  ·  Ctrl+S save", TextColor3 = C.dim, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -10, 0, 0), Size = UDim2.new(0, 320, 1, 0), Parent = ribbon,
})

-- left panel (Explorer / Find Results)
local bodyY = TOP + RIBBON
local leftW = 270
local leftPanel = new("Frame", { BackgroundColor3 = C.panel, BorderSizePixel = 0, Parent = main })
local leftHeader = new("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.header, BorderSizePixel = 0, Parent = leftPanel })
local leftTitle = label({
    Text = "Explorer", Font = UI_BOLD, Position = UDim2.fromOffset(8, 0),
    Size = UDim2.new(1, -16, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = leftHeader,
})
local list = new("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 1, -24),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 8,
    ScrollBarImageColor3 = Color3.fromRGB(90, 90, 90), CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
    Parent = leftPanel,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })

local splitter = new("Frame", { BackgroundColor3 = C.border, BorderSizePixel = 0, Active = true, Parent = main })
splitter.MouseEnter:Connect(function() splitter.BackgroundColor3 = C.accent end)
splitter.MouseLeave:Connect(function() splitter.BackgroundColor3 = C.border end)

-- editor area
local editorArea = new("Frame", { BackgroundColor3 = C.editor, BorderSizePixel = 0, ClipsDescendants = true, Parent = main })

local tabBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C.header, BorderSizePixel = 0,
    ClipsDescendants = true, Parent = editorArea,
})
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Parent = tabBar })

local findBar = new("Frame", {
    Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = C.window, BorderSizePixel = 0, Visible = false, Parent = editorArea,
})
new("Frame", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.border, BorderSizePixel = 0, Parent = findBar })
local prevBtn = toolButton("<", UDim2.fromOffset(22, 20), UDim2.fromOffset(6, 4), findBar)
local nextBtn = toolButton(">", UDim2.fromOffset(22, 20), UDim2.fromOffset(32, 4), findBar)
local localBox = inputBox("Find in this script…", UDim2.fromOffset(60, 4), UDim2.fromOffset(170, 20), findBar, 14)
local findInfo = label({
    Position = UDim2.fromOffset(238, 0), Size = UDim2.new(1, -(238 + 270), 1, 0), TextColor3 = C.dim,
    TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Parent = findBar,
})
local roTag = label({
    Text = "READ-ONLY", TextColor3 = C.match, TextSize = 12, Font = UI_BOLD, Visible = false,
    TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -194, 0, 0), Size = UDim2.new(0, 70, 1, 0), Parent = findBar,
})
local saveBtn   = toolButton("Save",   UDim2.fromOffset(56, 20), UDim2.new(1, -186, 0, 4), findBar)
local copyBtn   = toolButton("Copy",   UDim2.fromOffset(56, 20), UDim2.new(1, -124, 0, 4), findBar)
local revertBtn = toolButton("Revert", UDim2.fromOffset(56, 20), UDim2.new(1, -62, 0, 4), findBar)

local body = new("Frame", {
    Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 1, -54),
    BackgroundColor3 = C.editor, BorderSizePixel = 0, Visible = false, Parent = editorArea,
})
local gutter = new("Frame", {
    Size = UDim2.new(0, GUT_W, 1, 0), BackgroundColor3 = C.editor, BorderSizePixel = 0,
    ClipsDescendants = true, Parent = body,
})
local gutterInner = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), Parent = gutter })
new("Frame", { Position = UDim2.new(1, -1, 0, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = Color3.fromRGB(55, 55, 55), BorderSizePixel = 0, Parent = gutter })

local scroll = new("ScrollingFrame", {
    Position = UDim2.fromOffset(GUT_W, 0), Size = UDim2.new(1, -GUT_W, 1, 0),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 10,
    ScrollBarImageColor3 = Color3.fromRGB(85, 85, 85), CanvasSize = UDim2.new(),
    ScrollingDirection = Enum.ScrollingDirection.XY, Parent = body,
})
local content = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(), Parent = scroll })

-- the real TextBox sits underneath with invisible text; the highlight layer draws on top
local editBox = new("TextBox", {
    Position = UDim2.fromOffset(PAD, PAD), BackgroundTransparency = 1, TextColor3 = C.editor,
    Font = CODE_FONT, TextSize = CODE_SIZE, MultiLine = true, ClearTextOnFocus = false,
    TextWrapped = false, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top, Text = "", ZIndex = 1, Parent = content,
})
local hlHolder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = content })
local matchFrame = new("Frame", { BackgroundTransparency = 1, Visible = false, ZIndex = 3, Parent = content })
stroke(matchFrame, C.match)
local caret = new("Frame", {
    Size = UDim2.fromOffset(2, math.ceil(lineH)), BackgroundColor3 = Color3.fromRGB(235, 235, 235),
    BorderSizePixel = 0, Visible = false, ZIndex = 3, Parent = content,
})

local emptyLabel = label({
    Text = "Select a script in the Explorer to open it here.\nUse the search box to find text across every script.",
    TextColor3 = C.dim, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center, Position = UDim2.fromOffset(0, 26),
    Size = UDim2.new(1, 0, 1, -26), Parent = editorArea,
})

-- status bar + resize grip
local statusBar = new("Frame", {
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, STATUS),
    BackgroundColor3 = C.header, BorderSizePixel = 0, Parent = main,
})
new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.border, BorderSizePixel = 0, Parent = statusBar })
local statusText = label({
    Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -220, 1, 0), TextSize = 13,
    TextColor3 = C.dim, TextTruncate = Enum.TextTruncate.AtEnd, Parent = statusBar,
})
local cursorText = label({
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -24, 0, 0), Size = UDim2.new(0, 180, 1, 0),
    TextSize = 13, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Right, Parent = statusBar,
})
local grip = new("Frame", {
    AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), Size = UDim2.fromOffset(18, 18),
    BackgroundTransparency = 1, Active = true, Parent = statusBar,
})
for _, p in ipairs({ { 13, 13 }, { 9, 13 }, { 13, 9 }, { 5, 13 }, { 9, 9 }, { 13, 5 } }) do
    new("Frame", { Position = UDim2.fromOffset(p[1], p[2]), Size = UDim2.fromOffset(2, 2), BackgroundColor3 = C.dim, BorderSizePixel = 0, Parent = grip })
end

local function setStatus(t) statusText.Text = t end

local function applyLayout()
    local w = main.AbsoluteSize.X
    leftW = math.clamp(leftW, 160, math.max(160, w - 300))
    local h = -(bodyY + STATUS)
    leftPanel.Position  = UDim2.fromOffset(0, bodyY);         leftPanel.Size  = UDim2.new(0, leftW, 1, h)
    splitter.Position   = UDim2.fromOffset(leftW, bodyY);     splitter.Size   = UDim2.new(0, 4, 1, h)
    editorArea.Position = UDim2.fromOffset(leftW + 4, bodyY); editorArea.Size = UDim2.new(1, -(leftW + 4), 1, h)
    hint.Visible = w >= 1000
end
main:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
applyLayout()

-- ================= EDITOR STATE =================
local sources = {}          -- { {obj, path, service, parentPath, name, class, source, lower, draft} }
local tabs, activeTab = {}, nil
local searchTerm = ""       -- global search (all scripts)
local localTerm = ""        -- find inside the open script (overrides global highlight)
local function editorTerm() return localTerm ~= "" and localTerm or searchTerm end
local chunkLabels = {}
local contentW, contentH = 0, 0
local switchTab, closeTab   -- forward declarations

scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    gutterInner.Position = UDim2.fromOffset(0, -scroll.CanvasPosition.Y)
end)

local function sizeContent()
    local view = scroll.AbsoluteWindowSize
    local w = math.max(contentW + PAD * 2, view.X)
    local h = math.max(contentH + PAD * 2 + 200, view.Y)
    content.Size = UDim2.fromOffset(w, h)
    editBox.Size = UDim2.fromOffset(w - PAD, h - PAD)
    scroll.CanvasSize = UDim2.fromOffset(w, h)
    gutterInner.Size = UDim2.new(1, 0, 0, h)
end
scroll:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(sizeContent)

local function placeMatchFrame(tab)
    local m = tab.matches and tab.matches[tab.matchIdx or 0]
    if not m then matchFrame.Visible = false; return nil end
    local line, col = lineCol(tab.text, m[1])
    local seg = string.sub(tab.text, m[1], m[2])
    local x, y = PAD + col * charW, PAD + line * lineH
    matchFrame.Position = UDim2.fromOffset(math.floor(x) - 1, math.floor(y))
    matchFrame.Size = UDim2.fromOffset(math.ceil((utf8.len(seg) or #seg) * charW) + 2, math.ceil(lineH))
    matchFrame.Visible = true
    return x, y
end

local function updateFindBar()
    local tab = activeTab
    if not tab then return end
    local term = editorTerm()
    if term == "" then
        findInfo.Text = tab.entry.path
    else
        local n = #tab.matches
        findInfo.Text = n == 0 and ('No matches for "%s"'):format(term)
            or ('"%s"   %d of %d%s'):format(term, tab.matchIdx, n, n >= 5000 and "+" or "")
    end
end

local function renderActive(keepScroll)
    for _, l in ipairs(chunkLabels) do l:Destroy() end
    table.clear(chunkLabels)

    local tab = activeTab
    emptyLabel.Visible = tab == nil
    findBar.Visible = tab ~= nil
    body.Visible = tab ~= nil
    if not tab then cursorText.Text = ""; matchFrame.Visible = false; return end

    local src = tab.text
    local prevScroll = scroll.CanvasPosition
    tab.matches = findAll(src, editorTerm())
    local lines = buildLines(src, tab.matches)
    local n = #lines

    local maxLen = 0
    for s in string.gmatch(src, "[^\n]+") do
        local l = utf8.len(s) or #s
        if l > maxLen then maxLen = l end
    end
    contentW = math.ceil(maxLen * charW) + 40
    contentH = math.ceil(n * lineH) + 4

    for a = 1, n, CHUNK_LINES do
        local b = math.min(n, a + CHUNK_LINES - 1)
        local yOff = math.floor((a - 1) * lineH + 0.5) + PAD
        local hgt = math.ceil((b - a + 1) * lineH) + 2
        chunkLabels[#chunkLabels + 1] = label({
            RichText = true, Text = table.concat(lines, "\n", a, b), Font = CODE_FONT,
            TextSize = CODE_SIZE, TextYAlignment = Enum.TextYAlignment.Top,
            Position = UDim2.fromOffset(PAD, yOff), Size = UDim2.fromOffset(contentW, hgt),
            Parent = hlHolder,
        })
        local nums = {}
        for k = a, b do nums[#nums + 1] = k end
        chunkLabels[#chunkLabels + 1] = label({
            Text = table.concat(nums, "\n"), Font = CODE_FONT, TextSize = CODE_SIZE,
            TextColor3 = C.lineNum, TextXAlignment = Enum.TextXAlignment.Right,
            TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, yOff),
            Size = UDim2.new(1, -10, 0, hgt), Parent = gutterInner,
        })
    end

    local editable = #src <= MAX_EDIT_CHARS
    roTag.Visible = not editable
    editBox.TextEditable = editable
    editBox.Visible = editable
    if editable then
        if editBox.Text ~= src then editBox.Text = src end
    elseif editBox.Text ~= "" then
        editBox.Text = ""
    end
    editBox.TextColor3 = C.editor
    hlHolder.Visible = true

    sizeContent()
    scroll.CanvasPosition = keepScroll and prevScroll or (tab.scrollPos or Vector2.zero)
    if not tab.matches[tab.matchIdx or 0] then
        tab.matchIdx = (#tab.matches > 0) and 1 or 0
    end
    placeMatchFrame(tab)
    updateFindBar()
end

local function gotoMatch(idx)
    local tab = activeTab
    if not tab or #tab.matches == 0 then return end
    tab.matchIdx = ((idx - 1) % #tab.matches) + 1
    local x, y = placeMatchFrame(tab)
    local view = scroll.AbsoluteWindowSize
    local cx = scroll.CanvasPosition.X
    if x < cx + 10 or x > cx + view.X - 60 then cx = math.max(0, x - 60) end
    scroll.CanvasPosition = Vector2.new(cx, math.max(0, y - view.Y / 3))
    updateFindBar()
end

-- tabs
local tabButtons = {}
local function refreshTabs()
    for _, b in ipairs(tabButtons) do b:Destroy() end
    table.clear(tabButtons)
    for i, tab in ipairs(tabs) do
        local isActive = tab == activeTab
        local name = tab.entry.name .. (tab.dirty and " *" or "")
        local tw = TextService:GetTextSize(name, 14, UI_FONT, Vector2.new(1000, 26)).X
        local b = new("TextButton", {
            Size = UDim2.new(0, tw + 54, 1, 0), BackgroundColor3 = isActive and C.editor or C.header,
            AutoButtonColor = false, BorderSizePixel = 0, Text = "", LayoutOrder = i, Parent = tabBar,
        })
        if isActive then
            new("Frame", { Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = C.accent, BorderSizePixel = 0, Parent = b })
        end
        new("Frame", { Position = UDim2.new(1, -1, 0, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = C.border, BorderSizePixel = 0, Parent = b })
        classIcon(tab.entry.class, b, 6, 5)
        label({
            Text = name, TextColor3 = isActive and C.text or C.dim, Position = UDim2.fromOffset(26, 0),
            Size = UDim2.new(1, -48, 1, 0), Parent = b,
        })
        local x = new("TextButton", {
            Text = "×", TextSize = 18, Font = UI_FONT, TextColor3 = C.dim, BackgroundColor3 = C.hover,
            BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false,
            AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
            Size = UDim2.fromOffset(18, 18), Parent = b,
        })
        x.MouseEnter:Connect(function() x.BackgroundTransparency = 0; x.TextColor3 = C.text end)
        x.MouseLeave:Connect(function() x.BackgroundTransparency = 1; x.TextColor3 = C.dim end)
        x.MouseButton1Click:Connect(function() closeTab(tab) end)
        b.MouseButton1Click:Connect(function() switchTab(tab) end)
        tabButtons[#tabButtons + 1] = b
    end
end

function switchTab(tab)
    if activeTab and activeTab ~= tab then activeTab.scrollPos = scroll.CanvasPosition end
    activeTab = tab
    refreshTabs()
    renderActive(false)
end

function closeTab(tab)
    local i = table.find(tabs, tab)
    if not i then return end
    if tab.dirty then tab.entry.draft = tab.text end   -- unsaved edits survive reopening
    table.remove(tabs, i)
    if activeTab == tab then
        activeTab = tabs[i] or tabs[i - 1]
        refreshTabs()
        renderActive(false)
    else
        refreshTabs()
    end
end

local function openEntry(entry, matchIdx)
    local tab
    for _, t in ipairs(tabs) do
        if t.entry == entry then tab = t; break end
    end
    if not tab then
        tab = { entry = entry, text = entry.draft or entry.source, dirty = entry.draft ~= nil, matchIdx = 0, matches = {} }
        table.insert(tabs, tab)
    end
    -- jumping to a global search hit clears the in-script filter so the index lines up
    if matchIdx and localTerm ~= "" then
        localTerm = ""
        localBox.Text = ""
    end
    switchTab(tab)
    if editorTerm() ~= "" and #tab.matches > 0 then gotoMatch(matchIdx or 1) end
end

local localSerial = 0
localBox:GetPropertyChangedSignal("Text"):Connect(function()
    localSerial += 1
    local my = localSerial
    task.delay(0.15, function()
        if my ~= localSerial or localBox.Text == localTerm then return end
        localTerm = localBox.Text
        if activeTab then
            renderActive(true)
            if #activeTab.matches > 0 then gotoMatch(1) end
        end
    end)
end)
localBox.FocusLost:Connect(function(enter)
    if enter and activeTab then gotoMatch(activeTab.matchIdx + 1) end
end)

-- caret, Ln/Col, keep caret visible while typing
local blinkT = 0
local function updateCaret(ensureVisible)
    local cur = editBox.CursorPosition
    if not activeTab or cur < 1 then caret.Visible = false; return end
    local line, col = lineCol(editBox.Text, cur)
    local x, y = PAD + col * charW, PAD + line * lineH
    caret.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
    cursorText.Text = ("Ln %d, Col %d"):format(line + 1, col + 1)
    if ensureVisible and editBox:IsFocused() then
        local view, cp = scroll.AbsoluteWindowSize, scroll.CanvasPosition
        local nx, ny = cp.X, cp.Y
        if y < cp.Y then ny = y - PAD elseif y + lineH > cp.Y + view.Y then ny = y + lineH - view.Y + PAD end
        if x < cp.X then nx = math.max(0, x - 40) elseif x > cp.X + view.X - 20 then nx = x - view.X + 60 end
        if nx ~= cp.X or ny ~= cp.Y then scroll.CanvasPosition = Vector2.new(nx, ny) end
    end
end
editBox:GetPropertyChangedSignal("CursorPosition"):Connect(function() blinkT = 0; updateCaret(true) end)
editBox.Focused:Connect(function() blinkT = 0; updateCaret(false) end)
bind(RunService.Heartbeat, function(dt)
    if activeTab and editBox:IsFocused() then
        blinkT += dt
        caret.Visible = (blinkT % 1) < 0.55
    else
        caret.Visible = false
    end
end)

-- live editing: small scripts re-highlight instantly, big ones after a pause
local editSerial = 0
editBox:GetPropertyChangedSignal("Text"):Connect(function()
    local tab = activeTab
    if not tab or not editBox.TextEditable or editBox.Text == tab.text then return end
    tab.text = editBox.Text
    if not tab.dirty then tab.dirty = true; refreshTabs() end
    editSerial += 1
    local my = editSerial
    local big = #tab.text > 30000
    if big then editBox.TextColor3 = C.text; hlHolder.Visible = false end
    task.delay(big and 0.4 or 0.03, function()
        if my == editSerial and activeTab == tab then renderActive(true) end
    end)
end)

-- save / copy / revert
local function saveActive()
    local tab = activeTab
    if not tab then return end
    local entry = tab.entry
    local wrote = entry.obj and pcall(function() entry.obj.Source = tab.text end)
    local fileName
    if not wrote and writefile then
        pcall(function()
            if makefolder and not (isfolder and isfolder("ScriptFinder")) then makefolder("ScriptFinder") end
        end)
        local f = "ScriptFinder/" .. (string.gsub(entry.path, "[^%w%._%-]", "_")) .. ".lua"
        if pcall(writefile, f, tab.text) then fileName = f end
    end
    if wrote or fileName then
        entry.source, entry.lower, entry.draft = tab.text, string.lower(tab.text), nil
        tab.dirty = false
        refreshTabs()
        setStatus(wrote and ("Saved " .. entry.path)
            or ("Source is read-only here; wrote " .. fileName .. " to your executor workspace"))
    else
        setStatus("Couldn't save: Source is read-only and writefile isn't available. Use Copy instead.")
    end
end

local function copyActive()
    if not activeTab then return end
    local clip = setclipboard or toclipboard
    if clip then
        clip(activeTab.text)
        setStatus("Copied " .. activeTab.entry.name .. " to clipboard")
    else
        setStatus("No clipboard function available in this executor")
    end
end

local function revertActive()
    local tab = activeTab
    if not tab then return end
    tab.text, tab.dirty, tab.entry.draft = tab.entry.source, false, nil
    refreshTabs()
    renderActive(true)
    setStatus("Reverted " .. tab.entry.name)
end

saveBtn.MouseButton1Click:Connect(saveActive)
copyBtn.MouseButton1Click:Connect(copyActive)
revertBtn.MouseButton1Click:Connect(revertActive)
prevBtn.MouseButton1Click:Connect(function() if activeTab then gotoMatch(activeTab.matchIdx - 1) end end)
nextBtn.MouseButton1Click:Connect(function() if activeTab then gotoMatch(activeTab.matchIdx + 1) end end)

-- ================= EXPLORER / FIND RESULTS =================
local listRows, selectedRow = {}, nil

local function makeRow(height, order)
    local r = new("TextButton", {
        Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = C.hover, BackgroundTransparency = 1,
        AutoButtonColor = false, BorderSizePixel = 0, Text = "", LayoutOrder = order, Parent = list,
    })
    r.MouseEnter:Connect(function()
        if r ~= selectedRow then r.BackgroundColor3 = C.hover; r.BackgroundTransparency = 0 end
    end)
    r.MouseLeave:Connect(function()
        if r ~= selectedRow then r.BackgroundTransparency = 1 end
    end)
    listRows[#listRows + 1] = r
    return r
end

local function selectRow(r)
    if selectedRow and selectedRow.Parent then selectedRow.BackgroundTransparency = 1 end
    selectedRow = r
    r.BackgroundColor3 = C.select
    r.BackgroundTransparency = 0
end

local function snippetFor(src, s, e)
    local ls = s
    while ls > 1 and string.byte(src, ls - 1) ~= 10 do ls -= 1 end
    local le = (string.find(src, "\n", e + 1, true) or #src + 1) - 1
    local pre = string.gsub(string.sub(src, ls, s - 1), "^%s+", "")
    if #pre > 40 then pre = "…" .. string.sub(pre, -40) end
    local post = string.sub(src, e + 1, le)
    if #post > 90 then post = string.sub(post, 1, 90) .. "…" end
    return esc(pre) .. MARK_OPEN .. esc(string.sub(src, s, e)) .. MARK_CLOSE .. esc(post)
end

local function runSearch()
    for _, r in ipairs(listRows) do r:Destroy() end
    table.clear(listRows)
    selectedRow = nil

    local term = searchTerm
    local order, rows = 0, 0
    local nameFilter = string.lower(nameBox.Text)
    local function nameOk(entry)
        return nameFilter == "" or string.find(string.lower(entry.path), nameFilter, 1, true) ~= nil
    end

    if term == "" then
        local shown = 0
        local lastService
        for _, entry in ipairs(sources) do
            if rows >= MAX_RESULT_ROWS then break end
            if not nameOk(entry) then continue end
            shown += 1
            if entry.service ~= lastService then
                lastService = entry.service
                order += 1
                local h = makeRow(22, order)
                classIcon("Folder", h, 6, 3)
                label({ Text = entry.service, Font = UI_BOLD, Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -30, 1, 0), Parent = h })
            end
            order += 1; rows += 1
            local r = makeRow(22, order)
            classIcon(entry.class, r, 24, 3)
            label({
                RichText = true, TextTruncate = Enum.TextTruncate.AtEnd,
                Text = esc(entry.name) .. '  <font color="#7A7A7A">' .. esc(entry.parentPath) .. "</font>",
                Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -48, 1, 0), Parent = r,
            })
            r.MouseButton1Click:Connect(function() selectRow(r); openEntry(entry) end)
        end
        leftTitle.Text = nameFilter == "" and ("Explorer  ·  %d scripts"):format(#sources)
            or ("Explorer  ·  %d of %d scripts"):format(shown, #sources)
        setStatus(("%d scripts indexed"):format(#sources))
        return
    end

    local needle = matchCase and term or string.lower(term)
    local totalHits, scriptsHit = 0, 0
    for _, entry in ipairs(sources) do
        if rows >= MAX_RESULT_ROWS then break end
        if not nameOk(entry) then continue end
        local hay = matchCase and entry.source or entry.lower
        local nameHay = matchCase and entry.path or string.lower(entry.path)
        local s = string.find(hay, needle, 1, true)
        if s or string.find(nameHay, needle, 1, true) then
            scriptsHit += 1
            local hits, count, line, scanned = {}, 0, 1, 1
            while s do
                count += 1
                if #hits < 3 then
                    local _, nl = string.gsub(string.sub(hay, scanned, s - 1), "\n", "")
                    line += nl
                    scanned = s
                    hits[#hits + 1] = { s = s, e = s + #needle - 1, line = line, idx = count }
                end
                if count >= 999 then break end
                s = string.find(hay, needle, s + #needle, true)
            end
            totalHits += count

            order += 1; rows += 1
            local h = makeRow(22, order)
            classIcon(entry.class, h, 6, 3)
            label({
                RichText = true, TextTruncate = Enum.TextTruncate.AtEnd,
                Text = esc(entry.name) .. '  <font color="#7A7A7A">' .. esc(entry.service .. "." .. entry.parentPath) .. "</font>",
                Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -70, 1, 0), Parent = h,
            })
            if count > 0 then
                label({
                    Text = count >= 999 and "999+" or tostring(count), TextSize = 12, TextColor3 = C.dim,
                    TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, -10, 0, 0), Size = UDim2.new(0, 40, 1, 0), Parent = h,
                })
            end
            h.MouseButton1Click:Connect(function() selectRow(h); openEntry(entry, 1) end)

            for _, hit in ipairs(hits) do
                order += 1; rows += 1
                local r = makeRow(20, order)
                label({
                    RichText = true, Font = CODE_FONT, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = '<font color="#6E6E6E">' .. hit.line .. ":</font> " .. snippetFor(entry.source, hit.s, hit.e),
                    Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -34, 1, 0), Parent = r,
                })
                r.MouseButton1Click:Connect(function() selectRow(r); openEntry(entry, hit.idx) end)
            end
        end
    end
    leftTitle.Text = ("Find Results  ·  %d hits in %d scripts"):format(totalHits, scriptsHit)
    setStatus(rows >= MAX_RESULT_ROWS and "Showing the first results only; refine your search" or "")
end

local searchSerial = 0
local function onSearchChanged()
    searchSerial += 1
    local my = searchSerial
    task.delay(0.2, function()
        if my ~= searchSerial then return end
        searchTerm = searchBox.Text
        runSearch()
        if activeTab then
            renderActive(true)
            if #activeTab.matches > 0 then gotoMatch(1) end
        end
    end)
end
searchBox:GetPropertyChangedSignal("Text"):Connect(onSearchChanged)
searchBox.FocusLost:Connect(function(enter)
    if enter and activeTab then gotoMatch(activeTab.matchIdx + 1) end
end)
local nameSerial = 0
nameBox:GetPropertyChangedSignal("Text"):Connect(function()
    nameSerial += 1
    local my = nameSerial
    task.delay(0.15, function()
        if my == nameSerial then runSearch() end
    end)
end)
caseBtn.MouseButton1Click:Connect(function()
    matchCase = not matchCase
    caseBtn:SetAttribute("on", matchCase)
    caseBtn.BackgroundColor3 = matchCase and C.select or C.button
    onSearchChanged()
end)

-- ================= INDEXING =================
local function getScriptSource(obj)
    local ok, src = pcall(function() return obj.Source end)
    if ok and src and #src > 0 then return src end

    if typeof(decompile) == "function" then
        local ok2, dec = pcall(decompile, obj)
        if ok2 and type(dec) == "string" and #dec > 0 then return dec end
    end
    if typeof(getscriptbytecode) == "function" and typeof(decompile) == "function" then
        local ok3, bc = pcall(getscriptbytecode, obj)
        if ok3 and type(bc) == "string" and #bc > 0 then
            local ok4, dec2 = pcall(decompile, bc)
            if ok4 and type(dec2) == "string" and #dec2 > 0 then return dec2 end
        end
    end
    return nil
end

local CORE_ROOTS = { "CoreGui", "CorePackages", "RobloxScript", "PlayerModule" }
if not INCLUDE_PLAYER_SCRIPTS then table.insert(CORE_ROOTS, "PlayerScripts") end
local CORE_CLASSES = { CoreScript = true, CoreScriptContainer = true, RobloxScript = true, RobloxLocalScript = true }

-- server-side code is never shown
local SERVER_ROOTS = { ServerScriptService = true, ServerStorage = true }
local function isServerSide(obj)
    if obj.ClassName == "Script" then
        local ok, rc = pcall(function() return obj.RunContext end)
        if not (ok and rc == Enum.RunContext.Client) then return true end
    end
    local cur = obj.Parent
    while cur and cur ~= game do
        if SERVER_ROOTS[cur.ClassName] then return true end
        cur = cur.Parent
    end
    return false
end

local function isCore(obj)
    if CORE_CLASSES[obj.ClassName] then return true end
    local cur = obj
    while cur and cur ~= game do
        for _, root in ipairs(CORE_ROOTS) do
            if cur.Name == root or cur.ClassName == root then return true end
        end
        cur = cur.Parent
    end
    return false
end

local indexing = false
local function indexGame()
    if indexing then return end
    indexing = true
    setStatus("Indexing…")
    local fresh = {}
    for i, obj in ipairs(game:GetDescendants()) do
        local okClass, isScript = pcall(function() return obj:IsA("LuaSourceContainer") end)
        if okClass and isScript and not isCore(obj) and not isServerSide(obj) then
            local src = getScriptSource(obj)
            if src then
                src = (string.gsub(string.gsub(src, "\r\n", "\n"), "\t", "    "))
                local parts, cur = {}, obj
                while cur and cur ~= game do
                    table.insert(parts, 1, cur.Name)
                    cur = cur.Parent
                end
                fresh[#fresh + 1] = {
                    obj = obj, name = obj.Name, class = obj.ClassName,
                    path = table.concat(parts, "."), service = parts[1] or "?",
                    parentPath = table.concat(parts, ".", 2, math.max(1, #parts - 1)),
                    source = src, lower = string.lower(src),
                }
                setTitleCount(#fresh)
                setStatus(("Indexing…  %d scripts"):format(#fresh))
                if #fresh % 5 == 0 then task.wait() end
            end
        end
        if i % 300 == 0 then task.wait() end
    end
    table.sort(fresh, function(a, b) return string.lower(a.path) < string.lower(b.path) end)
    sources = fresh
    indexing = false
    setTitleCount(#fresh)
    runSearch()
    setStatus(("Indexed %d scripts"):format(#fresh))
end
reindexBtn.MouseButton1Click:Connect(function() task.spawn(indexGame) end)

-- ================= DRAG / RESIZE / WINDOW STATE =================
local function makeDrag(handle, onStart, onMove)
    handle.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local start = input.Position
        local state = onStart()
        local moveConn, endConn
        moveConn = UserInputService.InputChanged:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
                local d = i.Position - start
                onMove(Vector2.new(d.X, d.Y), state)
            end
        end)
        endConn = UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                moveConn:Disconnect()
                endConn:Disconnect()
            end
        end)
    end)
end

local maximized, minimized = false, false
local restoreSize, restorePos, minRestoreSize

local function setBodyVisible(v)
    for _, ch in ipairs(main:GetChildren()) do
        if ch:IsA("GuiObject") and ch ~= titleBar then ch.Visible = v end
    end
end

local function toggleMin()
    if minimized then
        main.Size = minRestoreSize
        minimized = false
        setBodyVisible(true)
    else
        minRestoreSize = main.Size
        main.Size = UDim2.new(main.Size.X.Scale, main.Size.X.Offset, 0, TOP)
        minimized = true
        setBodyVisible(false)
    end
end

local function toggleMax()
    if minimized then toggleMin() end
    if maximized then
        main.Size, main.Position = restoreSize, restorePos
        maximized = false
    else
        restoreSize, restorePos = main.Size, main.Position
        main.Position = UDim2.new()
        main.Size = UDim2.fromScale(1, 1)
        maximized = true
    end
    grip.Visible = not maximized
end

makeDrag(titleBar, function() return main.Position end, function(d, startPos)
    if maximized then return end
    local v = workspace.CurrentCamera.ViewportSize
    local w = main.AbsoluteSize.X
    main.Position = UDim2.fromOffset(
        math.clamp(startPos.X.Offset + d.X, -w + 120, v.X - 120),
        math.clamp(startPos.Y.Offset + d.Y, 0, v.Y - TOP)
    )
end)

makeDrag(grip, function() return main.AbsoluteSize end, function(d, s)
    if maximized or minimized then return end
    local v = workspace.CurrentCamera.ViewportSize
    main.Size = UDim2.fromOffset(math.clamp(s.X + d.X, MINW, v.X), math.clamp(s.Y + d.Y, MINH, v.Y))
end)

makeDrag(splitter, function() return leftW end, function(d, s)
    leftW = s + d.X
    applyLayout()
end)

local lastTitleClick = 0
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if os.clock() - lastTitleClick < 0.3 then toggleMax() end
        lastTitleClick = os.clock()
    end
end)

maxBtn.MouseButton1Click:Connect(toggleMax)
minBtn.MouseButton1Click:Connect(toggleMin)
closeBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(conns) do c:Disconnect() end
    gui:Destroy()
end)

-- ================= HOTKEYS =================
bind(UserInputService.InputBegan, function(input, gp)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
    local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
    local key = input.KeyCode

    if ctrl and shift and key == Enum.KeyCode.F then
        main.Visible = not main.Visible
    elseif ctrl and key == Enum.KeyCode.S and editBox:IsFocused() then
        saveActive()
    elseif key == Enum.KeyCode.F3 and activeTab then
        gotoMatch(activeTab.matchIdx + (shift and -1 or 1))
    elseif key == Enum.KeyCode.F5 and not gp then
        task.spawn(indexGame)
    end
end)

-- ================= START =================
renderActive(false)
task.spawn(indexGame)
