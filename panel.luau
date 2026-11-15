--!nonstrict
local snapshot = { state = "unconfigured", devices = {} }
local opened, selected, hovered = false, nil, nil
local nonce = 0
local render
local renderedTree,appHoverNodes=nil,{}
local tileWidth = 180
local confirmWifi, hotspotMenu = nil, nil
local drafts, sentDrafts, draftRevisions = {}, {}, {}
local lastTypeSent = nil
local page, pageKey, pageDevice = "home", nil, nil
local offset, cursors, before, beforeId, thread, album, search = 0, {}, nil, nil, nil, nil, ""
local searchDraft=""
local pageDrafts, recipient, pendingAction, detail, detailPart = {}, "", nil, nil, 0
local guideTopic=1
local dialOpen=false
local PAGE_HEIGHT=398
local pageHeight=PAGE_HEIGHT
local lastCacheEpoch=nil
local function activeSession(session, kind)
  local state = session and session[kind]
  return type(state)=="string" and state~="off" and state~="ended"
end
local function setting(key) return noctalia.getConfig(key) ~= false end
local function appsLayout()
  local names=noctalia.getConfig("apps_display")~="icons"
  local side=names and 64 or 48
  local width=822-(setting("panel_navigation") and 52 or 0)-12
  local columns=math.floor((width+6)/(side+6))
  local rows=math.floor((274+6)/(side+6))
  return {names=names,side=side,columns=columns,rows=rows,limit=math.min(96,columns*rows),gap=(width-columns*side)/(columns-1)}
end
local appsSignature=nil
local function decode(raw)
  if not raw then return nil end
  local ok, value = pcall(noctalia.json.decode, raw)
  return ok and type(value) == "table" and type(value.devices) == "table" and value or nil
end
local function send(action, device, value)
  nonce = nonce + 1
  noctalia.state.set("nl.command", noctalia.json.encode({ n = nonce, action = action, device = device, value = value }))
end
-- Incoming titles may contain whole clipboard entries, explicit newlines and
-- Unicode paragraph separators. A preview must not dictate the popup's size.
local function preview(text, limit)
  text = type(text)=="string" and text or ""
  text = text:gsub("\194\133", " "):gsub("\226\128[\168\169]", " ")
    :gsub("[%c%s]+", " "):gsub("^ +", ""):gsub(" +$", "")
  local valid, length = pcall(utf8.len, text)
  if not valid or not length then
    text = text:gsub("[\128-\255]", "?")
  end
  local cut = utf8.offset(text, limit + 1)
  return cut and (text:sub(1, cut - 1) .. "…") or text
end
local function label(text, size, color, bold)
  return ui.label({ text = preview(text, 96), height = math.ceil((size or 12)*1.4), fontFamily = "sans-serif", fontSize = size or 12, color = color or "on_surface",
    fontWeight = bold and "bold" or nil, maxLines = 1 })
end
local titles={home="Главная",messages="Сообщения",calls="Вызовы",photos="Фото",apps="Приложения",deck="Deck",guide="Руководство"}
local function resetPage()
  dialOpen=false
  pageKey=nil; offset=0; cursors={}; before=nil; beforeId=nil; thread=nil; album=nil; pendingAction=nil; detail=nil; search=""; searchDraft=""
end
local function loadPage(force)
  if page=="home" or page=="guide" or not selected or snapshot.state~="ready" then return end
  if page=="messages" and thread and thread.id=="" then return end
  local limit=page=="messages" and (thread and 6 or 7) or (page=="calls" and 6 or (page=="apps" and appsLayout().limit or nil))
  local fields={page,selected,thread and thread.id or "",tostring(offset),tostring(before),beforeId or "",album or "",search,tostring(limit or 0)}
  for i,value in ipairs(fields) do fields[i]=tostring(#value)..":"..value end
  local key=table.concat(fields)
  if pageKey==key and not force then return end
  pageKey=key
  send("page",selected,{key=key,page=page,thread=thread and thread.id or nil,offset=offset,before=before,before_id=beforeId,album=album,search=search,limit=limit,force=force==true})
end
local function smallButton(text,callback,enabled)
  return ui.button({text=text,controlSize="sm",height=32,fontSize=11,variant="ghost",enabled=enabled~=false,onClick=enabled~=false and callback or nil})
end
local function pager(width,index,back,nextPage,canBack,canNext,key)
  return ui.row({key=key or "page-pagination",width=width,height=32,align="center"},{
    ui.button({key="pager-prev",glyph="chevron-left",width=32,height=32,variant="ghost",tooltip="Предыдущая страница",enabled=canBack,onClick=canBack and back or nil}),
    ui.spacer({flexGrow=1}),
    ui.column({key="page-number",width=40,height=28,align="center",justify="center"},{label(tostring(index),12,"on_surface_variant")}),
    ui.spacer({flexGrow=1}),
    ui.button({key="pager-next",glyph="chevron-right",width=32,height=32,variant="ghost",tooltip="Следующая страница",enabled=canNext,onClick=canNext and nextPage or nil}),
  })
end
local directions={incoming="Входящий",outgoing="Исходящий",missed="Пропущенный",rejected="Отклонённый",ringing="Входящий вызов",active="Разговор"}
local deckLabels={["Play / pause"]="Пуск / пауза",Previous="Предыдущий трек",Next="Следующий трек",["Volume up"]="Громче",["Volume down"]="Тише"}
local deckGlyphs={media_play_pause="player-play",media_next="player-skip-forward",media_previous="player-skip-back",volume_up="volume",volume_down="volume-2",lock_pc="lock",run_command="terminal",launch_app="apps"}
local function pageNote(title,text,glyph,height)
  return ui.row({height=height or 72,gap=10,padding=10,radius=10,clip=true,fill="surface_container"},{
    ui.glyph({name=glyph or "info-circle",size=20,color="primary"}),
    ui.column({gap=4,flexGrow=1,clip=true},{label(title,13,"on_surface",true),
      ui.label({text=text,fontFamily="sans-serif",fontSize=12,height=(height or 72)-36,maxLines=3,color="on_surface_variant"})}),
  })
end
local function confirmAction(action,id,text,recipients,title)
  pendingAction={action=action,id=id,text=text,recipients=recipients,title=title,device=selected}; render()
end
local function dispatchPageAction(action,id,text,recipients,device)
  local requestId=""; for _=1,8 do requestId=requestId..string.format("%04x",math.random(0,65535)) end
  send("page_action",device or selected,{action=action,id=id,text=text,recipients=recipients,request_id=requestId,confirm=true})
end
local function sidebarPage(phone,online,width)
  local rows={}
  local function add(n) table.insert(rows,n) end
  local function refresh(force) pageKey=nil; loadPage(force); render() end
  local heading={}
  if (page=="calls" and dialOpen) or (page=="photos" and detail) then
    table.insert(heading,ui.button({key="back-to-list",glyph="chevron-left",width=28,height=28,variant="ghost",tooltip="К списку",onClick=function() dialOpen=false; detail=nil; pendingAction=nil; render() end}))
  end
  if page=="messages" and thread then table.insert(heading,ui.button({key="back-to-threads",glyph="chevron-left",width=28,height=28,variant="ghost",tooltip="К списку диалогов",onClick=function() thread=nil; offset=0; cursors={}; before=nil; pageKey=nil; render() end})) end
  table.insert(heading,label(page=="messages" and thread and preview(thread.title,28) or titles[page],16,"on_surface",true))
  table.insert(heading,ui.spacer({flexGrow=1}))
  if phone and page~="guide" then table.insert(heading,label(preview(phone.name,36),11,"on_surface_variant")) end
  if page=="messages" and not thread then table.insert(heading,ui.button({key="new-sms",glyph="message-plus",width=28,height=28,variant="ghost",tooltip="Новое SMS",onClick=function()
    thread={id="",kind="sms",title="Новое SMS",addresses={}}; offset=0; before=nil; cursors={}; pageKey=nil; render()
  end})) end
  local view=snapshot.page
  if page=="calls" and not dialOpen and not pendingAction then
    table.insert(heading,ui.button({key="new-call",glyph="phone-plus",width=28,height=28,variant="ghost",tooltip="Набрать номер",onClick=function() dialOpen=true; render() end}))
  end
  if page=="photos" and detail and not pendingAction then
    table.insert(heading,ui.button({key="download-photo",glyph="download",width=28,height=28,variant="ghost",tooltip="Скачать оригинал",enabled=online and not snapshot.pageActionBusy,
      onClick=online and not snapshot.pageActionBusy and function() confirmAction("photo",detail.id,nil,nil,"скачать "..detail.title) end or nil}))
  end
  if view and view.key==pageKey and view.status=="ready" and (view.refreshing or view.stale) then
    table.insert(heading,ui.row({width=16,height=18,tooltip=view.refreshing and "Обновление в фоне" or "Сохранённые данные; обновить можно кнопкой справа"},{ui.glyph({name=view.refreshing and "refresh" or "clock",size=14,color="on_surface_variant"})}))
  end
  if page~="guide" then table.insert(heading,ui.button({key="refresh-page",glyph="refresh",controlSize="sm",height=28,width=28,variant="ghost",tooltip="Обновить раздел",enabled=phone~=nil,onClick=function() refresh(true) end})) end
  add(ui.row({key="page-heading",width=width-12,gap=8,align="center",height=32},heading))
  if pendingAction then
    add(label("Подтвердите: "..pendingAction.title,14,"primary",true))
    add(ui.label({text=preview(pendingAction.text or pendingAction.id,180),fontFamily="sans-serif",height=68,maxLines=3,fontSize=13,color="on_surface"}))
    add(label("Действие выполняется на выбранном телефоне или ПК.",12))
    add(ui.row({gap=8},{smallButton("Отмена",function() pendingAction=nil; render() end),
      smallButton("Подтвердить",function()
        local p=pendingAction; pendingAction=nil
        dispatchPageAction(p.action,p.id,p.text,p.recipients,p.device); render()
      end,not snapshot.pageActionBusy and (online or page=="deck"))}))
  elseif page=="guide" then
    local tabs={}
    for i,title in ipairs({"Панель","Разделы","Помощь"}) do table.insert(tabs,ui.button({key="guide-tab-"..i,text=title,controlSize="sm",height=28,variant=guideTopic==i and "secondary" or "ghost",onClick=function() guideTopic=i; render() end})) end
    add(ui.row({gap=6,height=30},tabs))
    local notes={
      {{"Виджет на панели","Нажмите значок NectarLink в баре Noctalia, чтобы открыть эту панель. Значки слева переключают разделы.","device-mobile"},
       {"Главная — быстрые действия","Карточка сверху показывает телефон и заряд. Ниже — экран, файлы, буфер, поиск телефона и камера; справа — управление и хронология.","home"},
       {"Настройте под себя","Шестерёнка внизу слева открывает настройки именно плагина: заряд, имя телефона, видимость офлайн и блоки главной.","settings"}},
      {{"Сообщения и вызовы","Выберите диалог; значок сообщения с плюсом в заголовке создаёт SMS. Отправка и набор номера — после подтверждения. Черновики хранятся до очистки/перезагрузки плагина.","message"},
        {"Фото и приложения","Фото: выберите альбом, откройте миниатюру и скачайте оригинал. Приложения запускаются по нажатию; вид сетки выбирается в настройках плагина.","photo"},
       {"Deck и страницы","Deck выполняет заранее настроенную плитку сразу по нажатию. Стрелки внизу листают остальные разделы; обновление сверху перечитывает текущий раздел.","layout-grid"}},
      {{"Нет подключения или кнопка неактивна","Запустите NectarLink и его локальный API. Проверьте сеть, разрешения Android и переключатели устройства в приложении; затем обновите раздел.","wifi"},
       {"Не хватает истории чата","Мессенджеры показывают сохранённые уведомления, не полный архив. Ответ возможен, пока уведомление активно; SMS требуют отдельного разрешения телефона.","message"},
       {"Действие не подтверждено","Сначала проверьте телефон/ПК: запрос мог дойти. Плагин не повторяет отправку сам и не очищает черновик. Экран и виртуальная камера требуют разрешений Android.","info-circle"}},
    }
    for _,note in ipairs(notes[guideTopic]) do add(pageNote(note[1],note[2],note[3],88)) end
  elseif detail then
    if page=="photos" then
      add(ui.column({key="photo-preview",width=width-12,height=350,padding=4,clip=true,radius=10,align="center",justify="center",tooltip=detail.title},
        {detail.thumbnailPath and ui.image({path=detail.thumbnailPath,width=width-20,height=342,fit="contain",radius=6}) or
          label("Миниатюра не получена. Можно скачать оригинал.",12,"on_surface_variant")}))
    else
      add(smallButton("← Назад",function() detail=nil; render() end))
      add(label(detail.title,14,"primary",true))
      local full=detail.subtitle or ""
      local start=utf8.offset(full,detailPart*220+1) or (#full+1)
      local stop=utf8.offset(full,(detailPart+1)*220+1) or (#full+1)
      add(ui.label({text=full:sub(start,stop-1),fontFamily="sans-serif",fontSize=14,height=220,maxLines=10,color="on_surface"}))
      add(ui.spacer({flexGrow=1}))
      add(pager(width-12,detailPart+1,function() detailPart=math.max(0,detailPart-1); render() end,
        function() detailPart=detailPart+1; render() end,detailPart>0,stop<=#full,"text-pagination"))
    end
  else
    local view=snapshot.page
    local data=view and view.key==pageKey and view.status=="ready" and view.data or nil
    if page=="messages" then
      local draftKey=(selected or "none").."|"..(thread and thread.id or "new")
      local draft=pageDrafts[draftKey] or ""
      if thread then
        if thread.id=="" then
          add(ui.input({key="sms-recipient",value=recipient,placeholder="Номер получателя",height=28,controlSize="sm",onChange=function(v) recipient=v end}))
        end
        add(ui.row({key="message-composer",width=width-12,gap=6,height=32},{
          ui.input({key="message-draft-"..draftKey,value=draft,placeholder="Текст (черновик сохраняется)",controlSize="sm",height=28,flexGrow=1,
            onChange=function(v) pageDrafts[draftKey]=v; render() end}),
          smallButton("Отправить",function()
            local to=thread.id=="" and {recipient} or thread.addresses
            confirmAction(thread.kind=="chat" and "reply" or "sms",thread.id,draft,to,"отправить сообщение «"..preview(thread.title,25).."»")
          end,online and not snapshot.pageActionBusy and draft~="" and (thread.id=="" and recipient~="" or data and data.reply==true)),
          smallButton("Очистить",function() pageDrafts[draftKey]=""; render() end,not snapshot.pageActionBusy),
        }))
      end
    elseif page=="calls" then
      local key=(selected or "none").."|dial"
      if dialOpen then
      add(ui.row({key="dial-toolbar",width=width-12,gap=6,height=32},{ui.input({key="dial-number-"..tostring(selected),value=pageDrafts[key] or "",placeholder="Номер телефона",flexGrow=1,controlSize="sm",height=28,onChange=function(v) pageDrafts[key]=v; render() end}),
        smallButton("Позвонить",function() confirmAction("dial",nil,pageDrafts[key],nil,"набрать "..preview(pageDrafts[key],32)) end,online and data and data.dial==true and (pageDrafts[key] or "")~="" and not snapshot.pageActionBusy)}))
      end
      if data and type(data.active)=="table" and data.active.state~="ended" then
        local c=data.active
        local buttons={label((c.name or c.number or "Вызов").." · "..(directions[c.state] or c.state),12,"primary")}
        for _,def in ipairs({{"answer","Ответить"},{"decline","Завершить"},{"silence","Без звука"}}) do
          if def[1]=="decline" or c.state=="ringing" then
            table.insert(buttons,smallButton(def[2],function() confirmAction(def[1],c.id,nil,nil,def[2]) end,data.control==true and not snapshot.pageActionBusy))
          end
        end
        add(ui.row({key="active-call-toolbar",gap=5,height=32},buttons))
      end
    elseif page=="apps" then
      local function findApps() search=searchDraft; offset=0; cursors={}; refresh() end
      add(ui.row({key="app-toolbar",width=width-12,gap=6,height=32},{ui.input({key="app-search",value=searchDraft,placeholder="Поиск приложения",flexGrow=1,controlSize="sm",height=28,onChange=function(v) searchDraft=v end,onSubmit=findApps}),
        smallButton("Найти",findApps)}))
    elseif page=="photos" and data and type(data.albums)=="table" then
      local options,ids,index={"Все альбомы"},{false},0
      for _,a in ipairs(data.albums) do table.insert(options,a.name or a.id); table.insert(ids,a.id); if a.id==album then index=#options-1 end end
      add(ui.select({key="photo-album",width=width-12,options=options,selectedIndex=index,controlSize="sm",height=28,onChange=function(v)
        album=ids[(tonumber(v) or 0)+1] or nil; before=nil; beforeId=nil; offset=0; cursors={}; refresh()
      end}))
    end
    local newSms=page=="messages" and thread and thread.id==""
    if not data and not newSms then
      local failed=view and view.key==pageKey and view.status~="loading"
      add(pageNote(not phone and "Нет выбранного телефона" or (failed and "Не удалось загрузить раздел" or "Загружаем с телефона…"),
        failed and "Проверьте подключение и разрешения Android. Нажмите обновление справа сверху, чтобы повторить чтение." or "Первое чтение может занять несколько секунд. Другие разделы доступны слева.",failed and "wifi" or "device-mobile",88))
    elseif not newSms then
      local items=data.items or {}
      local appLayout=appsLayout()
      local maxRows=page=="photos" and 8 or (page=="apps" and appLayout.limit or (page=="deck" and #items or (page=="messages" and 7 or 6)))
      if page=="calls" and type(data.active)=="table" and data.active.state~="ended" then maxRows=5 end
      -- Reserve space for composer, navigation and status; lists never scroll.
      if page=="messages" and thread then maxRows=6 end
      if (page=="messages" or page=="calls") and data.notice and data.notice~="" and not data.notice:find("Последние 100",1,true) then maxRows=math.max(1,maxRows-1) end
      if page=="calls" and dialOpen then maxRows=0 end
      local grid={}
      local gridColumns=page=="apps" and appLayout.columns or 4
      if page=="deck" then gridColumns=#items<=16 and 4 or (#items<=30 and 5 or (#items<=48 and 6 or (#items<=96 and 8 or 16))) end
      local gridRows=math.max(1,math.ceil(math.min(#items,maxRows)/gridColumns))
      local cellWidth=math.floor((width-12-(gridColumns-1)*6)/gridColumns)
      local imageSide=cellWidth-8
      local cellHeight=page=="photos" and 136 or (page=="apps" and 80 or math.min(88,math.floor((336-(gridRows-1)*6)/gridRows)))
      if page=="apps" then cellWidth=appLayout.side; cellHeight=appLayout.side; imageSide=cellWidth-8 end
      for i,item in ipairs(items) do
        if i>maxRows then break end
        local title=item.title~="" and item.title or (type(item.addresses)=="table" and table.concat(item.addresses,", ") or "Сообщение")
        local subtitle=item.subtitle or (item.size and tostring(math.floor(item.size/1024)).." КБ") or ""
        if page=="deck" then title=deckLabels[title] or title; subtitle=subtitle=="Main" and "Основная" or subtitle end
        if page=="calls" then subtitle=(directions[subtitle] or subtitle)..(item.duration and item.duration>0 and (" · "..tostring(math.floor(item.duration/60)).." мин "..tostring(item.duration%60).." с") or "") end
        if page=="messages" and not thread then subtitle=(item.kind=="sms" and "SMS · " or "Чат · ")..subtitle end
        local itemClick=function()
          if page=="messages" and not thread then thread=item; offset=0; cursors={}; before=nil; pageKey=nil; render()
          elseif page=="messages" then detail=item; detailPart=0; render()
          elseif page=="calls" then pageDrafts[(selected or "none").."|dial"]=item.number or ""; dialOpen=true; render()
          elseif page=="photos" then detail=item; detailPart=0; render()
          elseif page=="apps" and online and not snapshot.pageActionBusy then dispatchPageAction("app",item.id); render()
          elseif page=="deck" and not snapshot.pageActionBusy then dispatchPageAction("deck",item.id); render() end
        end
        if page=="photos" or page=="deck" or page=="apps" then
          local children={}
          if page=="photos" then
            table.insert(children,ui.row({width=imageSide,height=128,clip=true,align="center",justify="center"},{item.thumbnailPath and ui.image({path=item.thumbnailPath,width=imageSide,height=128,fit="cover",radius=6}) or
              ui.column({width=imageSide,height=128,align="center",justify="center",fill="surface_container_high",radius=6},{ui.glyph({name="photo",size=28,color="on_surface_variant"})})}))
          elseif page=="apps" then
            table.insert(children,ui.row({width=imageSide,height=24,align="center",justify="center"},{item.iconPath and ui.image({path=item.iconPath,width=24,height=24,fit="contain"}) or ui.glyph({name="apps",size=24,color="primary"})}))
          else
            local glyphSize=cellHeight>=76 and 24 or math.min(18,cellHeight-8)
            table.insert(children,ui.row({width=imageSide,height=cellHeight>=76 and 28 or glyphSize},{ui.glyph({name=deckGlyphs[item.kind] or "layout-grid",size=glyphSize,color="primary"})}))
          end
          -- Label.height is not a rigid layout constraint in Noctalia 5.5.
          -- Give text its own fixed flex slot and maxWidth so image/title
          -- measurements cannot grow a card or spill into the next row.
          if (page=="apps" and appLayout.names) or (page~="apps" and page~="photos" and (page~="deck" or cellHeight>=48)) then table.insert(children,ui.column({width=imageSide,height=20,clip=true,align=page=="apps" and "center" or "start",justify="center"},{ui.label({text=preview(title,26),maxWidth=imageSide,maxLines=1,fontFamily="sans-serif",fontSize=page=="apps" and 10 or 12,fontWeight=page~="apps" and "bold" or nil})})) end
          if page=="deck" and cellHeight>=76 then table.insert(children,ui.column({width=imageSide,height=16,clip=true,align="start"},{ui.label({text=preview(subtitle,26),maxWidth=imageSide,maxLines=1,fontFamily="sans-serif",fontSize=10,color="on_surface_variant"})})) end
          local appKey="page-item-"..tostring(item.id)
          table.insert(grid,ui.column({key=appKey,width=cellWidth,height=cellHeight,gap=2,padding=4,clip=true,radius=8,align=page=="apps" and "center" or "start",justify=page=="apps" and "center" or "start",
            tooltip=title..(subtitle~="" and (" · "..subtitle) or ""),onClick=itemClick,onHover=page=="apps" and "onTileHover" or nil,fill=page=="apps" and (hovered==appKey and "surface_container_high" or "transparent") or "surface_container"},children))
          if page=="apps" then appHoverNodes[appKey]=grid[#grid] end
        else
          local glyph=page=="calls" and (item.subtitle=="outgoing" and "arrow-up-right" or "arrow-down-left") or (page=="apps" and "apps" or "message")
          local children={ui.column({width=28,height=30,align="center",justify="center",radius=8,fill="primary/0.1"},{ui.glyph({name=glyph,size=18,color=page=="calls" and item.subtitle=="missed" and "error" or "primary"})}),
            ui.column({gap=1,flexGrow=1,clip=true},{label(preview(title,54),12,"on_surface",true),label(preview(subtitle,72),11,"on_surface_variant")})}
          if item.date and noctalia.formatTime then table.insert(children,label(noctalia.formatTime("%d.%m %H:%M",math.floor(item.date/1000)),10,"on_surface_variant")) end
          if page=="apps" then table.insert(children,ui.glyph({name="external-link",size=16,color="on_surface_variant"})) end
          add(ui.row({key="page-item-"..tostring(item.id),width=width-12,gap=8,padding=3,height=40,clip=true,radius=9,fill="surface_container",tooltip=page=="apps" and "Открыть приложение в отдельном окне" or title,onClick=itemClick},children))
        end
      end
      if #grid>0 then
        local lines={}
        for first=1,#grid,gridColumns do local cells={}; for j=first,math.min(first+gridColumns-1,#grid) do table.insert(cells,grid[j]) end
          table.insert(lines,ui.row({key="grid-row-"..first,width=width-12,gap=page=="apps" and appLayout.gap or 6,height=cellHeight,align="start",justify="start",clip=true},cells))
        end
        add(ui.column({key="page-grid",width=width-12,gap=6,height=gridRows*cellHeight+(gridRows-1)*6,align="start",justify="start",clip=true},lines))
      end
      if #items==0 then add(label("Нет элементов",12,"on_surface_variant")) end
      if data.notice and data.notice~="" and not data.notice:find("Последние 100",1,true) then add(label(preview(data.notice,110),10,"on_surface_variant")) end
      if page~="deck" and not (page=="calls" and dialOpen) then
      add(ui.spacer({flexGrow=1}))
      add(pager(width-12,#cursors+1,function()
        local old=table.remove(cursors); if old then offset=old.offset; before=old.before; beforeId=old.beforeId; refresh() end
      end,function()
        table.insert(cursors,{offset=offset,before=before,beforeId=beforeId})
        if page=="calls" or page=="photos" or (page=="messages" and thread and thread.kind=="sms") then
          local last=items[math.min(#items,maxRows)]; before=last.date; beforeId=last.id; offset=0
         else offset=offset+math.min(maxRows,#items) end
        refresh()
      end,#cursors>0,data.more==true or #items>maxRows))
      end
    end
  end
  pageHeight=PAGE_HEIGHT
  return ui.column({key="sidebar-page",width=width,height=pageHeight,gap=4,padding=6,align="start",justify="start",clip=true,radius=10,fill="surface_container/0.5"},rows)
end
local function badge(text, glyph)
  return ui.row({ gap = 4, align = "center", paddingH = 6, paddingV = 3, radius = 10, fill = "surface_container_high" }, {
    ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }), label(text, 11, "on_surface_variant"),
  })
end
-- A single click target, not a card containing a second native button.
local function tile(key, text, glyph, command, enabled, reason, device, value, active, width)
  return ui.column({ key = key, gap = 4, padding = 8, radius = 12, width = width or tileWidth, clip = true,
    height = 68, opacity = enabled and 1 or 0.48,
    fill = (active or hovered == key) and "primary/0.18" or "surface_container",
    border = active and "primary/0.5" or "surface_container", borderWidth = 1,
    tooltip = reason or text, onHover = "onTileHover",
    onClick = enabled and function() send(command, device, value) end or nil }, {
    ui.row({ justify = "start" }, {
      ui.column({ width = 20, height = 20, radius = 10, fill = "primary/0.15", align = "center", justify = "center" }, {
        ui.glyph({ name = glyph, size = 14, color = "primary" }),
      }),
    }),
    ui.label({ text = text, height = 28, fontFamily = "sans-serif", fontSize = 11, fontWeight = "bold", maxLines = 2, color = "on_surface" }),
  })
end
local function timeline(phone)
  local rows = {
    ui.row({ key="timeline-header",align = "center", gap = 8, width=244,height=20,clip=true }, {
      ui.column({width=184,height=20,clip=true,justify="center",align="start"},{ui.label({text="Хронология",fontFamily="sans-serif",fontSize=13,fontWeight="bold",maxWidth=184,maxLines=1})}),
      ui.row({ key="timeline-more",width=52,gap = 4, align = "center",justify="end",height=20,
        tooltip = "Открыть хронологию в NectarLink", onClick = function() send("timeline") end }, {
        label("Все", 11, "primary"), ui.glyph({ name = "arrow-up-right", size = 14, color = "primary" }),
      }),
    }),
  }
  local count = 0
  local glyphs = { clipboard = "clipboard", file = "file", photo = "photo", link = "link" }
  if snapshot.timelineState == "ready" then
    for _, item in ipairs(snapshot.timeline or {}) do
      if phone and item.deviceId == phone.id and count < (#snapshot.devices > 1 and 1 or 2) then
        count = count + 1
        table.insert(rows, ui.row({ key = "event-" .. tostring(item.id),width=244, gap = 8, height = 32, clip = true, align = "center" }, {
          ui.column({width=20,height=32,align="center",justify="center",clip=true},{ui.glyph({ name = glyphs[item.kind] or "history", size = 18, color = "primary" })}),
          ui.column({key="event-text-"..tostring(item.id),width=216,height=32,gap=0,clip=true,align="start"}, {
            ui.column({width=216,height=18,clip=true,align="start",justify="center"},{ui.label({text=preview(type(item.title)=="string" and item.title or "Событие",28),fontFamily="sans-serif",fontSize=12,fontWeight="bold",maxWidth=216,maxLines=1})}),
            ui.column({width=216,height=14,clip=true,align="start",justify="center"},{ui.label({text=item.direction=="incoming" and "Получено с телефона" or "Отправлено на телефон",fontFamily="sans-serif",fontSize=10,color="on_surface_variant",maxWidth=216,maxLines=1})}),
          }),
        }))
      end
    end
  end
  if count == 0 then
    local text = snapshot.timelineState == "ready" and "Нет недавних событий"
      or (snapshot.timelineState == "offline" and "Не удалось загрузить события" or "Загрузка событий…")
    table.insert(rows, label(text, 12, "on_surface_variant"))
  end
  return ui.column({ key = "timeline",width=260, gap = 6, padding = 8, radius = 10, height = count>0 and (36 + count*38) or 64, clip = true,
    fill = "surface_container/0.65", border = "outline_variant/0.35", borderWidth = 1 }, rows)
end
local function controlsCard(phone, online)
  local controls = phone and phone.controls
  local state = controls and controls.state
  local allowed = controls and controls.allowed or {}
  local rows = {
    ui.row({ width=244,height=28,gap = 5, align = "center" }, {
      ui.label({ text = "Управление телефоном", fontFamily = "sans-serif", fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "external-link",width=28,height=28,controlSize = "sm", variant = "ghost", tooltip = "Открыть NectarLink",
        onClick = function() send("open") end }),
    }),
  }
  local chips = {}
  for _, def in ipairs({{"dnd","Не беспок.","moon"}, {"flashlight","Фонарик","bolt"},
      {"wifi","Wi-Fi","wifi"}, {"bluetooth","BT","bluetooth"}, {"hotspot","Точка дост.","world"}}) do
    local id, title, glyph = def[1], def[2], def[3]
    local active = type(state) == "table" and state[id] == true
    local known = type(state) == "table" and type(state[id]) == "boolean"
    local enabled = online and not snapshot.controlBusy and allowed[id] == true and (known or id == "hotspot")
    local reason = not online and "Телефон не в сети" or (not controls and "Требуется обновлённое приложение NectarLink"
      or (not allowed[id] and "Недоступно с текущими разрешениями Android" or (id == "hotspot" and "Выбрать включение или выключение; телефон не сообщает состояние"
        or (not known and "Состояние пока не получено" or title))))
    table.insert(chips, ui.column({ key = "control-" .. id, width = 44, height = 54, gap = 5, padding = 4,
      radius = 10, align = "center", justify = "center", opacity = enabled and 1 or 0.45,
      fill = active and "primary/0.25" or "surface_container_high", tooltip = reason,
      onClick = enabled and function()
        if id == "wifi" and active then confirmWifi = phone.id; hotspotMenu = nil; render()
        elseif id == "hotspot" then hotspotMenu = phone.id; confirmWifi = nil; render()
        else send("phone_toggle", phone.id, {id = id, on = not active}) end
      end or nil }, {
      ui.glyph({ name = glyph, size = 17, color = active and "primary" or "on_surface_variant" }),
      label(title, 9, "on_surface_variant"),
    }))
  end
  table.insert(rows, ui.row({ width=244,gap = 4,justify="center" }, chips))
  if phone and confirmWifi == phone.id then
    table.insert(rows, label("Wi-Fi выключится. Связь может оборваться.", 10, "primary"))
    table.insert(rows, ui.row({ gap = 5 }, {
      ui.button({ text = "Отмена", controlSize = "sm", variant = "ghost", onClick = function() confirmWifi = nil; render() end }),
      ui.button({ text = "Выключить", controlSize = "sm", variant = "destructive", enabled = online and allowed.wifi == true and not snapshot.controlBusy,
        onClick = function() confirmWifi = nil; send("phone_toggle", phone.id, {id="wifi",on=false,confirm_disconnect=true}); render() end }),
    }))
  elseif phone and hotspotMenu == phone.id then
    local buttons = {}
    for _, choice in ipairs({{"Вкл.",true},{"Выкл.",false}}) do
      local on = choice[2]
      table.insert(buttons, ui.button({ text = choice[1], controlSize = "sm", variant = "secondary", enabled = online and allowed.hotspot == true and not snapshot.controlBusy,
        onClick = function() hotspotMenu = nil; send("phone_toggle",phone.id,{id="hotspot",on=on}); render() end }))
    end
    table.insert(buttons, ui.button({glyph="x",controlSize="sm",variant="ghost",onClick=function() hotspotMenu=nil; render() end}))
    table.insert(rows, ui.row({gap=5},buttons))
  end
  local session = phone and snapshot.sessions and snapshot.sessions[phone.id]
  local phases = {preparing="Подготовка…",asking="Разрешите на телефоне",watching="Просмотр на телефоне",playing="Звук воспроизводится",enabled="Включено"}
  for _, def in ipairs({{"Телефон как динамик","volume","pc_audio"},{"Смотреть на телефоне","video","watch"},{"Звук телефона на этом ПК","headphones","phone_audio"}}) do
    local kind=def[3]
    local active=activeSession(session,kind)
    local enabled=not snapshot.sessionBusy and session and (active or (online and session.allowed[kind]))
    local text=active and (phases[session[kind]] or session[kind]) or (not enabled and "Сейчас недоступно" or "")
    table.insert(rows, ui.row({ key="session-row-"..kind,width=244,height=32,clip=true,gap = 6, padding = 3, radius = 9, fill = "surface_container_high",
      tooltip = kind=="watch" and "Сначала включите видео на ПК; на телефоне может потребоваться подтверждение" or "Управление реальной сессией NectarLink" }, {
      ui.glyph({name=def[2],size=15,color="on_surface_variant"}),
      ui.column({gap=0,flexGrow=1,height=26,clip=true,align="start",justify="center"},{
        ui.column({height=14,clip=true,align="start",justify="center"},{ui.label({text=def[1],fontFamily="sans-serif",fontSize=10,maxWidth=184,maxLines=1})}),
        ui.column({height=12,clip=true,align="start",justify="center",visible=text~=""},{ui.label({text=text,fontFamily="sans-serif",fontSize=9,maxWidth=184,maxLines=1,color="on_surface_variant"})}),
      }),
      ui.toggle({key="session-"..kind,checked=active,enabled=enabled==true,width=30,height=18,
        onChange=function(value) if enabled then send("session",phone.id,{kind=kind,on=value=="true" or value==true}) end end}),
    }))
  end
  return ui.column({key="phone-controls",width=260,gap=7,padding=8,radius=14,align="start",fill="surface_container/0.75",clip=true},rows)
end
local function ringerCard(phone,online)
  local controls=phone and phone.controls
  local mode=controls and controls.state and controls.state.ringer
  local known=mode=="ring" or mode=="vibrate" or mode=="silent"
  local allowed=controls and controls.allowed and controls.allowed.ringer==true
  local enabled=online and allowed and known and not snapshot.controlBusy
  local buttons={}
  for _,choice in ipairs({{"ring","Звонок"},{"vibrate","Вибрация"},{"silent","Без звука"}}) do
    local value,title=choice[1],choice[2]
    table.insert(buttons,ui.button({key="ringer-"..value,text=title,width=80,height=32,fontSize=10,controlSize="sm",
      variant=known and mode==value and "secondary" or "ghost",enabled=enabled==true,
      tooltip=not online and "Телефон не в сети" or (not allowed and "Недоступно с текущими разрешениями Android" or (not known and "Состояние пока не получено" or title)),
      onClick=enabled and function() if mode~=value then send("phone_toggle",phone.id,{id="ringer",mode=value}) end end or nil}))
  end
  return ui.row({key="ringer-controls",width=260,height=40,padding=4,gap=6,clip=true,radius=12,fill="surface_container/0.75",align="center"},buttons)
end
local function renderFrame(header,content)
  if setting("panel_navigation") then
    local nav={}
    for _,entry in ipairs({{"Главная","home","home"},{"Сообщения","message","messages"},{"Вызовы","phone","calls"},
        {"Фото","photo","photos"},{"Приложения","apps","apps"},{"Deck","layout-grid","deck"},{"Руководство","book","guide"}}) do
      table.insert(nav,ui.button({glyph=entry[2],glyphSize=18,controlSize="sm",width=32,height=32,key="nav-"..entry[3],
        variant=page==entry[3] and "secondary" or "ghost",tooltip=entry[1],onClick=function()
          page=entry[3]; resetPage(); if page=="home" or page=="guide" then send("page_leave",nil,page) end; render()
        end}))
    end
    table.insert(nav,ui.spacer({flexGrow=1}))
    table.insert(nav,ui.button({key="plugin-settings",glyph="settings",glyphSize=18,variant="ghost",controlSize="sm",width=32,height=32,
      tooltip="Настройки плагина",onClick=function() noctalia.openSettings() end}))
    table.insert(content,1,ui.column({key="navigation",gap=5,padding=5,width=42,height=PAGE_HEIGHT,radius=12,align="center",fill="surface_container/0.6"},nav))
  end
  renderedTree=ui.column({key="panel-layout-0100",width=828,height=438,gap=6,padding=3,align="start",clip=true},{
    header,ui.row({key="dashboard",width=822,gap=10,height=PAGE_HEIGHT,clip=true},content),
  })
  panel.render(renderedTree)
end
render = function()
  if not opened then return end
  appHoverNodes={}
  local ready = snapshot.state == "ready"
  local phone
  for _, d in ipairs(snapshot.devices) do if d.id == selected then phone = d end end
  if not phone then
    for _, d in ipairs(snapshot.devices) do if d.online then phone = d; break end end
    phone = phone or snapshot.devices[1]; selected = phone and phone.id or nil
  end
  local online = ready and phone ~= nil and phone.online == true
  if pageDevice~=selected then pageDevice=selected; resetPage() end
  local layout=appsLayout()
  local signature=tostring(layout.names)..":"..tostring(layout.limit)
  if appsSignature~=signature then
    appsSignature=signature
    if page=="apps" then pageKey=nil; offset=0; cursors={} end
  end
  loadPage()
  local session = phone and snapshot.sessions and snapshot.sessions[phone.id]
  local function canSession(kind)
    return not snapshot.sessionBusy and session and (activeSession(session,kind) or (online and session.allowed[kind])) == true
  end
  if snapshot.typeSent and snapshot.typeSent~=lastTypeSent then
    lastTypeSent=snapshot.typeSent
    local id=snapshot.typeSentDevice
    if id and drafts[id]==sentDrafts[id] then drafts[id]=""; draftRevisions[id]=(draftRevisions[id] or 0)+1 end
  end
  if selected ~= confirmWifi then confirmWifi = nil end
  if selected ~= hotspotMenu then hotspotMenu = nil end
  local unavailable = not ready and "Нет связи с NectarLink" or (not phone and "Сначала подключите телефон" or "Телефон не в сети")
  local later = "Пока доступно только в приложении. Добавим управление через API позже."
  local notices = {}
  if ready and phone and setting("panel_notifications") and snapshot.notificationsState == "ready" then
    for _, item in ipairs(snapshot.notifications or {}) do
      if item.deviceId == phone.id then table.insert(notices, item) end
    end
  end
  -- Match the fixed manifest width, host padding (16 per side), root padding
  -- (3 per side), optional 42px rail + gap, and 260px right column + gap.
  local showControls = setting("panel_controls")
  local showTimeline = ready and phone and setting("panel_timeline")
  local sidebar = showControls or showTimeline
  local mainWidth = 860 - 32 - 6 - (setting("panel_navigation") and 52 or 0) - (sidebar and 270 or 0)
  tileWidth = math.floor((mainWidth - 30) / 4)
  mainWidth = tileWidth * 4 + 30
  local headerItems = {
    ui.glyph({ name = "device-mobile", size = 20, color = "primary" }),
    ui.label({ text = "NectarLink", fontFamily = "sans-serif", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({ glyph = "external-link", controlSize = "sm", variant = "ghost", tooltip = "Открыть приложение", onClick = function() send("open") end }),
    ui.button({ glyph = "settings", controlSize = "sm",height=28,visible=not setting("panel_navigation"), variant = "ghost", tooltip = "Настройки плагина", onClick = function() noctalia.openSettings() end }),
  }
  if page=="home" then table.insert(headerItems,ui.button({key="refresh-home",glyph="refresh",width=28,height=28,controlSize="sm",variant="ghost",tooltip="Обновить",onClick=function() send("refresh"); render() end})) end
  local header = ui.row({width=822,gap=8,align="center",height=28},headerItems)
  if page~="home" then
    local width=860-32-6-(setting("panel_navigation") and 52 or 0)
    renderFrame(header,{ui.column({key="page-layout-"..page,width=width,height=PAGE_HEIGHT,align="start"},{sidebarPage(phone,online,width)})})
    return
  end
  local body = {}
  if not ready then
    local states = {
      unconfigured = "Включите локальный API в NectarLink → Настройки → Подключение и о программе.",
      unauthorized = "Доступ к приложению изменился. Нажмите «Обновить».",
      offline = "Нет связи с NectarLink. Запустите приложение и обновите панель.",
    }
    table.insert(body, label(states[snapshot.state] or "Подключение…", 12, "on_surface_variant"))
  end
  local battery = phone and phone.battery
  local level = battery and tonumber(battery.level)
  if level then level = math.max(0, math.min(100, level)) end
  local powerVisible = setting("panel_battery")
  local powerColor = online and (level and level <= 20 and not battery.charging and "error" or "primary") or "on_surface_variant"
  -- Stylized device silhouette, not a fabricated screenshot of the real phone.
  local devicePreview = {
    ui.row({width=44,height=5,align="center",justify="center"},{ui.box({width=14,height=3,radius=2,fill="on_surface_variant/0.65"})}),
    ui.column({key="phone-preview-screen",width=44,height=62,padding=6,gap=4,radius=7,fill="primary/0.12",clip=true,align="center",justify="center"},{
      ui.row({width=32,height=24,align="center",justify="center"},{ui.glyph({name="hexagon",size=24,color="primary"})}),
      ui.box({width=22,height=3,radius=2,fill="primary/0.6"}),
      ui.box({width=14,height=2,radius=1,fill="primary/0.3"}),
    }),
    ui.box({width=14,height=2,radius=1,fill="on_surface_variant/0.45"}),
  }
  local info = {
    label(phone and phone.name or "Телефон не подключён", 16, "on_surface", true),
    label(phone and type(phone.platform) == "string" and phone.platform or "NectarLink", 12, "on_surface_variant"),
    ui.row({ gap = 6, justify = "start" }, {
      badge(online and (({lan = "Локальная сеть", usb = "USB", relay = "Реле"})[phone.link] or "Подключён") or "Не в сети", online and "link" or "unlink"),
    }),
  }
  if powerVisible then
    table.insert(info, ui.row({ justify = "start" }, {
      badge(level and (not online and "Последние данные о заряде" or (battery.charging and "Заряжается" or "От аккумулятора")) or "Заряд неизвестен",
        battery and battery.charging and "battery-charging" or "battery"),
    }))
  end
  if #snapshot.devices > 1 then
    local devices, ids, index = {}, {}, 0
    for i, d in ipairs(snapshot.devices) do
      table.insert(devices, d.name); table.insert(ids, d.id)
      if d.id == selected then index = i - 1 end
    end
    info[1] = ui.select({ key = "device-picker", options = devices, selectedIndex = index, controlSize = "sm",
      onChange = function(value)
        local i = tonumber(value)
        if i and ids[i + 1] then selected = ids[i + 1]; render() end
      end })
  end
  local deviceCard = {
    ui.column({key="phone-preview",gap = 4, width = 56, height = 92, padding = 5, radius = 12,clip=true,opacity=online and 1 or 0.55,
      fill = "surface_container_high", border = "primary/0.5", borderWidth = 1,
      align = "center", justify = "center" }, devicePreview),
    ui.column({key="phone-info",gap = 3, flexGrow = 1,clip=true,align="start",justify = "center" }, info),
  }
  if powerVisible then
    local power = {
      ui.row({width=108,height=18,align="center",justify="center"},{ui.glyph({ name = battery and battery.charging and "battery-charging" or "battery", size = 18, color = powerColor })}),
      ui.column({key="battery-value",width=108,height=30,clip=true,align="center",justify="center"},{label(level and (tostring(level) .. "%") or "—",21,powerColor,true)}),
    }
    if level then table.insert(power, ui.progress({ progress = level / 100,width=108,height = 4, fill = powerColor })) end
    table.insert(power,ui.column({width=108,height=14,clip=true,align="center",justify="center"},{label(online and "Заряд телефона" or "Последние данные",10,"on_surface_variant")}))
    table.insert(deviceCard, ui.column({key="phone-battery",gap = 4, width = 120,height=92,padding = 6, radius = 12,clip=true,
      fill = "surface_container/0.6",align="center",justify = "center" }, power))
  end
  table.insert(body, ui.row({ key = "device",width=mainWidth,gap = 10, padding = 12, radius = 16, height=126,clip=true,align="center",fill = "primary/0.12" }, deviceCard))
  local single = #snapshot.devices == 1
  local transfer = online and single
  local transferReason = not online and unavailable or "При нескольких телефонах выберите получателя в приложении"
  if setting("panel_actions") then
    table.insert(body, ui.row({ gap = 10 }, {
      tile("screen", activeSession(session,"screen") and "Остановить экран" or "Экран телефона", "devices-pc", "session", canSession("screen"),
        "Открыть/закрыть отдельное окно экрана телефона",selected,{kind="screen",on=not activeSession(session,"screen")},activeSession(session,"screen")),
      tile("files", "Файлы", "send", "files", transfer, transfer and "Выбрать файлы для отправки" or transferReason),
      tile("clipboard", "Буфер обмена", "clipboard", "clipboard", transfer, transfer and "Отправить текст на телефон" or transferReason),
      tile("ring", snapshot.ringBusy and "Отправка…" or (phone and phone.ringing and "Остановить сигнал" or "Найти телефон"),
        phone and phone.ringing and "player-stop" or "bell", "ring",
        online and not snapshot.ringBusy and type(phone.ringing) == "boolean",
        not online and unavailable or (snapshot.ringBusy and "Ожидаю ответ телефона" or (type(phone.ringing) ~= "boolean" and "Обновите NectarLink" or nil)),
        selected, not (phone and phone.ringing), phone and phone.ringing),
    }))
    if activeSession(session,"keyboard") then
      local id=selected
      local function submit()
        if not snapshot.typeBusy and drafts[id] and drafts[id]~="" then
          sentDrafts[id]=drafts[id]; send("type_text",id,drafts[id])
        end
      end
      table.insert(body,ui.column({key="typing-form",gap=5,padding=8,radius=12,height=124,clip=true,fill="surface_container"},{
        ui.input({key="draft-"..id.."-"..tostring(draftRevisions[id] or 0),value=drafts[id] or "",placeholder="Текст для телефона",controlSize="sm",
          enabled=not snapshot.typeBusy,onChange=function(value) drafts[id]=value; render() end,onSubmit=submit}),
        ui.row({gap=6},{
          ui.button({text=snapshot.typeBusy and "Отправка…" or "Отправить",controlSize="sm",variant="secondary",enabled=not snapshot.typeBusy and (drafts[id] or "")~="",onClick=submit}),
          ui.button({text="Очистить",controlSize="sm",variant="ghost",enabled=not snapshot.typeBusy,
            onClick=function() drafts[id]=""; draftRevisions[id]=(draftRevisions[id] or 0)+1; render() end}),
          ui.button({text="Завершить печать",controlSize="sm",variant="ghost",enabled=not snapshot.sessionBusy,
            onClick=function() send("session",id,{kind="keyboard",on=false}) end}),
        }),
        ui.label({text="Отправлено. Черновик сохранён — проверьте ввод на телефоне.",fontFamily="sans-serif",fontSize=9,color="on_surface_variant",
          visible=not snapshot.typeBusy and snapshot.typeDeliveryDevice==id and drafts[id]==sentDrafts[id],maxLines=2}),
      }))
    else
    table.insert(body, ui.row({ gap = 10 }, {
      tile("camera", snapshot.cameraBusy and "Запуск…" or "Камера", "camera", "camera", online and not snapshot.cameraBusy,
        not online and unavailable or "Запустить камеру через NectarLink", selected,nil,false,math.floor((mainWidth-20)/3)),
      tile("webcam", activeSession(session,"webcam") and "Остановить камеру" or "Веб-камера", "video", "session", canSession("webcam"),
        "Запуск/остановка виртуальной камеры; установка драйверов не выполняется",selected,{kind="webcam",on=not activeSession(session,"webcam")},activeSession(session,"webcam"),math.floor((mainWidth-20)/3)),
      tile("typing", "Печать на телефоне", "keyboard", "session", canSession("keyboard"), "Включить ввод текста на выбранном телефоне",
        selected,{kind="keyboard",on=true},false,math.floor((mainWidth-20)/3)),
    }))
    end
  end
  local side = {}
  if showControls then table.insert(side, controlsCard(phone, online)) end
  if showControls and not confirmWifi and not hotspotMenu then table.insert(side,ringerCard(phone,online)) end
  if #notices > 0 and not activeSession(session,"keyboard") then
    local cards = { ui.row({gap=6,align="center",height=18},{
      ui.label({text="Уведомления · " .. tostring(#notices),fontFamily="sans-serif",fontSize=13,fontWeight="bold",flexGrow=1}),
      ui.row({gap=4,align="center",tooltip="Все уведомления в приложении",onClick=function() send("open") end},{
        label("Показать всё",11,"primary"),ui.glyph({name="external-link",size=13,color="primary"}),
      }),
    }) }
    for i, item in ipairs(notices) do
      if i > 1 then break end
      table.insert(cards, ui.column({ key = "notice-" .. tostring(item.key), gap = 2, padding = 8,
        height=80,clip=true,radius = 12, fill = "surface_container" }, {
        label(preview(type(item.appName) == "string" and item.appName or "Телефон", 48), 10, "primary"),
        label(preview(type(item.title) == "string" and item.title or "Уведомление", 60), 12, "on_surface", true),
        ui.label({ text = preview(item.text, 96), fontFamily = "sans-serif", fontSize = 11,
          height=28,maxLines = 2, color = "on_surface_variant" }),
      }))
    end
    table.insert(body,ui.spacer({key="notifications-spacer",flexGrow=1}))
    table.insert(body, ui.column({ key = "notifications", gap = 6, height=104,clip=true }, cards))
  end
  if showTimeline and not confirmWifi and not hotspotMenu then
    table.insert(side,ui.spacer({key="timeline-spacer",flexGrow=1}))
    table.insert(side, timeline(phone))
  end
  local content = { ui.column({ key = "content", gap = 8, width = mainWidth,height=PAGE_HEIGHT,clip=true }, body) }
  if sidebar then table.insert(content, ui.column({key="sidebar",width=260,height=PAGE_HEIGHT,gap=8,clip=true},side)) end
  renderFrame(header,content)
end
-- Read-only navigation hook for IPC/UI diagnostics; never dispatches an action.
function onNavigate(value)
  if not opened or not titles[value] then return end
  page=value; resetPage(); if page=="home" or page=="guide" then send("page_leave",nil,page) end; render()
end
function onIpc(event,value)
  if event=="navigate" then onNavigate(value) end
end
function onTileHover(state, key)
  local nextHover = hovered
  if state == "true" then nextHover = key elseif hovered == key then nextHover = nil end
  if nextHover ~= hovered then
    local old=hovered; hovered=nextHover
    if renderedTree and page=="apps" and (not old or appHoverNodes[old]) and (not nextHover or appHoverNodes[nextHover]) then
      if old then appHoverNodes[old].props.fill="transparent" end
      if nextHover then appHoverNodes[nextHover].props.fill="surface_container_high" end
      panel.render(renderedTree)
    else render() end
  end
end
noctalia.state.watch("nl.snapshot", function(raw)
  snapshot=decode(raw) or snapshot
  if snapshot.cacheEpoch~=lastCacheEpoch then lastCacheEpoch=snapshot.cacheEpoch; pageKey=nil end
  render()
end)
function onOpen()
  opened = true; hovered = nil; confirmWifi = nil; hotspotMenu = nil
  snapshot = decode(noctalia.state.get("nl.snapshot")) or snapshot
  pageKey=nil; send("visible", nil, {open=true,page=page}); render()
end
function onClose() opened = false; hovered = nil; pageKey=nil; pendingAction=nil; detail=nil; send("visible", nil, false) end
function onConfigChanged() render() end
