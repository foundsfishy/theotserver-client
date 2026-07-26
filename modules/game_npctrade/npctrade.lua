BUY = 1
SELL = 2
CURRENCY = 'gold'
CURRENCY_DECIMAL = false
WEIGHT_UNIT = 'oz'
LAST_INVENTORY = 10

npcWindow = nil
itemsPanel = nil
radioTabs = nil
radioItems = nil
searchText = nil
setupPanel = nil
quantity = nil
quantityScroll = nil
priceLabel = nil
moneyLabel = nil
weightDesc = nil
weightLabel = nil
capacityDesc = nil
capacityLabel = nil
tradeButton = nil
buyTab = nil
sellTab = nil
initialized = false

showWeight = true
buyWithBackpack = nil
ignoreCapacity = nil
ignoreEquipped = nil
showAllItems = nil
sellAllButton = nil
sellAllWithDelayButton = nil
playerFreeCapacity = 0
playerMoney = 0
tradeItems = {}
playerItems = {}
selectedItem = nil

cancelNextRelease = nil

sellAllWithDelayEvent = nil

-- Long custom item names ("sorcerers spellbook of enlightenment") overflow the
-- grid tile's 160px cell sideways (nothing here clips a widget to its parent's
-- bounds). Truncate for display and keep the full name as a tooltip -- same
-- pattern as game_skills/skills.lua's LIMITBREAK_VALUE_MAX_CHARS truncation.
local GRID_NAME_MAX_CHARS = 24

local function truncateName(text, maxChars)
  if #text <= maxChars then
    return text
  end
  return text:sub(1, maxChars - 3) .. '...'
end

function init()
  npcWindow = g_ui.displayUI('npctrade')
  npcWindow:setVisible(false)

  itemsPanel = npcWindow:recursiveGetChildById('itemsPanel')
  searchText = npcWindow:recursiveGetChildById('searchText')

  setupPanel = npcWindow:recursiveGetChildById('setupPanel')
  quantityScroll = setupPanel:getChildById('quantityScroll')
  priceLabel = setupPanel:getChildById('price')
  moneyLabel = setupPanel:getChildById('money')
  weightDesc = setupPanel:getChildById('weightDesc')
  weightLabel = setupPanel:getChildById('weight')
  capacityDesc = setupPanel:getChildById('capacityDesc')
  capacityLabel = setupPanel:getChildById('capacity')
  tradeButton = npcWindow:recursiveGetChildById('tradeButton')

  buyWithBackpack = npcWindow:recursiveGetChildById('buyWithBackpack')
  ignoreCapacity = npcWindow:recursiveGetChildById('ignoreCapacity')
  ignoreEquipped = npcWindow:recursiveGetChildById('ignoreEquipped')
  showAllItems = npcWindow:recursiveGetChildById('showAllItems')
  sellAllButton = npcWindow:recursiveGetChildById('sellAllButton')
  sellAllWithDelayButton = npcWindow:recursiveGetChildById('sellAllWithDelayButton')
  buyTab = npcWindow:getChildById('buyTab')
  sellTab = npcWindow:getChildById('sellTab')

  radioTabs = UIRadioGroup.create()
  radioTabs:addWidget(buyTab)
  radioTabs:addWidget(sellTab)
  radioTabs:selectWidget(buyTab)
  radioTabs.onSelectionChange = onTradeTypeChange

  cancelNextRelease = false

  if g_game.isOnline() then
    playerFreeCapacity = g_game.getLocalPlayer():getFreeCapacity()
  end

  connect(g_game, { onGameEnd = hide,
                    onOpenNpcTrade = onOpenNpcTrade,
                    onCloseNpcTrade = onCloseNpcTrade,
                    onPlayerGoods = onPlayerGoods } )

  connect(LocalPlayer, { onFreeCapacityChange = onFreeCapacityChange,
                         onInventoryChange = onInventoryChange } )

  initialized = true
end

function terminate()
  initialized = false
  npcWindow:destroy()
  removeEvent(sellAllWithDelayEvent)
  
  disconnect(g_game, {  onGameEnd = hide,
                        onOpenNpcTrade = onOpenNpcTrade,
                        onCloseNpcTrade = onCloseNpcTrade,
                        onPlayerGoods = onPlayerGoods } )

  disconnect(LocalPlayer, { onFreeCapacityChange = onFreeCapacityChange,
                            onInventoryChange = onInventoryChange } )
end

function show()
  if g_game.isOnline() then
    if #tradeItems[BUY] > 0 then
      radioTabs:selectWidget(buyTab)
    else
      radioTabs:selectWidget(sellTab)
    end

    npcWindow:show()
    npcWindow:raise()
    npcWindow:focus()
  end
end

function hide()
  removeEvent(sellAllWithDelayEvent)

  npcWindow:hide()

  local layout = itemsPanel:getLayout()
  layout:disableUpdates()

  clearSelectedItem()

  searchText:clearText()
  setupPanel:disable()
  itemsPanel:destroyChildren()

  if radioItems then
    radioItems:destroy()
    radioItems = nil
  end

  layout:enableUpdates()
  layout:update()  
end

function onItemBoxChecked(widget)
  if widget:isChecked() then
    local item = widget.item
    selectedItem = item
    refreshItem(item)
    tradeButton:enable()

    if getCurrentTradeType() == SELL then
      quantityScroll:setValue(quantityScroll:getMaximum())
    end
  end
end

function onQuantityValueChange(quantity)
  if selectedItem then
    weightLabel:setText(string.format('%.2f', selectedItem.weight*quantity) .. ' ' .. WEIGHT_UNIT)
    priceLabel:setText(formatCurrency(getItemPrice(selectedItem)))
  end
end

function onTradeTypeChange(radioTabs, selected, deselected)
  tradeButton:setText(selected:getText())
  selected:setOn(true)
  deselected:setOn(false)

  local currentTradeType = getCurrentTradeType()
  buyWithBackpack:setVisible(currentTradeType == BUY)
  ignoreCapacity:setVisible(currentTradeType == BUY)
  ignoreEquipped:setVisible(currentTradeType == SELL)
  showAllItems:setVisible(currentTradeType == SELL)
  sellAllButton:setVisible(currentTradeType == SELL)
  sellAllWithDelayButton:setVisible(currentTradeType == SELL)
  
  refreshTradeItems()
  refreshPlayerGoods()
end

function onTradeClick()
  removeEvent(sellAllWithDelayEvent)
  if getCurrentTradeType() == BUY then
    g_game.buyItem(selectedItem.ptr, quantityScroll:getValue(), ignoreCapacity:isChecked(), buyWithBackpack:isChecked())
  else
    g_game.sellItem(selectedItem.ptr, quantityScroll:getValue(), ignoreEquipped:isChecked())
  end
end

function onSearchTextChange()
  refreshPlayerGoods()
end

function itemPopup(self, mousePosition, mouseButton)
  if cancelNextRelease then
    cancelNextRelease = false
    return false
  end

  if mouseButton == MouseRightButton then
    local menu = g_ui.createWidget('PopupMenu')
    menu:setGameMenu(true)
    menu:addOption(tr('Look'), function() return g_game.inspectNpcTrade(self:getItem()) end)
    menu:display(mousePosition)
    return true
  elseif ((g_mouse.isPressed(MouseLeftButton) and mouseButton == MouseRightButton)
    or (g_mouse.isPressed(MouseRightButton) and mouseButton == MouseLeftButton)) then
    cancelNextRelease = true
    g_game.inspectNpcTrade(self:getItem())
    return true
  end
  return false
end

function onBuyWithBackpackChange()
  if selectedItem then
    refreshItem(selectedItem)
  end
end

function onIgnoreCapacityChange()
  refreshPlayerGoods()
end

function onIgnoreEquippedChange()
  refreshPlayerGoods()
end

function onShowAllItemsChange()
  refreshPlayerGoods()
end

function setCurrency(currency, decimal)
  CURRENCY = currency
  CURRENCY_DECIMAL = decimal
end

function setShowWeight(state)
  showWeight = state
  weightDesc:setVisible(state)
  weightLabel:setVisible(state)
end

function setShowYourCapacity(state)
  capacityDesc:setVisible(state)
  capacityLabel:setVisible(state)
  ignoreCapacity:setVisible(state)
end

function clearSelectedItem()
  weightLabel:clearText()
  priceLabel:clearText()
  tradeButton:disable()
  quantityScroll:setMinimum(0)
  quantityScroll:setMaximum(0)
  if selectedItem then
    radioItems:selectWidget(nil)
    selectedItem = nil
  end
end

function getCurrentTradeType()
  if tradeButton:getText() == tr('Buy') then
    return BUY
  else
    return SELL
  end
end

function getItemPrice(item, single)
  local amount = 1
  local single = single or false
  if not single then
    amount = quantityScroll:getValue()
  end
  if getCurrentTradeType() == BUY then
    if buyWithBackpack:isChecked() then
      if item.ptr:isStackable() then
          return item.price*amount + 20
      else
        return item.price*amount + math.ceil(amount/20)*20
      end
    end
  end
  return item.price*amount
end

function getSellQuantity(item)
  if not item or not playerItems[item:getId()] then return 0 end
  local removeAmount = 0
  if ignoreEquipped:isChecked() then
    local localPlayer = g_game.getLocalPlayer()
    for i=1,LAST_INVENTORY do
      local inventoryItem = localPlayer:getInventoryItem(i)
      if inventoryItem and inventoryItem:getId() == item:getId() then
        removeAmount = removeAmount + inventoryItem:getCount()
      end
    end
  end
  return playerItems[item:getId()] - removeAmount
end

function canTradeItem(item)
  if getCurrentTradeType() == BUY then
    return (ignoreCapacity:isChecked() or (not ignoreCapacity:isChecked() and playerFreeCapacity >= item.weight)) and playerMoney >= getItemPrice(item, true)
  else
    return getSellQuantity(item.ptr) > 0
  end
end

function refreshItem(item)
  weightLabel:setText(string.format('%.2f', item.weight) .. ' ' .. WEIGHT_UNIT)
  priceLabel:setText(formatCurrency(getItemPrice(item)))

  if getCurrentTradeType() == BUY then
    local capacityMaxCount = math.floor(playerFreeCapacity / item.weight)
    if ignoreCapacity:isChecked() then
      capacityMaxCount = 65535
    end
    local priceMaxCount = math.floor(playerMoney / getItemPrice(item, true))
    local finalCount = math.max(0, math.min(getMaxAmount(), math.min(priceMaxCount, capacityMaxCount)))
    quantityScroll:setMinimum(1)
    quantityScroll:setMaximum(finalCount)
  else
    quantityScroll:setMinimum(1)
    quantityScroll:setMaximum(math.max(0, math.min(getMaxAmount(), getSellQuantity(item.ptr))))
  end

  setupPanel:enable()
end

function refreshTradeItems()
  local layout = itemsPanel:getLayout()
  layout:disableUpdates()

  clearSelectedItem()

  searchText:clearText()
  setupPanel:disable()
  itemsPanel:destroyChildren()

  if radioItems then
    radioItems:destroy()
  end
  radioItems = UIRadioGroup.create()

  local currentTradeItems = tradeItems[getCurrentTradeType()]
  -- Category-grouped shop sorting (2026-07-05, custom order; furniture
  -- categories added 2026-07-22 for the Deco Seller's kit overhaul - every
  -- one of its 41 items was previously falling into the generic "everything
  -- else" bucket and getting alphabetized, silently ignoring the server's
  -- own category order entirely): ammunition, tools, runes, potions,
  -- furniture (tables/chairs/beds/storage/decor), everything else,
  -- containers last. Ids are this server's 8.60 set; anything unrecognized
  -- lands in "other" and still sorts by name.
  -- IMPORTANT: it.ptr:getId() returns the CLIENT sprite id (items.otb
  -- clientid), NOT the server item id from the game repo's items.xml - the
  -- two only look the same for old/base items (like armor rack kit,
  -- 6114==6114) by coincidence. Confirmed live 2026-07-22 via the request/
  -- response test bridge (ItemType(id):getClientId()) after these tables were first
  -- written keyed by SERVER id and silently matched almost nothing. Every
  -- key/value below is the CLIENT id.
  local FURNITURE_TABLES  = {[2782]=1,[2788]=1,[2785]=1,[2787]=1,[2786]=1,[9061]=1}
  local FURNITURE_CHAIRS  = {[2777]=1,[2775]=1,[2776]=1,[2778]=1,[2779]=1,[2780]=1,[2781]=1}
  local FURNITURE_BEDS    = {[831]=1,[832]=1,[833]=1,[834]=1}
  local FURNITURE_STORAGE = {[2789]=1,[2795]=1,[2790]=1,[2794]=1,[2791]=1,[6372]=1}
  local FURNITURE_DECOR   = {[2798]=1,[2811]=1,[2797]=1,[2796]=1,[2806]=1,[2800]=1,[2805]=1,
    [6114]=1,[6115]=1,[2799]=1,[2804]=1,[2801]=1,[2802]=1,[2803]=1,[2808]=1,[2807]=1,[10288]=1}
  -- Kit CLIENT id -> the real, constructed item's CLIENT id (2026-07-22
  -- request): show what the kit actually becomes in the shop grid
  -- instead of its own wrapped-parcel sprite, while still selling the kit
  -- itself underneath - only cosmetic, itemBox.item (set below) still
  -- points at the real trade item so buying/selling is unaffected. Both
  -- sides of this map are CLIENT ids for the same reason as the category
  -- tables above - Item.create() below expects one.
  -- Left out on purpose (still show their own kit icon):
  --  - table lamp kit / knight statue kit (client ids 2798/2802) - no plain
  --    "table lamp"/"knight statue" item exists anywhere in this item set,
  --    confirmed via items.xml - nothing to preview.
  --  - the 4 bed-colour kits (client ids 831/832/833/834) - these modify an
  --    EXISTING bed's colour rather than construct a new object; this item
  --    set has no separate "green/yellow/red/blue bed" sprite to show
  --    (every plain "bed" entry is just directional, not colour-specific),
  --    so faking a preview would risk showing the WRONG colour.
  local KIT_PREVIEW = {
    [2782]=2319, [2788]=2350, [2785]=2314, [2787]=2348, [2786]=7273, [9061]=9062,
    [2777]=2358, [2775]=2374, [2776]=2378, [2778]=2382, [2779]=2366, [2780]=2418, [2781]=2422,
    [2795]=2465, [2790]=2441, [2791]=2449, [6372]=6367,
    [2797]=2979, [2796]=2975, [2806]=171, [2800]=2997, [2805]=2904, [6114]=6111, [6115]=6109,
    [2799]=3484, [2804]=2030, [2801]=2445, [2803]=2029, [2808]=2963, [2807]=2959, [10288]=10286,
    [2811]=2982, [2789]=2431, [2794]=2483,
  }
  local function tradeCategory(it)
    local id = it.ptr and it.ptr:getId() or 0
    local nm = it.name:lower()
    if (id >= 2543 and id <= 2547) or (id >= 7363 and id <= 7365)
        or id == 7838 or id == 7839 or id == 7840 or id == 7850 then
      return 1 -- ammunition
    elseif id == 2120 or id == 2420 or id == 2553 or id == 2554 or id == 2580 then
      return 2 -- tools
    elseif id >= 2260 and id <= 2316 then
      return 3 -- runes
    elseif (id >= 7588 and id <= 7620) or id == 8472 or id == 8473 then
      return 4 -- potions
    elseif FURNITURE_TABLES[id] then
      return 5 -- furniture: tables
    elseif FURNITURE_CHAIRS[id] then
      return 6 -- furniture: chairs
    elseif FURNITURE_BEDS[id] then
      return 7 -- furniture: beds
    elseif FURNITURE_STORAGE[id] then
      return 8 -- furniture: storage
    elseif FURNITURE_DECOR[id] then
      return 9 -- furniture: general decor
    elseif (id >= 1987 and id <= 2003) or id == 3939 or id == 3940
        or nm:find("backpack") ~= nil or nm:find(" bag") ~= nil then
      return 11 -- containers, always last
    end
    return 10 -- everything else (weapons, wands, spellbooks, gear)
  end
  table.sort(currentTradeItems, function(a, b)
    local ca, cb = tradeCategory(a), tradeCategory(b)
    if ca ~= cb then return ca < cb end
    return a.name < b.name
  end)
  for key,item in ipairs(currentTradeItems) do
    local itemBox = g_ui.createWidget('NPCItemBox', itemsPanel)
    itemBox.item = item

    local text = ''
    local name = truncateName(item.name, GRID_NAME_MAX_CHARS)
    text = text .. name
    if showWeight then
      local weight = string.format('%.2f', item.weight) .. ' ' .. WEIGHT_UNIT
      text = text .. '\n' .. weight
    end
    local price = formatCurrency(item.price)
    text = text .. '\n' .. price
    itemBox:setText(text)
    itemBox:setTooltip(item.name)

    local itemWidget = itemBox:getChildById('item')
    local previewId = item.ptr and KIT_PREVIEW[item.ptr:getId()]
    -- Cosmetic only - itemBox.item above still holds the real kit, which is
    -- what actually gets bought/sold; this just changes what sprite renders.
    itemWidget:setItem(previewId and Item.create(previewId) or item.ptr)
    itemWidget.onMouseRelease = itemPopup

    radioItems:addWidget(itemBox)
  end

  layout:enableUpdates()
  layout:update()
end

function refreshPlayerGoods()
  if not initialized then return end

  checkSellAllTooltip()

  moneyLabel:setText(formatCurrency(playerMoney))
  capacityLabel:setText(string.format('%.2f', playerFreeCapacity) .. ' ' .. WEIGHT_UNIT)

  local currentTradeType = getCurrentTradeType()
  local searchFilter = searchText:getText():lower()
  local foundSelectedItem = false

  local items = itemsPanel:getChildCount()
  for i=1,items do
    local itemWidget = itemsPanel:getChildByIndex(i)
    local item = itemWidget.item

    local canTrade = canTradeItem(item)
    itemWidget:setOn(canTrade)
    itemWidget:setEnabled(canTrade)

    local searchCondition = (searchFilter == '') or (searchFilter ~= '' and string.find(item.name:lower(), searchFilter) ~= nil)
    local showAllItemsCondition = (currentTradeType == BUY) or (showAllItems:isChecked()) or (currentTradeType == SELL and not showAllItems:isChecked() and canTrade)
    itemWidget:setVisible(searchCondition and showAllItemsCondition)

    if selectedItem == item and itemWidget:isEnabled() and itemWidget:isVisible() then
      foundSelectedItem = true
    end
  end

  if not foundSelectedItem then
    clearSelectedItem()
  end

  if selectedItem then
    refreshItem(selectedItem)
  end
end

function onOpenNpcTrade(items)
  tradeItems[BUY] = {}
  tradeItems[SELL] = {}
  for key,item in pairs(items) do
    if item[4] > 0 then
      local newItem = {}
      newItem.ptr = item[1]
      newItem.name = item[2]
      newItem.weight = item[3] / 100
      newItem.price = item[4]
      table.insert(tradeItems[BUY], newItem)
    end
    
    if item[5] > 0 then
      local newItem = {}
      newItem.ptr = item[1]
      newItem.name = item[2]
      newItem.weight = item[3] / 100
      newItem.price = item[5]
      table.insert(tradeItems[SELL], newItem)
    end
  end

  refreshTradeItems()
  addEvent(show) -- player goods has not been parsed yet
end

function closeNpcTrade()
  g_game.closeNpcTrade()
  addEvent(hide)
end

function onCloseNpcTrade()
  addEvent(hide)
end

function onPlayerGoods(money, items)
  playerMoney = money

  playerItems = {}
  for key,item in pairs(items) do
    local id = item[1]:getId()
    if not playerItems[id] then
      playerItems[id] = item[2]
    else
      playerItems[id] = playerItems[id] + item[2]
    end
  end

  refreshPlayerGoods()
end

function onFreeCapacityChange(localPlayer, freeCapacity, oldFreeCapacity)
  playerFreeCapacity = freeCapacity

  if npcWindow:isVisible() then
    refreshPlayerGoods()
  end
end

function onInventoryChange(inventory, item, oldItem)
  refreshPlayerGoods()
end

function getTradeItemData(id, type)
  if table.empty(tradeItems[type]) then
    return false
  end

  if type then
    for key,item in pairs(tradeItems[type]) do
      if item.ptr and item.ptr:getId() == id then
        return item
      end
    end
  else
    for _,items in pairs(tradeItems) do
      for key,item in pairs(items) do
        if item.ptr and item.ptr:getId() == id then
          return item
        end
      end
    end
  end
  return false
end

function checkSellAllTooltip()
  sellAllButton:setEnabled(true)
  sellAllButton:removeTooltip()
  sellAllWithDelayButton:setEnabled(true)
  sellAllWithDelayButton:removeTooltip()

  local total = 0
  local info = ''
  local first = true

  for key, amount in pairs(playerItems) do
    local data = getTradeItemData(key, SELL)
    if data then
      amount = getSellQuantity(data.ptr)
      if amount > 0 then
        if data and amount > 0 then
          info = info..(not first and "\n" or "")..
                 amount.." "..
                 data.name.." ("..
                 data.price*amount.." gold)"

          total = total+(data.price*amount)
          if first then first = false end
        end
      end
    end
  end
  if info ~= '' then
    info = info.."\nTotal: "..total.." gold"
    sellAllButton:setTooltip(info)
    sellAllWithDelayButton:setTooltip(info)
  else
    sellAllButton:setEnabled(false)
    sellAllWithDelayButton:setEnabled(false)
  end
end

function formatCurrency(amount)
  if CURRENCY_DECIMAL then
    return string.format("%.02f", amount/100.0) .. ' ' .. CURRENCY
  else
    return amount .. ' ' .. CURRENCY
  end
end

function getMaxAmount()
  if getCurrentTradeType() == SELL and g_game.getFeature(GameDoubleShopSellAmount) then
    return 10000
  end
  return 100
end

function sellAll(delayed, exceptions)
  -- backward support
  if type(delayed) == "table" then
    exceptions = delayed
    delayed = false
  end
  exceptions = exceptions or {}
  removeEvent(sellAllWithDelayEvent)
  local queue = {}
  for _,entry in ipairs(tradeItems[SELL]) do
    local id = entry.ptr:getId()
    if not table.find(exceptions, id) then
      local sellQuantity = getSellQuantity(entry.ptr)
      while sellQuantity > 0 do
        local maxAmount = math.min(sellQuantity, getMaxAmount())
        if delayed then
          g_game.sellItem(entry.ptr, maxAmount, ignoreEquipped:isChecked())
          sellAllWithDelayEvent = scheduleEvent(function() sellAll(true) end, 1100)
          return
        end
        table.insert(queue, {entry.ptr, maxAmount, ignoreEquipped:isChecked()})
        sellQuantity = sellQuantity - maxAmount
      end
    end
  end
  for _, entry in ipairs(queue) do
    g_game.sellItem(entry[1], entry[2], entry[3])
  end
end
