-- Alters Forever

local ADDON, ns = ...

local PREFIX = "Alters Forever: "
local ROW_HEIGHT = 20
local ROWS = 16
local REST_PER_HOUR = 0.05 / 8      -- de barra, descansando; fuera, la cuarta parte
local REST_CAP = 1.5

local BAGS = { -1, 0, 1, 2, 3, 4, 5 }
local BANK = { 6, 7, 8, 9, 10, 11, 12, 13, 14 }

local OPTIONS = {
    tooltip     = true,
    button      = true,
    buttonAngle = 225,
    sorts       = {},
    theme       = ns.DEFAULT_THEME,
    scale       = 1,
    mailWarning = true,
    cooldownWarning = true,
    auctionWarning = true,
    showHidden  = false,
    tooltipSkipMe = false,
    tooltipTotalOnly = false,
    tooltipShift = false,
    bgAlpha     = 1,
}

local DATA_VERSION = 1
local MAIL_DAYS = 30
local MAIL_WARNING_DAYS = 3

local MIN_SCALE, MAX_SCALE = 0.6, 1.6

local db, me, myGUID
local bankOpen, mailOpen
local window, minimapButton
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo

-- ---------------------------------------------------------------- utilidades

-- la clave es el ingles; lo que no este traducido se ve en ingles
local L = setmetatable({}, { __index = function(_, key) return key end })

for key, value in pairs(ns.L[(GetLocale and GetLocale()) or "enUS"] or {}) do
    L[key] = value
end

local function Say(text, ...)
    local message = L[text]
    if select("#", ...) > 0 then
        message = format(message, ...)
    end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
end

local function ClassColored(c, text)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class or ""]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. (text or c.name) .. "|r"
    end
    return text or c.name
end

local function ClassIcon(c)
    if not c.class or not CreateAtlasMarkup then return "" end
    return CreateAtlasMarkup("classicon-" .. c.class:lower(), 14, 14) .. " "
end

local function Money(copper)
    copper = copper or 0
    if GetMoneyString then return GetMoneyString(copper, true) end
    return format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- con signo y color: verde lo ganado, rojo lo gastado
local function MoneyChange(copper)
    if copper == 0 then return Money(0) end
    if copper > 0 then return "|cff40bf40+|r" .. Money(copper) end
    return "|cffff5050-|r" .. Money(-copper)
end

-- oro al empezar el dia y la semana (desde el lunes)
local function MarkGold(c)
    local day, week = date("%Y-%m-%d"), date("%Y-%W")
    if c.goldDay ~= day then c.goldDay, c.goldDayStart = day, c.money end
    if c.goldWeek ~= week then c.goldWeek, c.goldWeekStart = week, c.money end
end

local function GoldToday(c)
    if c.goldDay ~= date("%Y-%m-%d") then return 0 end
    return (c.money or 0) - (c.goldDayStart or c.money or 0)
end

local function GoldWeek(c)
    if c.goldWeek ~= date("%Y-%W") then return 0 end
    return (c.money or 0) - (c.goldWeekStart or c.money or 0)
end

local function Duration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds >= 86400 then
        return format(L["%dd %dh"], math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
    elseif seconds >= 3600 then
        return format(L["%dh %dm"], math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    end
    return format(L["%dm"], math.floor(seconds / 60))
end

local function SortedChars()
    local list = {}
    for _, c in pairs(db.chars) do
        if not c.hidden or db.options.showHidden then
            table.insert(list, c)
        end
    end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return list
end

local function ByName(c) return (c.name or ""):lower() end
-- parte de nivel ya hecha, de 0 a 1; nil en el tope
local function LevelProgress(c)
    if not c.xpMax or c.xpMax == 0 or (c.level or 0) >= (db.maxLevel or 60) then return end
    return math.min((c.xp or 0) / c.xpMax, 0.999)
end

local function LevelText(c)
    local progress = LevelProgress(c)
    if not progress then return tostring(c.level or 0) end
    return format("%d|cff8fb8ff.%d|r", c.level or 0, math.floor(progress * 10))
end

local function ByLevel(c) return (c.level or 0) + (LevelProgress(c) or 0) end
local function BySlot(slot)
    return function(c)
        local prof = c.profs and c.profs[slot]
        return prof and prof.rank or -1
    end
end

local function Played(c)
    local played = c.played or 0
    if c == me and c.playedAt then
        played = played + GetTime() - c.playedAt
    end
    return played
end

-- descanso estimado: lo guardado mas lo ganado desde que salio
local function Rested(c)
    if not c.xpMax or c.xpMax == 0 or (c.level or 0) >= (db.maxLevel or 60) then return end
    local bars = (c.rested or 0) / c.xpMax
    if c ~= me and c.lastSeen then
        local rate = c.resting and REST_PER_HOUR or REST_PER_HOUR / 4
        bars = bars + (time() - c.lastSeen) / 3600 * rate
    end
    return math.min(bars, REST_CAP)
end

-- ------------------------------------------------------------------- temas

local theme
local skinned = {}

local function Paint(object)
    local color = theme[object.role]
    if object:GetObjectType() == "Texture" then
        -- el texto no se toca
        local alpha = (color[4] or 1) * (db and db.options.bgAlpha or 1)
        object:SetColorTexture(color[1], color[2], color[3], alpha)
    else
        object:SetTextColor(color[1], color[2], color[3])
    end
end

local function Skin(object, role)
    if not object.role then table.insert(skinned, object) end
    object.role = role
    Paint(object)
    return object
end

local function FindTheme(key)
    for _, entry in ipairs(ns.themes) do
        if entry.key == key then return entry end
    end
    return ns.themes[1]
end

local function TitleText()
    local c = theme.title
    return format("|cff%02x%02x%02xAlters Forever|r", c[1] * 255, c[2] * 255, c[3] * 255)
end

local RefreshWindow

-- dibujadas o con plantillas del juego
local natives = {}

local function ApplyTheme(key)
    theme = FindTheme(key)
    db.options.theme = theme.key
    for _, object in ipairs(skinned) do
        Paint(object)
    end
    for _, widget in ipairs(natives) do
        widget:SetNative(theme.native)
    end
    if window then
        window.title:SetText(TitleText())
        RefreshWindow()
    end
end

-- ----------------------------------------------------------------- recogida

local function Remember(itemID, link)
    local name = link and link:match("%[(.-)%]")
    if name then db.names[itemID] = name end
end

-- la bolsa que ocupa ese contenedor, si es una bolsa de verdad
local function BagLink(bag)
    if bag < 1 or bag == BANK[1] then return end
    local ok, slot = pcall(C_Container.ContainerIDToInventoryID, bag)
    return ok and slot and GetInventoryItemLink("player", slot) or nil
end

-- tambien por bolsa, para iluminarla en la ficha
local function ScanContainers(list)
    local counts = {}
    me.containers = me.containers or {}
    for _, bag in ipairs(list) do
        local size = GetContainerNumSlots(bag) or 0
        local bagInfo = { size = size, free = 0, items = {}, link = BagLink(bag) }
        for slot = 1, size do
            local info = GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local count = info.stackCount or 1
                counts[info.itemID] = (counts[info.itemID] or 0) + count
                bagInfo.items[info.itemID] = (bagInfo.items[info.itemID] or 0) + count
                Remember(info.itemID, info.hyperlink)
            else
                bagInfo.free = bagInfo.free + 1
            end
        end
        me.containers[bag] = size > 0 and bagInfo or nil
    end
    return counts
end

local function ScanBags()
    me.bags = ScanContainers(BAGS)
    local free, total = 0, 0
    for bag = 0, 5 do
        local slots = GetContainerNumSlots(bag) or 0
        local empty, family = C_Container.GetContainerNumFreeSlots(bag)
        if slots > 0 and (family or 0) == 0 then
            free, total = free + (empty or 0), total + slots
        end
    end
    me.bagFree, me.bagSlots = free, total
end

local function ScanBank()
    me.bank = ScanContainers(BANK)
    me.bankSeen = time()
end

-- el enlace guarda encantamientos y sufijos ("del oso")
local function ScanWorn()
    me.worn, me.gear = {}, {}
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        if id then
            local link = GetInventoryItemLink("player", slot)
            me.worn[id] = (me.worn[id] or 0) + 1
            me.gear[slot] = link or ("item:" .. id)
            Remember(id, link)
        end
    end
end

local function ScanMail()
    local counts, soonest, gold = {}, nil, 0
    local letters = GetInboxNumItems()
    for i = 1, letters do
        local _, _, _, _, money, _, daysLeft, hasItem = GetInboxHeaderInfo(i)
        gold = gold + (money or 0)
        if hasItem or (money or 0) > 0 then
            soonest = math.min(soonest or daysLeft, daysLeft)
        end
        for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
            local _, itemID, _, count = GetInboxItem(i, a)
            if itemID then
                counts[itemID] = (counts[itemID] or 0) + (count or 1)
                Remember(itemID, GetInboxItemLink(i, a))
            end
        end
    end
    me.mail = counts
    me.mailLetters = letters
    me.mailMoney = gold
    me.mailExpires = soonest and (time() + soonest * 86400) or nil
end

local function FindAlt(name)
    if not name or name == "" then return end
    local short, realm = strsplit("-", name, 2)
    short = short:lower()
    for _, c in pairs(db.chars) do
        if c ~= me and c.name and c.name:lower() == short
            and (not realm or not c.realm or c.realm:gsub("[%s']", "") == realm:gsub("[%s']", "")) then
            return c
        end
    end
end

-- se apunta al enviarse; el buzon del alt lo corrige
local function Deliver(c, items, money)
    c.mail = c.mail or {}
    for id, count in pairs(items) do
        c.mail[id] = (c.mail[id] or 0) + count
    end
    c.mailLetters = (c.mailLetters or 0) + 1
    c.mailMoney = (c.mailMoney or 0) + (money or 0)
    local expires = time() + MAIL_DAYS * 86400
    c.mailExpires = math.min(c.mailExpires or expires, expires)
end

local outgoing

local function WatchMail()
    hooksecurefunc("SendMail", function(recipient)
        local c = FindAlt(recipient)
        if not c then outgoing = nil return end
        local items = {}
        for a = 1, ATTACHMENTS_MAX_SEND or 12 do
            local _, itemID, _, count = GetSendMailItem(a)
            if itemID then
                items[itemID] = (items[itemID] or 0) + (count or 1)
                Remember(itemID, GetSendMailItemLink(a))
            end
        end
        outgoing = { c = c, items = items, money = GetSendMailMoney() }
    end)

    hooksecurefunc("ReturnInboxItem", function(index)
        local _, _, sender, _, money = GetInboxHeaderInfo(index)
        local c = FindAlt(sender)
        if not c then return end
        local items = {}
        for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
            local _, itemID, _, count = GetInboxItem(index, a)
            if itemID then items[itemID] = (items[itemID] or 0) + (count or 1) end
        end
        Deliver(c, items, money)
    end)
end

-- una vez por espera
local function CheckCooldowns()
    if not db.options.cooldownWarning then return end
    local now = time()
    for _, c in pairs(db.chars) do
        c.cooldownsWarned = c.cooldownsWarned or {}
        for id, ready in pairs(c.cooldowns or {}) do
            if ready <= now and c.cooldownsWarned[id] ~= ready then
                c.cooldownsWarned[id] = ready
                local recipe = db.recipes[id]
                Say("%s: %s is ready.", ClassColored(c), (recipe and recipe.name) or C_Spell.GetSpellName(id) or id)
            end
        end
    end
end

-- subastas: se piden al abrir la casa de subastas
local AH_TIME_LEFT = { [0] = 1800, [1] = 7200, [2] = 43200, [3] = 172800 }

local function ScanAuctions()
    local list, counts = {}, {}
    for index = 1, C_AuctionHouse.GetNumOwnedAuctions() do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(index)
        local id = info and info.itemKey and info.itemKey.itemID
        if id then
            local count = info.quantity or 1
            local sold = info.status == 1
            local left = info.timeLeftSeconds or AH_TIME_LEFT[info.timeLeft] or 0
            table.insert(list, { id, info.itemLink, count, info.buyoutAmount or info.bidAmount or 0, time() + left, sold })
            if not sold then counts[id] = (counts[id] or 0) + count end
            Remember(id, info.itemLink)
            db.names[id] = db.names[id] or C_Item.GetItemNameByID(id)
        end
    end
    me.auctions, me.ah, me.auctionsSeen = list, counts, time()
end

local function ScanBids()
    local list = {}
    for index = 1, C_AuctionHouse.GetNumBids() do
        local info = C_AuctionHouse.GetBidInfo(index)
        local id = info and info.itemKey and info.itemKey.itemID
        if id then
            table.insert(list, { id, info.itemLink, 1, info.bidAmount or info.minBid or 0, time() + (AH_TIME_LEFT[info.timeLeft] or 0) })
            Remember(id, info.itemLink)
            db.names[id] = db.names[id] or C_Item.GetItemNameByID(id)
        end
    end
    me.bids = list
end

local function QueryAuctions()
    pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    pcall(C_AuctionHouse.QueryBids, {}, {})
end

-- una vez por cada lectura de la casa de subastas
local function WarnAuctions()
    if not db.options.auctionWarning then return end
    for _, c in pairs(db.chars) do
        if c.auctionsSeen and c.auctionsWarned ~= c.auctionsSeen then
            local sold, ended = 0, 0
            for _, auction in ipairs(c.auctions or {}) do
                if auction[6] then
                    sold = sold + 1
                elseif auction[5] <= time() then
                    ended = ended + 1
                end
            end
            if sold + ended > 0 then
                c.auctionsWarned = c.auctionsSeen
                Say("%s: %d sold and %d ended unsold; check the mail.", ClassColored(c), sold, ended)
            end
        end
    end
end

local function WarnMail()
    if not db.options.mailWarning then return end
    for _, c in pairs(db.chars) do
        local left = c.mailExpires and c.mailExpires - time()
        if left and (c.mailLetters or 0) > 0 and left < MAIL_WARNING_DAYS * 86400 then
            if left > 0 then
                Say("%s has mail that expires in %s.", ClassColored(c), Duration(left))
            else
                Say("%s had mail that may have expired.", ClassColored(c))
            end
        end
    end
end

-- ranuras: 1-2 principales, 3 cocina, 4 pesca, 5 primeros auxilios
local function ScanProfessions()
    local first, second, aid, fishing, cooking = GetProfessions()
    me.profs = {}
    for slot, index in ipairs({ first or false, second or false, cooking or false, fishing or false, aid or false }) do
        if index then
            local name, icon, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
            me.profs[slot] = { name = name, icon = icon, rank = rank, max = maxRank, skillLine = skillLine }
            if name and skillLine then db.skillLines[name] = skillLine end
        else
            me.profs[slot] = false
        end
    end
end

-- al abrir la profesion la lista tarda en cambiar
local recipeIndex
local scanTries = 0

local function ScanRecipes()
    if C_TradeSkillUI.IsTradeSkillLinked() or C_TradeSkillUI.IsTradeSkillGuild() or C_TradeSkillUI.IsNPCCrafting() then return end
    local base = C_TradeSkillUI.GetBaseProfessionInfo()
    local skillLine = base and base.professionID
    if not skillLine or skillLine == 0 then return end

    local first = C_TradeSkillUI.GetCategories()
    local category = first and C_TradeSkillUI.GetCategoryInfo(first)
    if not category or category.skillLineID ~= skillLine then
        if scanTries < 10 then
            scanTries = scanTries + 1
            C_Timer.After(0.5, ScanRecipes)
        else
            scanTries = 0
            DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. format("could not read recipes (profession %s, first category %s, skill line %s)",
                tostring(skillLine), tostring(first), tostring(category and category.skillLineID)))
        end
        return
    end
    scanTries = 0

    local known = {}
    me.cooldowns = me.cooldowns or {}
    for _, id in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local info = C_TradeSkillUI.GetRecipeInfo(id)
        if info and info.learned then
            known[id] = info.relativeDifficulty or 0
            db.recipes[id] = db.recipes[id] or {}
            local recipe = db.recipes[id]
            recipe.name, recipe.icon, recipe.skill = info.name, info.icon, skillLine
            if recipe.item == nil or recipe.reagents == nil then
                local schematic = C_TradeSkillUI.GetRecipeSchematic(id, false)
                recipe.item = schematic and schematic.outputItemID or false
                recipe.reagents = {}
                -- solo los obligatorios; los opcionales no existen en Forever
                local basic = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
                for _, slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
                    local reagent = slot.reagents and slot.reagents[1]
                    if reagent and reagent.itemID and (slot.quantityRequired or 0) > 0
                        and (not basic or slot.reagentType == basic or slot.required) then
                        table.insert(recipe.reagents, { reagent.itemID, slot.quantityRequired })
                    end
                end
            end
            local cooldown = C_TradeSkillUI.GetRecipeCooldown(id)
            -- una vez vista con espera se sigue mostrando, como lista
            if cooldown and cooldown > 0 then
                me.cooldowns[id] = time() + cooldown
            elseif me.cooldowns[id] then
                me.cooldowns[id] = math.min(me.cooldowns[id], time())
            end
        end
    end
    me.recipes = me.recipes or {}
    me.recipes[skillLine] = known
    me.recipesSeen = me.recipesSeen or {}
    me.recipesSeen[skillLine] = time()
    recipeIndex = nil
end

-- desplegar cabeceras dispara estos mismos eventos: sin esto, bucle
local busy, quietUntil = false, 0
local queued = {}

local function RunScan(scan)
    if busy then return end
    busy = true
    local ok, err = pcall(scan)
    busy = false
    quietUntil = GetTime() + 2
    if not ok then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "scan error: " .. tostring(err)) end
end

local function ScanLater(scan)
    if busy or GetTime() < quietUntil or queued[scan] then return end
    queued[scan] = true
    C_Timer.After(2, function()
        queued[scan] = nil
        RunScan(scan)
    end)
end

-- se despliegan para leer y se vuelven a plegar, de abajo arriba
local function ScanReputations()
    if not C_Reputation then return end
    local collapsed = {}
    local i = 1
    while i <= C_Reputation.GetNumFactions() do
        local data = C_Reputation.GetFactionDataByIndex(i)
        if data and data.isHeader and data.isCollapsed then
            collapsed[data.name] = true
            C_Reputation.ExpandFactionHeader(i)
        end
        i = i + 1
    end

    local reps, header = {}, nil
    local count = C_Reputation.GetNumFactions()
    for index = 1, count do
        local data = C_Reputation.GetFactionDataByIndex(index)
        if data then
            if data.isHeader and not data.isChild then header = data.name end
            if (not data.isHeader or data.isHeaderWithRep) and data.factionID and data.factionID > 0 then
                local low = data.currentReactionThreshold or 0
                reps[data.factionID] = { data.reaction, (data.currentStanding or 0) - low, (data.nextReactionThreshold or 0) - low }
                db.factions[data.factionID] = { name = data.name, header = header, order = index }
            end
        end
    end
    me.reps = reps

    for index = count, 1, -1 do
        local data = C_Reputation.GetFactionDataByIndex(index)
        if data and data.isHeader and collapsed[data.name] then
            C_Reputation.CollapseFactionHeader(index)
        end
    end
end

-- cada profesion sale dos veces, la hija con parentSkillLineID
local function SkillLine(index)
    local info = C_SkillInfo.GetSkillLineInfo(index)
    if type(info) ~= "table" then return end
    local child = (info.parentSkillLineID or 0) ~= 0
    return info.name, info.isHeader, not info.isCollapsed, info.rank, info.maxRank, info.modifier, child
end

local function ScanSkills()
    if not C_SkillInfo then return end
    local collapsed = {}
    for index = C_SkillInfo.GetNumSkillLines(), 1, -1 do
        local name, isHeader, isExpanded = SkillLine(index)
        if isHeader and not isExpanded then
            collapsed[name] = true
            C_SkillInfo.ExpandSkillHeader(index)
        end
    end
    local list = {}
    local count = C_SkillInfo.GetNumSkillLines()
    local seen
    for index = 1, count do
        local name, isHeader, _, rank, maxRank, modifier, child = SkillLine(index)
        if isHeader then
            table.insert(list, { header = name })
            seen = {}
        elseif name and not child and not (seen and seen[name]) then
            if seen then seen[name] = true end
            table.insert(list, { name, rank or 0, maxRank or 0, modifier or 0 })
        end
    end
    me.skills = list
    for index = count, 1, -1 do
        local name, isHeader = SkillLine(index)
        if isHeader and collapsed[name] then C_SkillInfo.CollapseSkillHeader(index) end
    end
end

local function ScanPvP()
    local pvp = {}
    pvp.lifetime = { GetPVPLifetimeStats() }
    pvp.session = { GetPVPSessionStats() }
    pvp.yesterday = { GetPVPYesterdayStats() }
    pvp.honor = UnitHonor and UnitHonor("player")
    pvp.honorLevel = UnitHonorLevel and UnitHonorLevel("player")
    me.pvp = pvp
end

-- llega con UPDATE_INSTANCE_INFO despues de RequestRaidInfo
local function ScanLockouts()
    local list = {}
    for i = 1, GetNumSavedInstances() do
        local name, _, reset, _, locked, extended, _, isRaid, _, difficulty, total, done = GetSavedInstanceInfo(i)
        if name and (locked or extended) and (reset or 0) > 0 then
            table.insert(list, { name, time() + reset, difficulty, done or 0, total or 0, isRaid })
        end
    end
    for i = 1, GetNumSavedWorldBosses and GetNumSavedWorldBosses() or 0 do
        local name, _, reset = GetSavedWorldBossInfo(i)
        if name and (reset or 0) > 0 then table.insert(list, { name, time() + reset, L["World boss"], 0, 0, true }) end
    end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    me.lockouts = list
    me.lockoutsSeen = time()
end

-- C_Timer no acepta funciones del juego directamente
local function AskLockouts()
    if RequestRaidInfo then RequestRaidInfo() end
end

local function ScanCurrencies()
    local api = C_CurrencyInfo
    if not api or not api.GetCurrencyListSize then return end
    local collapsed = {}
    for index = api.GetCurrencyListSize(), 1, -1 do
        local info = api.GetCurrencyListInfo(index)
        if info and info.isHeader and not info.isHeaderExpanded then
            collapsed[info.name] = true
            api.ExpandCurrencyList(index, true)
        end
    end
    local list = {}
    local count = api.GetCurrencyListSize()
    for index = 1, count do
        local info = api.GetCurrencyListInfo(index)
        if info and info.isHeader then
            table.insert(list, { header = info.name })
        elseif info then
            table.insert(list, { info.name, info.quantity or 0, info.maxQuantity or 0, info.iconFileID })
        end
    end
    me.currencies = list
    for index = count, 1, -1 do
        local info = api.GetCurrencyListInfo(index)
        if info and info.isHeader and collapsed[info.name] then api.ExpandCurrencyList(index, false) end
    end
end

local function Percent(value)
    return format("%.2f%%", value or 0)
end

-- lista ya traducida, como la del panel de personaje
local function ScanStats()
    local list = {}
    local function Header(text) table.insert(list, { header = text }) end
    local function Stat(label, value) table.insert(list, { label, value }) end

    Header(L["General"])
    Stat(HEALTH or L["Health"], UnitHealthMax("player"))
    local mana = UnitPowerMax("player", 0)
    if mana and mana > 0 then Stat(MANA or L["Mana"], mana) end

    Header(L["Attributes"])
    for i = 1, 5 do
        local _, value = UnitStat("player", i)
        Stat(_G["SPELL_STAT" .. i .. "_NAME"] or ("stat " .. i), value)
    end

    Header(L["Melee"])
    local low, high = UnitDamage("player")
    Stat(L["Damage"], format("%d - %d", low or 0, high or 0))
    local base, plus, minus = UnitAttackPower("player")
    Stat(L["Attack power"], (base or 0) + (plus or 0) + (minus or 0))
    Stat(L["Critical strike"], Percent(GetCritChance()))
    Stat(L["Hit bonus"], Percent(GetHitModifier and GetHitModifier() or 0))

    local _, rangedLow, rangedHigh = UnitRangedDamage("player")
    if rangedHigh and rangedHigh > 0 then
        Header(L["Ranged"])
        Stat(L["Damage"], format("%d - %d", rangedLow, rangedHigh))
        local rBase, rPlus, rMinus = UnitRangedAttackPower("player")
        Stat(L["Attack power"], (rBase or 0) + (rPlus or 0) + (rMinus or 0))
        Stat(L["Critical strike"], Percent(GetRangedCritChance()))
    end

    Header(L["Spells"])
    local power = 0
    for school = 2, 7 do power = math.max(power, GetSpellBonusDamage(school) or 0) end
    Stat(L["Spell power"], power)
    Stat(L["Healing"], GetSpellBonusHealing() or 0)
    Stat(L["Spell critical strike"], Percent(GetSpellCritChance(2)))
    local regen, casting = GetManaRegen()
    if mana and mana > 0 then
        Stat(L["Mana every 5 s"], format("%d (%d %s)", (regen or 0) * 5, (casting or 0) * 5, L["casting"]))
    end

    Header(L["Defence"])
    local _, armor = UnitArmor("player")
    Stat(ARMOR or L["Armour"], armor or 0)
    Stat(L["Dodge"], Percent(GetDodgeChance()))
    Stat(L["Parry"], Percent(GetParryChance()))
    Stat(L["Block"], Percent(GetBlockChance()))

    Header(L["Resistances"])
    for i, key in ipairs({ "Fire", "Nature", "Frost", "Shadow", "Arcane" }) do
        local _, value = UnitResistance("player", i + 1)
        Stat(L[key], value or 0)
    end
    me.stats = list
end

local statsQueued
local function QueueStats()
    if statsQueued then return end
    statsQueued = true
    C_Timer.After(1, function()
        statsQueued = false
        ScanStats()
    end)
end

-- en Forever los tres arboles clasicos son un solo arbol C_Traits, uno al lado del otro
local TALENT_STEP = 600

local function ReadTalentNodes(configID, treeID)
    local nodes = {}
    for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
        local node = C_Traits.GetNodeInfo(configID, nodeID)
        if node and node.ID and node.ID ~= 0 and node.isVisible ~= false then
            local entryID = node.activeEntry and node.activeEntry.entryID or (node.entryIDs and node.entryIDs[1])
            local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
            local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
            local spell = def and (def.spellID or def.overriddenSpellID)
            if spell then
                local targets = {}
                for _, edge in ipairs(node.visibleEdges or {}) do table.insert(targets, edge.targetNode) end
                table.insert(nodes, { id = nodeID, x = node.posX, y = node.posY, rank = node.currentRank or 0,
                    max = node.maxRanks or 1, spell = spell, entry = entryID, targets = targets })
            end
        end
    end
    return nodes
end

-- fila y columna dentro del arbol; las aristas van del requisito al que lo necesita
local function PlaceTalents(nodes, step, ranks)
    local left, top = math.huge, math.huge
    for _, node in ipairs(nodes) do
        left, top = math.min(left, node.x), math.min(top, node.y)
    end
    local tree, byID, spent = {}, {}, 0
    for _, node in ipairs(nodes) do
        local talent = { id = node.id, spell = node.spell, entry = node.entry, max = node.max,
            icon = C_Spell.GetSpellTexture(node.spell) or 134400,
            tier = math.floor((node.y - top) / step + 0.5) + 1,
            col = math.floor((node.x - left) / step + 0.5) + 1 }
        table.insert(tree, talent)
        byID[node.id] = talent
        ranks[node.id] = node.rank
        spent = spent + node.rank
    end
    for _, node in ipairs(nodes) do
        for _, target in ipairs(node.targets) do
            if byID[target] then byID[target].req = node.id end
        end
    end
    table.sort(tree, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.col < b.col
    end)
    return tree, spent
end

local function ScanTalents()
    if not (C_ClassTalents and C_Traits) then return end
    local configID = C_ClassTalents.GetActiveConfigID()
    local config = configID and C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    if not treeID then return end
    local nodes = ReadTalentNodes(configID, treeID)
    if #nodes == 0 then return end

    -- entre arboles hay mas hueco que una columna vacia
    table.sort(nodes, function(a, b) return a.x < b.x end)
    local groups = {}
    for i, node in ipairs(nodes) do
        if i == 1 or node.x - nodes[i - 1].x > 2.5 * TALENT_STEP then table.insert(groups, {}) end
        table.insert(groups[#groups], node)
    end

    local trees, ranks, spent = {}, {}, {}
    for t, group in ipairs(groups) do
        table.sort(group, function(a, b) return a.y < b.y end)
        local kept = {}
        for i, node in ipairs(group) do
            -- algun nodo interno sale suelto muy por debajo
            if i > 1 and node.y - group[i - 1].y > 3 * TALENT_STEP then break end
            table.insert(kept, node)
        end
        trees[t], spent[t] = PlaceTalents(kept, TALENT_STEP, ranks)
    end

    local currency = C_Traits.GetTreeCurrencyInfo(configID, treeID, false)
    db.talents[me.class] = trees
    me.talents = { ranks = ranks, spent = spent, free = currency and currency[1] and currency[1].quantity or 0, seen = time() }
end

-- arboles de legado: otra configuracion C_Traits, con una moneda comun a los tres
local LEGACY_SYSTEM, LEGACY_STEP = 45, 750
-- en el orden de la ventana de legado, con el nombre que les da el juego
local LEGACY_TREES = { { 1189, "LEGACY_TREE_PROGRESSION" }, { 1188, "LEGACY_TREE_ADVENTURE" }, { 1187, "LEGACY_TREE_PROFESSIONS" } }

local function ScanLegacy()
    if not (C_Traits and C_Traits.GetConfigIDBySystemID) then return end
    local configID = C_Traits.GetConfigIDBySystemID(LEGACY_SYSTEM)
    if not configID then return end
    local trees, ranks, spent, currency = {}, {}, {}, nil
    for t, entry in ipairs(LEGACY_TREES) do
        local nodes = {}
        for _, node in ipairs(ReadTalentNodes(configID, entry[1])) do
            -- nodos de relleno sin hechizo de verdad
            if C_Spell.GetSpellName(node.spell) ~= UNKNOWN then table.insert(nodes, node) end
        end
        if #nodes == 0 then return end
        trees[t], spent[t] = PlaceTalents(nodes, LEGACY_STEP, ranks)
        currency = currency or C_Traits.GetTreeCurrencyInfo(configID, entry[1], false)
    end
    -- el bote es de la cuenta; cada pj gasta el suyo por su cuenta
    currency = currency and currency[1] or {}
    db.legacy = trees
    db.legacyPoints = currency.maxQuantity or db.legacyPoints
    me.legacy = { ranks = ranks, spent = spent, seen = time() }
end

local talentsQueued
local function QueueTalents()
    if talentsQueued then return end
    talentsQueued = true
    C_Timer.After(1, function()
        talentsQueued = false
        RunScan(ScanTalents)
        RunScan(ScanLegacy)
    end)
end

local function ScanPlayer()
    me.name = UnitName("player")
    me.realm = GetRealmName()
    me.className, me.class = UnitClass("player")
    me.race = UnitRace("player")
    me.level = UnitLevel("player")
    me.guild = GetGuildInfo("player")
    me.money = GetMoney()
    MarkGold(me)
    me.xp, me.xpMax = UnitXP("player"), UnitXPMax("player")
    me.rested = GetXPExhaustion() or 0
    me.resting = IsResting() and true or false
    me.zone = GetRealZoneText()
    me.lastSeen = time()
end

-- /played sin que salga en el chat
local muted = {}

local function AskPlayed()
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame and frame:IsEventRegistered("TIME_PLAYED_MSG") then
            frame:UnregisterEvent("TIME_PLAYED_MSG")
            table.insert(muted, frame)
        end
    end
    RequestTimePlayed()
    C_Timer.After(10, function()
        for _, frame in ipairs(muted) do frame:RegisterEvent("TIME_PLAYED_MSG") end
        wipe(muted)
    end)
end

-- ------------------------------------------------------------------ tooltip

local function ItemName(id)
    local name = db.names[id] or C_Item.GetItemNameByID(id)
    if not name and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(id)
    end
    return name
end

local PLACES = {
    { "bags", "bags" },
    { "bank", "bank" },
    { "mail", "mail" },
    { "worn", "equipped" },
    { "ah",   "auction" },
}

local function AddOwners(tooltip, itemID)
    if not db.options.tooltip or not itemID then return end
    local options = db.options
    local lines, grand = {}, 0
    for _, c in ipairs(SortedChars()) do
        if not (c == me and options.tooltipSkipMe) then
            local total, parts = 0, {}
            for _, place in ipairs(PLACES) do
                local count = c[place[1]] and c[place[1]][itemID]
                if count and count > 0 then
                    total = total + count
                    table.insert(parts, format("%s %d", L[place[2]], count))
                end
            end
            if total > 0 then
                grand = grand + total
                table.insert(lines, { c, total, table.concat(parts, ", ") })
            end
        end
    end
    if #lines == 0 then return end

    tooltip:AddLine(" ")
    if options.tooltipTotalOnly then
        tooltip:AddDoubleLine(L["Your characters"], tostring(grand), theme.header[1], theme.header[2], theme.header[3], 1, 1, 1)
        tooltip:Show()
        return
    end
    local detail = not options.tooltipShift or IsShiftKeyDown()
    for _, line in ipairs(lines) do
        local right = detail and format("%d |cff999999(%s)|r", line[2], line[3]) or tostring(line[2])
        tooltip:AddDoubleLine(ClassColored(line[1]), right, 1, 1, 1, 1, 1, 1)
    end
    if #lines > 1 then
        tooltip:AddDoubleLine(L["Total"], tostring(grand), theme.header[1], theme.header[2], theme.header[3], 1, 1, 1)
    end
    tooltip:Show()
end

-- subclase de receta -> linea de habilidad
local RECIPE_SKILL = { [1] = 165, [2] = 197, [3] = 202, [4] = 164, [5] = 185, [6] = 171, [7] = 129, [8] = 333, [9] = 356, [10] = 755 }
local DIFFICULTY_COLORS = { [0] = "|cffff8040", "|cffffff00", "|cff40bf40", "|cff808080" }

local requiresPattern
local function RequiredSkill(lines)
    if not requiresPattern then
        local text = ITEM_MIN_SKILL or "Requires %s (%d)"
        requiresPattern = "^" .. text:gsub("([%(%)%.%-%+%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", ".-"):gsub("%%%%d", "(%%d+)") .. "$"
    end
    for _, text in ipairs(lines) do
        local level = text:match(requiresPattern)
        if level then return tonumber(level) end
    end
end

local function RecipeIDsByName(name)
    if not recipeIndex then
        recipeIndex = {}
        for id, recipe in pairs(db.recipes) do
            if recipe.name then
                local key = recipe.name:lower()
                recipeIndex[key] = recipeIndex[key] or {}
                table.insert(recipeIndex[key], id)
            end
        end
    end
    return recipeIndex[name:lower()] or {}
end

local function TooltipLines(tooltip, data)
    local lines = {}
    if data and data.lines then
        for _, line in ipairs(data.lines) do
            if line.leftText then table.insert(lines, line.leftText) end
        end
    elseif tooltip:GetName() then
        for i = 1, tooltip:NumLines() do
            local left = _G[tooltip:GetName() .. "TextLeft" .. i]
            if left and left:GetText() then table.insert(lines, left:GetText()) end
        end
    end
    return lines
end

local function SkillLineOf(prof)
    return prof and (prof.skillLine or db.skillLines[prof.name])
end

local function ProfessionOf(c, skillLine)
    for _, prof in ipairs(c.profs or {}) do
        if prof and SkillLineOf(prof) == skillLine then return prof end
    end
end

local function AddRecipeOwners(tooltip, itemID, data)
    if not db.options.tooltip or not itemID then return end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    local skillLine = classID == 9 and RECIPE_SKILL[subClassID]
    if not skillLine then return end
    local itemName = ItemName(itemID)
    if not itemName then return end

    local ids = RecipeIDsByName(itemName:match("^[^:]+:%s*(.+)$") or itemName)
    local required = RequiredSkill(TooltipLines(tooltip, data)) or 0
    local known, canLearn, later, unknown = {}, {}, {}, {}
    for _, c in ipairs(SortedChars()) do
        local prof = ProfessionOf(c, skillLine)
        if prof then
            local list = c.recipes and c.recipes[skillLine]
            local knows
            for _, id in ipairs(ids) do
                if list and list[id] then knows = true end
            end
            if knows then
                table.insert(known, ClassColored(c))
            elseif prof.rank >= required and list then
                table.insert(canLearn, ClassColored(c))
            elseif prof.rank < required then
                table.insert(later, format("%s (%d/%d)", ClassColored(c), prof.rank, required))
            else
                table.insert(unknown, ClassColored(c))
            end
        end
    end
    if #known + #canLearn + #later + #unknown == 0 then return end

    tooltip:AddLine(" ")
    if #known > 0 then tooltip:AddLine(format(L["Already known by: %s"], table.concat(known, ", ")), 0.4, 0.85, 0.4, true) end
    if #canLearn > 0 then tooltip:AddLine(format(L["Can learn it: %s"], table.concat(canLearn, ", ")), 1, 0.85, 0.2, true) end
    if #later > 0 then tooltip:AddLine(format(L["Not enough skill yet: %s"], table.concat(later, ", ")), 1, 0.5, 0.25, true) end
    if #unknown > 0 then tooltip:AddLine(format(L["Open the profession to check: %s"], table.concat(unknown, ", ")), 0.6, 0.6, 0.6, true) end
    tooltip:Show()
end

local function HookTooltips()
    if TooltipDataProcessor and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then
                AddOwners(tooltip, data and data.id)
                AddRecipeOwners(tooltip, data and data.id, data)
            end
        end)
    else
        for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
            tooltip:HookScript("OnTooltipSetItem", function(self)
                local _, link = self:GetItem()
                local id = link and tonumber(link:match("item:(%d+)"))
                AddOwners(self, id)
                AddRecipeOwners(self, id)
            end)
        end
    end
end

-- ------------------------------------------------------------------ ventana

-- lineas sueltas: un rectangulo detras se veria al bajar la opacidad
local function Border(frame, size)
    local sides = {
        { "TOPLEFT", "TOPRIGHT", 0, -size, "y" },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, size, "y" },
        { "TOPLEFT", "BOTTOMLEFT", size, 0, "x" },
        { "TOPRIGHT", "BOTTOMRIGHT", -size, 0, "x" },
    }
    for _, side in ipairs(sides) do
        local line = Skin(frame:CreateTexture(nil, "BACKGROUND"), "border")
        line:SetPoint(side[1])
        line:SetPoint(side[2])
        if side[5] == "y" then line:SetHeight(size) else line:SetWidth(size) end
    end
end

local function Box(parent, faceRole)
    Border(parent, 1)
    local face = Skin(parent:CreateTexture(nil, "BORDER"), faceRole)
    face:SetPoint("TOPLEFT", 1, -1)
    face:SetPoint("BOTTOMRIGHT", -1, 1)
    return face
end

local function MakeButton(parent, width, label, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, 22)
    btn.face = Box(btn, "button")
    btn.label = Skin(btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    btn.label:SetPoint("CENTER")
    btn.label:SetText(label)
    btn:SetScript("OnEnter", function(self)
        if self.face.role == "button" then Skin(self.face, "hover") end
    end)
    btn:SetScript("OnLeave", function(self)
        if self.face.role == "hover" then Skin(self.face, "button") end
    end)
    btn:SetScript("OnClick", onClick)

    local native = CreateFrame("Button", nil, btn, "UIPanelButtonTemplate")
    native:SetAllPoints()
    native:SetNormalFontObject(GameFontNormalSmall)
    native:SetHighlightFontObject(GameFontHighlightSmall)
    native:SetText(label)
    native:SetScript("OnClick", function(_, mouse)
        if onClick then onClick(btn, mouse) end
    end)
    btn.native = native
    btn.SetLabel = function(self, text)
        self.label:SetText(text)
        self.native:SetText(text)
    end
    btn.SetNative = function(self, on)
        self.native:SetShown(on)
        self.face:SetShown(not on)
        self.label:SetShown(not on)
    end
    btn:SetNative(theme.native)
    table.insert(natives, btn)
    return btn
end

local function SetSelected(btn, on)
    Skin(btn.face, on and "selected" or "button")
    if on then btn.native:LockHighlight() else btn.native:UnlockHighlight() end
end

local function MakeCheck(parent, label, key, onChange)
    local check = CreateFrame("Button", nil, parent)
    check:SetSize(18, 18)
    local face = Box(check, "box")
    local mark = check:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mark:SetPoint("CENTER")
    local text = Skin(check:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    text:SetPoint("LEFT", check, "RIGHT", 6, 0)
    text:SetText(label)
    check:SetHitRectInsets(0, -(text:GetStringWidth() + 6), 0, 0)
    check:SetScript("OnEnter", function() Skin(face, "hover") end)
    check:SetScript("OnLeave", function() Skin(face, "box") end)
    check:SetScript("OnClick", function()
        db.options[key] = not db.options[key]
        if onChange then onChange() end
        check.Update()
    end)
    local native = CreateFrame("CheckButton", nil, check, "UICheckButtonTemplate")
    native:SetSize(24, 24)
    native:SetPoint("CENTER")
    native:SetScript("OnClick", function() check:GetScript("OnClick")(check) end)
    check.Update = function()
        mark:SetText(db.options[key] and "|cff66dd66x|r" or "")
        native:SetChecked(db.options[key] and true or false)
    end
    check.SetNative = function(_, on)
        native:SetShown(on)
        face:SetShown(not on)
        mark:SetShown(not on)
    end
    check:SetNative(theme.native)
    table.insert(natives, check)
    check:SetScript("OnShow", check.Update)
    return check
end

local function MakeTable(parent, columns, top, rows)
    local t = CreateFrame("Frame", nil, parent)
    t:SetPoint("TOPLEFT", 12, top)
    t:SetPoint("RIGHT", -12, 0)
    t:SetHeight(18 + rows * ROW_HEIGHT)
    t.offset = 0

    -- con sort, clic en la cabecera
    t.headers = {}
    for _, col in ipairs(columns) do
        local holder = t
        if col.sort then
            holder = CreateFrame("Button", nil, t)
            holder:SetPoint("TOPLEFT", col.x, 0)
            holder:SetSize(col.width, 16)
            holder:SetScript("OnClick", function()
                local current = db.options.sorts[t.id] or {}
                local desc = col.desc or false
                if current.key == col.key then desc = not current.desc end
                db.options.sorts[t.id] = { key = col.key, desc = desc }
                t.offset = 0
                t:Refresh()
            end)
            holder:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(L["Click: sort by this column"], 1, 1, 1)
                GameTooltip:Show()
            end)
            holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        local header = Skin(holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "header")
        if holder == t then
            header:SetPoint("TOPLEFT", col.x, 0)
        else
            header:SetPoint("TOPLEFT", 0, 0)
        end
        header:SetWidth(col.width)
        header:SetWordWrap(false)
        header:SetJustifyH(col.justify or "LEFT")
        header:SetText(L[col.title])
        header.title = L[col.title]
        t.headers[col.key] = header
    end

    t.rows = {}
    for i = 1, rows do
        local row = CreateFrame("Button", nil, t)
        row:SetPoint("TOPLEFT", 0, -18 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT")
        row:SetHeight(ROW_HEIGHT)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        if i % 2 == 0 then
            Skin(row:CreateTexture(nil, "BACKGROUND"), "stripe"):SetAllPoints()
        end
        local light = Skin(row:CreateTexture(nil, "BORDER"), "row")
        light:SetAllPoints()
        light:Hide()

        row.cells = {}
        for _, col in ipairs(columns) do
            local cell = Skin(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), "text")
            cell:SetPoint("LEFT", col.x, 0)
            cell:SetWidth(col.width)
            cell:SetJustifyH(col.justify or "LEFT")
            cell:SetWordWrap(false)
            row.cells[col.key] = cell
        end

        row:SetScript("OnEnter", function(self)
            light:Show()
            if t.onEnter and self.data then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                t.onEnter(self.data)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function()
            light:Hide()
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self, mouse)
            if t.onClick and self.data then t.onClick(self.data, mouse, self) end
        end)
        t.rows[i] = row
    end

    t:EnableMouseWheel(true)
    t:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta
        self:Refresh()
    end)

    local ARROWS = {
        [false] = " |TInterface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up:12:12|t",
        [true]  = " |TInterface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up:12:12|t",
    }

    function t:Refresh()
        local items = self.source()
        local chosen = self.id and db.options.sorts[self.id]
        local sortCol
        for _, col in ipairs(columns) do
            if chosen and col.key == chosen.key and col.sort then sortCol = col end
        end
        for key, header in pairs(self.headers) do
            -- la flecha solo si cabe
            header:SetText(header.title)
            if sortCol and key == sortCol.key then
                header:SetText(header.title .. ARROWS[chosen.desc])
                local measure = header.GetUnboundedStringWidth or header.GetStringWidth
                if (measure(header) or 0) > header:GetWidth() then header:SetText(header.title) end
                header:SetTextColor(theme.text[1], theme.text[2], theme.text[3])
            else
                Paint(header)
            end
        end
        if sortCol then
            local get, desc, tie = sortCol.sort, chosen.desc, columns[1].sort
            table.sort(items, function(a, b)
                local x, y = get(a), get(b)
                if x == y then
                    if tie then return tie(a) < tie(b) end
                    return false
                end
                if desc then return x > y end
                return x < y
            end)
        end
        self.offset = math.max(0, math.min(self.offset, #items - rows))
        for i, row in ipairs(self.rows) do
            local item = items[i + self.offset]
            row.data = item
            if item then
                for _, cell in pairs(row.cells) do cell:SetText("") end
                self.fill(row.cells, item)
                row:Show()
            else
                row:Hide()
            end
        end
        if self.after then self.after(items) end
    end
    return t
end

-- pestana de personajes

local function CharacterTooltip(c)
    GameTooltip:AddLine(ClassColored(c, c.name .. (c.realm and (" - " .. c.realm) or "")))
    GameTooltip:AddLine(format(L["Level %d %s %s"], c.level or 0, c.race or "", c.className or ""), 1, 1, 1)
    local progress = LevelProgress(c)
    if progress then
        GameTooltip:AddDoubleLine(L["Experience"], format("%d / %d (%d%%)", c.xp or 0, c.xpMax, progress * 100), 1, 0.82, 0, 1, 1, 1)
    end
    if c.guild then GameTooltip:AddLine("<" .. c.guild .. ">", 0.6, 1, 0.6) end
    GameTooltip:AddLine(" ")
    if c.bagSlots then
        GameTooltip:AddDoubleLine(L["Free bag slots"], format("%d / %d", c.bagFree, c.bagSlots), 1, 0.82, 0, 1, 1, 1)
    end
    if c.bankSeen then
        GameTooltip:AddDoubleLine(L["Bank seen"], format(L["%s ago"], Duration(time() - c.bankSeen)), 1, 0.82, 0, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine(L["Bank seen"], L["never"], 1, 0.82, 0, 0.6, 0.6, 0.6)
    end
    if c.mailLetters and c.mailLetters > 0 then
        local left = L["no hurry"]
        if c.mailExpires then
            local seconds = c.mailExpires - time()
            left = seconds > 0 and format(L["expires in %s"], Duration(seconds)) or L["expired"]
        end
        GameTooltip:AddDoubleLine(format(L["Mail: %d"], c.mailLetters), left, 1, 0.82, 0, 1, 1, 1)
        if (c.mailMoney or 0) > 0 then
            GameTooltip:AddDoubleLine(L["Gold in mail"], Money(c.mailMoney), 1, 0.82, 0, 1, 1, 1)
        end
    end
    if c.goldWeek == date("%Y-%W") then
        GameTooltip:AddDoubleLine(L["Gold today"], MoneyChange(GoldToday(c)), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["Gold this week"], MoneyChange(GoldWeek(c)), 1, 0.82, 0, 1, 1, 1)
    end
    if c.auctions and #c.auctions > 0 then
        GameTooltip:AddDoubleLine(L["Auctions"], #c.auctions, 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Left click: open the character"], 0.6, 0.6, 0.6)
    GameTooltip:AddLine(L["Right click: hide or forget this character"], 0.6, 0.6, 0.6)
end

local function RestedText(c)
    local rested = Rested(c)
    if not rested then return "-" end
    local color = rested >= REST_CAP and "|cff66dd66" or "|cff8fb8ff"
    return format("%s%d%%|r", color, rested * 100)
end

local function PlayedText(c)
    return c.played and Duration(Played(c)) or "-"
end

local function SeenText(c)
    return c == me and L["now"] or Duration(time() - (c.lastSeen or time()))
end

local function FillCharacter(cells, c)
    cells.name:SetText(ClassIcon(c) .. ClassColored(c) .. (c.hidden and (" |cff808080" .. L["(hidden)"] .. "|r") or ""))
    cells.level:SetText(LevelText(c))
    cells.zone:SetText(c.zone or "")
    cells.money:SetText(Money(c.money))
    cells.rested:SetText(RestedText(c))
    cells.played:SetText(PlayedText(c))
    cells.seen:SetText(SeenText(c))
end

-- ocultar no borra; olvidar si, salvo al actual
local function CharacterDialog(key, text, action, forget)
    StaticPopupDialogs[key] = {
        text = text,
        button1 = action,
        button2 = CANCEL,
        button3 = forget and L["Forget"] or nil,
        OnAccept = function(_, guid)
            local c = db.chars[guid]
            if c then c.hidden = not c.hidden or nil end
            RefreshWindow()
        end,
        OnAlt = function(_, guid)
            local c = db.chars[guid]
            if c then StaticPopup_Show("ALTERSFOREVER_FORGET", c.name, nil, guid) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
end

CharacterDialog("ALTERSFOREVER_HIDE", L["Hide %s from the lists and tooltips? Nothing is deleted."], L["Hide"], true)
CharacterDialog("ALTERSFOREVER_SHOW", L["Show %s again?"], L["Show"], true)
CharacterDialog("ALTERSFOREVER_HIDE_ME", L["Hide %s from the lists and tooltips? Nothing is deleted."], L["Hide"], false)
CharacterDialog("ALTERSFOREVER_SHOW_ME", L["Show %s again?"], L["Show"], false)

StaticPopupDialogs.ALTERSFOREVER_FORGET = {
    text = L["Forget the saved data of %s?"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, guid)
        db.chars[guid] = nil
        RefreshWindow()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- pestana de profesiones

local function ProfessionCell(prof)
    if not prof then return "" end
    local color = prof.rank >= prof.max and "|cffff9933" or "|cffffffff"
    return format("|T%s:14:14|t %s%d/%d|r", prof.icon or 134400, color, prof.rank, prof.max)
end

local function FillProfessions(cells, c)
    cells.name:SetText(ClassIcon(c) .. ClassColored(c) .. (c.hidden and (" |cff808080" .. L["(hidden)"] .. "|r") or ""))
    cells.level:SetText(LevelText(c))
    local profs = c.profs or {}
    for slot = 1, 5 do
        cells["p" .. slot]:SetText(ProfessionCell(profs[slot]))
    end
end

local function ProfessionsTooltip(c)
    GameTooltip:AddLine(ClassColored(c))
    local any
    for _, prof in ipairs(c.profs or {}) do
        if prof then
            any = true
            GameTooltip:AddDoubleLine(format("|T%s:14:14|t %s", prof.icon or 134400, prof.name), format("%d / %d", prof.rank, prof.max), 1, 1, 1, 1, 1, 1)
        end
    end
    if not any then GameTooltip:AddLine(L["No professions"], 0.6, 0.6, 0.6) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Orange: at the cap, time to visit a trainer"], 1, 0.6, 0.2, true)
    GameTooltip:AddLine(L["Click: its professions and recipes"], 0.6, 0.6, 0.6)
end

-- pestana de busqueda

local function QualityColored(id, name)
    local quality = C_Item.GetItemQualityByID(id)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color and color.hex then
        return color.hex .. name .. "|r"
    end
    return name
end

local function SearchResults(query)
    local results = {}
    query = strtrim(query or ""):lower()
    if #query < 2 then return results end
    local found = {}
    for _, c in ipairs(SortedChars()) do
        for _, place in ipairs(PLACES) do
            for id, count in pairs(c[place[1]] or {}) do
                local name = ItemName(id)
                if name and name:lower():find(query, 1, true) then
                    local entry = found[id]
                    if not entry then
                        entry = { id = id, name = name, total = 0, owners = {}, order = {} }
                        found[id] = entry
                        table.insert(results, entry)
                    end
                    if not entry.owners[c] then
                        entry.owners[c] = 0
                        table.insert(entry.order, c)
                    end
                    entry.owners[c] = entry.owners[c] + count
                    entry.total = entry.total + count
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end

local function FillSearch(cells, entry)
    local icon = C_Item.GetItemIconByID(entry.id) or 134400
    cells.item:SetText(format("|T%s:14:14|t %s", icon, QualityColored(entry.id, entry.name)))
    local owners = {}
    for _, c in ipairs(entry.order) do
        table.insert(owners, format("%s %d", ClassColored(c), entry.owners[c]))
    end
    cells.who:SetText(table.concat(owners, ", "))
    cells.total:SetText(entry.total)
end

-- ficha del personaje

local DOLL_LEFT = { "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot", "WristSlot" }
local DOLL_RIGHT = { "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot" }
local DOLL_BOTTOM = { "MainHandSlot", "SecondaryHandSlot", "RangedSlot" }
local DOLL_SLOT, DOLL_STEP = 26, 28

local BAG_SLOT = 32
local BAG_ICONS = {
    [-1] = "Interface\\Icons\\INV_Misc_Key_03",
    [0]  = "Interface\\Buttons\\Button-Backpack-Up",
    bank = "Interface\\Icons\\INV_Box_02",
}
local BAG_NAMES = {
    [-1] = KEYRING or "Keyring",
    [0]  = BACKPACK_TOOLTIP or "Backpack",
    bank = _G.BANK or "Bank",
}

local FILTERS = {
    { "bags", "Bags" },
    { "bank", "Bank" },
    { "mail", "Mail" },
    { "worn", "Equipped" },
    { "ah",   "Auction" },
    { "all",  "All" },
}

-- en bolsas y banco apaga en vez de quitar
local DIM_SEARCH = { bags = true, bank = true }

local function CharacterItems(c, filter, query)
    local found, list = {}, {}
    query = strtrim(query or ""):lower()
    for _, place in ipairs(PLACES) do
        if filter == "all" or filter == place[1] then
            for id, count in pairs(c[place[1]] or {}) do
                local name = ItemName(id) or ("item:" .. id)
                local match = query == "" or name:lower():find(query, 1, true)
                if match or DIM_SEARCH[filter] then
                    local entry = found[id]
                    if not entry then
                        entry = { id = id, name = name, total = 0, parts = {}, dim = not match }
                        found[id] = entry
                        table.insert(list, entry)
                    end
                    entry.total = entry.total + count
                    table.insert(entry.parts, format("%s %d", L[place[2]], count))
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- casillas como las de la bolsa
local SLOT, GAP = 37, 5

local function SetSlotItem(slot, item, count)
    slot.item = item
    slot.icon:SetTexture(C_Item.GetItemIconByID(item) or 134400)
    slot.icon:SetDesaturated(false)
    slot.count:SetText(count and count > 1 and count or "")
    local quality = C_Item.GetItemQualityByID(item)
    local color = quality and quality >= 2 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then
        slot.quality:SetVertexColor(color.r, color.g, color.b)
        slot.quality:Show()
    else
        slot.quality:Hide()
    end
end

-- item puede ser un id o un enlace
local function MakeSlot(parent, size)
    local slot = CreateFrame("Button", nil, parent)
    slot:SetSize(size, size)
    Box(slot, "box")

    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetPoint("TOPLEFT", 2, -2)
    slot.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    slot.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    slot.quality = slot:CreateTexture(nil, "OVERLAY")
    slot.quality:SetTexture("Interface\\Common\\WhiteIconFrame")
    slot.quality:SetAllPoints()

    slot.count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    slot.count:SetPoint("BOTTOMRIGHT", -3, 3)

    slot.SetItem = SetSlotItem
    slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    slot:SetScript("OnEnter", function(self)
        if not self.item and not self.empty then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if type(self.item) == "string" then
            GameTooltip:SetHyperlink(self.item)
        elseif self.item then
            GameTooltip:SetItemByID(self.item)
        else
            GameTooltip:SetText(self.empty, 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
    slot:SetScript("OnClick", function(self)
        if not self.item or not IsModifiedClick() then return end
        local link = self.item
        if type(link) ~= "string" then link = select(2, C_Item.GetItemInfo(link)) end
        if link then HandleModifiedItemClick(link) end
    end)
    return slot
end

local function MakeGrid(parent, top, cols, rows)
    local grid = CreateFrame("Frame", nil, parent)
    grid:SetPoint("TOPLEFT", 12, top)
    grid:SetSize(cols * (SLOT + GAP), rows * (SLOT + GAP))
    grid.offset = 0
    grid.slots = {}

    for i = 1, cols * rows do
        local slot = MakeSlot(grid, SLOT)
        slot:SetPoint("TOPLEFT", ((i - 1) % cols) * (SLOT + GAP), -math.floor((i - 1) / cols) * (SLOT + GAP))
        grid.slots[i] = slot
    end

    grid:EnableMouseWheel(true)
    grid:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta
        self:Refresh()
    end)

    function grid:Refresh()
        local items = self.source()
        local lastRow = math.max(0, math.ceil(#items / cols) - rows)
        self.offset = math.max(0, math.min(self.offset, lastRow))
        for i, slot in ipairs(self.slots) do
            local entry = items[i + self.offset * cols]
            if entry then
                slot:SetItem(entry.id, entry.total)
                local lit = self.highlight and self.highlight[entry.id]
                local dim = self.highlight and not lit or (not self.highlight and entry.dim)
                slot:SetAlpha(dim and 0.2 or 1)
                if lit then slot:LockHighlight() else slot:UnlockHighlight() end
                slot:Show()
            else
                slot:Hide()
            end
        end
        if self.after then self.after(items, lastRow > 0) end
    end
    return grid
end

-- reputacion

local function StandingLabel(reaction)
    return _G["FACTION_STANDING_LABEL" .. (reaction or 4)] or tostring(reaction)
end

local function StandingColor(reaction)
    local color = FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction or 4]
    if color then return format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255) end
    return "|cffffffff"
end

-- cabeceras en el orden del juego y sus facciones debajo
local function ReputationRows(c)
    local groups, order = {}, {}
    for id in pairs(c.reps or {}) do
        local faction = db.factions[id] or { name = tostring(id), order = 9999 }
        local key = faction.header or ""
        if not groups[key] then
            groups[key] = { name = key, first = faction.order, list = {} }
            table.insert(order, groups[key])
        end
        local group = groups[key]
        group.first = math.min(group.first, faction.order)
        table.insert(group.list, { id = id, name = faction.name, order = faction.order })
    end
    table.sort(order, function(a, b) return a.first < b.first end)
    local rows = {}
    for _, group in ipairs(order) do
        if group.name ~= "" then table.insert(rows, { header = group.name }) end
        table.sort(group.list, function(a, b) return a.order < b.order end)
        for _, faction in ipairs(group.list) do table.insert(rows, faction) end
    end
    return rows
end

local InfoRows

local SECTIONS = {
    { "items",      "Items",      "Interface\\Icons\\INV_Misc_Bag_08" },
    { "talents",    "Talents",    "Interface\\Icons\\Ability_Marksmanship" },
    { "legacy",     "Legacy",     "Interface\\Icons\\achievement_guildperk_everybodysfriend" },
    { "reps",       "Reputation", "Interface\\Icons\\INV_Shield_06" },
    { "skills",     "Skills",     "Interface\\Icons\\INV_Misc_Book_09" },
    { "pvp",        "PvE/PvP",    "Interface\\Icons\\Ability_DualWield" },
    { "currencies", "Currency",   "Interface\\Icons\\INV_Misc_Coin_01" },
    { "stats",      "Statistics", "Interface\\Icons\\INV_Scroll_03" },
}

function InfoRows(c, section)
    local rows = {}
    if section == "reps" then
        for _, entry in ipairs(ReputationRows(c)) do
            if entry.header then
                table.insert(rows, entry)
            else
                local rep = c.reps[entry.id]
                table.insert(rows, { entry.name, StandingColor(rep[1]) .. StandingLabel(rep[1]) .. "|r",
                    rep[3] > 0 and format("%d / %d", rep[2], rep[3]) or "" })
            end
        end
    elseif section == "skills" then
        for _, skill in ipairs(c.skills or {}) do
            if skill.header then
                table.insert(rows, skill)
            else
                local bonus = (skill[4] or 0) ~= 0 and format(" |cff40bf40%+d|r", skill[4]) or ""
                table.insert(rows, { skill[1], format("%d / %d", skill[2], skill[3]) .. bonus })
            end
        end
    elseif section == "currencies" then
        for _, currency in ipairs(c.currencies or {}) do
            if currency.header then
                table.insert(rows, currency)
            else
                local icon = currency[4] and format("|T%s:14:14|t ", currency[4]) or ""
                table.insert(rows, { icon .. currency[1], currency[2], currency[3] > 0 and format(L["max %d"], currency[3]) or "" })
            end
        end
    elseif section == "pvp" then
        if c.lockoutsSeen then
            table.insert(rows, { header = L["Saved instances"] })
            local any
            for _, lockout in ipairs(c.lockouts or {}) do
                local left = lockout[2] - time()
                if left > 0 then
                    any = true
                    local name = lockout[1] .. (lockout[3] and lockout[3] ~= "" and ("  |cff999999" .. lockout[3] .. "|r") or "")
                    table.insert(rows, { name, lockout[5] > 0 and format(L["%d/%d bosses"], lockout[4], lockout[5]) or "",
                        format(L["resets in %s"], Duration(left)) })
                end
            end
            if not any then table.insert(rows, { "|cff999999" .. L["No saved instances"] .. "|r" }) end
        end
        local pvp = c.pvp
        if not pvp then return rows end
        table.insert(rows, { header = L["Honourable kills"] })
        table.insert(rows, { L["Today"], pvp.session[1] or 0 })
        table.insert(rows, { L["Yesterday"], pvp.yesterday[1] or 0 })
        table.insert(rows, { L["Total"], pvp.lifetime[1] or 0 })
        if pvp.honor or pvp.honorLevel then
            table.insert(rows, { header = L["Honour"] })
            if pvp.honor then table.insert(rows, { L["Honour"], pvp.honor }) end
            if pvp.honorLevel then table.insert(rows, { L["Honour level"], pvp.honorLevel }) end
        end
    elseif section == "stats" then
        rows = c.stats or rows
    elseif section == "ah" and c.auctionsSeen then
        local function Add(entry, status)
            local id, link, count = entry[1], entry[2], entry[3]
            local name = (link and link:match("%[(.-)%]")) or ItemName(id) or ("item:" .. id)
            local icon = C_Item.GetItemIconByID(id) or 134400
            local price = count > 1 and (Money(entry[4]) .. " " .. L["each"]) or Money(entry[4])
            table.insert(rows, { format("|T%s:14:14|t %s%s", icon, QualityColored(id, name), count > 1 and (" x" .. count) or ""),
                price, status, item = link or id })
        end
        table.insert(rows, { header = L["For sale"] .. "  |cff999999" .. format(L["(seen %s ago)"], Duration(time() - c.auctionsSeen)) .. "|r" })
        for _, auction in ipairs(c.auctions or {}) do
            local left = auction[5] - time()
            local status = auction[6] and ("|cff40bf40" .. L["sold"] .. "|r")
                or (left > 0 and Duration(left)) or ("|cff999999" .. L["ended"] .. "|r")
            Add(auction, status)
        end
        if #(c.bids or {}) > 0 then
            table.insert(rows, { header = L["Bids"] })
            for _, bid in ipairs(c.bids) do
                local left = bid[5] - time()
                Add(bid, left > 0 and Duration(left) or ("|cff999999" .. L["ended"] .. "|r"))
            end
        end
    end
    return rows
end

local function BuildCharacterPage(page)
    local name = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("TOPLEFT", 16, -8)

    local back = MakeButton(page, 100, L["Back"], function() window.ShowTab(window.lastTab or 1) end)
    back:SetPoint("TOPRIGHT", -12, -6)

    -- secciones como iconos junto al nombre, con borde dorado como los del minimapa
    local function SectionIcon(section)
        local btn = CreateFrame("Button", nil, page, "BackdropTemplate")
        btn:SetSize(26, 29)
        btn:SetBackdrop({ edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", edgeSize = 8 })
        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetPoint("TOPLEFT", 3, -3)
        btn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
        btn.icon:SetTexture(section[3])
        btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(L[section[2]])
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function()
            window.section = section[1]
            page.table.offset = 0
            page.info.offset = 0
            RefreshWindow()
        end)
        btn.key = section[1]
        return btn
    end

    page.sectionButtons = {}
    for i, section in ipairs(SECTIONS) do
        local btn = SectionIcon(section)
        if i == 1 then
            btn:SetPoint("LEFT", name, "RIGHT", 10, 0)
        else
            btn:SetPoint("LEFT", page.sectionButtons[i - 1], "RIGHT", 4, 0)
        end
        table.insert(page.sectionButtons, btn)
    end

    -- el mismo dibujo que los botones de la barra
    local function CopyMicroIcon(micro, icon)
        local source = micro and micro.GetNormalTexture and micro:GetNormalTexture()
        if not source then return end
        local atlas = source:GetAtlas()
        if atlas then
            icon:SetAtlas(atlas)
        elseif source:GetTexture() then
            icon:SetTexture(source:GetTexture())
            icon:SetTexCoord(source:GetTexCoord())
        end
    end
    CopyMicroIcon(TalentMicroButton or PlayerSpellsMicroButton, page.sectionButtons[2].icon)
    CopyMicroIcon(LegacyMicroButton, page.sectionButtons[3].icon)

    local info = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    info:SetPoint("TOPLEFT", 16, -30)
    local stats = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    stats:SetPoint("TOPLEFT", 16, -46)

    page.filterButtons = {}
    for i, filter in ipairs(FILTERS) do
        local btn = MakeButton(page, 80, L[filter[2]], function()
            window.filter = filter[1]
            page.table.offset = 0
            RefreshWindow()
        end)
        btn:SetPoint("TOPLEFT", 16 + (i - 1) * 86, -64)
        btn.key = filter[1]
        table.insert(page.filterButtons, btn)
    end

    local search = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("TOPLEFT", 16 + #FILTERS * 86 + 12, -65)
    search:SetAutoFocus(false)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    page.search = search

    local items = MakeGrid(page, -96, 17, 6)

    local bagRow = CreateFrame("Frame", nil, page)
    bagRow:SetPoint("TOPLEFT", items, "BOTTOMLEFT", 0, -4)
    bagRow:SetSize(17 * (SLOT + GAP), BAG_SLOT)
    local divider = Skin(bagRow:CreateTexture(nil, "ARTWORK"), "border")
    divider:SetPoint("BOTTOMLEFT", bagRow, "TOPLEFT", 0, 1)
    divider:SetPoint("BOTTOMRIGHT", bagRow, "TOPRIGHT", -GAP, 1)
    divider:SetHeight(1)
    bagRow.slots = {}
    for i = 1, 17 do
        local slot = MakeSlot(bagRow, BAG_SLOT)
        slot:SetPoint("TOPLEFT", (i - 1) * (SLOT + GAP) + (SLOT - BAG_SLOT) / 2, 0)
        slot:SetScript("OnEnter", function(self)
            local bag = self.bag
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if bag.link then
                GameTooltip:SetHyperlink(bag.link)
            else
                GameTooltip:SetText(self.label)
            end
            GameTooltip:AddLine(format(L["%d of %d slots free"], bag.free, bag.size), 1, 1, 1)
            GameTooltip:Show()
            items.highlight = bag.items
            items:Refresh()
        end)
        slot:SetScript("OnLeave", function()
            GameTooltip:Hide()
            items.highlight = nil
            items:Refresh()
        end)
        bagRow.slots[i] = slot
    end

    local bagHint = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "dim")
    bagHint:SetPoint("LEFT", bagRow, "LEFT", 4, 0)

    bagRow.Update = function(c, filter)
        local list = {}
        local function Add(bags)
            for _, bag in ipairs(bags) do
                if c.containers and c.containers[bag] then table.insert(list, bag) end
            end
        end
        if filter == "all" or filter == "bags" then Add(BAGS) end
        if filter == "all" and #list > 0 then table.insert(list, false) end
        if filter == "all" or filter == "bank" then Add(BANK) end
        if list[#list] == false then list[#list] = nil end

        for i, slot in ipairs(bagRow.slots) do
            local bag = list[i]
            local bagInfo = bag and c.containers[bag]
            slot.bag = bagInfo
            if bagInfo then
                if bagInfo.link then
                    slot:SetItem(bagInfo.link)
                else
                    slot.item = nil
                    slot.icon:SetTexture(BAG_ICONS[bag] or BAG_ICONS.bank)
                    slot.icon:SetDesaturated(false)
                    slot.quality:Hide()
                end
                slot.label = BAG_NAMES[bag] or BAG_NAMES.bank
                slot.count:SetText(bagInfo.free)
                slot:Show()
            else
                slot:Hide()
            end
        end
        bagRow:SetShown(#list > 0)

        local hint
        if filter == "bank" and not (c.containers and c.containers[BANK[1]]) then
            hint = L["Open the bank with this character to see its bags."]
        elseif filter == "bags" and #list == 0 then
            hint = L["Log in with this character once to see its bags."]
        end
        bagHint:SetText(hint or "")
        bagHint:SetShown(hint ~= nil)
    end

    local doll = CreateFrame("Frame", nil, page)
    doll:SetPoint("TOPLEFT", 0, -96)
    doll:SetPoint("BOTTOMRIGHT", 0, 30)
    doll.slots = {}
    local function AddDollSlot(slotName, x, y, side)
        local slot = MakeSlot(doll, DOLL_SLOT)
        slot:SetPoint("TOPLEFT", x, y)
        slot.id, slot.background = GetInventorySlotInfo(slotName)
        slot.label = _G[slotName:upper()] or slotName
        if side then
            slot.name = doll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            slot.name:SetWidth(260)
            slot.name:SetWordWrap(false)
            slot.name:SetJustifyH(side)
            if side == "LEFT" then
                slot.name:SetPoint("LEFT", slot, "RIGHT", 8, 0)
            else
                slot.name:SetPoint("RIGHT", slot, "LEFT", -8, 0)
            end
        end
        table.insert(doll.slots, slot)
    end
    for i, slotName in ipairs(DOLL_LEFT) do
        AddDollSlot(slotName, 16, -(i - 1) * DOLL_STEP, "LEFT")
    end
    for i, slotName in ipairs(DOLL_RIGHT) do
        AddDollSlot(slotName, 740 - 16 - DOLL_SLOT, -(i - 1) * DOLL_STEP, "RIGHT")
    end
    for i, slotName in ipairs(DOLL_BOTTOM) do
        AddDollSlot(slotName, 370 - (#DOLL_BOTTOM * DOLL_STEP) / 2 + (i - 1) * DOLL_STEP, -#DOLL_LEFT * DOLL_STEP - 4)
    end

    local noGear = Skin(doll:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "dim")
    noGear:SetPoint("CENTER", doll, "TOP", 0, -100)
    noGear:SetWidth(300)
    noGear:SetText(L["Log in with this character once to see its gear here."])

    -- lo que no encaja con la busqueda se apaga
    doll.Update = function(c, query)
        noGear:SetShown(not c.gear)
        query = strtrim(query or ""):lower()
        for _, slot in ipairs(doll.slots) do
            local link = c.gear and c.gear[slot.id]
            local alpha = 1
            if link then
                slot:SetItem(link)
                slot.empty = nil
                local id = tonumber(link:match("item:(%d+)"))
                local name = link:match("%[(.-)%]") or (id and ItemName(id)) or ""
                if slot.name then slot.name:SetText(id and QualityColored(id, name) or name) end
                if query ~= "" and not name:lower():find(query, 1, true) then alpha = 0.25 end
            else
                slot.item, slot.empty = nil, slot.label
                slot.icon:SetTexture(slot.background)
                slot.icon:SetDesaturated(true)
                slot.quality:Hide()
                slot.count:SetText("")
                if slot.name then slot.name:SetText("") end
                if query ~= "" then alpha = 0.25 end
            end
            slot:SetAlpha(alpha)
            if slot.name then slot.name:SetAlpha(alpha) end
        end
    end
    items.source = function() return CharacterItems(window.detail, window.filter, search:GetText()) end
    search:SetScript("OnTextChanged", function()
        items.offset = 0
        RefreshWindow()
    end)

    local footer = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "dim")
    footer:SetPoint("BOTTOMLEFT", 16, 14)
    items.after = function(list, more)
        local c = window.detail
        local bank = c.bankSeen and format(L["%s ago"], Duration(time() - c.bankSeen)) or L["never"]
        local text = format(L["%d different items"], #list) .. "    " .. L["Bank seen"] .. ": " .. bank
        if more then text = text .. "    " .. L["mouse wheel to see more"] end
        footer:SetText(text)
    end
    page.table = items

    local infoTable = MakeTable(page, {
        { key = "label", title = "", x = 4,   width = 330 },
        { key = "value", title = "", x = 340, width = 180 },
        { key = "extra", title = "", x = 526, width = 186, justify = "RIGHT" },
    }, -64, ROWS - 1)
    local function InfoSection()
        if window.section == "items" then return "ah" end
        return window.section
    end
    infoTable.source = function() return InfoRows(window.detail, InfoSection()) end
    infoTable.onEnter = function(entry)
        if type(entry.item) == "string" then
            GameTooltip:SetHyperlink(entry.item)
        elseif entry.item then
            GameTooltip:SetItemByID(entry.item)
        end
    end
    infoTable.fill = function(cells, entry)
        if entry.header then
            local color = theme.header
            cells.label:SetText(format("|cff%02x%02x%02x%s|r", color[1] * 255, color[2] * 255, color[3] * 255, entry.header))
        else
            cells.label:SetText("  " .. entry[1])
            cells.value:SetText(entry[2] or "")
            cells.extra:SetText(entry[3] or "")
        end
    end
    local infoEmpty = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "dim")
    infoEmpty:SetPoint("TOP", 0, -180)
    infoEmpty:SetWidth(520)
    infoTable.after = function(list)
        infoEmpty:SetShown(#list == 0)
        if InfoSection() == "ah" then
            infoEmpty:SetText(L["Open the auction house with this character to read its auctions."])
        else
            infoEmpty:SetText(L["Log in with this character once to read this."])
        end
    end
    page.info = infoTable

    -- tres arboles de 4 columnas, como la ventana de talentos clasica
    -- source(c) da los arboles, los datos del pj y los nombres
    local TALENT_ICON, TALENT_X, TALENT_Y, TREE_WIDTH = 32, 50, 41, 236
    local function TreePanel(source)
        local talents = CreateFrame("Frame", nil, page)
        talents:SetPoint("TOPLEFT", 16, -64)
        talents:SetPoint("BOTTOMRIGHT", -16, 28)
        talents.trees = {}
        for t = 1, 3 do
            local tree = CreateFrame("Frame", nil, talents)
            tree:SetPoint("TOPLEFT", (t - 1) * TREE_WIDTH, 0)
            tree:SetPoint("BOTTOM")
            tree:SetWidth(TREE_WIDTH - 8)
            Border(tree, 1)
            tree.title = Skin(tree:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "header")
            tree.title:SetPoint("TOP", 0, -6)
            tree.slots, tree.lines = {}, {}
            talents.trees[t] = tree
        end

        local function TalentSlot(tree, i)
            local slot = tree.slots[i]
            if slot then return slot end
            slot = MakeSlot(tree, TALENT_ICON)
            slot.count:SetFontObject("NumberFontNormalSmall")
            slot.count:SetPoint("BOTTOMRIGHT", 2, -2)
            slot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                -- con el rango del pj; sin puntos, lo que da el primero
                if self.entry and GameTooltip.SetTraitEntry then
                    GameTooltip:SetTraitEntry(self.entry, math.max(self.rank, 1))
                else
                    GameTooltip:SetSpellByID(self.spell)
                end
                GameTooltip:AddLine(format(L["Rank %d/%d"], self.rank, self.max), 1, 1, 1)
                GameTooltip:Show()
            end)
            slot:SetScript("OnClick", nil)
            tree.slots[i] = slot
            return slot
        end

        local function TalentLine(tree, i)
            local line = tree.lines[i]
            if line then return line end
            line = tree:CreateLine(nil, "ARTWORK")
            line:SetThickness(2)
            tree.lines[i] = line
            return line
        end

        local talentsEmpty = Skin(talents:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "dim")
        talentsEmpty:SetPoint("TOP", 0, -86)
        talentsEmpty:SetWidth(520)
        talentsEmpty:SetText(L["Log in with this character once to read this."])
        local talentsFooter = Skin(talents:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "dim")
        talentsFooter:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 14)

        talents.Update = function(c)
            local layout, data, names, free, total = source(c)
            talentsEmpty:SetShown(not layout)
            talentsFooter:SetShown(layout ~= nil)
            for t, tree in ipairs(talents.trees) do
                local list = layout and layout[t]
                tree:SetShown(list ~= nil)
                for _, slot in ipairs(tree.slots) do slot:Hide() end
                for _, line in ipairs(tree.lines) do line:Hide() end
                if list then
                    tree.title:SetText(format("%s (%d)", names[t] or (L["Tree"] .. " " .. t), data.spent[t] or 0))
                    local left = (TREE_WIDTH - 8 - 3 * TALENT_X - TALENT_ICON) / 2
                    local byID, lines = {}, 0
                    for i, talent in ipairs(list) do
                        local slot = TalentSlot(tree, i)
                        local rank = data.ranks[talent.id] or 0
                        slot:SetPoint("TOPLEFT", left + (talent.col - 1) * TALENT_X, -26 - (talent.tier - 1) * TALENT_Y)
                        slot.icon:SetTexture(talent.icon)
                        slot.icon:SetDesaturated(rank == 0)
                        slot.quality:Hide()
                        slot.spell, slot.entry, slot.rank, slot.max = talent.spell, talent.entry, rank, talent.max
                        local color = rank == 0 and "|cff999999" or (rank < talent.max and "|cff40ff40" or "|cffffd100")
                        slot.count:SetText(color .. rank .. "/" .. talent.max .. "|r")
                        slot:Show()
                        byID[talent.id] = { slot = slot, talent = talent, rank = rank }
                    end
                    -- del requisito al que lo necesita, dorada si esta completo
                    for _, entry in pairs(byID) do
                        local req = entry.talent.req and byID[entry.talent.req]
                        if req then
                            lines = lines + 1
                            local line = TalentLine(tree, lines)
                            if req.talent.tier == entry.talent.tier then
                                line:SetStartPoint(req.talent.col < entry.talent.col and "RIGHT" or "LEFT", req.slot)
                                line:SetEndPoint(req.talent.col < entry.talent.col and "LEFT" or "RIGHT", entry.slot)
                            else
                                line:SetStartPoint("BOTTOM", req.slot)
                                line:SetEndPoint("TOP", entry.slot)
                            end
                            if req.rank >= req.talent.max then
                                line:SetColorTexture(1, 0.82, 0, 1)
                            else
                                line:SetColorTexture(0.4, 0.4, 0.4, 1)
                            end
                            line:Show()
                        end
                    end
                end
            end
            if layout then
                local text = total and format(L["Unspent points: %d of %d"], free, total) or format(L["Unspent points: %d"], free or 0)
                if c ~= me and data.seen then text = text .. "    " .. format(L["(seen %s ago)"], Duration(time() - data.seen)) end
                talentsFooter:SetText(text)
            end
        end
        return talents
    end

    local talents = TreePanel(function(c)
        local data = c.talents
        local names = ns.trees[GetLocale()] or ns.trees.enUS
        return data and db.talents[c.class], data, names[c.class] or {}, data and data.free
    end)
    local legacy = TreePanel(function(c)
        local names = {}
        for t, entry in ipairs(LEGACY_TREES) do names[t] = _G[entry[2]] end
        local data, used = c.legacy, 0
        for _, points in ipairs(data and data.spent or {}) do used = used + points end
        local total = db.legacyPoints or used
        return data and db.legacy, data, names, math.max(total - used, 0), total
    end)
    page.talents = talents

    page.Update = function()
        local c = window.detail
        name:SetText(ClassIcon(c) .. ClassColored(c, c.name .. (c.realm and (" - " .. c.realm) or "")))
        local line = format(L["Level %d %s %s"], c.level or 0, c.race or "", c.className or "")
        local progress = LevelProgress(c)
        if progress then line = line .. format(" |cff8fb8ff(%d%%)|r", progress * 100) end
        if c.guild then line = line .. "  <" .. c.guild .. ">" end
        if c.zone then line = line .. "  -  " .. c.zone end
        info:SetText(line)
        stats:SetText(format("%s: %s     %s: %s     %s: %s     %s: %s",
            L["Gold"], Money(c.money) .. ((c.mailMoney or 0) > 0 and ("  " .. format(L["(+%s in mail)"], Money(c.mailMoney))) or ""),
            L["Rested"], RestedText(c),
            L["Played"], PlayedText(c), L["Last seen"], SeenText(c)))
        for _, btn in ipairs(page.sectionButtons) do
            if btn.key == window.section then btn:LockHighlight() else btn:UnlockHighlight() end
        end
        local itemsShown = window.section == "items"
        local auctions = itemsShown and window.filter == "ah"
        local talentsShown = window.section == "talents"
        local legacyShown = window.section == "legacy"
        talents:SetShown(talentsShown)
        legacy:SetShown(legacyShown)
        if talentsShown or legacyShown then
            for _, btn in ipairs(page.filterButtons) do btn:Hide() end
            search:Hide()
            footer:Hide()
            infoTable:Hide()
            items:Hide()
            doll:Hide()
            bagRow:Hide()
            bagHint:Hide()
            if talentsShown then talents.Update(c) else legacy.Update(c) end
            return
        end
        for _, btn in ipairs(page.filterButtons) do btn:SetShown(itemsShown) end
        search:SetShown(itemsShown and not auctions)
        footer:SetShown(itemsShown and not auctions)
        infoTable:SetShown(not itemsShown or auctions)
        if not itemsShown or auctions then
            for _, btn in ipairs(page.filterButtons) do
                SetSelected(btn, btn.key == window.filter)
            end
            items:Hide()
            doll:Hide()
            bagRow:Hide()
            bagHint:Hide()
            infoTable:Refresh()
            return
        end

        local worn = window.filter == "worn"
        items:SetShown(not worn)
        doll:SetShown(worn)
        bagRow.Update(c, window.filter)
        if worn then
            bagRow:Hide()
            bagHint:Hide()
        end
        if worn then
            if c == me then ScanWorn() end
            doll.Update(c, search:GetText())
        end
        for _, btn in ipairs(page.filterButtons) do
            SetSelected(btn, btn.key == window.filter)
        end
    end
end

-- recetas de una profesion

local function RecipeList(c, skillLine, query)
    local list = {}
    query = strtrim(query or ""):lower()
    for id, difficulty in pairs(c.recipes and c.recipes[skillLine] or {}) do
        local recipe = db.recipes[id] or {}
        local name = recipe.name or C_Spell.GetSpellName(id) or ("spell:" .. id)
        local match = query == "" or name:lower():find(query, 1, true)
        -- tambien por material; el que coincide se marca en la columna
        local matched = {}
        if query ~= "" then
            for _, reagent in ipairs(recipe.reagents or {}) do
                local reagentName = ItemName(reagent[1])
                if reagentName and reagentName:lower():find(query, 1, true) then
                    matched[reagent[1]] = true
                    match = true
                end
            end
        end
        if match then
            table.insert(list, { id = id, name = name, icon = recipe.icon, item = recipe.item, reagents = recipe.reagents,
                matched = matched, difficulty = difficulty, ready = c.cooldowns and c.cooldowns[id] })
        end
    end
    table.sort(list, function(a, b)
        if a.difficulty ~= b.difficulty then return a.difficulty < b.difficulty end
        return a.name < b.name
    end)
    return list
end

local function BuildRecipesPage(page)
    local name = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("TOPLEFT", 16, -8)

    local back = MakeButton(page, 100, L["Back"], function() window.ShowTab(window.lastTab or 2) end)
    back:SetPoint("TOPRIGHT", -12, -6)

    local search = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    search:SetSize(240, 20)
    search:SetPoint("TOPLEFT", 22, -66)
    search:SetAutoFocus(false)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    page.search = search

    -- un boton por profesion del personaje
    page.profButtons = {}
    for slot = 1, 5 do
        local btn = MakeButton(page, 136, "", function(self)
            window.recipesSkill = self.skillLine
            page.table.offset = 0
            RefreshWindow()
        end)
        btn:SetPoint("TOPLEFT", 16 + (slot - 1) * 142, -36)
        btn.label:SetWordWrap(false)
        page.profButtons[slot] = btn
    end
    local hint = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "dim")
    hint:SetPoint("LEFT", search, "RIGHT", 12, 0)
    hint:SetText(L["Search by recipe or material.  Colour: skill-up chance when last opened"])

    local recipes = MakeTable(page, {
        { key = "name",     title = "Recipe",    x = 4,   width = 300 },
        { key = "reagents", title = "Materials", x = 310, width = 300 },
        { key = "cooldown", title = "Cooldown",  x = 616, width = 96, justify = "RIGHT" },
    }, -94, ROWS - 4)
    recipes.source = function() return RecipeList(window.recipesOf, window.recipesSkill, search:GetText()) end
    recipes.fill = function(cells, entry)
        local icon = entry.icon or (entry.item and C_Item.GetItemIconByID(entry.item)) or 134400
        cells.name:SetText(format("|T%s:14:14|t %s%s|r", icon, DIFFICULTY_COLORS[entry.difficulty] or "|cffffffff", entry.name))
        local mats = {}
        for _, reagent in ipairs(entry.reagents or {}) do
            local count = entry.matched[reagent[1]] and format("|cff40ff40[%d]|r", reagent[2]) or reagent[2]
            table.insert(mats, format("|T%s:14:14|t%s", C_Item.GetItemIconByID(reagent[1]) or 134400, count))
        end
        cells.reagents:SetText(entry.reagents and table.concat(mats, "  ") or "|cff808080?|r")
        if entry.ready then
            local left = entry.ready - time()
            cells.cooldown:SetText(left > 0 and format(L["ready in %s"], Duration(left)) or ("|cff40bf40" .. L["ready"] .. "|r"))
        end
    end
    -- verde si este personaje tiene bastante entre bolsas y banco
    recipes.onEnter = function(entry)
        if entry.item then
            GameTooltip:SetItemByID(entry.item)
        else
            GameTooltip:SetSpellByID(entry.id)
        end
        local c = window.recipesOf
        GameTooltip:AddLine(" ")
        if not entry.reagents then
            GameTooltip:AddLine(L["Open the profession again to read the materials."], 0.6, 0.6, 0.6, true)
            return
        end
        GameTooltip:AddLine(L["Materials"], theme.header[1], theme.header[2], theme.header[3])
        for _, reagent in ipairs(entry.reagents) do
            local id, need = reagent[1], reagent[2]
            local have = ((c.bags and c.bags[id]) or 0) + ((c.bank and c.bank[id]) or 0)
            local color = have >= need and "|cff40bf40" or "|cffff5050"
            GameTooltip:AddDoubleLine(format("|T%s:14:14|t %s x%d", C_Item.GetItemIconByID(id) or 134400, ItemName(id) or ("item:" .. id), need),
                format(L["%shas %d|r"], color, have), 1, 1, 1, 1, 1, 1)
        end
    end
    search:SetScript("OnTextChanged", function()
        recipes.offset = 0
        recipes:Refresh()
    end)

    local footer = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "dim")
    footer:SetPoint("BOTTOMLEFT", 16, 14)
    recipes.after = function(list)
        local c, skillLine = window.recipesOf, window.recipesSkill
        local seen = c.recipesSeen and c.recipesSeen[skillLine]
        if not skillLine then
            footer:SetText(L["No professions"])
        elseif type(skillLine) == "string" then
            footer:SetText(L["Log in with this character once to update its professions."])
        elseif not (c.recipes and c.recipes[skillLine]) then
            footer:SetText(L["Open this profession with the character to read its recipes."])
        else
            footer:SetText(format(L["%d recipes"], #list) .. "    " .. format(L["read %s ago"], Duration(time() - (seen or time()))))
        end
    end
    page.table = recipes

    page.Update = function()
        local c = window.recipesOf
        name:SetText(ClassIcon(c) .. ClassColored(c))
        local profs = c.profs or {}
        -- cada boton tan ancho como su texto
        local x = 16
        for slot, btn in ipairs(page.profButtons) do
            local prof = profs[slot]
            if prof then
                btn.skillLine = SkillLineOf(prof) or ("?" .. prof.name)
                local color = prof.rank >= prof.max and "|cffff9933" or ""
                btn:SetLabel(format("|T%s:14:14|t %s %s%d/%d|r", prof.icon or 134400, prof.name, color, prof.rank, prof.max))
                btn:SetWidth(btn.label:GetStringWidth() + 20)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", x, -36)
                x = x + btn:GetWidth() + 6
                SetSelected(btn, btn.skillLine == window.recipesSkill)
                btn:Show()
            else
                btn:Hide()
            end
        end
    end
end

-- pestana de opciones

local HELP = {
    "|cffffd100/alts|r - opens or closes this window",
    "|cffffd100/alts tooltip|r - owners in item tooltips",
    "|cffffd100/alts button|r - shows or hides the minimap button",
    "|cffffd100/alts theme <name>|r - changes the colours",
    "|cffffd100/alts scale <0.6-1.6>|r - window size",
}

local UpdateMinimapButton

local function SetScale(value)
    value = math.floor(value * 10 + 0.5) / 10
    db.options.scale = math.max(MIN_SCALE, math.min(MAX_SCALE, value))
    if window then window:SetScale(db.options.scale) end
end

local function BuildOptionsTab(page)
    local header = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "header")
    header:SetPoint("TOPLEFT", 16, -8)
    header:SetText(L["Options"])

    local function Check(label, key, x, y, onChange)
        MakeCheck(page, L[label], key, onChange):SetPoint("TOPLEFT", x, y)
    end
    Check("Minimap button", "button", 16, -32, function() UpdateMinimapButton() end)
    Check("Warn at login about mail that is about to expire", "mailWarning", 16, -56)
    Check("Warn when a profession cooldown is over", "cooldownWarning", 16, -80, CheckCooldowns)
    Check("Warn at login about sold or ended auctions", "auctionWarning", 16, -104)
    Check("Show hidden characters", "showHidden", 16, -128, function() RefreshWindow() end)

    -- tooltip a la derecha
    local tipHeader = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "header")
    tipHeader:SetPoint("TOPLEFT", 400, -8)
    tipHeader:SetText(L["Item tooltips"])
    Check("Show who has each item in tooltips", "tooltip", 400, -32)
    Check("Leave out the current character", "tooltipSkipMe", 400, -56)
    Check("Only the total", "tooltipTotalOnly", 400, -80)
    Check("Where it is only with Shift held", "tooltipShift", 400, -104)

    local sizeLabel = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    sizeLabel:SetPoint("TOPLEFT", 16, -164)
    sizeLabel:SetText(L["Window size"])
    local minus = MakeButton(page, 22, "-", function()
        SetScale(db.options.scale - 0.1)
        RefreshWindow()
    end)
    minus:SetPoint("TOPLEFT", 200, -160)
    local sizeValue = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    sizeValue:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    sizeValue:SetWidth(32)
    page.sizeValue = sizeValue
    local plus = MakeButton(page, 22, "+", function()
        SetScale(db.options.scale + 0.1)
        RefreshWindow()
    end)
    plus:SetPoint("LEFT", sizeValue, "RIGHT", 6, 0)
    local reset = MakeButton(page, 100, L["Reset"], function()
        SetScale(1)
        db.options.point = nil
        window:ClearAllPoints()
        window:SetPoint("CENTER")
        RefreshWindow()
    end)
    reset:SetPoint("LEFT", plus, "RIGHT", 12, 0)

    local alphaLabel = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    alphaLabel:SetPoint("TOPLEFT", 16, -192)
    alphaLabel:SetText(L["Window opacity"])
    local function SetAlpha(value)
        db.options.bgAlpha = math.max(0.3, math.min(1, math.floor(value * 10 + 0.5) / 10))
        ApplyTheme(db.options.theme)
    end
    local alphaMinus = MakeButton(page, 22, "-", function() SetAlpha(db.options.bgAlpha - 0.1) end)
    alphaMinus:SetPoint("TOPLEFT", 200, -188)
    local alphaValue = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    alphaValue:SetPoint("LEFT", alphaMinus, "RIGHT", 6, 0)
    alphaValue:SetWidth(32)
    page.alphaValue = alphaValue
    local alphaPlus = MakeButton(page, 22, "+", function() SetAlpha(db.options.bgAlpha + 0.1) end)
    alphaPlus:SetPoint("LEFT", alphaValue, "RIGHT", 6, 0)

    local themeHeader = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "header")
    themeHeader:SetPoint("TOPLEFT", 16, -228)
    themeHeader:SetText(L["Theme"])

    page.themeButtons = {}
    for i, entry in ipairs(ns.themes) do
        local btn = MakeButton(page, 84, L[entry.name], function() ApplyTheme(entry.key) end)
        btn:SetPoint("TOPLEFT", 16 + (i - 1) * 88, -252)
        btn.key = entry.key
        table.insert(page.themeButtons, btn)
    end

    local commandsHeader = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "header")
    commandsHeader:SetPoint("TOPLEFT", 16, -288)
    commandsHeader:SetText(L["Commands"])

    local lines = {}
    for _, line in ipairs(HELP) do table.insert(lines, L[line]) end
    local commands = Skin(page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    commands:SetPoint("TOPLEFT", 16, -310)
    commands:SetJustifyH("LEFT")
    commands:SetSpacing(4)
    commands:SetText(table.concat(lines, "\n"))
end

-- marco y pestanas

local TABS = { "Characters", "Professions", "Cooldowns", "Guild", "Search", "Options" }

-- ficha y recetas no tienen pestana
local function ShowTab(index)
    if window.tabs[index] then window.lastTab = index end
    window.tab = index
    for i, page in ipairs(window.pages) do
        page:SetShown(i == index)
        if window.tabs[i] then
            SetSelected(window.tabs[i], i == window.lastTab)
        end
    end
    RefreshWindow()
end

local COOLDOWNS_PAGE, GUILD_PAGE, SEARCH_PAGE, OPTIONS_PAGE, CHARACTER_PAGE, RECIPES_PAGE = 3, 4, 5, 6, 7, 8

local function OpenCharacter(c)
    local page = window.pages[CHARACTER_PAGE]
    window.detail = c
    window.filter = "bags"
    window.section = "items"
    page.search:SetText("")
    page.table.offset = 0
    ShowTab(CHARACTER_PAGE)
end

local function OpenRecipes(c, skillLine)
    local page = window.pages[RECIPES_PAGE]
    window.recipesOf, window.recipesSkill = c, skillLine
    page.search:SetText("")
    page.table.offset = 0
    ShowTab(RECIPES_PAGE)
end

function RefreshWindow()
    if not window or not window:IsShown() then return end
    local page = window.pages[window.tab]
    if page.Update then page.Update() end
    if page.table then page.table:Refresh() end
    if page.sizeValue then
        page.sizeValue:SetFormattedText("%.1f", db.options.scale)
        page.alphaValue:SetFormattedText("%d%%", db.options.bgAlpha * 100)
    end
    if page.themeButtons then
        for _, btn in ipairs(page.themeButtons) do
            SetSelected(btn, btn.key == theme.key)
        end
    end
end

local function BuildWindow()
    window = CreateFrame("Frame", "AltersForeverWindow", UIParent)
    window:SetSize(740, 106 + 18 + ROWS * ROW_HEIGHT + 30)
    window:SetScale(db.options.scale)
    local point = db.options.point
    if point then
        window:SetPoint(point[1], UIParent, point[2], point[3], point[4])
    else
        window:SetPoint("CENTER")
    end
    window:SetFrameStrata("DIALOG")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local anchor, _, relative, x, y = self:GetPoint()
        db.options.point = { anchor, relative, x, y }
    end)
    window:SetScript("OnShow", RefreshWindow)
    window:Hide()
    table.insert(UISpecialFrames, "AltersForeverWindow")   -- se cierra con Esc

    Border(window, 2)
    local face = Skin(window:CreateTexture(nil, "BORDER"), "background")
    face:SetPoint("TOPLEFT", 2, -2)
    face:SetPoint("BOTTOMRIGHT", -2, 2)

    window.title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    window.title:SetPoint("TOP", 0, -12)
    window.title:SetText(TitleText())

    local close = MakeButton(window, 22, "x", function() window:Hide() end)
    close:SetPoint("TOPRIGHT", -8, -8)

    -- tema Blizzard, por debajo del contenido
    local ok, art = pcall(CreateFrame, "Frame", nil, window, "ButtonFrameTemplate")
    if ok and art then
        art:SetAllPoints()
        art:SetFrameStrata("HIGH")
        art:EnableMouse(false)
        pcall(ButtonFrameTemplate_HidePortrait, art)
        pcall(ButtonFrameTemplate_HideButtonBar, art)
        if type(art.CloseButton) == "table" then art.CloseButton:Hide() end
    end
    local nativeClose = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    nativeClose:SetPoint("TOPRIGHT", 0, 0)
    nativeClose:SetScript("OnClick", function() window:Hide() end)
    window.SetNative = function(_, on)
        if ok and art then
            art:SetShown(on)
            art:SetAlpha(db.options.bgAlpha or 1)
        end
        nativeClose:SetShown(on)
        close:SetShown(not on)
        -- la barra de titulo del marco del juego es mas baja
        window.title:ClearAllPoints()
        window.title:SetPoint("TOP", 0, on and -5 or -12)
    end
    window:SetNative(theme.native)
    table.insert(natives, window)

    window.tabs, window.pages = {}, {}
    window.ShowTab = ShowTab
    for i = 1, RECIPES_PAGE do
        if TABS[i] then
            local tab = MakeButton(window, 110, L[TABS[i]], function() ShowTab(i) end)
            tab:SetPoint("TOPLEFT", 12 + (i - 1) * 116, -36)
            window.tabs[i] = tab
        end

        local page = CreateFrame("Frame", nil, window)
        page:SetPoint("TOPLEFT", 0, -64)
        page:SetPoint("BOTTOMRIGHT")
        window.pages[i] = page
    end

    -- personajes
    local chars = MakeTable(window.pages[1], {
        { key = "name",   title = "Character", x = 4,   width = 150, sort = ByName },
        { key = "level",  title = "Lvl",       x = 158, width = 36, justify = "CENTER", sort = ByLevel, desc = true },
        { key = "zone",   title = "Zone",      x = 200, width = 160, sort = function(c) return (c.zone or ""):lower() end },
        { key = "money",  title = "Gold",      x = 366, width = 120, justify = "RIGHT", sort = function(c) return c.money or 0 end, desc = true },
        { key = "rested", title = "Rested",    x = 492, width = 72,  justify = "RIGHT", sort = function(c) return Rested(c) or -1 end, desc = true },
        { key = "played", title = "Played",    x = 570, width = 70,  justify = "RIGHT", sort = Played, desc = true },
        { key = "seen",   title = "Last seen", x = 646, width = 66,  justify = "RIGHT",
          sort = function(c) return c == me and 0 or time() - (c.lastSeen or 0) end },
    }, -8, ROWS)
    chars.id = "chars"
    chars.source = SortedChars
    chars.fill = FillCharacter
    chars.onEnter = CharacterTooltip
    chars.onClick = function(c, mouse)
        if mouse == "RightButton" then
            for guid, other in pairs(db.chars) do
                if other == c then
                    local key = (c.hidden and "ALTERSFOREVER_SHOW" or "ALTERSFOREVER_HIDE") .. (c == me and "_ME" or "")
                    StaticPopup_Show(key, c.name, nil, guid)
                end
            end
        else
            OpenCharacter(c)
        end
    end
    local total = Skin(window.pages[1]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "text")
    total:SetPoint("BOTTOMRIGHT", -28, 14)
    chars.after = function(list)
        local money = 0
        for _, c in ipairs(list) do money = money + (c.money or 0) end
        local inMail = 0
        for _, c in ipairs(list) do inMail = inMail + (c.mailMoney or 0) end
        local today, week = 0, 0
        for _, c in ipairs(list) do
            today, week = today + GoldToday(c), week + GoldWeek(c)
        end
        local text = format(L["today %s, this week %s"], MoneyChange(today), MoneyChange(week)) .. "    "
            .. format(L["%d characters, total %s"], #list, Money(money))
        if inMail > 0 then text = text .. "  " .. format(L["(+%s in mail)"], Money(inMail)) end
        total:SetText(text)
    end
    window.pages[1].table = chars

    -- profesiones
    local profs = MakeTable(window.pages[2], {
        { key = "name",  title = "Character",  x = 4,   width = 150, sort = ByName },
        { key = "level", title = "Lvl",        x = 158, width = 36, justify = "CENTER", sort = ByLevel, desc = true },
        { key = "p1",    title = "Profession", x = 200, width = 96,  sort = BySlot(1), desc = true },
        { key = "p2",    title = "Profession", x = 300, width = 96,  sort = BySlot(2), desc = true },
        { key = "p3",    title = "Cooking",    x = 400, width = 96,  sort = BySlot(3), desc = true },
        { key = "p4",    title = "Fishing",    x = 500, width = 96,  sort = BySlot(4), desc = true },
        { key = "p5",    title = "First Aid",  x = 600, width = 112, sort = BySlot(5), desc = true },
    }, -8, ROWS)
    profs.id = "profs"
    profs.source = SortedChars
    profs.fill = FillProfessions
    profs.onEnter = ProfessionsTooltip
    -- columna segun donde se pulse
    profs.onClick = function(c, mouse, row)
        if mouse ~= "LeftButton" then return end
        local x = GetCursorPosition() / row:GetEffectiveScale() - row:GetLeft()
        local slot = x >= 200 and math.min(math.floor((x - 200) / 100) + 1, 5)
        local prof = slot and c.profs and c.profs[slot]
        if not prof then
            for _, other in ipairs(c.profs or {}) do
                if other then prof = other break end
            end
        end
        OpenRecipes(c, prof and (SkillLineOf(prof) or ("?" .. prof.name)))
    end
    window.pages[2].table = profs

    -- busqueda
    local search = CreateFrame("EditBox", nil, window.pages[SEARCH_PAGE], "InputBoxTemplate")
    search:SetSize(240, 20)
    search:SetPoint("TOPLEFT", 22, -6)
    search:SetAutoFocus(false)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    local hint = Skin(window.pages[SEARCH_PAGE]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "dim")
    hint:SetPoint("LEFT", search, "RIGHT", 12, 0)
    hint:SetText(L["Type part of an item name"])

    local found = MakeTable(window.pages[SEARCH_PAGE], {
        { key = "item",  title = "Item",       x = 4,   width = 300, sort = function(e) return e.name:lower() end },
        { key = "who",   title = "Who has it", x = 310, width = 330 },
        { key = "total", title = "Total",      x = 648, width = 64, justify = "RIGHT", sort = function(e) return e.total end, desc = true },
    }, -34, ROWS - 1)
    found.id = "search"
    found.source = function() return SearchResults(search:GetText()) end
    found.fill = FillSearch
    found.onEnter = function(entry) GameTooltip:SetItemByID(entry.id) end
    search:SetScript("OnTextChanged", function()
        found.offset = 0
        found:Refresh()
    end)
    window.pages[SEARCH_PAGE].table = found

    BuildOptionsTab(window.pages[OPTIONS_PAGE])

    -- banco de hermandad: pendiente
    local guild = window.pages[GUILD_PAGE]
    local soon = Skin(guild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), "header")
    soon:SetPoint("TOP", 0, -110)
    soon:SetText(L["Under development"])
    local soonText = Skin(guild:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "dim")
    soonText:SetPoint("TOP", soon, "BOTTOM", 0, -14)
    soonText:SetWidth(520)
    soonText:SetText(L["This tab will show your guild bank. It will come once it can be tested with a real one."])

    -- esperas de todos los personajes, la mas cercana primero
    local cooldowns = MakeTable(window.pages[COOLDOWNS_PAGE], {
        { key = "name",   title = "Character",  x = 4,   width = 150, sort = function(e) return ByName(e.c) end },
        { key = "recipe", title = "Recipe",     x = 160, width = 300, sort = function(e) return (e.recipe.name or ""):lower() end },
        { key = "prof",   title = "Profession", x = 466, width = 140 },
        { key = "ready",  title = "Ready",      x = 612, width = 100, justify = "RIGHT", sort = function(e) return e.ready end },
    }, -8, ROWS)
    cooldowns.id = "cooldowns"
    cooldowns.source = function()
        local list = {}
        for _, c in ipairs(SortedChars()) do
            for id, ready in pairs(c.cooldowns or {}) do
                table.insert(list, { c = c, id = id, ready = ready, recipe = db.recipes[id] or {} })
            end
        end
        table.sort(list, function(a, b) return a.ready < b.ready end)
        return list
    end
    cooldowns.fill = function(cells, entry)
        local recipe = entry.recipe
        local prof = recipe.skill and ProfessionOf(entry.c, recipe.skill)
        cells.name:SetText(ClassIcon(entry.c) .. ClassColored(entry.c))
        cells.recipe:SetText(format("|T%s:14:14|t %s", recipe.icon or 134400, recipe.name or C_Spell.GetSpellName(entry.id) or entry.id))
        cells.prof:SetText(prof and prof.name or "")
        local left = entry.ready - time()
        cells.ready:SetText(left > 0 and Duration(left) or ("|cff40bf40" .. L["ready"] .. "|r"))
    end
    cooldowns.onEnter = function(entry)
        if entry.recipe.item then
            GameTooltip:SetItemByID(entry.recipe.item)
        else
            GameTooltip:SetSpellByID(entry.id)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Click: open the profession"], 0.6, 0.6, 0.6)
    end
    cooldowns.onClick = function(entry, mouse)
        if mouse == "LeftButton" and entry.recipe.skill then OpenRecipes(entry.c, entry.recipe.skill) end
    end
    local empty = Skin(window.pages[COOLDOWNS_PAGE]:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "dim")
    empty:SetPoint("TOP", 0, -120)
    empty:SetWidth(520)
    empty:SetText(L["No recipe with a cooldown yet. They show up here once a character opens a profession that has them (transmutes, mooncloth...)."])
    cooldowns.after = function(list) empty:SetShown(#list == 0) end
    window.pages[COOLDOWNS_PAGE].table = cooldowns
    BuildCharacterPage(window.pages[CHARACTER_PAGE])
    BuildRecipesPage(window.pages[RECIPES_PAGE])

    ShowTab(1)
end

local function ToggleWindow()
    if not window then BuildWindow() end
    window:SetShown(not window:IsShown())
end

-- ------------------------------------------------------- boton del minimapa

local function PlaceMinimapButton()
    local angle = math.rad(db.options.buttonAngle)
    local x, y = math.cos(angle), math.sin(angle)
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        local reach = math.max(math.abs(x), math.abs(y))
        x, y = x / reach, y / reach
    end
    local radius = Minimap:GetWidth() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x * radius, y * radius)
end

function UpdateMinimapButton()
    if not minimapButton then return end
    if db.options.button then
        PlaceMinimapButton()
        minimapButton:Show()
    else
        minimapButton:Hide()
    end
end

local function FollowCursor()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    db.options.buttonAngle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
    PlaceMinimapButton()
end

local function BuildMinimapButton()
    minimapButton = CreateFrame("Button", "AltersForeverMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Head_Human_01")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnClick", ToggleWindow)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", FollowCursor)
        GameTooltip:Hide()
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Alters Forever", theme.title[1], theme.title[2], theme.title[3])
        GameTooltip:AddLine(L["Click: open the window"], 1, 1, 1)
        GameTooltip:AddLine(L["Drag: move the button"], 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateMinimapButton()
end

-- ------------------------------------------------------------ comandos

local function HandleSlash(msg)
    local command, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    command = command:lower()

    if command == "" then
        ToggleWindow()
    elseif command == "tooltip" then
        db.options.tooltip = not db.options.tooltip
        Say(db.options.tooltip and "item tooltips: on." or "item tooltips: off.")
    elseif command == "button" then
        db.options.button = not db.options.button
        UpdateMinimapButton()
        Say(db.options.button and "minimap button: on." or "minimap button: off.")
    elseif command == "scale" then
        local value = tonumber((rest:gsub(",", ".")))
        if not value then
            Say("usage: |cffffd100/alts scale <0.6-1.6>|r")
            return
        end
        SetScale(value)
        Say("window size set to %.1f.", db.options.scale)
    elseif command == "theme" then
        rest = rest:lower()
        for _, entry in ipairs(ns.themes) do
            if rest == entry.key or rest == L[entry.name]:lower() then
                ApplyTheme(entry.key)
                Say("theme: %s.", L[entry.name])
                return
            end
        end
        local names = {}
        for _, entry in ipairs(ns.themes) do table.insert(names, entry.key) end
        Say("themes: %s.", table.concat(names, ", "))
    else
        Say("commands:")
        for _, line in ipairs(HELP) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. L[line])
        end
    end
    RefreshWindow()
end

-- ------------------------------------------------------------ arranque

local events = {}

function events.PLAYER_MONEY()
    me.money = GetMoney()
    MarkGold(me)
end
function events.PLAYER_XP_UPDATE()
    me.xp, me.xpMax = UnitXP("player"), UnitXPMax("player")
    me.rested = GetXPExhaustion() or 0
end
events.UPDATE_EXHAUSTION = events.PLAYER_XP_UPDATE
function events.PLAYER_LEVEL_UP(level)
    me.level = level
    events.PLAYER_XP_UPDATE()
end
function events.PLAYER_UPDATE_RESTING() me.resting = IsResting() and true or false end
function events.ZONE_CHANGED_NEW_AREA() me.zone = GetRealZoneText() end
function events.PLAYER_GUILD_UPDATE() me.guild = GetGuildInfo("player") end
function events.SKILL_LINES_CHANGED()
    if busy then return end
    ScanProfessions()
    ScanLater(ScanSkills)
end
function events.CURRENCY_DISPLAY_UPDATE() ScanLater(ScanCurrencies) end
function events.PLAYER_PVP_KILLS_CHANGED() ScanPvP() end
function events.UPDATE_INSTANCE_INFO() ScanLockouts() end
function events.BOSS_KILL() C_Timer.After(2, AskLockouts) end
function events.UNIT_STATS(unit) if unit == "player" then QueueStats() end end
events.UNIT_RESISTANCES = events.UNIT_STATS
events.UNIT_MAXHEALTH = events.UNIT_STATS
function events.PLAYER_DAMAGE_DONE_MODS() QueueStats() end
function events.TRAIT_CONFIG_UPDATED() QueueTalents() end
events.PLAYER_TALENT_UPDATE = events.TRAIT_CONFIG_UPDATED
events.CHARACTER_POINTS_CHANGED = events.TRAIT_CONFIG_UPDATED
function events.UPDATE_FACTION() ScanLater(ScanReputations) end
function events.TRADE_SKILL_SHOW() C_Timer.After(0.3, ScanRecipes) end
function events.TRADE_SKILL_LIST_UPDATE()
    if scanTries == 0 then C_Timer.After(0.3, ScanRecipes) end
end
-- aprendida desde un patron, con la profesion cerrada
function events.NEW_RECIPE_LEARNED(id)
    local ok, line, _, parent = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, id)
    if not ok then return end
    for _, skillLine in ipairs({ parent or false, line or false }) do
        if skillLine and me.recipes and me.recipes[skillLine] then
            me.recipes[skillLine][id] = me.recipes[skillLine][id] or 0
            db.recipes[id] = db.recipes[id] or { name = C_Spell.GetSpellName(id) }
            recipeIndex = nil
            return
        end
    end
end
function events.PLAYER_EQUIPMENT_CHANGED()
    ScanWorn()
    QueueStats()
end
-- en PLAYER_LOGIN el equipo aun no esta cargado
function events.PLAYER_ENTERING_WORLD() ScanWorn() end
function events.UNIT_INVENTORY_CHANGED(unit)
    if unit == "player" then ScanWorn() end
end

function events.BAG_UPDATE_DELAYED()
    ScanBags()
    if bankOpen then ScanBank() end
end
function events.BANKFRAME_OPENED()
    bankOpen = true
    ScanBank()
end
function events.BANKFRAME_CLOSED() bankOpen = false end
function events.PLAYERBANKSLOTS_CHANGED()
    if bankOpen then ScanBank() end
end

function events.MAIL_SHOW() mailOpen = true end
function events.AUCTION_HOUSE_SHOW() QueryAuctions() end
function events.AUCTION_HOUSE_AUCTION_CREATED() pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
function events.OWNED_AUCTIONS_UPDATED() ScanAuctions() end
function events.BIDS_UPDATED() ScanBids() end
function events.MAIL_SEND_SUCCESS()
    if outgoing then
        Deliver(outgoing.c, outgoing.items, outgoing.money)
        outgoing = nil
    end
end
function events.MAIL_FAILED() outgoing = nil end
function events.MAIL_CLOSED() mailOpen = false end
function events.MAIL_INBOX_UPDATE()
    if mailOpen then ScanMail() end
end

function events.TIME_PLAYED_MSG(total)
    me.played, me.playedAt = total, GetTime()
    for _, frame in ipairs(muted) do frame:RegisterEvent("TIME_PLAYED_MSG") end
    wipe(muted)
end

function events.GET_ITEM_INFO_RECEIVED() end

function events.PLAYER_LOGOUT()
    if me.playedAt then
        me.played = Played(me)
        me.playedAt = nil
    end
    me.zone = GetRealZoneText()
    me.resting = IsResting() and true or false
    me.rested = GetXPExhaustion() or 0
    me.lastSeen = time()
end

local refreshQueued
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        RefreshWindow()
    end)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, ...)
    if event ~= "PLAYER_LOGIN" then
        events[event](...)
        QueueRefresh()
        return
    end

    AltersForeverDB = AltersForeverDB or {}
    db = AltersForeverDB
    db.chars = db.chars or {}
    db.names = db.names or {}
    db.recipes = db.recipes or {}
    db.skillLines = db.skillLines or {}
    db.factions = db.factions or {}
    db.talents = db.talents or {}
    db.probe = nil
    for _, c in pairs(db.chars) do
        for _, prof in ipairs(c.profs or {}) do
            if prof and prof.skillLine then db.skillLines[prof.name] = prof.skillLine end
        end
    end
    db.options = db.options or {}
    for key, value in pairs(OPTIONS) do
        if db.options[key] == nil then db.options[key] = value end
    end
    db.maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
    theme = FindTheme(db.options.theme)

    if (db.version or 0) < 1 then
        for _, c in pairs(db.chars) do c.guid = nil end
    end
    db.version = DATA_VERSION

    -- por GUID: en Forever el nombre llega tarde y sin reino
    myGUID = UnitGUID("player")
    db.chars[myGUID] = db.chars[myGUID] or {}
    me = db.chars[myGUID]
    me.playedAt = nil

    ScanPlayer()
    ScanProfessions()
    ScanBags()
    ScanWorn()

    -- nombres de objetos que ya no tiene nadie
    local owned = {}
    for _, c in pairs(db.chars) do
        for _, place in ipairs(PLACES) do
            for id in pairs(c[place[1]] or {}) do owned[id] = true end
        end
    end
    for id in pairs(db.names) do
        if not owned[id] then db.names[id] = nil end
    end

    HookTooltips()
    WatchMail()
    BuildMinimapButton()

    for name in pairs(events) do
        pcall(self.RegisterEvent, self, name)
    end
    C_Timer.After(5, AskPlayed)
    C_Timer.After(3, ScanWorn)
    C_Timer.After(8, WarnMail)
    C_Timer.After(9, WarnAuctions)
    C_Timer.After(10, CheckCooldowns)
    C_Timer.After(11, AskLockouts)
    -- de una en una, separadas
    for i, scan in ipairs({ ScanReputations, ScanSkills, ScanPvP, ScanCurrencies, ScanStats, ScanTalents, ScanLegacy }) do
        C_Timer.After(2 + i, function() RunScan(scan) end)
    end
    C_Timer.NewTicker(60, CheckCooldowns)

    SLASH_ALTERSFOREVER1 = "/alts"
    SLASH_ALTERSFOREVER2 = "/af"
    SLASH_ALTERSFOREVER3 = "/alters"
    SlashCmdList.ALTERSFOREVER = HandleSlash
end)
